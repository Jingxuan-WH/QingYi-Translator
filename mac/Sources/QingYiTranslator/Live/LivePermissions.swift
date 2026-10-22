import AppKit
import AVFoundation
import CoreGraphics
import QingYiCore
import Speech

/// The privacy permissions live transcription needs, and the System Settings panes that grant them.
///
/// The app is ad-hoc signed, so macOS identifies it by the hash of this exact build: after an update, earlier
/// grants may no longer match and the switch in System Settings can look on while access is denied. `reset`
/// clears this app's entries so macOS asks again.
enum LivePermissions {
    enum Kind {
        case microphone
        case speechRecognition
        /// The "System Audio Recording" permission of process taps (macOS 14.2+) or Screen Recording before that.
        case systemAudio
    }

    enum Status {
        case granted
        case denied
        case notAsked
        /// macOS offers no way to check (system audio on 14.2+); it only shows up as silence.
        case unknown
    }

    static func status(_ kind: Kind) -> Status {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .systemAudio:
            if usesProcessTap {
                return .unknown
            }
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
    }

    /// Process taps (macOS 14.2+) record the system audio with their own permission; older systems need Screen Recording.
    static var usesProcessTap: Bool {
        if #available(macOS 14.2, *) {
            return true
        }
        return false
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func requestSpeechRecognition() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    /// Before macOS 14.2: shows the Screen Recording prompt once; granting it takes effect after the app is reopened.
    static func requestScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    static func openSettings(_ kind: Kind) {
        let anchor: String
        switch kind {
        case .microphone: anchor = "Privacy_Microphone"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .systemAudio: anchor = "Privacy_ScreenCapture" // "Screen & System Audio Recording"
        }
        open("x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    /// Offline recognition models for SFSpeechRecognizer come with Dictation languages.
    static func openDictationSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    /// Forgets this app's answers (`tccutil reset`), so the next start asks again.
    static func reset(_ kinds: [Kind]) {
        let bundleId = Bundle.main.bundleIdentifier ?? AppInfo.bundleIdentifier
        for kind in kinds {
            let services: [String]
            switch kind {
            case .microphone: services = ["Microphone"]
            case .speechRecognition: services = ["SpeechRecognition"]
            case .systemAudio: services = ["AudioCapture", "ScreenCapture"]
            }
            for service in services {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = ["reset", service, bundleId]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    Log.error("tccutil reset \(service) 失败", error)
                }
            }
        }
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }
}
