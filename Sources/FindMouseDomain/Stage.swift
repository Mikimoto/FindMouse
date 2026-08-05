import CoreGraphics

/// 螢幕幾何。由 driver（M2）從 NSScreen 填入，Domain 不需要知道 AppKit。
/// 座標系為 AppKit 全域座標：原點在主螢幕左下，Y 向上。
public struct Stage: Sendable, Equatable {
    /// 所有螢幕的聯集矩形
    public var union: CGRect
    /// 鼠標當前所在螢幕的矩形
    public var cursorScreen: CGRect

    public init(union: CGRect, cursorScreen: CGRect) {
        self.union = union
        self.cursorScreen = cursorScreen
    }
}
