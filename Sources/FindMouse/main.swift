import AppKit
import OSLog

private let log = Logger(subsystem: "com.findmouse.app", category: "spike")

@MainActor
final class SpikeDelegate: NSObject, NSApplicationDelegate {
    private var hotkeys: CarbonHotkeyDriver?
    private var window: OverlayWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let driver = CarbonHotkeyDriver { key in
            log.notice("hotkey fired: \(String(describing: key), privacy: .public)")
            print("hotkey fired: \(key)")
        }
        driver.install()
        // 同時 print 與 log：裸執行檔看得到 print，但 .app 沒有終端機，
        // 註冊結果只有走 OSLog 才到得了使用者眼前。
        if driver.failed.isEmpty {
            print("兩個快捷鍵都註冊成功，按 ⌥⌘F 或 ⌥⌘T 試試（Ctrl-C 結束）")
            log.notice("hotkeys registered: toggleCat=⌥⌘F toggleTeaser=⌥⌘T")
        } else {
            print("註冊失敗：\(driver.failed)")
            log.error("hotkey registration failed: \(String(describing: driver.failed), privacy: .public)")
        }
        hotkeys = driver

        // 暫時的紅色底：只為了用眼睛確認視窗真的落在正確的位置與層級。
        // Task 15 接線時整個 main.swift 會被換掉。
        let screens = NSScreen.screens.map(\.frame)
        let union = screens.dropFirst().reduce(screens.first ?? .zero) { $0.union($1) }
        let overlay = OverlayWindow(union: union, level: .overlayWindow)
        overlay.backgroundColor = NSColor.systemRed.withAlphaComponent(0.25)
        overlay.orderFrontRegardless()
        window = overlay
        log.notice("overlay window up: union=\(String(describing: union), privacy: .public) screens=\(screens.count)")
    }
}

let delegate = SpikeDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
