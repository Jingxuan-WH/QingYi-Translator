import Carbon.HIToolbox
import Foundation
import QingYiCore

/// A system-wide hotkey registered with Carbon's RegisterEventHotKey, which needs no special permission.
final class GlobalHotkey {
    private static let signature: OSType = 0x5159_4859 // "QYHY"

    /// Tells this app's hotkeys apart (the translation hotkey and the live transcription one).
    private let hotkeyId: UInt32
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?

    var pressed: (() -> Void)?

    init(id: UInt32 = 0x5159) {
        hotkeyId = id
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            guard status == noErr, id.signature == GlobalHotkey.signature, id.id == hotkey.hotkeyId else {
                return OSStatus(eventNotHandledErr) // another hotkey: let the next handler have it
            }
            DispatchQueue.main.async { hotkey.pressed?() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        unregister()
        if let handler {
            RemoveEventHandler(handler)
        }
    }

    @discardableResult
    func register(_ gesture: HotkeyGesture) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: GlobalHotkey.signature, id: hotkeyId)
        let status = RegisterEventHotKey(gesture.keyCode, gesture.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotkey)
        if status != noErr {
            hotkey = nil
            Log.error("注册全局快捷键失败：\(gesture)，错误码 \(status)")
            return false
        }
        return true
    }

    func unregister() {
        if let hotkey {
            UnregisterEventHotKey(hotkey)
        }
        hotkey = nil
    }
}
