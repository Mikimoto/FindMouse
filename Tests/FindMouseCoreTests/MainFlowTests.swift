import CoreGraphics
import Foundation
import Testing
@testable import FindMouseCore
import FindMouseDomain

@Test func startsHiddenAndInvisible() {
    let h = Harness()
    #expect(h.last.phase == .hidden)
    #expect(h.last.isVisible == false)
    #expect(h.last.spotlight.isActive == false)
}

@Test func summonPlacesCatOffTheCursorScreenEdge() {
    let h = Harness()
    // 鼠標靠近左緣 → 貓從左邊外側進場
    let state = h.step(cursor: CGPoint(x: 100, y: 540), commands: [.summon])
    #expect(state.phase == .hunting)
    #expect(state.body.position.x < Harness.screen.minX)
}

@Test func fullLifecycleReachesHiddenAgain() {
    let h = Harness()
    h.step(commands: [.summon])
    #expect(h.run(until: .resting))
    // 休息 10 秒 → lyingDown → sleeping → 5 秒 → exiting → hidden
    #expect(h.run(until: .hidden, maxSeconds: 40))
    #expect(h.phases.contains(.lyingDown))
    #expect(h.phases.contains(.sleeping))
    #expect(h.phases.contains(.exiting))
}

@Test func arrivalHappensWithinArriveRadius() {
    let h = Harness()
    h.step(commands: [.summon])
    #expect(h.run(until: .resting))
    let arriveRadius = h.config.value.arriveRadius(logicalHeight: h.catalog.logicalHeight)
    #expect(h.last.distanceToCursor <= arriveRadius)
}

@Test func missingBrakeSkipsArriving() {
    let h = Harness(catalog: StubCatalog(dropping: [.brake]))
    h.step(commands: [.summon])
    #expect(h.run(until: .resting))
    #expect(h.phases.contains(.arriving) == false)
    #expect(h.phases.contains(.sitting))
}

@Test func missingLieDownSkipsLyingDown() {
    let h = Harness(catalog: StubCatalog(dropping: [.lieDown]))
    h.step(commands: [.summon])
    #expect(h.run(until: .sleeping, maxSeconds: 30))
    #expect(h.phases.contains(.lyingDown) == false)
}

@Test func transitionClipsPlayForTheirDeclaredDuration() {
    let h = Harness()   // StubCatalog：每個動作 2 格、10 fps → 每段 0.2 秒
    h.step(commands: [.summon])
    #expect(h.run(until: .arriving))

    var frames = 0
    while h.last.phase == .arriving && frames < 200 {
        h.step()
        frames += 1
    }
    // brake 有 2 格、10 fps，dt = 1/60，所以 arriving 至少要持續 12 帧。
    // 少了 enter() 或 syncAction() 裡的 actionElapsed 歸零，clipFinished 會在
    // 第一帧就成立，煞車動畫整段不播——而其餘 7 個測試全部照樣通過。
    #expect(frames >= 10, "arriving 只持續了 \(frames) 帧，brake 動畫沒播完")
}

@Test func repeatedDismissIsIdempotent() {
    let h = Harness()
    h.step(commands: [.summon])
    #expect(h.run(until: .resting))
    h.step(commands: [.dismiss])
    #expect(h.last.phase == .exiting)

    // 每帧再送一次 dismiss：仍然必須淡出並回到 hidden。
    // 沒有 goHome 的 exiting 守衛時，alpha 每帧被重設成 1、exitTarget 依新位置
    // 重算，貓永遠走不完也永遠不消失。
    for _ in 0..<1200 where h.last.phase != .hidden {
        h.step(commands: [.dismiss])
    }
    #expect(h.last.phase == .hidden)
}

@Test func dismissSendsCatHomeFromAnyVisiblePhase() {
    let h = Harness()
    h.step(commands: [.summon])
    #expect(h.run(until: .resting))
    h.step(commands: [.dismiss])
    #expect(h.last.phase == .exiting)
    #expect(h.run(until: .hidden, maxSeconds: 10))
}
