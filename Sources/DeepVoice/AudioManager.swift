@preconcurrency import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import os

private let log = Logger(subsystem: "com.thebrownproject.deepvoice", category: "AudioManager")
private let captureInputProc: AURenderCallback = { refCon, ioActionFlags, timeStamp, busNumber, frameCount, _ in
    let manager = Unmanaged<AudioManager>.fromOpaque(refCon).takeUnretainedValue()
    return manager.handleCaptureInput(
        ioActionFlags: ioActionFlags,
        timeStamp: timeStamp,
        busNumber: busNumber,
        frameCount: frameCount
    )
}

enum AudioConstants {
    static let sampleRate: Double = 24000
    static let voiceProcessingSampleRate: Double = 44100
    static let captureBufferSize: AVAudioFrameCount = 1024
    static let channels: AVAudioChannelCount = 1

    static let floatFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: false
    )!

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
    private let routeModeQueue = DispatchQueue(label: "com.deepvoice.audio-route-mode")
    private var routeMode: AudioRouteMode = .highQualityOutput

    private func notifyState() {
        let capturing = isCapturing
        let playing = isPlaying
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(capturing, playing)
        }
    }

    // Capture uses a dedicated HAL input unit so we never touch AVAudioEngine.inputNode,
    // which can bind the graph to the system default input and flip Bluetooth output into HFP.
    private var captureOutputUnit: AudioUnit?
    private var converter: AVAudioConverter?
    private var captureSourceFormat: AVAudioFormat?
    private var captureTargetFormat: AVAudioFormat?
    private let audioQueue = DispatchQueue(label: "com.deepvoice.audio-capture")
    private var capturing = false

    private var playbackEngine: AVAudioEngine?
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

    func setRouteMode(_ mode: AudioRouteMode) {
        routeModeQueue.sync {
            routeMode = mode
        }
    }

    /// Called on main thread when capture fails to start.
    var onCaptureError: ((_ message: String) -> Void)?

    func startCapture(onAudioData: @escaping @Sendable (Data) -> Void) {
        let mode = currentRouteMode()
        audioQueue.async { [weak self] in
            guard let self else { return }
            do {
                switch mode {
                case .highQualityOutput:
                    try self.setupAndStartHighQuality(onChunk: onAudioData)
                case .headsetConversation:
                    try self.setupAndStartHeadsetVPIO(onChunk: onAudioData)
                }
            } catch {
                let msg = "Capture start failed (\(mode.rawValue)): \(error.localizedDescription)"
                log.error("\(msg)")
                self.isCapturing = false
                let errorCallback = self.onCaptureError
                DispatchQueue.main.async { errorCallback?(msg) }
            }
        }
    }

    func stopCapture() {
        playbackQueue.sync { [weak self] in
            guard let self else { return }
            self.playbackEpoch &+= 1
            self.samplesScheduled = 0
            self.samplesPlayed = 0
            self.teardownPlayback()
            self.isPlaying = false
        }
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.capturing = false
            self.isCapturing = false
            self.teardownCapture()
        }
    }

    func stopInputCapture() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.capturing = false
            self.isCapturing = false
            self.teardownCapture()
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

    private func currentRouteMode() -> AudioRouteMode {
        routeModeQueue.sync {
            routeMode
        }
    }

    // MARK: - Playback internals (called on playbackQueue)

    private func ensurePlayerReady() throws {
        let engine: AVAudioEngine
        if let existing = self.playbackEngine {
            engine = existing
        } else {
            engine = AVAudioEngine()
            self.playbackEngine = engine
        }

        // If the player was detached, discard it
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

    /// Prefer a built-in mic, then any non-Bluetooth input device, so capture does not
    /// pull AirPods into HFP and degrade system output quality.
    private func findPreferredInputDeviceID() -> AudioDeviceID? {
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

        var fallbackDevice: AudioDeviceID?

        for device in devices {
            guard inputChannelCount(for: device) > 0 else { continue }

            let transportType = transportType(for: device)
            if transportType == kAudioDeviceTransportTypeBuiltIn {
                log.info("Using built-in input device: \(self.deviceName(for: device)) (\(device))")
                return device
            }

            if transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE {
                continue
            }

            if fallbackDevice == nil {
                fallbackDevice = device
            }
        }

        if let fallbackDevice {
            log.info("Using non-Bluetooth input device: \(self.deviceName(for: fallbackDevice)) (\(fallbackDevice))")
        }
        return fallbackDevice
    }

    private func inputChannelCount(for device: AudioDeviceID) -> Int {
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &inputAddress, 0, nil, &inputSize) == noErr, inputSize > 0 else {
            return 0
        }

        let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferListPtr.deallocate() }

        guard AudioObjectGetPropertyData(device, &inputAddress, 0, nil, &inputSize, bufferListPtr) == noErr else {
            return 0
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    // MARK: - Capture internals (called on audioQueue)

    private func setupAndStartHighQuality(onChunk: @escaping @Sendable (Data) -> Void) throws {
        teardownInput()

        guard let deviceID = findPreferredInputDeviceID() else {
            throw AudioCaptureError.noSuitableInputDevice
        }

        let deviceFormat = try inputStreamDescription(for: deviceID)
        guard deviceFormat.mSampleRate > 0, deviceFormat.mChannelsPerFrame > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }

        guard let captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: deviceFormat.mSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.invalidInputFormat
        }

        var audioConverter: AVAudioConverter?
        if captureFormat != AudioConstants.floatFormat {
            audioConverter = AVAudioConverter(from: captureFormat, to: AudioConstants.floatFormat)
            guard audioConverter != nil else {
                throw AudioCaptureError.converterCreationFailed
            }
        }

        let outputUnit = try makeHALInputUnit()
        try configureCaptureUnit(
            outputUnit,
            deviceID: deviceID,
            deviceFormat: deviceFormat,
            clientFormat: captureFormat
        )

        self.converter = audioConverter
        self.captureOutputUnit = outputUnit
        self.captureSourceFormat = captureFormat
        self.captureTargetFormat = AudioConstants.floatFormat
        self.capturing = true
        self.isCapturing = true
        self.captureHandler = onChunk

        let startStatus = AudioOutputUnitStart(outputUnit)
        if startStatus != noErr {
            self.capturing = false
            self.isCapturing = false
            self.teardownInput()
            throw AudioCaptureError.operationFailed("AudioOutputUnitStart", startStatus)
        }

        log.info("Capture started: \(self.deviceName(for: deviceID)) \(Int(deviceFormat.mSampleRate))Hz -> 24kHz PCM16 mono")
    }

    private func setupAndStartHeadsetVPIO(onChunk: @escaping @Sendable (Data) -> Void) throws {
        teardownInput()
        try prewarmPlaybackEngine()
        let inputDeviceID = defaultInputDeviceID()

        guard let captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioConstants.voiceProcessingSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioCaptureError.invalidInputFormat
        }

        var audioConverter: AVAudioConverter?
        if captureFormat != AudioConstants.pcm16Format {
            audioConverter = AVAudioConverter(from: captureFormat, to: AudioConstants.pcm16Format)
            guard audioConverter != nil else {
                throw AudioCaptureError.converterCreationFailed
            }
        }

        let outputUnit = try makeVoiceProcessingInputUnit()
        try configureVoiceProcessingCaptureUnit(outputUnit, clientFormat: captureFormat)

        self.converter = audioConverter
        self.captureOutputUnit = outputUnit
        self.captureSourceFormat = captureFormat
        self.captureTargetFormat = AudioConstants.pcm16Format
        self.capturing = true
        self.isCapturing = true
        self.captureHandler = onChunk

        let startStatus = AudioOutputUnitStart(outputUnit)
        if startStatus != noErr {
            self.capturing = false
            self.isCapturing = false
            self.teardownInput()
            throw AudioCaptureError.operationFailed("AudioOutputUnitStart", startStatus)
        }

        let inputName = inputDeviceID.map(deviceName(for:)) ?? "system default input"
        log.info("Capture started: headset conversation mode via \(inputName) \(Int(AudioConstants.voiceProcessingSampleRate))Hz -> 24kHz PCM16 mono")
    }

    private func teardownInput() {
        captureHandler = nil

        if let outputUnit = captureOutputUnit {
            let stopStatus = AudioOutputUnitStop(outputUnit)
            if stopStatus != noErr {
                log.warning("AudioOutputUnitStop failed: OSStatus \(stopStatus)")
            }
            let uninitializeStatus = AudioUnitUninitialize(outputUnit)
            if uninitializeStatus != noErr, uninitializeStatus != kAudioUnitErr_Uninitialized {
                log.warning("AudioUnitUninitialize failed: OSStatus \(uninitializeStatus)")
            }
            let disposeStatus = AudioComponentInstanceDispose(outputUnit)
            if disposeStatus != noErr {
                log.warning("AudioComponentInstanceDispose failed: OSStatus \(disposeStatus)")
            }
        }

        converter = nil
        captureSourceFormat = nil
        captureTargetFormat = nil
        captureOutputUnit = nil
    }

    private func teardownCapture() {
        teardownInput()
    }

    private func teardownPlayback() {
        playerNode?.stop()
        playerNode = nil
        playbackFormat = nil
        playbackConverter = nil
        playbackEngine?.stop()
        playbackEngine = nil
    }

    private func teardown() {
        teardownCapture()
        teardownPlayback()
    }

    private var captureHandler: (@Sendable (Data) -> Void)?

    private func prewarmPlaybackEngine() throws {
        var caughtError: Error?
        playbackQueue.sync {
            do {
                try self.ensurePlayerReady()
            } catch {
                caughtError = error
            }
        }

        if let caughtError {
            throw caughtError
        }
    }

    private func makeCaptureOutputUnit(subType: OSType) throws -> AudioUnit {
        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw AudioCaptureError.audioComponentUnavailable
        }

        var audioUnit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let audioUnit else {
            throw AudioCaptureError.operationFailed("AudioComponentInstanceNew", status)
        }

        return audioUnit
    }

    private func makeVoiceProcessingInputUnit() throws -> AudioUnit {
        try makeCaptureOutputUnit(subType: kAudioUnitSubType_VoiceProcessingIO)
    }

    private func makeHALInputUnit() throws -> AudioUnit {
        try makeCaptureOutputUnit(subType: kAudioUnitSubType_HALOutput)
    }

    private func configureCaptureUnit(
        _ outputUnit: AudioUnit,
        deviceID: AudioDeviceID,
        deviceFormat: AudioStreamBasicDescription,
        clientFormat: AVAudioFormat
    ) throws {
        var enableInput: UInt32 = 1
        try requireNoErr(
            AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enableInput,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            operation: "AudioUnitSetProperty(EnableInput)"
        )

        var disableOutput: UInt32 = 0
        try requireNoErr(
            AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &disableOutput,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            operation: "AudioUnitSetProperty(DisableOutput)"
        )

        var currentDevice = deviceID
        try requireNoErr(
            AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &currentDevice,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            operation: "AudioUnitSetProperty(CurrentDevice)"
        )

        var callback = AURenderCallbackStruct(
            inputProc: captureInputProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try requireNoErr(
            AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            operation: "AudioUnitSetProperty(SetInputCallback)"
        )

        if deviceFormat.mChannelsPerFrame > 1 {
            var channelMap: [Int32] = [0]
            try requireNoErr(
                AudioUnitSetProperty(
                    outputUnit,
                    kAudioOutputUnitProperty_ChannelMap,
                    kAudioUnitScope_Output,
                    1,
                    &channelMap,
                    UInt32(MemoryLayout<Int32>.size * channelMap.count)
                ),
                operation: "AudioUnitSetProperty(ChannelMap)"
            )
        }

        var clientStreamFormat = clientFormat.streamDescription.pointee
        try requireNoErr(
            AudioUnitSetProperty(
                outputUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &clientStreamFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            operation: "AudioUnitSetProperty(StreamFormat)"
        )

        try requireNoErr(AudioUnitInitialize(outputUnit), operation: "AudioUnitInitialize")
    }

    private func configureVoiceProcessingCaptureUnit(
        _ outputUnit: AudioUnit,
        clientFormat: AVAudioFormat
    ) throws {
        var enableInput: UInt32 = 1
        try requireNoErr(
            AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enableInput,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            operation: "AudioUnitSetProperty(EnableInput)"
        )

        var disableOutput: UInt32 = 0
        try requireNoErr(
            AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &disableOutput,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            operation: "AudioUnitSetProperty(DisableOutput)"
        )

        var callback = AURenderCallbackStruct(
            inputProc: captureInputProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try requireNoErr(
            AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                1,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            operation: "AudioUnitSetProperty(SetInputCallback)"
        )

        var clientStreamFormat = clientFormat.streamDescription.pointee
        try requireNoErr(
            AudioUnitSetProperty(
                outputUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &clientStreamFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            operation: "AudioUnitSetProperty(StreamFormat)"
        )

        try requireNoErr(AudioUnitInitialize(outputUnit), operation: "AudioUnitInitialize")
    }

    fileprivate func handleCaptureInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
        timeStamp: UnsafePointer<AudioTimeStamp>?,
        busNumber _: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard capturing,
              let outputUnit = captureOutputUnit,
              let sourceFormat = captureSourceFormat,
              let timeStamp,
              frameCount > 0 else {
            return noErr
        }

        let bytesPerFrame = Int(sourceFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(frameCount) * max(bytesPerFrame, 1)
        let bufferMemory = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: max(MemoryLayout<Float>.alignment, MemoryLayout<Int16>.alignment)
        )
        defer { bufferMemory.deallocate() }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferList.deallocate() }

        bufferList.pointee.mNumberBuffers = 1
        bufferList.pointee.mBuffers.mNumberChannels = 1
        bufferList.pointee.mBuffers.mDataByteSize = UInt32(byteCount)
        bufferList.pointee.mBuffers.mData = bufferMemory

        let renderStatus = AudioUnitRender(
            outputUnit,
            ioActionFlags,
            timeStamp,
            1,
            frameCount,
            bufferList
        )
        guard renderStatus == noErr else {
            return renderStatus
        }

        let capturedData = Data(bytes: bufferMemory, count: byteCount)
        let handler = captureHandler
        audioQueue.async { [weak self] in
            guard let self, self.capturing, let handler else { return }
            self.processCapturedAudio(
                capturedData,
                frameCount: AVAudioFrameCount(frameCount),
                sourceFormat: sourceFormat,
                onChunk: handler
            )
        }

        return noErr
    }

    private func processCapturedAudio(
        _ capturedData: Data,
        frameCount: AVAudioFrameCount,
        sourceFormat: AVAudioFormat,
        onChunk: @escaping @Sendable (Data) -> Void
    ) {
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            return
        }
        sourceBuffer.frameLength = frameCount

        capturedData.withUnsafeBytes { rawBuffer in
            guard let src = rawBuffer.baseAddress else { return }

            switch sourceFormat.commonFormat {
            case .pcmFormatFloat32:
                guard let channelData = sourceBuffer.floatChannelData?[0] else { return }
                memcpy(channelData, src, capturedData.count)
            case .pcmFormatInt16:
                guard let channelData = sourceBuffer.int16ChannelData?[0] else { return }
                memcpy(channelData, src, capturedData.count)
            default:
                break
            }
        }

        let targetBuffer: AVAudioPCMBuffer
        if let converter, let captureTargetFormat {
            guard let converted = convert(buffer: sourceBuffer, using: converter, to: captureTargetFormat) else {
                return
            }
            targetBuffer = converted
        } else {
            targetBuffer = sourceBuffer
        }

        switch targetBuffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let pcmData = float32ToPCM16Data(targetBuffer) else { return }
            onChunk(pcmData)
        case .pcmFormatInt16:
            guard let pcmData = pcm16BufferToData(targetBuffer) else { return }
            onChunk(pcmData)
        default:
            return
        }
    }

    private func requireNoErr(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw AudioCaptureError.operationFailed(operation, status)
        }
    }

    private func transportType(for device: AudioDeviceID) -> UInt32 {
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &size, &transportType)
        return status == noErr ? transportType : kAudioDeviceTransportTypeUnknown
    }

    private func deviceName(for device: AudioDeviceID) -> String {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<CFString?>.alignment
        )
        storage.initializeMemory(as: CFString?.self, repeating: nil, count: 1)
        defer {
            storage.assumingMemoryBound(to: CFString?.self).deinitialize(count: 1)
            storage.deallocate()
        }

        let status = AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &size, storage)
        let name = storage.assumingMemoryBound(to: CFString?.self).pointee
        return status == noErr ? ((name as String?) ?? "Unknown Device") : "Unknown Device"
    }

    private func inputStreamDescription(for device: AudioDeviceID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &description)
        guard status == noErr else {
            throw AudioCaptureError.operationFailed("AudioObjectGetPropertyData(StreamFormat)", status)
        }
        return description
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

    private func pcm16BufferToData(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let samples = buffer.int16ChannelData?[0] else { return nil }
        let byteCount = Int(buffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: samples, count: byteCount)
    }
}

enum AudioCaptureError: LocalizedError {
    case noSuitableInputDevice
    case audioComponentUnavailable
    case invalidInputFormat
    case converterCreationFailed
    case operationFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noSuitableInputDevice:
            return "No built-in or non-Bluetooth input device is available for capture"
        case .audioComponentUnavailable:
            return "The HAL output audio component is unavailable"
        case .invalidInputFormat:
            return "Audio input format has zero channels or sample rate"
        case .converterCreationFailed:
            return "Failed to create AVAudioConverter for sample rate conversion"
        case .operationFailed(let operation, let status):
            return "\(operation) failed with OSStatus \(status)"
        }
    }
}
