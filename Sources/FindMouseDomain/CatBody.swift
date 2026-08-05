import CoreGraphics
import Foundation

/// 貓的位置與朝向。heading 為弧度，0 指向 +x。
public struct CatBody: Sendable, Equatable {
    public var position: CGPoint
    public var heading: CGFloat

    public init(position: CGPoint, heading: CGFloat) {
        self.position = position
        self.heading = heading
    }

    public var facing: Facing { cos(heading) < 0 ? .left : .right }
}
