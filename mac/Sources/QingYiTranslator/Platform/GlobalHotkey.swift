import Carbon.HIToolbox
import Foundation
import QingYiCore

/// A system-wide hotkey registered with Carbon's RegisterEventHotKey, which needs no special permission.
final class GlobalHotkey {
    private static let signature: OSType = 0x5159_4859 // "QYHY"
    private static let hotkeyId: UInt32 = 0x5159

    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?

    var pressed: (() -> Void)?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotkey.signature, id.id == GlobalHotkey.hotkeyId else {
                return OSStatus(eventNotHandledErr)
            }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
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
        let id = EventHotKeyID(signature: GlobalHotkey.signature, id: GlobalHotkey.hotkeyId)
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
