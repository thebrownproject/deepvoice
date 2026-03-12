import AVFoundation
import AppKit
import os

private let log = Logger(subsystem: "com.thebrownproject.deepvoice", category: "AudioManager")

enum AudioConstants {
    static let sampleRate: Double = 24000
    static let captureBufferSize: AVAudioFrameCount = 480
    static let channels: AVAudioChannelCount = 1

    static let pcm16Format: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: true
    )!
}

final class AudioManager: ObservableObject, @unchecked Sendable {
    @Published private(set) var isCapturing = false
    @Published private(set) var isPlaying = false
    @Published private(set) var permissionGranted = false

    var onPlaybackStarted: (@Sendable () -> Void)?

    private var captureEngine: AVAudioEngine?
    private var captureConverter: AVAudioConverter?
    private var captureMixerNode: AVAudioMixerNode?
    private let audioQueue = DispatchQueue(label: "com.deepvoice.audio-capture")
    private var capturing = false

    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackQueue = DispatchQueue(label: "com.deepvoice.audio-playback")
    private var playbackSuppressed = false
    private var playbackEpoch: UInt64 = 0
    private var samplesScheduled: UInt64 = 0
    private var samplesPlayed: UInt64 = 0

    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            updatePermission(true)
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            updatePermission(granted)
            return granted
        case .denied, .restricted:
            updatePermission(false)
            return false
        @unknown default:
            updatePermission(false)
            return false
        }
    }

    func preparePlayback() {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.ensurePlayerReady()
            } catch {
                log.error("Playback prewarm failed: \(error.localizedDescription)")
            }
        }
    }

    func startCapture(
        onCaptureStarted: (@Sendable () -> Void)? = nil,
        onAudioData: @escaping @Sendable (Data) -> Void
    ) {
        guard !isCapturing else { return }

        audioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.setupAndStart(onChunk: onAudioData)
                DispatchQueue.main.async { onCaptureStarted?() }
            } catch {
                log.error("Capture start failed: \(error.localizedDescription)")
                self.updateCaptureState(false)
            }
        }
    }

    func stopCapture() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.capturing = false
            self.teardownCapture()
        }
        updateCaptureState(false)
    }

    func suppressPlayback() {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            self.playbackSuppressed = true
            self.playbackEpoch &+= 1
            self.samplesScheduled = 0
            self.samplesPlayed = 0
            self.playerNode?.stop()
            self.playerNode?.reset()
            self.updatePlaybackState(false)
            let epoch = self.playbackEpoch
            log.debug("Playback suppressed (epoch \(epoch))")
        }
    }

    func resumePlayback() {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            self.playbackSuppressed = false
            do {
                try self.ensurePlayerReady()
            } catch {
                log.error("Playback resume failed: \(error.localizedDescription)")
            }
        }
    }

    func stopPlayback() {
        suppressPlayback()
    }

    func shutdown() {
        stopCapture()
        playbackQueue.async { [weak self] in
            guard let self else { return }
            self.teardownPlayback()
        }
        updatePlaybackState(false)
    }

    /// Safe to call from any thread -- all work is dispatched to playbackQueue.
    nonisolated func enqueueAudio(data: Data) {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            guard !self.playbackSuppressed else { return }

            do {
                try self.ensurePlayerReady()
            } catch {
                log.error("Playback engine setup failed: \(error.localizedDescription)")
                return
            }

            guard let player = self.playerNode,
                  let buffer = Self.pcm16DataToBuffer(data) else { return }

            let epoch = self.playbackEpoch
            let scheduled = UInt64(buffer.frameLength)
            let wasIdle = self.samplesPlayed >= self.samplesScheduled
            self.samplesScheduled += scheduled

            if wasIdle {
                self.updatePlaybackState(true)
                DispatchQueue.main.async { [weak self] in
                    self?.onPlaybackStarted?()
                }
            }

            player.scheduleBuffer(buffer) { [weak self] in
                self?.playbackQueue.async {
                    guard let self, self.playbackEpoch == epoch else { return }
                    self.samplesPlayed += scheduled
                    if self.samplesPlayed >= self.samplesScheduled {
                        self.updatePlaybackState(false)
                    }
                }
            }

            if !player.isPlaying {
                player.play()
            }
        }
    }

    private func ensurePlayerReady() throws {
        let engine: AVAudioEngine
        if let existing = playbackEngine {
            engine = existing
        } else {
            let created = AVAudioEngine()
            playbackEngine = created
            engine = created
        }

        if playerNode == nil {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: AudioConstants.pcm16Format)
            playerNode = player
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        if let player = playerNode, !player.isPlaying, !playbackSuppressed {
            player.play()
        }
    }

    private static func pcm16DataToBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let bytesPerSample = 2
        let frameCount = AVAudioFrameCount(data.count / bytesPerSample)
        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioConstants.pcm16Format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        guard let channelData = buffer.int16ChannelData else { return nil }
        data.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            memcpy(channelData[0], src, data.count)
        }
        return buffer
    }

    private func setupAndStart(onChunk: @escaping @Sendable (Data) -> Void) throws {
        teardownCapture()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioConstants.sampleRate,
            channels: AudioConstants.channels,
            interleaved: false
        ) else {
            throw AudioCaptureError.invalidInputFormat
        }

        let captureFormat: AVAudioFormat
        if inputFormat.channelCount > 1 {
            captureFormat = AVAudioFormat(
                standardFormatWithSampleRate: inputFormat.sampleRate,
                channels: 1
            ) ?? inputFormat
        } else {
            captureFormat = inputFormat
        }

        let mixer = AVAudioMixerNode()
        mixer.volume = 1.0
        engine.attach(mixer)
        engine.connect(input, to: mixer, format: captureFormat)

        let audioConverter: AVAudioConverter?
        if captureFormat != targetFormat {
            audioConverter = AVAudioConverter(from: captureFormat, to: targetFormat)
            guard audioConverter != nil else {
                throw AudioCaptureError.converterCreationFailed
            }
        }

        mixer.installTap(
            onBus: 0,
            bufferSize: AudioConstants.captureBufferSize,
            format: captureFormat
        ) { [weak self, audioConverter, targetFormat] buffer, _ in
            self?.audioQueue.async { [weak self] in
                guard let self, self.capturing else { return }

                let floatBuffer: AVAudioPCMBuffer
                if let conv = audioConverter {
                    guard let converted = Self.convert(buffer: buffer, using: conv, to: targetFormat) else {
                        return
                    }
                    floatBuffer = converted
                } else {
                    floatBuffer = buffer
                }

                guard let pcmData = Self.float32ToPCM16Data(floatBuffer) else { return }
                onChunk(pcmData)
            }
        }

        engine.prepare()
        try engine.start()

        captureEngine = engine
        captureMixerNode = mixer
        captureConverter = audioConverter
        capturing = true
        updateCaptureState(true)

        log.info("Capture started: \(inputFormat.channelCount)ch \(Int(inputFormat.sampleRate))Hz -> 24kHz PCM16 mono")
    }

    private func teardownCapture() {
        captureMixerNode?.removeTap(onBus: 0)
        if let mixer = captureMixerNode, let engine = captureEngine {
            engine.disconnectNodeInput(mixer)
            engine.detach(mixer)
        }
        captureMixerNode = nil
        captureConverter = nil
        captureEngine?.stop()
        captureEngine = nil
    }

    private func teardownPlayback() {
        playbackSuppressed = true
        playbackEpoch &+= 1
        samplesScheduled = 0
        samplesPlayed = 0
        playerNode?.stop()
        playerNode?.reset()
        playbackEngine?.stop()
        playerNode = nil
        playbackEngine = nil
    }

    private static func convert(
        buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = Float(targetFormat.sampleRate) / Float(buffer.format.sampleRate)
        let frameCount = AVAudioFrameCount(Float(buffer.frameLength) * ratio)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
            return nil
        }
        output.frameLength = frameCount

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            log.error("Audio conversion failed: \(error.localizedDescription)")
            return nil
        }
        return output
    }

    private static func float32ToPCM16Data(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let samples = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        var data = Data(count: count * 2)
        data.withUnsafeMutableBytes { raw in
            let int16 = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let clamped = max(-32768, min(32767, Int32(samples[i] * 32767.0)))
                int16[i] = Int16(clamped).littleEndian
            }
        }
        return data
    }

    private func updatePermission(_ granted: Bool) {
        if Thread.isMainThread {
            permissionGranted = granted
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.permissionGranted = granted
            }
        }
    }

    private func updateCaptureState(_ capturing: Bool) {
        if Thread.isMainThread {
            isCapturing = capturing
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.isCapturing = capturing
            }
        }
    }

    private func updatePlaybackState(_ playing: Bool) {
        if Thread.isMainThread {
            isPlaying = playing
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.isPlaying = playing
            }
        }
    }
}

enum AudioCaptureError: LocalizedError {
    case invalidInputFormat
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "Audio input format has zero channels or sample rate"
        case .converterCreationFailed:
            return "Failed to create AVAudioConverter for sample rate conversion"
        }
    }
}
