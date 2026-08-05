import CoreGraphics
import Foundation

/// tick 的輸出，也是整個 App 的唯一真相：畫面與 status --json 讀同一份。
public struct CatFrameState: Sendable, Equatable {
    public let phase: CatPhase
    public let phaseElapsed: TimeInterval
    public let body: CatBody
    public let action: CatAction
    public let frameIndex: Int
    public let frameCount: Int
    /// 退場淡出用的整體不透明度，1 = 完全實體
    public let alpha: CGFloat
    public let spotlight: SpotlightState
    public let cursor: CGPoint
    public let teaserEnabled: Bool
    public let teaserAvailable: Bool
    public let restTimer: TimeInterval
    public let sleepTimer: TimeInterval

    public init(phase: CatPhase, phaseElapsed: TimeInterval, body: CatBody,
                action: CatAction, frameIndex: Int, frameCount: Int, alpha: CGFloat,
                spotlight: SpotlightState, cursor: CGPoint,
                teaserEnabled: Bool, teaserAvailable: Bool,
                restTimer: TimeInterval, sleepTimer: TimeInterval) {
        self.phase = phase
        self.phaseElapsed = phaseElapsed
        self.body = body
        self.action = action
        self.frameIndex = frameIndex
        self.frameCount = frameCount
        self.alpha = alpha
        self.spotlight = spotlight
        self.cursor = cursor
        self.teaserEnabled = teaserEnabled
        self.teaserAvailable = teaserAvailable
        self.restTimer = restTimer
        self.sleepTimer = sleepTimer
    }

    public var isVisible: Bool { phase.isVisible }

    public var distanceToCursor: CGFloat {
        hypot(cursor.x - body.position.x, cursor.y - body.position.y)
    }
}
