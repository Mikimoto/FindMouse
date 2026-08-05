import CoreGraphics
import Foundation

/// 全域時間與係數常數。spec 未將這些列為設定項，故為常數。
public enum Timings {
    /// spotlight 淡入秒數
    public static let spotlightFadeIn: TimeInterval = 0.25
    /// spotlight 淡出秒數
    public static let spotlightFadeOut: TimeInterval = 0.4
    /// 退場淡出秒數
    public static let exitFade: TimeInterval = 0.4
    /// 單次 tick 的 dt 上限。防止系統睡眠喚醒後 dt 暴衝讓貓瞬移。
    public static let maxTickDelta: TimeInterval = 0.1
    /// 逗貓棒屁股搖持續秒數
    public static let windup: TimeInterval = 0.5
    /// 休息池動作的插入間隔範圍
    public static let flourishInterval: ClosedRange<TimeInterval> = 2...4
    /// 潛行速度 = catSpeed × 此係數
    public static let stalkSpeedFactor: CGFloat = 0.15
    /// 退開速度 = catSpeed × 此係數
    public static let retreatSpeedFactor: CGFloat = 0.6
    /// spotlight 半徑中貓體型項的係數
    public static let spotlightHeightFactor: CGFloat = 0.6
}
