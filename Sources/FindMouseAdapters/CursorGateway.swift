import AppKit
import CoreGraphics
import FindMouseCore

/// `CursorPort` 的實作。
///
/// spec 第 13 節：輪詢 `NSEvent.mouseLocation` **不需要任何授權**。需要輔助使用
/// 權限的是 `NSEvent` 的全域**事件監聽**（`addGlobalMonitorForEvents`），
/// 讀位置不是。這是「零系統權限」那條產品承諾的一半，另一半是 Carbon 快捷鍵。
///
/// 座標系是 AppKit 全域座標：原點在主螢幕左下、Y 向上——與 `Stage` 一致，
/// 所以不需要任何翻轉。
public struct CursorGateway: CursorPort {
    public init() {}
    public var location: CGPoint { NSEvent.mouseLocation }
}
