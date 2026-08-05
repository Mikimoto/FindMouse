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

@Test func dismissSendsCatHomeFromAnyVisiblePhase() {
    let h = Harness()
    h.step(commands: [.summon])
    #expect(h.run(until: .resting))
    h.step(commands: [.dismiss])
    #expect(h.last.phase == .exiting)
    #expect(h.run(until: .hidden, maxSeconds: 10))
}
