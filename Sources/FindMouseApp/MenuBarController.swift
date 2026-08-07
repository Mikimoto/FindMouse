import AppKit

/// 極簡選單列。M2 只需要兩件事：叫貓咪、退出。
///
/// 為什麼 M2 就要做：`LSUIElement` 的 app 沒有 Dock 圖示，若快捷鍵註冊失敗
/// 就完全沒有入口，只能從終端機 killall。設定視窗與 pack 切換是 M4。
@MainActor
final class MenuBarController {

    private let item: NSStatusItem
    private let onToggleCat: () -> Void
    private let onOpenSettings: () -> Void

    init(onToggleCat: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.onToggleCat = onToggleCat
        self.onOpenSettings = onOpenSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐱"

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "叫貓咪／讓貓咪回家",
                                action: #selector(toggleCat), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        // `,` 是 macOS 開設定的慣例鍵；`.accessory` 的 app 沒有主選單列，
        // 所以它只在這個選單開著的時候有效——放著是為了讓熟悉慣例的人找得到。
        let settings = NSMenuItem(title: "設定…",
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "結束 FindMouse",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
    }

    /// 降級提示。快捷鍵註冊失敗、socket 綁不起來——這些都是
    /// 「App 還能用，但少了一個入口」的情況（spec 第 10 節）。
    ///
    /// 一律走同一份清單而不是各自改圖示：兩件事同時發生時，後寫的那個
    /// 會把前一個的說明蓋掉，而使用者只看得到其中一個原因。
    private var degradations: [String] = []

    func reportDegradation(_ message: String) {
        degradations.append(message)
        item.button?.title = "🐱⚠️"
        item.button?.toolTip = degradations.joined(separator: "\n")
    }

    /// 不講的話使用者只會覺得「按了沒反應」，而真正的原因（被別的 app 佔用）
    /// 從畫面上完全看不出來。
    func showHotkeyFailure(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        reportDegradation("這些快捷鍵註冊失敗（可能被其他 app 佔用）：\(keys.joined(separator: "、"))")
    }

    @objc private func toggleCat() { onToggleCat() }

    @objc private func openSettings() { onOpenSettings() }
}
