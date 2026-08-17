// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// 一個延遲建立、關掉不釋放的視窗殼。
///
/// 抽出來是因為設定視窗與進階設定視窗需要一模一樣的四件事：延遲建立、
/// `isReleasedWhenClosed = false`、`NSApp.activate()`、以及一個 close 回呼。
/// 各寫一份的話改一邊會忘另一邊。
///
/// **內容的型別是 `NSViewController` 而不是 SwiftUI 的 view。**
/// `import SwiftUI` 由 `ArchitectureBoundaryTests.swiftUIStaysInTheSettingsWindow`
/// 用**檔名白名單**釘住（目前是 `SettingsWindow.swift` 與
/// `AdvancedSettingsWindow.swift`），所以這個共用層不能碰
/// `NSHostingController`——呼叫端自己包好送進來就行，這裡只管視窗。
/// 順帶省掉在 `AnyView`（型別抹除）與泛型參數（跟著跑到每個持有者身上）之間二選一。
///
/// 自己強持有 `window`，同時當它的 delegate：`NSWindow.delegate` 是 weak
///（AppKit 的 `NSWindow.h:338`：`@property (nullable, weak)`），所以互相指不成環。
@MainActor
final class HostedWindow: NSObject, NSWindowDelegate {

    private let title: String
    private let makeContent: () -> NSViewController
    private let onWillClose: () -> Void
    private var window: NSWindow?

    init(title: String,
         onWillClose: @escaping () -> Void = {},
         content: @escaping () -> NSViewController) {
        self.title = title
        self.onWillClose = onWillClose
        self.makeContent = content
    }

    func show() {
        if window == nil {
            let created = NSWindow(contentViewController: makeContent())
            created.title = title
            created.styleMask = [.titled, .closable]
            // 關掉再打開要是同一個視窗。少了這行，關閉會釋放它而下次
            // `makeKeyAndOrderFront` 打在已釋放的物件上。
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        // `.accessory` 政策的 app 不會自動變成前景，不叫的話視窗收不到鍵盤輸入
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onWillClose() }
}
