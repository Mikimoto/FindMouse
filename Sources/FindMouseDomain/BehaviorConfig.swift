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

    public func arriveRadius(logicalHeight: CGFloat) -> CGFloat {
        arriveRadiusOverride ?? effectiveHeight(logicalHeight: logicalHeight) * 0.8
    }
}
