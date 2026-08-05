import CoreGraphics
import Foundation
import Testing
@testable import FindMouseDomain

@Test func normalizeAngleWrapsIntoPlusMinusPi() {
    #expect(abs(Kinematics.normalizeAngle(3 * .pi) - .pi) < 1e-9)
    #expect(abs(Kinematics.normalizeAngle(-3 * .pi) + .pi) < 1e-9)
    #expect(abs(Kinematics.normalizeAngle(0.5) - 0.5) < 1e-9)
}

@Test func targetBehindProducesArcNotInstantReversal() {
    // 朝右（heading 0），目標在正後方
    let body = CatBody(position: .zero, heading: 0)
    let stepped = Kinematics.step(body: body, target: CGPoint(x: -500, y: 0),
                                  dt: 1.0 / 60, speed: 900, turnRateDegreesPerSecond: 540)
    // 一帧最多轉 540/60 = 9° = 0.157 rad，不可能瞬間轉到 π
    #expect(abs(stepped.heading) <= 540.0 / 60 * .pi / 180 + 1e-9)
    // 而且它仍然往前走（+x），這就是弧線的起點
    #expect(stepped.position.x > 0)
}

@Test func turnsTheShortWayAround() {
    // 目標在下方（-y），最短路徑是負向轉
    let body = CatBody(position: .zero, heading: 0)
    let stepped = Kinematics.step(body: body, target: CGPoint(x: 0, y: -500),
                                  dt: 1.0 / 60, speed: 900, turnRateDegreesPerSecond: 540)
    #expect(stepped.heading < 0)
}

@Test func headingConvergesToTargetDirection() {
    var body = CatBody(position: .zero, heading: 0)
    let target = CGPoint(x: 0, y: 1000)   // 正上方，需要轉 90°
    for _ in 0..<60 {   // 一秒 = 540°，足夠
        body = Kinematics.step(body: body, target: target,
                               dt: 1.0 / 60, speed: 1, turnRateDegreesPerSecond: 540)
    }
    #expect(abs(body.heading - .pi / 2) < 0.05)
}
