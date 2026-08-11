// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Carbon.HIToolbox
import FindMouseDomain

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

    /// 註冊（或整批換掉）兩個快捷鍵。
    ///
    /// Carbon 沒有「改一個熱鍵」的 API，只能 unregister 再 register，所以設定改了
    /// 就整批換。事件回呼不跟著換（見 `installHandlerIfNeeded`）。
    ///
    /// **兩個設成同一組鍵時第二個會註冊失敗**：實測 `RegisterEventHotKey` 回
    /// `eventHotKeyExistsErr`（-9878），於是那個鍵進 `failed`。這裡不擋——
    /// 「summon 與 teaser 不得相同」不屬於任何單一 key 的值域，擋在
    /// `SettingsUseCase` 會讓「把兩個對調」變成做不到的事（一定得先經過某個中間值）。
    /// 呼叫端要在每次重新註冊之後把 `failed` 攤給使用者看。
    func install(summon: HotkeySpec, teaser: HotkeySpec) {
        installHandlerIfNeeded()
        unregisterHotkeys()
        register(summon, as: .toggleCat)
        register(teaser, as: .toggleTeaser)
    }

    /// 事件回呼**只裝一次**，不隨重新註冊一起換。
    ///
    /// 它掛在 application event target 上，與「現在註冊了哪些熱鍵」無關。裝第二次
    /// 的話同一次按鍵會進來兩次，`toggle` 連下兩個等於沒按——而那個症狀
    /// （改完設定之後貓再也叫不出來）看起來完全不像註冊問題。
    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
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
    }

    private func register(_ spec: HotkeySpec, as key: Hotkey) {
        var ref: EventHotKeyRef?
        // signature 是四位元組的 app 識別碼，慣例上寫成四個 ASCII 字元：'FMSC'
        let id = EventHotKeyID(signature: OSType(0x464D_5343), id: key.rawValue)
        let status = RegisterEventHotKey(spec.keyCode, Self.carbonModifiers(spec.modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs.append(ref)
        } else {
            failed.append(key)
        }
    }

    /// `HotkeySpec` 住在 Domain，構不到 Carbon 的位元佈局（也不該構得到），
    /// 所以轉換落在這一層——App 是唯一允許 import Carbon 的 target。
    private static func carbonModifiers(_ modifiers: HotkeySpec.Modifiers) -> UInt32 {
        var bits = 0
        if modifiers.contains(.control) { bits |= controlKey }
        if modifiers.contains(.option) { bits |= optionKey }
        if modifiers.contains(.shift) { bits |= shiftKey }
        if modifiers.contains(.command) { bits |= cmdKey }
        return UInt32(bits)
    }

    private func unregisterHotkeys() {
        for case let ref? in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        // 上一輪的失敗紀錄要一起清掉：留著的話它描述的是一組已經不存在的鍵，
        // 而選單列會把它當成現在的狀態顯示（改對了還在警告，且每重註冊一次多一筆）。
        failed.removeAll()
    }

    func uninstall() {
        unregisterHotkeys()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
