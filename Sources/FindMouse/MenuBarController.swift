import AppKit

/// 極簡選單列。M2 只需要兩件事：叫貓咪、退出。
///
/// 為什麼 M2 就要做：`LSUIElement` 的 app 沒有 Dock 圖示，若快捷鍵註冊失敗
/// 就完全沒有入口，只能從終端機 killall。設定視窗與 pack 切換是 M4。
@MainActor
final class MenuBarController {

    private let item: NSStatusItem
    private let onToggleCat: () -> Void

    init(onToggleCat: @escaping () -> Void) {
        self.onToggleCat = onToggleCat
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐱"

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "叫貓咪／讓貓咪回家",
                                action: #selector(toggleCat), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "結束 FindMouse",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
    }

    /// 快捷鍵註冊失敗時換掉圖示並在 tooltip 說明。
    /// 不講的話使用者只會覺得「按了沒反應」，而真正的原因（被別的 app 佔用）
    /// 從畫面上完全看不出來。
    func showHotkeyFailure(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        item.button?.title = "🐱⚠️"
        item.button?.toolTip = "這些快捷鍵註冊失敗（可能被其他 app 佔用）：\(keys.joined(separator: "、"))"
    }

    @objc private func toggleCat() { onToggleCat() }
}
