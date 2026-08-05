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
