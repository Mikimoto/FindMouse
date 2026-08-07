import AppKit
import FindMouseCore

/// 極簡選單列。M2 只需要兩件事：叫貓咪、退出；M4 多一個 pack 子選單
/// ——換圖組是使用者最常做的操作，不該每次都得開設定視窗。
///
/// 為什麼 M2 就要做：`LSUIElement` 的 app 沒有 Dock 圖示，若快捷鍵註冊失敗
/// 就完全沒有入口，只能從終端機 killall。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let item: NSStatusItem
    private let onToggleCat: () -> Void
    private let onOpenSettings: () -> Void
    private let packRows: () -> [PackChoice]
    private let onChoosePack: (String) -> Void

    private let packMenu = NSMenu()

    /// - Parameter packRows: **每次打開子選單都會呼叫一次**，所以它必須重新掃描
    ///   而不是回一份快取——使用者把 pack 丟進 `~/Library/Application Support/FindMouse/Packs/`
    ///   之後不該還要重開 App 才看得到。
    /// - Parameter onChoosePack: 收到 pack id。**不是「寫 pack.id」**：只寫設定
    ///   不會換 pack（那是 `AppDelegate.performSwap` 的副作用），使用者會看到
    ///   「選了新的、貓還是舊的」。
    init(onToggleCat: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void,
         packRows: @escaping () -> [PackChoice],
         onChoosePack: @escaping (String) -> Void) {
        self.onToggleCat = onToggleCat
        self.onOpenSettings = onOpenSettings
        self.packRows = packRows
        self.onChoosePack = onChoosePack
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.title = "🐱"

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "叫貓咪／讓貓咪回家",
                                action: #selector(toggleCat), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        // 子選單的 delegate 與父選單是分開的：掛在 `menu` 上不會有人通知這裡。
        // 實測（macOS 27）子選單展開時 `menuNeedsUpdate` 確實會被呼叫到。
        packMenu.delegate = self
        // **這一行不能省。** `autoenablesItems` 預設是 true，那時 AppKit 會在
        // 選單顯示前自己跑一輪驗證，把手動設的 `isEnabled = false` **改回 true**
        // ——實測：顯示後讀回來是 true。少了這行，不合格的 pack 看起來灰不掉、
        // 點得下去，然後換 pack 失敗、選單列掛上一個永遠不會消失的警告圖示。
        packMenu.autoenablesItems = false
        let packs = NSMenuItem(title: "圖組", action: nil, keyEquivalent: "")
        packs.submenu = packMenu
        menu.addItem(packs)

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

    // MARK: - pack 子選單

    /// 打開的當下才建，不是啟動時建一次。理由見 `packRows` 的說明。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for row in packRows() {
            let entry = NSMenuItem(title: row.menuTitle,
                                   action: #selector(choosePack(_:)), keyEquivalent: "")
            entry.target = self
            // id 另外存一份：標題會帶上「（內建）」與不可用的原因，
            // 從標題解回 id 就等於再寫一份剖析器去對付自己剛組出來的字串。
            entry.representedObject = row.id
            // 標題已經帶了原因，這裡是標題被選單寬度截掉時的完整版。
            // 實測 tooltip 在 isEnabled = false 的項目上照樣會浮出來。
            entry.toolTip = row.menuTooltip
            entry.isEnabled = row.isUsable
            // 勾的是**實際跑著的**那一套，不是設定裡寫的那個 id：啟動時想要的
            // pack 載不起來會退回內建，而設定裡那個壞掉的 id 不會被改寫。
            //
            // 換 pack 要等貓退場（spec 第 6.5 節），那幾百毫秒之間勾號會留在舊的
            // 那一套。刻意如此：勾號的意思是「現在跑的是這個」，而使用者當下正在
            // 看貓走回家——設定視窗需要 `pendingPackID` 是因為它的下拉選單一直
            // 留在畫面上、會當著使用者的面彈回去，選單點完就關了，沒有這個問題。
            entry.state = row.isCurrent ? .on : .off
            menu.addItem(entry)
        }
    }

    @objc private func choosePack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onChoosePack(id)
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
