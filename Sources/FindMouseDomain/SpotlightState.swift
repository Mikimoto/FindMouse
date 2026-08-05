import CoreGraphics

public struct SpotlightState: Sendable, Equatable {
    public var center: CGPoint
    public var radius: CGFloat
    /// 暗幕不透明度。0 表示完全不變暗。
    public var opacity: CGFloat

    public init(center: CGPoint, radius: CGFloat, opacity: CGFloat) {
        self.center = center
        self.radius = radius
        self.opacity = opacity
    }

    public var isActive: Bool { opacity > 0 }

    public static let inactive = SpotlightState(center: .zero, radius: 0, opacity: 0)
}
