import AppKit
import QingYiCore
import SwiftUI

/// Draft of the live transcription settings (the hotkey) plus the state of its permissions; part of `SettingsViewModel`.
@MainActor
final class LiveSettingsDraft: ObservableObject {
    private unowned let app: AppDelegate
    private let mainHotkey: () -> HotkeyGesture?

    @Published var hotkeyEnabled: Bool { didSet { updateHotkeyStatus() } }
    @Published private(set) var hotkey: HotkeyGesture?
    @Published var hotkeyText = ""
    @Published private(set) var hotkeyStatus = ""
    @Published private(set) var hotkeyStatusIsError = false
    @Published private(set) var microphone = LivePermissions.status(.microphone)
    @Published private(set) var speech = LivePermissions.status(.speechRecognition)
    @Published private(set) var systemAudio = LivePermissions.status(.systemAudio)

    init(settings: AppSettings, app: AppDelegate, mainHotkey: @escaping () -> HotkeyGesture?) {
        self.app = app
        self.mainHotkey = mainHotkey
        hotkeyEnabled = settings.live.hotkeyEnabled
        hotkey = HotkeyGesture.parse(settings.live.hotkey)
        hotkeyText = hotkey?.description ?? ""
        updateHotkeyStatus()
    }

    var engineText: String {
        SpeechEngine.usesAnalyzer
            ? L("语音识别：macOS 的 SpeechAnalyzer，完全在本机进行。第一次使用某种语言时会下载它的模型（由系统管理）。",
                "Speech recognition: macOS SpeechAnalyzer, entirely on this Mac. Each language’s model is downloaded the first time it is used (managed by macOS).")
            : L("语音识别：macOS 的离线听写（SFSpeechRecognizer），完全在本机进行。需要在“系统设置 › 键盘 › 听写”中添加所用的语言。",
                "Speech recognition: macOS offline dictation (SFSpeechRecognizer), entirely on this Mac. Add the languages you use under System Settings › Keyboard › Dictation.")
    }

    var systemAudioHint: String {
        LivePermissions.usesProcessTap
            ? L("录制电脑的声音：第一次使用时 macOS 会询问是否允许轻译录制系统声音（“屏幕与系统录音”）。",
                "Recording the Mac’s sound: macOS asks the first time whether QingYi may record system audio (Screen & System Audio Recording).")
            : L("录制电脑的声音需要“屏幕录制”权限（macOS 14.2 之前），授权后需要重新打开轻译。",
                "Recording the Mac’s sound needs the Screen Recording permission (before macOS 14.2); reopen QingYi after granting it.")
    }

    func refreshPermissions() {
        microphone = LivePermissions.status(.microphone)
        speech = LivePermissions.status(.speechRecognition)
        systemAudio = LivePermissions.status(.systemAudio)
    }

    func resetPermissions() {
        LivePermissions.reset([.microphone, .speechRecognition, .systemAudio])
        refreshPermissions()
    }

    // ---------------- hotkey ----------------

    func hotkeyFocusChanged(_ focused: Bool) {
        if focused {
            // Release both registrations so pressing the current hotkeys reaches the recorder.
            app.suspendHotkey()
            app.live.suspendHotkey()
            setHotkeyStatus(L("请按下新的组合键（Esc 取消，⌫ 清除）", "Press the new key combination (Esc cancels, ⌫ clears)"), isError: false)
        } else {
            app.resumeHotkey()
            app.live.resumeHotkey()
            hotkeyText = hotkey?.description ?? ""
            updateHotkeyStatus()
        }
    }

    func hotkeyModifiersChanged(_ modifiers: HotkeyModifiers) {
        hotkeyText = modifiers.isEmpty ? (hotkey?.description ?? "") : HotkeyGesture.symbols(for: modifiers) + "…"
    }

    func hotkeyRecorded(_ gesture: HotkeyGesture) {
        hotkeyText = gesture.description
        if !gesture.isValid {
            setHotkeyStatus(L("快捷键需要包含 ⌘、⌥ 或 ⌃ 键", "The hotkey must include ⌘, ⌥ or ⌃"), isError: true)
            return
        }
        hotkey = gesture
        updateHotkeyStatus()
    }

    func hotkeyCleared() {
        hotkey = nil
        hotkeyText = ""
        setHotkeyStatus(L("已清除快捷键", "Hotkey cleared"), isError: false)
    }

    /// False when the hotkey still needs attention.
    func validate() -> Bool {
        if hotkeyEnabled && hotkey == nil {
            setHotkeyStatus(L("请先设置快捷键，或者关闭这个选项", "Set a hotkey first, or turn this option off"), isError: true)
            return false
        }
        return true
    }

    func apply(to settings: AppSettings) {
        settings.live.hotkeyEnabled = hotkeyEnabled
        settings.live.hotkey = hotkey?.storageString ?? ""
    }

    func onInterfaceLanguageChanged() {
        updateHotkeyStatus()
        objectWillChange.send()
    }

    private func updateHotkeyStatus() {
        if let hotkey {
            if hotkey == mainHotkey() {
                setHotkeyStatus(L("和取词快捷键相同，请换一个", "This is the hotkey for translating a selection. Please pick another one"), isError: true)
            } else {
                setHotkeyStatus(L("在任意应用中按下即可开始实时转录，再按一次停止。", "Press it in any app to start live transcription; press it again to stop."), isError: false)
            }
        } else {
            setHotkeyStatus(hotkeyEnabled ? L("尚未设置快捷键，点击上面的输入框后按下组合键", "No hotkey yet. Click the box above and press a key combination") : "",
                            isError: hotkeyEnabled)
        }
    }

    private func setHotkeyStatus(_ text: String, isError: Bool) {
        hotkeyStatus = text
        hotkeyStatusIsError = isError
    }
}

struct LiveSettingsSection: View {
    @ObservedObject var draft: LiveSettingsDraft

    var body: some View {
        Group {
            SectionTitle(text: L("实时转录", "Live transcription"))
            Card {
                HintText(text: draft.engineText).padding(.top, 6)
                VStack(alignment: .leading, spacing: 8) {
                    permissionRow(L("麦克风", "Microphone"), draft.microphone, .microphone)
                    if !SpeechEngine.usesAnalyzer {
                        permissionRow(L("语音识别", "Speech recognition"), draft.speech, .speechRecognition)
                    }
                    permissionRow(L("录制电脑的声音", "Recording the Mac’s sound"), draft.systemAudio, .systemAudio)
                }
                .padding(.top, 12)
                HStack(alignment: .top) {
                    HintText(text: draft.systemAudioHint + " "
                             + L("轻译没有开发者签名，更新后 macOS 可能不再认可之前的授权；遇到这种情况点“重置权限”，下次开始时重新授权即可。",
                                 "QingYi isn’t signed with a developer certificate, so after an update macOS may no longer accept the earlier permissions; click “Reset permissions” and allow them again at the next start."))
                    Spacer(minLength: 8)
                    Button(L("重置权限", "Reset permissions")) { draft.resetPermissions() }
                        .buttonStyle(SecondaryButtonStyle(compact: true)).padding(.top, 6)
                }
                ToggleRow(title: L("用快捷键开始 / 停止实时转录", "Use a hotkey to start / stop live transcription"), isOn: $draft.hotkeyEnabled)
                    .padding(.top, 8)
                HStack(spacing: 12) {
                    Text(L("快捷键", "Hotkey")).font(.system(size: 13))
                    HotkeyRecorder(text: draft.hotkeyText, onFocusChange: draft.hotkeyFocusChanged, onModifiers: draft.hotkeyModifiersChanged,
                                   onGesture: draft.hotkeyRecorded, onClear: draft.hotkeyCleared)
                        .frame(width: 200, height: 30)
                    Spacer()
                }
                .padding(.top, 10)
                HintText(text: draft.hotkeyStatus, color: draft.hotkeyStatusIsError ? Palette.error : Palette.textTertiary)
            }
        }
    }

    private func permissionRow(_ title: String, _ status: LivePermissions.Status, _ kind: LivePermissions.Kind) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color(status)).frame(width: 7, height: 7)
            Text(title).font(.system(size: 13))
            Text(describe(status)).font(.system(size: 12)).foregroundColor(Palette.textTertiary)
            Spacer()
            if status != .granted {
                Button(L("打开系统设置…", "Open System Settings…")) { LivePermissions.openSettings(kind) }.buttonStyle(LinkButtonStyle())
            }
        }
    }

    private func color(_ status: LivePermissions.Status) -> Color {
        switch status {
        case .granted: return Palette.success
        case .denied: return Palette.error
        case .notAsked, .unknown: return Palette.warning
        }
    }

    private func describe(_ status: LivePermissions.Status) -> String {
        switch status {
        case .granted: return L("已授权", "Granted")
        case .denied: return L("未授权", "Not granted")
        case .notAsked: return L("第一次使用时询问", "Asked on first use")
        case .unknown: return L("第一次使用时询问；无法预先检查", "Asked on first use; can’t be checked in advance")
        }
    }
}
