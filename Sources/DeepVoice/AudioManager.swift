@preconcurrency import AVFoundation
import AppKit
import CoreAudio
import os

private let log = Logger(subsystem: "com.thebrownproject.deepvoice", category: "AudioManager")

enum AudioConstants {
    static let sampleRate: Double = 24000
    static let captureBufferSize: AVAudioFrameCount = 1024
    static let channels: AVAudioChannelCount = 1

    static let pcm16Format: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: true
    )!
}

/// Audio capture and playback manager.
///
/// Uses `@unchecked Sendable` with manual queue synchronization instead of
/// `@MainActor`, because audio capture taps and playback completion handlers
/// fire on background threads. Published state is forwarded to MainActor
/// via `DispatchQueue.main.async`.
final class AudioManager: @unchecked Sendable {
    /// Called on main thread whenever capture/playback state changes.
    var onStateChange: ((_ isCapturing: Bool, _ isPlaying: Bool) -> Void)?

    private(set) var isCapturing = false {
        didSet { notifyState() }
    }
    private(set) var isPlaying = false {
        didSet { notifyState() }
    }
    private(set) var permissionGranted = false

    private func notifyState() {
        let capturing = isCapturing
        let playing = isPlaying
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(capturing, playing)
        }
    }

    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var mixerNode: AVAudioMixerNode?
    private let audioQueue = DispatchQueue(label: "com.deepvoice.audio-capture")
    private var capturing = false

    private var playerNode: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var playbackConverter: AVAudioConverter?
    private let playbackQueue = DispatchQueue(label: "com.deepvoice.audio-playback")
    private var playbackEpoch: UInt64 = 0
    private var samplesScheduled: UInt64 = 0
    private var samplesPlayed: UInt64 = 0

    @MainActor
    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            permissionGranted = true
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            permissionGranted = granted
            return granted
        case .denied, .restricted:
            permissionGranted = false
            return false
        @unknown default:
            permissionGranted = false
            return false
        }
    }

    func startCapture(onAudioData: @escaping @Sendable (Data) -> Void) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.setupAndStart(onChunk: onAudioData)
            } catch {
                log.error("Capture start failed: \(error.localizedDescription)")
                self.isCapturing = false
            }
        }
    }

    func stopCapture() {
        playbackQueue.sync { [weak self] in
            guard let self else { return }
            self.playbackEpoch &+= 1
            self.samplesScheduled = 0
            self.samplesPlayed = 0
            self.playerNode?.stop()
            self.playerNode = nil
            self.playbackFormat = nil
            self.playbackConverter = nil
        }
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.capturing = false
            self.isCapturing = false
            self.isPlaying = false
            self.teardown()
        }
    }

    func stopInputCapture() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.capturing = false
            self.isCapturing = false
            self.teardownInput()
        }
    }

    /// Safe to call from any thread -- all work is dispatched to playbackQueue.
    func enqueueAudio(data: Data) {
        playbackQueue.async { [weak self] in
            guard let self else { return }

            do {
                try self.ensurePlayerReady()
            } catch {
                log.error("Playback engine setup failed: \(error.localizedDescription)")
                return
            }

            guard let player = self.playerNode,
                  let srcBuffer = self.pcm16DataToBuffer(data) else { return }

            // Convert from 24kHz PCM16 to native output format
            let buffer: AVAudioPCMBuffer
            if let conv = self.playbackConverter, let fmt = self.playbackFormat {
                guard let converted = self.convertPlayback(buffer: srcBuffer, using: conv, to: fmt) else { return }
                buffer = converted
            } else {
                buffer = srcBuffer
            }

            let epoch = self.playbackEpoch
            let scheduled = UInt64(buffer.frameLength)
            self.samplesScheduled += scheduled

            let wasIdle = self.samplesPlayed >= (self.samplesScheduled - scheduled)
            if wasIdle {
                self.isPlaying = true
            }

            player.scheduleBuffer(buffer) { [weak self] in
                self?.playbackQueue.async {
                    guard let self, self.playbackEpoch == epoch else { return }
                    self.samplesPlayed += scheduled
                    if self.samplesPlayed >= self.samplesScheduled {
                        self.isPlaying = false
                    }
                }
            }
        }
    }

    func stopPlayback() {
        playbackQueue.async { [weak self] in
            guard let self else { return }
            self.playbackEpoch &+= 1
            self.samplesScheduled = 0
            self.samplesPlayed = 0
            self.playerNode?.stop()
            self.isPlaying = false
            log.debug("Playback stopped (epoch \(self.playbackEpoch))")
        }
    }

    // MARK: - Playback internals (called on playbackQueue)

    private func ensurePlayerReady() throws {
        let engine: AVAudioEngine
        if let existing = self.audioEngine {
            engine = existing
        } else {
            engine = AVAudioEngine()
            self.audioEngine = engine
        }

        // If the player was detached (e.g. by teardown on audioQueue), discard it
        if let existing = playerNode, !engine.attachedNodes.contains(existing) {
            playerNode = nil
            playbackFormat = nil
            playbackConverter = nil
        }

        if playerNode == nil {
            let wasRunning = engine.isRunning
            if wasRunning { engine.stop() }

            // Connect at the engine's native output format (e.g. 48kHz float32)
            // to avoid forcing the entire system to 24kHz
            let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: outputFormat.sampleRate,
                channels: 1,
                interleaved: false
            )!

            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: targetFormat)
            self.playerNode = player
            self.playbackFormat = targetFormat
            self.playbackConverter = AVAudioConverter(from: AudioConstants.pcm16Format, to: targetFormat)

            engine.prepare()
            try engine.start()
            player.play()
            log.info("Playback: \(Int(targetFormat.sampleRate))Hz float32 -> output")
            return
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        if let player = playerNode, !player.isPlaying {
            player.play()
        }
    }

    private func convertPlayback(
        buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / AudioConstants.sampleRate
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
            return nil
        }

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
            log.error("Playback conversion failed: \(error.localizedDescription)")
            return nil
        }
        return output
    }

    private func pcm16DataToBuffer(_ data: Data) -> AVAudioPCMBuffer? {
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

    // MARK: - Input device selection

    /// Find the built-in microphone device ID to avoid triggering Bluetooth HFP mode
    /// (which degrades all system audio to phone quality when AirPods mic is used).
    private func findBuiltInMicDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &devices) == noErr else { return nil }

        for device in devices {
            // Check if it has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &inputAddress, 0, nil, &inputSize) == noErr, inputSize > 0 else { continue }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            guard AudioObjectGetPropertyData(device, &inputAddress, 0, nil, &inputSize, bufferListPtr) == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            // Check transport type - built-in devices have kAudioDeviceTransportTypeBuiltIn
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transportType: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transportType) == noErr else { continue }

            if transportType == kAudioDeviceTransportTypeBuiltIn {
                log.info("Found built-in mic: device ID \(device)")
                return device
            }
        }
        return nil
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) {
        let inputNode = engine.inputNode
        let audioUnit = inputNode.audioUnit!

        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            log.info("Set input device to built-in mic (ID: \(deviceID))")
        } else {
            log.warning("Failed to set input device: OSStatus \(status)")
        }
    }

    // MARK: - Capture internals (called on audioQueue)

    private func setupAndStart(onChunk: @escaping @Sendable (Data) -> Void) throws {
        teardownInput()

        let engine: AVAudioEngine
        if let existing = self.audioEngine {
            engine = existing
        } else {
            engine = AVAudioEngine()
        }

        // Use built-in mic to prevent Bluetooth switching to HFP (phone quality)
        if let builtInMic = findBuiltInMicDeviceID() {
            setInputDevice(builtInMic, on: engine)
        }

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

        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }

        let mixer = AVAudioMixerNode()
        mixer.volume = 1.0
        engine.attach(mixer)
        engine.connect(input, to: mixer, format: captureFormat)

        var audioConverter: AVAudioConverter?
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
        ) { [weak self] buffer, _ in
            self?.audioQueue.async { [weak self] in
                guard let self, self.capturing else { return }

                let floatBuffer: AVAudioPCMBuffer
                if let conv = audioConverter {
                    guard let converted = self.convert(buffer: buffer, using: conv, to: targetFormat) else {
                        return
                    }
                    floatBuffer = converted
                } else {
                    floatBuffer = buffer
                }

                guard let pcmData = self.float32ToPCM16Data(floatBuffer) else { return }
                onChunk(pcmData)
            }
        }

        engine.prepare()
        try engine.start()

        if wasRunning, let player = self.playerNode, !player.isPlaying {
            player.play()
        }

        self.audioEngine = engine
        self.mixerNode = mixer
        self.converter = audioConverter
        self.capturing = true
        self.isCapturing = true

        log.info("Capture started: \(inputFormat.channelCount)ch \(Int(inputFormat.sampleRate))Hz -> 24kHz PCM16 mono")
    }

    private func teardownInput() {
        mixerNode?.removeTap(onBus: 0)
        if let mixer = mixerNode, let engine = audioEngine {
            engine.disconnectNodeInput(mixer)
            engine.detach(mixer)
        }
        mixerNode = nil
        converter = nil
    }

    private func teardown() {
        teardownInput()
        playerNode?.stop()
        playerNode = nil
        audioEngine?.stop()
        audioEngine = nil
    }

    private func convert(
        buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = Float(targetFormat.sampleRate) / Float(buffer.format.sampleRate)
        let frameCount = AVAudioFrameCount(Float(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
            return nil
        }

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

    private func float32ToPCM16Data(_ buffer: AVAudioPCMBuffer) -> Data? {
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
