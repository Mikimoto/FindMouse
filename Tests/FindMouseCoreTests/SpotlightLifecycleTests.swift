import CoreGraphics
import Foundation
import Testing
@testable import FindMouseCore
import FindMouseDomain

// 游標一律放在螢幕中央：貓從離游標最近的邊緣進場，游標貼邊時出生點只距 120px，
// 狩獵只持續 7 帧（實測 x=100 時 f8 就進 arriving、峰值不透明度僅 0.45），
// 那樣量不到淡入完成也量不到半徑收斂。中央出生點距離 638px、狩獵 40 帧。
@Test func spotlightFadesInDuringHuntAndOutOnArrival() {
    let h = Harness()
    h.step(cursor: CGPoint(x: 960, y: 540), commands: [.summon])
    // 淡入 0.25 秒後應接近設定的 dimOpacity
    for _ in 0..<20 { h.step(cursor: CGPoint(x: 960, y: 540)) }
    #expect(h.last.phase == .hunting)
    #expect(h.last.spotlight.opacity > 0.5)
    #expect(h.last.spotlight.center == CGPoint(x: 960, y: 540))

    #expect(h.run(until: .resting, cursor: CGPoint(x: 960, y: 540)))
    // 進入 resting 後至多再 0.4 秒完成淡出
    h.run(seconds: 0.5, cursor: CGPoint(x: 960, y: 540))
    #expect(h.last.spotlight.isActive == false)
}

@Test func spotlightRadiusShrinksAsCatApproaches() {
    let h = Harness()
    h.step(cursor: CGPoint(x: 960, y: 540), commands: [.summon])
    for _ in 0..<20 { h.step(cursor: CGPoint(x: 960, y: 540)) }
    let early = h.last.spotlight.radius

    for _ in 0..<20 { h.step(cursor: CGPoint(x: 960, y: 540)) }
    let later = h.last.spotlight.radius

    #expect(later < early)
    #expect(later > 0)
}

@Test func onSummonOnlyKeepsRehuntDark() {
    let h = Harness()
    h.step(commands: [.summon])
    #expect(h.run(until: .resting))
    h.run(seconds: 0.5)

    h.step(cursor: CGPoint(x: 960 + 600, y: 540))
    #expect(h.last.phase == .hunting)
    for _ in 0..<30 { h.step(cursor: CGPoint(x: 960 + 600, y: 540)) }
    #expect(h.last.spotlight.isActive == false)
}

@Test func everyHuntLightsUpOnRehunt() {
    var cfg = BehaviorConfig()
    cfg.spotlightTrigger = .everyHunt
    let h = Harness(config: StubConfig(cfg))
    h.step(commands: [.summon])
    #expect(h.run(until: .resting))
    h.run(seconds: 0.5)

    h.step(cursor: CGPoint(x: 960 + 600, y: 540))
    for _ in 0..<20 { h.step(cursor: CGPoint(x: 960 + 600, y: 540)) }
    #expect(h.last.phase == .hunting)
    #expect(h.last.spotlight.isActive)
}

@Test func disabledSpotlightNeverDimsButBehaviourIsUnchanged() {
    var cfg = BehaviorConfig()
    cfg.spotlightEnabled = false
    let h = Harness(config: StubConfig(cfg))
    h.step(cursor: CGPoint(x: 960, y: 540), commands: [.summon])
    for _ in 0..<40 { h.step(cursor: CGPoint(x: 960, y: 540)) }
    #expect(h.last.spotlight.isActive == false)
    #expect(h.run(until: .resting, cursor: CGPoint(x: 960, y: 540)))
    #expect(h.run(until: .hidden, cursor: CGPoint(x: 960, y: 540), maxSeconds: 40))
}

@Test func exitingNeverDims() {
    let h = Harness()
    h.step(cursor: CGPoint(x: 960, y: 540), commands: [.summon])
    for _ in 0..<20 { h.step(cursor: CGPoint(x: 960, y: 540)) }
    #expect(h.last.spotlight.isActive)

    h.step(cursor: CGPoint(x: 960, y: 540), commands: [.dismiss])
    #expect(h.last.phase == .exiting)
    h.run(seconds: 0.5, cursor: CGPoint(x: 960, y: 540))
    #expect(h.last.spotlight.isActive == false)
}

