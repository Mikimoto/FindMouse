import CoreGraphics
import Foundation
import Testing
@testable import FindMouseCore
import FindMouseDomain

private let center = CGPoint(x: 960, y: 540)

/// 把貓帶到「已鎖定、正在飛行」的狀態，回傳（鎖定點, 起飛點）。
///
/// 為什麼要這麼繞：`teaserStalking` 沒有停止距離，以 135 px/s 朝鼠標走，
/// 3 秒 stalkTimeout 內走 405 px 而 stalkRange 只有 250，所以「靠 timeout 進 windup」
/// 的路徑貓已經貼在鼠標上（實測 2.08 px），撲擊只飛 1 帧——那條路徑測不到飛行段。
///
/// 構造：跑到 stalking 後，下一帧把鼠標往遠處跳 150 px。一帧跳 150 px 等於
/// 9000 px/s，遠超 teaserPounceTriggerSpeed(400)，所以立刻進 windup；而 windup
/// 期間貓不移動（`teaserWindup` 沒有 move），分離距離就被凍結在約 376 px，
/// 鎖定後才有 11 帧的真實彈道飛行。
private func lockOnFromAfar(_ h: Harness) -> (lock: CGPoint, launch: CGPoint) {
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.run(until: .teaserStalking, cursor: center))
    let lock = CGPoint(x: center.x, y: center.y + 150)
    h.step(cursor: lock)
    #expect(h.session.currentCursorSpeed > h.config.value.teaserPounceTriggerSpeed)
    #expect(h.last.phase == .teaserWindup,
            "鼠標速度 \(h.session.currentCursorSpeed) px/s 沒有觸發 windup：phase=\(h.last.phase)")
    #expect(h.run(until: .teaserPouncing, cursor: lock, maxSeconds: 2))
    return (lock, h.last.body.position)
}

/// 一路推進到離開 `phase`，回傳停留的帧數。
private func stepWhile(_ h: Harness, phase: CatPhase, cursor: CGPoint, limit: Int = 240) -> Int {
    var frames = 0
    while h.last.phase == phase && frames < limit {
        h.step(cursor: cursor)
        frames += 1
    }
    return frames
}

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

/// 退開必須真的朝「遠離鼠標」的方向直線走。
///
/// 這個測試走**撲空**路徑而不是命中路徑，因為命中時貓的落點正好等於鼠標
/// （startDistance == 0），任何位移都讓距離變大，所以「退開後比較遠」在命中路徑上
/// 是恆真句，對退開方向零覆蓋。
///
/// 構造：讓貓撲過頭——鼠標在飛行途中退到鎖定點**後方** 70 px（沿飛行方向），
/// 於是落點與鼠標相距 70 px（> hitRadius 60 → 撲空），而且鼠標恰好落在貓的正後方。
/// 正確的退開方向（遠離鼠標）因此與貓的 heading 完全一致、不需轉向，貓會直線走完
/// 整段退開路徑：540 px/s × retreat clip 0.2 s = 13 帧 × 9 px = 117 px，
/// 分離距離必須增加 117 px（實測 70 → 187）。
/// 任何錯誤的退開方向都得先轉 180°，而轉向上限 540°/s 在 13 帧內只能彎 117°，
/// 淨增量會被壓到 72 px 左右——所以門檻取 100 px 就能把方向釘住。
@Test func retreatMovesStraightAwayFromCursorAfterAMiss() {
    let h = Harness()
    let (lock, launch) = lockOnFromAfar(h)

    let flightLength = hypot(lock.x - launch.x, lock.y - launch.y)
    let ux = (lock.x - launch.x) / flightLength
    let uy = (lock.y - launch.y) / flightLength
    let overshoot: CGFloat = 70
    #expect(overshoot > h.config.value.teaserHitRadius)
    let behind = CGPoint(x: lock.x - ux * overshoot, y: lock.y - uy * overshoot)

    #expect(stepWhile(h, phase: .teaserPouncing, cursor: behind) > 1)
    #expect(h.last.phase == .teaserRetreating, "撲過頭 70 px 應判撲空：phase=\(h.last.phase)")
    let startDistance = h.last.distanceToCursor
    #expect(abs(startDistance - overshoot) < 0.001)

    #expect(stepWhile(h, phase: .teaserRetreating, cursor: behind) > 1)
    #expect(h.last.phase == .teaserStalking)
    let gained = h.last.distanceToCursor - startDistance
    #expect(gained > 100,
            "退開只讓分離距離增加 \(gained) px（\(startDistance) → \(h.last.distanceToCursor)），退開方向不是遠離鼠標")
}

/// 撲擊必須真的飛一段距離，而且落在**鎖定點**上。
///
/// 這是唯一覆蓋撲擊彈道的測試：其他測試都走 stalkTimeout 路徑，那條路徑貓已貼在
/// 鼠標上、撲擊只有 1 帧，把 `pounceTarget = cursor` 改成 `pounceTarget = body.position`
/// （貓根本不撲）也不會有任何測試轉紅。
@Test func pounceFliesRealDistanceAndLandsOnLockedPoint() {
    let h = Harness()
    let (lock, launch) = lockOnFromAfar(h)
    let flight = hypot(lock.x - launch.x, lock.y - launch.y)
    #expect(flight > 100, "撲擊起點與鎖定點只差 \(flight) px，飛行段沒被測到")

    // 鼠標停在鎖定點不動 → 落點等於鎖定點，判定命中
    let frames = stepWhile(h, phase: .teaserPouncing, cursor: lock)
    #expect(frames > 5, "撲擊只飛了 \(frames) 帧")
    #expect(h.last.phase == .teaserTumbling)
    #expect(h.last.body.position == lock, "落點 \(h.last.body.position) 不等於鎖定點 \(lock)")
    let travelled = hypot(h.last.body.position.x - launch.x, h.last.body.position.y - launch.y)
    #expect(travelled > 100, "貓實際只飛了 \(travelled) px")
}

/// 鎖定後鼠標小幅漂移（< teaserHitRadius）仍算命中——把 hitRadius 的數值釘住。
@Test func pounceStillHitsWhenCursorDriftsWithinHitRadius() {
    let h = Harness()
    let (lock, _) = lockOnFromAfar(h)
    // 30 px 刻意落在 0 與 hitRadius(60) 之間：把判定式從 `> hitRadius` 改成 `> 0`
    // 就會把這一次判成撲空。
    let drift: CGFloat = 30
    #expect(drift > 0)
    #expect(drift < h.config.value.teaserHitRadius)
    let moved = CGPoint(x: lock.x + drift, y: lock.y)

    #expect(stepWhile(h, phase: .teaserPouncing, cursor: moved) > 1)
    #expect(h.last.body.position == lock)
    #expect(abs(h.last.distanceToCursor - drift) < 0.001)
    #expect(h.last.phase == .teaserTumbling,
            "落點離鼠標只有 \(h.last.distanceToCursor) px（hitRadius \(h.config.value.teaserHitRadius)）卻被判成撲空")
}

/// 關掉再開啟逗貓棒，必須取消掉那次還沒被消費的「下次轉換就回家」。
@Test func reEnablingTeaserCancelsPendingExit() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.run(until: .teaserStalking, cursor: center))

    h.step(cursor: center, commands: [.setTeaser(false)])   // pendingExit latch 起來
    #expect(h.last.teaserEnabled == false)
    h.step(cursor: center, commands: [.setTeaser(true)])    // 必須把 latch 清掉
    #expect(h.last.teaserEnabled)
    #expect(h.last.phase.isTeaser,
            "重新開啟的同一帧就被 pendingExit 送回家：phase=\(h.last.phase)")

    h.run(seconds: 10, cursor: center)
    #expect(h.last.phase.isTeaser, "10 秒後貓不在逗貓棒階段：phase=\(h.last.phase)")
    #expect(h.phases.contains(.exiting) == false, "出現退場：\(h.phases)")
}

/// retreat clip 夠長時，貓走到 retreatPoint 就結束退開，不會傻等 clip 播完。
///
/// 預設 StubCatalog（fps 10）的 retreat clip 只有 0.2 s，貓 13 帧走 117 px 就被
/// clipFinished 叫走，永遠碰不到 arrivedAtRetreat；fps 5 讓 clip 變成 0.4 s（24 帧），
/// 而走到距 retreatPoint(150 px) 4 px 內只需 17 帧（17 × 9 = 153），
/// 於是 arrivedAtRetreat 先成立。
@Test func retreatEndsOnArrivalWhenRetreatClipIsLong() {
    let h = Harness(catalog: StubCatalog(fps: 5))
    let (lock, launch) = lockOnFromAfar(h)
    let flightLength = hypot(lock.x - launch.x, lock.y - launch.y)
    let behind = CGPoint(x: lock.x - (lock.x - launch.x) / flightLength * 70,
                         y: lock.y - (lock.y - launch.y) / flightLength * 70)
    #expect(stepWhile(h, phase: .teaserPouncing, cursor: behind) > 1)
    #expect(h.last.phase == .teaserRetreating)

    let clipFrames = Int((h.catalog.clip(for: .retreat)?.duration ?? 0) * 60)
    #expect(clipFrames > 20)
    let startPosition = h.last.body.position
    let frames = stepWhile(h, phase: .teaserRetreating, cursor: behind)
    #expect(h.last.phase == .teaserStalking)
    #expect(frames < clipFrames,
            "退開跑了 \(frames) 帧，等於 clip 全長 \(clipFrames) 帧——沒有在抵達時結束")
    let travel = hypot(h.last.body.position.x - startPosition.x,
                       h.last.body.position.y - startPosition.y)
    #expect(abs(travel - h.config.value.teaserRetreatDistance) < 9.5,
            "退開走了 \(travel) px，與 teaserRetreatDistance \(h.config.value.teaserRetreatDistance) 不符")
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
