import AppKit

/// 覆蓋所有螢幕聯集矩形的透明視窗。
///
/// `ignoresMouseEvents = true` 是**硬性要求**：這個視窗蓋住整個桌面，
/// 若它吃事件，使用者會完全無法操作電腦。
///
/// `collectionBehavior` 的三項讓它出現在全螢幕 Space 上而不跟著切換：
/// `.canJoinAllSpaces` 讓它同時存在於每個 Space、`.stationary` 讓它不隨
/// Space 切換動畫移動、`.fullScreenAuxiliary` 允許它疊在全螢幕 app 之上。
final class OverlayWindow: NSWindow {

    init(union: CGRect, level key: CGWindowLevelKey) {
        super.init(contentRect: union, styleMask: .borderless,
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(key)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isExcludedFromWindowsMenu = true
        // 這個視窗會被反覆 order in/out，不能在關閉時被釋放
        isReleasedWhenClosed = false
    }

    /// borderless 視窗預設就不能成為 key/main，但明確寫出來，
    /// 免得日後有人加了 styleMask 就靜默開始搶焦點。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 螢幕組態變動時重設 frame。不重設的話，接上或拔掉螢幕之後
    /// 貓會被畫到視窗外——而視窗是透明的，看起來就像貓憑空消失。
    func resize(to union: CGRect) {
        setFrame(union, display: false)
    }
}
