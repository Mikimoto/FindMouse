import CoreGraphics
import Foundation
import Testing
@testable import FindMouseCore
import FindMouseDomain

private let center = CGPoint(x: 960, y: 540)

@Test func movingCursorBeyondThresholdRestartsHuntAndResetsRestTimer() {
    let h = Harness()
    h.step(commands: [.summon])
    #expect(h.run(until: .resting))
    h.run(seconds: 5)
    #expect(h.last.restTimer > 4)

    // 把鼠標移到遠處（超過 rehuntThreshold 160）
    let far = CGPoint(x: 960 + 600, y: 540)
    h.step(cursor: far)
    #expect(h.last.phase == .hunting)
    #expect(h.last.restTimer == 0)
}

@Test func smallCursorMovementDoesNotInterruptRestingOrResetTimer() {
    let h = Harness()
    h.step(commands: [.summon])
    #expect(h.run(until: .resting))

    // 連續小幅抖動 5 秒（每步 ±3pt，累積位移很大但距離始終在門檻內）
    var x: CGFloat = 960
    for i in 0..<300 {
        x += (i % 2 == 0) ? 3 : -3
        h.step(cursor: CGPoint(x: x, y: 540))
    }
    #expect(h.last.phase == .resting)
    #expect(h.last.restTimer > 4.5)
}

@Test func sleepingCatIgnoresSmallMovementButWakesOnLargeOne() {
    let h = Harness()
    h.step(commands: [.summon])
    #expect(h.run(until: .sleeping, maxSeconds: 30))

    // 小幅移動：低於 wakeThreshold（3 × 160 = 480），但高於 rehuntThreshold
    h.step(cursor: CGPoint(x: 960 + 200, y: 540))
    #expect(h.last.phase == .sleeping)

    // 大動作
    h.step(cursor: CGPoint(x: 960 + 700, y: 540))
    #expect(h.last.phase == .hunting)
}

@Test func flourishIsInterruptedImmediatelyByRehunt() {
    let h = Harness()
    h.step(commands: [.summon])
    #expect(h.run(until: .resting))

    // 推進到某個休息池動作正在播
    var sawFlourish = false
    for _ in 0..<600 {
        h.step()
        if CatAction.restPool.contains(h.last.action) { sawFlourish = true; break }
    }
    #expect(sawFlourish)

    h.step(cursor: CGPoint(x: 960 + 600, y: 540))
    #expect(h.last.phase == .hunting)
    #expect(h.last.action == .run)
}

@Test func flourishPlaysForItsDeclaredDuration() {
    let h = Harness()
    h.step(commands: [.summon])
    #expect(h.run(until: .resting))

    // 推進到某個休息池動作開始播
    var started = false
    for _ in 0..<600 {
        h.step()
        if CatAction.restPool.contains(h.last.action) { started = true; break }
    }
    #expect(started)

    var frames = 1
    while CatAction.restPool.contains(h.last.action) && frames < 200 {
        h.step()
        frames += 1
    }
    // 休息池動作 2 格、10 fps、dt = 1/60 → 至少 12 帧。
    // 這條釘住 syncAction() 裡的 actionElapsed 歸零：少了它，切進 flourish 時
    // actionElapsed 還是 sitIdle 累積的值，clipFinished 立刻成立，動作一帧就結束。
    #expect(frames >= 10, "休息動作只持續了 \(frames) 帧，syncAction 的 actionElapsed 沒有歸零")
}

@Test func emptyRestPoolFallsBackToSitIdle() {
    let h = Harness(catalog: StubCatalog(dropping: [.stretch, .yawn, .scratch]))
    h.step(commands: [.summon])
    #expect(h.run(until: .resting))
    h.run(seconds: 6)
    #expect(h.last.phase == .resting)
    #expect(h.last.action == .sitIdle)
}
