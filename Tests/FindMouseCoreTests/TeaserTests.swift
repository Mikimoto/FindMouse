import CoreGraphics
import Foundation
import Testing
@testable import FindMouseCore
import FindMouseDomain

private let center = CGPoint(x: 960, y: 540)

@Test func teaserUnavailablePackIgnoresCommand() {
    let h = Harness(catalog: StubCatalog(dropping: [.pounce]))
    #expect(h.last.teaserAvailable == false)
    h.step(commands: [.setTeaser(true)])
    #expect(h.last.phase == .hidden)
    #expect(h.last.teaserEnabled == false)
}

@Test func teaserFromHiddenApproachesThenStalks() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.last.phase == .teaserApproach)
    #expect(h.last.teaserEnabled)
    #expect(h.run(until: .teaserStalking, cursor: center))
    #expect(h.last.distanceToCursor <= h.config.value.teaserStalkRange)
}

@Test func stalkTimeoutTriggersWindupThenPounce() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.run(until: .teaserStalking, cursor: center))
    // 鼠標不動，靠 stalkTimeout（3 秒）觸發
    #expect(h.run(until: .teaserWindup, cursor: center, maxSeconds: 6))
    #expect(h.run(until: .teaserPouncing, cursor: center, maxSeconds: 2))
}

@Test func pounceHitsWhenCursorStaysPut() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.run(until: .teaserPouncing, cursor: center, maxSeconds: 12))
    #expect(h.run(until: .teaserTumbling, cursor: center, maxSeconds: 3))
}

@Test func pounceMissesWhenCursorMovesAwayAfterLockOn() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.run(until: .teaserPouncing, cursor: center, maxSeconds: 12))

    // 鎖定已發生。把鼠標挪到 hitRadius（60）之外，貓仍會撲向舊點 → 撲空
    let moved = CGPoint(x: center.x + 400, y: center.y)
    var reachedRetreat = false
    for _ in 0..<180 {
        h.step(cursor: moved)
        if h.last.phase == .teaserRetreating { reachedRetreat = true; break }
        if h.last.phase == .teaserTumbling { break }
    }
    #expect(reachedRetreat)
    #expect(h.phases.contains(.teaserTumbling) == false)
}

@Test func retreatReturnsToStalking() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.run(until: .teaserRetreating, cursor: center, maxSeconds: 20))
    let startDistance = h.last.distanceToCursor
    #expect(h.run(until: .teaserStalking, cursor: center, maxSeconds: 6))
    // 退開必須真的離開鼠標。原本這裡斷言「退開起點不等於鼠標」，那是個空洞的
    // 代理指標——命中時落點正好等於鼠標，所以它恆為 0；而且它根本沒測到方向。
    // 改成比較退開前後與鼠標的距離：退開結束時必須更遠。
    #expect(h.last.distanceToCursor > startDistance,
            "退開前距離 \(startDistance)，退開後 \(h.last.distanceToCursor)——貓沒有離開鼠標")
}

@Test func turningTeaserOffGoesHomeAtNextTransition() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.run(until: .teaserStalking, cursor: center))
    h.step(cursor: center, commands: [.setTeaser(false)])
    #expect(h.last.teaserEnabled == false)
    #expect(h.run(until: .exiting, cursor: center, maxSeconds: 8))
    #expect(h.run(until: .hidden, cursor: center, maxSeconds: 8))
}

@Test func summonWhileTeasingGoesHomeAndDisablesTeaser() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.run(until: .teaserStalking, cursor: center))
    h.step(cursor: center, commands: [.toggle])
    #expect(h.last.phase == .exiting)
    #expect(h.last.teaserEnabled == false)
}

@Test func teaserNeverDims() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    for _ in 0..<300 {
        h.step(cursor: center)
        #expect(h.last.spotlight.isActive == false)
    }
}
