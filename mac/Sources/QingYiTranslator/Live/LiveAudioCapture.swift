import AVFoundation
import CoreAudio
import CoreMedia
import QingYiCore
import ScreenCaptureKit

/// A source of 16 kHz mono samples. `onSamples` is called on an audio thread.
protocol LiveAudioSource: AnyObject {
    var onSamples: (([Float]) -> Void)? { get set }
    /// The device stopped by itself (unplugged, permission revoked…).
    var onStopped: ((Error?) -> Void)? { get set }
    func start() async throws
    func stop()
}

struct LiveAudioError: Error, LocalizedError {
    enum Kind { case microphone, systemAudio, screenRecordingPermission }

    let kind: Kind
    let message: String

    var errorDescription: String? { message }
}

/// Converts any PCM buffer to 16 kHz mono Float32 samples, keeping the resampler's state between calls.
final class MonoResampler {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if converter == nil || inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: MonoResampler.format)
            converter?.downmix = true
            inputFormat = buffer.format
        }
        guard let converter, buffer.frameLength > 0 else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: MonoResampler.format, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// Wraps 16 kHz mono samples in a buffer, e.g. for SFSpeechAudioBufferRecognitionRequest.
    static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}

// MARK: - Microphone

/// A microphone through AVAudioEngine, optionally a specific device rather than the system default.
final class MicrophoneCapture: LiveAudioSource, @unchecked Sendable {
    var onSamples: (([Float]) -> Void)?
    var onStopped: ((Error?) -> Void)?

    private let engine = AVAudioEngine()
    private let resampler = MonoResampler()
    private let deviceUID: String?
    private var observer: NSObjectProtocol?

    init(deviceUID: String?) {
        self.deviceUID = deviceUID
    }

    func start() async throws {
        let input = engine.inputNode
        if let deviceUID, let device = AudioDevices.deviceID(forUID: deviceUID) {
            do {
                try input.auAudioUnit.setDeviceID(device)
            } catch {
                Log.error("无法选择麦克风 \(deviceUID)，改用系统默认麦克风", error)
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw LiveAudioError(kind: .microphone, message: L("没有找到可用的麦克风。", "No microphone is available."))
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = resampler.convert(buffer)
            if !samples.isEmpty {
                onSamples?(samples)
            }
        }
        // Unplugging the device or changing its format stops the engine.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.onStopped?(nil)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw LiveAudioError(kind: .microphone, message: L("无法打开麦克风：\(error.localizedDescription)", "Couldn’t open the microphone: \(error.localizedDescription)"))
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: - System audio, macOS 14.2+

/// Records what the Mac plays through a Core Audio process tap (macOS 14.2+). The first start asks for the
/// "System Audio Recording" permission (NSAudioCaptureUsageDescription); without it the tap delivers silence.
@available(macOS 14.2, *)
final class ProcessTapCapture: LiveAudioSource, @unchecked Sendable {
    var onSamples: (([Float]) -> Void)?
    var onStopped: ((Error?) -> Void)?

    private let queue = DispatchQueue(label: "com.jingxuanwh.QingYiTranslator.tap", qos: .userInitiated)
    private let resampler = MonoResampler()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    func start() async throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), L("无法录制系统声音", "Couldn’t record the system audio"))
        tapID = tap

        do {
            let outputUID = try AudioDevices.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "QingYi Translator",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice), L("无法录制系统声音", "Couldn’t record the system audio"))
            aggregateID = aggregateDevice

            var streamDescription = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription), L("无法读取系统声音的格式", "Couldn’t read the system audio format"))
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw LiveAudioError(kind: .systemAudio, message: L("系统声音的格式不受支持。", "The system audio format isn’t supported."))
            }

            let resampler = self.resampler
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
                let samples = resampler.convert(buffer)
                if !samples.isEmpty {
                    self?.onSamples?(samples)
                }
            }, L("无法录制系统声音", "Couldn’t record the system audio"))
            try check(AudioDeviceStart(aggregateID, procID), L("无法录制系统声音", "Couldn’t record the system audio"))
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus, _ message: String) throws {
        if status != noErr {
            Log.error("\(message)（OSStatus \(status)）")
            throw LiveAudioError(kind: .systemAudio, message: "\(message)（\(status)）")
        }
    }
}

// MARK: - System audio, macOS 13–14.1

/// Records what the Mac plays through ScreenCaptureKit, for systems without process taps. Needs the
/// Screen Recording permission (granted in System Settings, then the app has to be reopened).
final class ScreenAudioCapture: NSObject, LiveAudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onSamples: (([Float]) -> Void)?
    var onStopped: ((Error?) -> Void)?

    private let queue = DispatchQueue(label: "com.jingxuanwh.QingYiTranslator.screenaudio", qos: .userInitiated)
    private let resampler = MonoResampler()
    private var stream: SCStream?

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            Log.error("ScreenCaptureKit 不可用", error)
            throw LiveAudioError(kind: .screenRecordingPermission, message: L("录制电脑的声音需要“屏幕录制”权限。", "Recording the Mac’s sound needs the Screen Recording permission."))
        }
        guard let display = content.displays.first else {
            throw LiveAudioError(kind: .systemAudio, message: L("没有找到显示器，无法录制系统声音。", "No display was found, so the system audio can’t be recorded."))
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        // Only the sound is wanted; keep the video as small and rare as possible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                              configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { error in
            if let error {
                Log.error("停止录制系统声音失败", error)
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = ScreenAudioCapture.pcmBuffer(sampleBuffer) else { return }
        let samples = resampler.convert(buffer)
        if !samples.isEmpty {
            onSamples?(samples)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("系统声音录制停止", error)
        onStopped?(error)
    }

    private static func pcmBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var streamDescription = basic.pointee
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let format = AVAudioFormat(streamDescription: &streamDescription),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

// MARK: - Devices

/// Core Audio device lookups.
enum AudioDevices {
    struct Device: Hashable {
        let uid: String
        let name: String
    }

    /// Devices with at least one input channel.
    static func inputDevices() -> [Device] {
        inputDeviceIDs().compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              let uid = string(device, kAudioDevicePropertyDeviceUID) else {
            throw LiveAudioError(kind: .systemAudio, message: L("没有找到播放设备（扬声器或耳机）。", "No playback device (speakers or headphones) was found."))
        }
        return uid
    }

    /// True when another app is playing sound right now (macOS 14.2+), to tell silence apart from a missing permission.
    static func otherAppIsPlaying() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return processes.contains { process in
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal,
                                                            mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr && pid != ownPID
                && AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr && running != 0
        }
    }

    private static func inputDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { inputChannels($0) > 0 }
    }

    private static func inputChannels(_ device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
