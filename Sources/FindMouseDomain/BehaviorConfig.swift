import CoreGraphics
import Foundation

/// 影響行為的設定。spec 第 9 節中屬於 Core 的部分
/// （pack.id / hotkey.* / window.level 由外層持有，不進 Domain）。
public struct BehaviorConfig: Sendable, Equatable {
    public var catScale: CGFloat = 1.0
    public var restDuration: TimeInterval = 10
    public var sleepDuration: TimeInterval = 5

    public var spotlightEnabled: Bool = true
    public var spotlightTrigger: SpotlightTrigger = .onSummonOnly
    public var spotlightDimOpacity: CGFloat = 0.75
    public var spotlightMargin: CGFloat = 24
    public var spotlightFeather: CGFloat = 0.65

    public var rehuntThreshold: CGFloat = 160
    public var catSpeed: CGFloat = 900
    /// 度/秒
    public var catTurnRate: CGFloat = 540

    public var teaserStalkRange: CGFloat = 250
    public var teaserStalkTimeout: TimeInterval = 3
    public var teaserPounceTriggerSpeed: CGFloat = 400
    public var teaserPounceSpeed: CGFloat = 2200
    public var teaserHitRadius: CGFloat = 60
    public var teaserRetreatDistance: CGFloat = 150

    /// nil 表示沿用衍生預設（3 × rehuntThreshold）
    public var wakeThresholdOverride: CGFloat? = nil
    /// nil 表示沿用衍生預設（0.8 × effectiveHeight）
    public var arriveRadiusOverride: CGFloat? = nil

    public init() {}

    public func effectiveHeight(logicalHeight: CGFloat) -> CGFloat {
        logicalHeight * catScale
    }

    public var wakeThreshold: CGFloat {
        wakeThresholdOverride ?? rehuntThreshold * 3
    }

    /// `arrive.radius` 的合法範圍（spec 第 9 節）。
    ///
    /// 定義在 Domain 而不是 Core 的註冊表裡，是因為**衍生預設也要夾在同一個範圍內**，
    /// 而衍生預設是這裡算的。兩邊各寫一次的話，只要有一邊改了就會分岔。
    public static let arriveRadiusRange: ClosedRange<CGFloat> = 20...400

    /// 抵達判定半徑。未設定時是 0.8 × 實際體高，**並夾進合法範圍**。
    ///
    /// 為什麼要夾：`PackValidator` 允許 logicalHeight 24–400、`cat.scale` 允許 0.5–2.0，
    /// 所以衍生值的跨度是 9.6–640，而這個 key 的範圍是 20–400。不夾的話，
    /// 極端 pack 加極端縮放下 `config get arrive.radius` 會回一個 `config set`
    /// 拒收的值——「讀出來的值餵回去一定被接受」那個保證就破了。
    /// 內建的 test-blocks（96）落在 38.4–153.6，所以今天碰不到；M4 開放換 pack 之後會。
    public func arriveRadius(logicalHeight: CGFloat) -> CGFloat {
        if let override = arriveRadiusOverride { return override }
        let derived = effectiveHeight(logicalHeight: logicalHeight) * 0.8
        return min(max(derived, Self.arriveRadiusRange.lowerBound),
                   Self.arriveRadiusRange.upperBound)
    }
}
