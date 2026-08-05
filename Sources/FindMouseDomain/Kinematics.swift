import CoreGraphics
import Foundation

/// spec 第 4.2 節的追蹤運動學：等速前進 ＋ 有限轉向速率。
public enum Kinematics {

    /// 把角度收斂到 -π…π
    public static func normalizeAngle(_ angle: CGFloat) -> CGFloat {
        var x = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi }
        if x < -.pi { x += 2 * .pi }
        return x
    }

    /// 朝 target 轉最多 turnRate × dt，然後以 speed 前進 dt。
    public static func step(body: CatBody, target: CGPoint, dt: TimeInterval,
                            speed: CGFloat, turnRateDegreesPerSecond: CGFloat) -> CatBody {
        let desired = atan2(target.y - body.position.y, target.x - body.position.x)
        let maxTurn = turnRateDegreesPerSecond * .pi / 180 * CGFloat(dt)
        let delta = normalizeAngle(desired - body.heading)
        let applied = min(max(delta, -maxTurn), maxTurn)
        let heading = normalizeAngle(body.heading + applied)

        let step = speed * CGFloat(dt)
        let position = CGPoint(x: body.position.x + cos(heading) * step,
                               y: body.position.y + sin(heading) * step)
        return CatBody(position: position, heading: heading)
    }

    /// 直線飛行，不轉向。回傳是否已抵達 target。逗貓棒撲擊用。
    public static func ballisticStep(body: CatBody, target: CGPoint,
                                     dt: TimeInterval, speed: CGFloat) -> (body: CatBody, reached: Bool) {
        let dx = target.x - body.position.x
        let dy = target.y - body.position.y
        let remaining = hypot(dx, dy)
        let step = speed * CGFloat(dt)
        let heading = remaining > 0 ? atan2(dy, dx) : body.heading

        if remaining <= step {
            return (CatBody(position: target, heading: heading), true)
        }
        let position = CGPoint(x: body.position.x + cos(heading) * step,
                               y: body.position.y + sin(heading) * step)
        return (CatBody(position: position, heading: heading), false)
    }
}
