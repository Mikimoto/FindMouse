import AppKit
import Carbon.HIToolbox

/// 全域快捷鍵。Carbon 的 `RegisterEventHotKey` 不需要輔助使用權限
/// （`NSEvent` 的全域監聽才需要），這是 spec 第 13 節「零系統權限」的關鍵。
///
/// C 事件回呼是函式指標，**不能捕獲 context**，所以 self 透過 `userData` 以
/// 不持有的方式傳進去，回呼內再取回來。回呼在 main run loop 上執行，
/// 所以 `MainActor.assumeIsolated` 是安全的而不是繞過檢查。
@MainActor
final class CarbonHotkeyDriver {

    enum Hotkey: UInt32 {
        case toggleCat = 1
        case toggleTeaser = 2
    }

    /// 註冊失敗的快捷鍵。呼叫端要據此提示使用者（例如被別的 app 佔用）。
    private(set) var failed: [Hotkey] = []

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private let onPress: (Hotkey) -> Void

    init(onPress: @escaping (Hotkey) -> Void) {
        self.onPress = onPress
    }

    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, let key = Hotkey(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            let driver = Unmanaged<CarbonHotkeyDriver>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { driver.onPress(key) }
            return noErr
        }, 1, &spec, context, &handler)

        register(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | cmdKey), as: .toggleCat)
        register(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey | cmdKey), as: .toggleTeaser)
    }

    private func register(keyCode: UInt32, modifiers: UInt32, as key: Hotkey) {
        var ref: EventHotKeyRef?
        // signature 是四位元組的 app 識別碼，慣例上寫成四個 ASCII 字元：'FMSC'
        let id = EventHotKeyID(signature: OSType(0x464D_5343), id: key.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs.append(ref)
        } else {
            failed.append(key)
        }
    }

    func uninstall() {
        for ref in refs where ref != nil { UnregisterEventHotKey(ref!) }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
