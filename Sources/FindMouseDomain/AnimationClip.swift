import Foundation

public struct AnimationClip: Sendable, Equatable {
    public let action: CatAction
    public let frames: Int
    public let fps: Double
    public let loops: Bool

    public init(action: CatAction, frames: Int, fps: Double, loops: Bool) {
        self.action = action
        self.frames = frames
        self.fps = fps
        self.loops = loops
    }

    public var duration: TimeInterval { Double(frames) / fps }
}
