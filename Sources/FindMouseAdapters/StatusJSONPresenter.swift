import CoreGraphics
import Foundation
import FindMouseDomain
import FindMouseWire

/// `CatFrameState` ＋ pack 與螢幕資訊 → `StatusPayload`。
///
/// spec 第 7.3 節：「`CatFrameState` 是唯一的真相：畫面與 `status --json` 讀同一份，
/// 不可能不一致。」這一層要維持那句話為真，所以規矩是——
/// **凡是 `CatFrameState` 已經知道的事，一律直接投影，不在這裡重算一次。**
///
/// 具體來說 `facing` 讀 `CatBody.facing`、`distance` 讀 `distanceToCursor`，
/// 而不是就地寫一次 `cos(heading) < 0` 或 `hypot(...)`。畫面（`OverlayPresenter`）
/// 讀的是同樣那兩個屬性；各自算一次的話，兩份公式遲早會漂開，
/// 而症狀是「畫面上的貓朝左，status 說朝右」這種沒人會想到要去查的鬼故事。
public enum StatusJSONPresenter {

    /// 螢幕全部睡著或拔掉時 `NSScreen.screens` 是空的，這時沒有任何索引是對的。
    /// 回 -1 而不是 0：0 是個看起來很正常的答案，腳本不會發現它是瞎猜的。
    public static let noScreen = -1

    public static func payload(state: CatFrameState,
                               appVersion: String,
                               packID: String,
                               packLogicalHeight: CGFloat,
                               screens: [ScreenInfo]) -> StatusPayload {
        // 索引與 scale 是**同一次查詢**的兩個結果，不是兩個獨立的答案。
        let index = StageReader.cursorScreenIndex(screens: screens.map(\.frame),
                                                  cursor: state.cursor)
        return StatusPayload(
            appVersion: appVersion,
            visible: state.isVisible,
            phase: state.phase.rawValue,
            phaseElapsed: state.phaseElapsed,
            teaser: .init(enabled: state.teaserEnabled, available: state.teaserAvailable),
            cat: .init(position: point(state.body.position),
                       facing: state.body.facing.rawValue,
                       action: state.action.rawValue,
                       frame: state.frameIndex,
                       frameCount: state.frameCount),
            cursor: point(state.cursor),
            distance: Double(state.distanceToCursor),
            spotlight: spotlight(state.spotlight),
            timers: .init(rest: state.restTimer, sleep: state.sleepTimer),
            pack: .init(id: packID, logicalHeight: Double(packLogicalHeight)),
            // 以**鼠標**為準，不是貓：spec 第 8.4 節。兩者可能在不同螢幕上。
            display: .init(screenIndex: index ?? noScreen,
                           scale: Double(index.map { screens[$0].scale } ?? 1)))
    }

    /// 暗幕不活躍時半徑也要歸零。
    ///
    /// `SpotlightState` 的 `isActive` 只看 opacity，所以淡出結束的那一帧
    /// 會留下一個「不活躍但半徑 340」的殘值。原樣送出去的話，讀 `radius`
    /// 而沒讀 `active` 的腳本會以為聚光燈還在。
    private static func spotlight(_ s: SpotlightState) -> StatusPayload.Spotlight {
        .init(active: s.isActive,
              radius: s.isActive ? Double(s.radius) : 0,
              opacity: Double(s.opacity))
    }

    private static func point(_ p: CGPoint) -> StatusPayload.Point {
        .init(x: Double(p.x), y: Double(p.y))
    }
}
