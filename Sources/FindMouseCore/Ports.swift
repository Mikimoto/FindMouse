import CoreGraphics
import FindMouseDomain

/// 提供當前設定。實作在 Adapters（UserDefaults）。
public protocol ConfigProviderPort: AnyObject, Sendable {
    var config: BehaviorConfig { get }
}

/// 提供當前 pack 的中介資料。實作在 Adapters（SpriteRepository）。
/// Core 只需要知道「有幾格、幾 fps、哪些動作可用」，不需要圖。
public protocol AnimationCatalogPort: AnyObject, Sendable {
    var logicalHeight: CGFloat { get }
    var capabilities: PackCapabilities { get }
    func clip(for action: CatAction) -> AnimationClip?
}

/// 鼠標位置來源。spec 第 13 節：輪詢 `NSEvent.mouseLocation` 不需要任何授權
/// （`NSEvent` 的全域**事件監聽**才需要輔助使用權限，讀位置不需要）。
///
/// 為什麼要這個 port 而不是讓 driver 直接讀：`tick(cursor:)` 收的是推進來的值，
/// 而 driver 本身需要能在測試中餵假鼠標。這是 M1 完成報告列為「M2 另需新增」的那一項。
public protocol CursorPort: Sendable {
    var location: CGPoint { get }
}
