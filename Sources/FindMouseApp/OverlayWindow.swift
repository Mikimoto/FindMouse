// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

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

    /// **不接受 AppKit 的 frame 夾制。**
    ///
    /// `NSWindow` 預設會把 frame 夾回「某一片螢幕」的可見範圍——那是為了保證
    /// 一般視窗的標題列不會跑到螢幕外。但這個視窗的整個目的就是橫跨所有螢幕，
    /// 夾制的結果是它只蓋住其中一片，而且**沒有任何錯誤訊息**：
    /// 單螢幕環境下完全正常，接上第二個螢幕才會發現另一片沒有變暗。
    ///
    /// 回傳未修改的 `frameRect` 就是關掉夾制。這對 `init` 的 contentRect 與
    /// 之後每一次 `setFrame` 都生效。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// 螢幕組態變動時重設 frame。不重設的話，接上或拔掉螢幕之後
    /// 貓會被畫到視窗外——而視窗是透明的，看起來就像貓憑空消失。
    func resize(to union: CGRect) {
        setFrame(union, display: false)
    }
}
