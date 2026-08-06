import CoreGraphics
import FindMouseDomain

/// 提供當前設定。實作在 Adapters（UserDefaults）。
public protocol ConfigProviderPort: AnyObject, Sendable {
    var config: BehaviorConfig { get }
}

/// 可讀可寫的設定儲存。`SettingsUseCase` 用它落地 spec 第 9 節的 23 個 key。
///
/// 為什麼要多兩個字串方法：`BehaviorConfig` 只裝得下 19 個進 Domain 的設定，
/// 另外 4 個（`pack.id`、`hotkey.summon`、`hotkey.teaser`、`window.level`）
/// 由外層持有，沒有對應的 Domain 欄位可以借住。
///
/// `setString(nil, forKey:)` 必須**移除**該鍵而不是寫空字串——
/// 「沒設定過」與「設成空字串」是兩件事，`config reset` 要的是前者。
public protocol SettingsStorePort: ConfigProviderPort {
    func save(_ config: BehaviorConfig)
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)
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
