// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import Testing
@testable import FindMouseCore
import FindMouseDomain

private let center = CGPoint(x: 960, y: 540)

/// 把貓帶到「已鎖定、正在飛行」的狀態，回傳（鎖定點, 起飛點）。
///
/// 構造：跑到 stalking 後，下一帧把鼠標往遠處跳 150 px。一帧跳 150 px 等於
/// 9000 px/s，遠超 teaserPounceTriggerSpeed(400)，所以立刻進 windup；而 windup
/// 期間貓不移動（`teaserWindup` 沒有 move），分離距離就被凍結在約 376 px，
/// 鎖定後才有 11 帧的真實彈道飛行。
///
/// 為什麼要跳鼠標而不是等 stalkTimeout：這個構造同時是
/// `teaserPounceTriggerSpeed` 那條離開條件的唯一覆蓋。等 timeout 的路徑由
/// `stalkingKeepsItsDistanceSoThePounceHasARealFlight` 覆蓋，它也有飛行段
/// （潛行的停止距離讓貓停在 stalkRange 上）。
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

/// 潛行有停止距離：貓進到 stalkRange 之後就不再靠近，於是等 timeout 的撲擊
/// 也有真實飛行段。
///
/// 這條規則的理由在 `CatSessionUseCase` 的 `case .teaserStalking` 註解裡：
/// 沒有停止距離的話貓會貼到鼠標腳邊，撲擊只飛 1 帧，撲空結構上不可能，
/// 而 spec 第 4.5 節說撲空正是逗貓棒的全部樂趣。
@Test func stalkingKeepsItsDistanceSoThePounceHasARealFlight() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.run(until: .teaserStalking, cursor: center))

    // 鼠標全程不動，所以離開 stalking 只能靠 stalkTimeout（3 秒）。
    // 潛行期間距離一次都不許減少——這就是「不再靠近」。
    // 停住的位置比 stalkRange 略小，最多小兩個 approach 步長（2 × 900/60 = 30 px）：
    // teaserApproach 的離開判定用的是**移動前**的距離，所以跨過 250 的那一帧不觸發
    // （當帧移動前還 > 250），下一帧才觸發，而那一帧又走了 15 px。實測 229.3 px。
    let atEntry = h.last.distanceToCursor
    let approachStep = h.config.value.catSpeed / 60
    #expect(atEntry > h.config.value.teaserStalkRange - 2 * approachStep - 1,
            "進入潛行時距離只有 \(atEntry) px，構造有問題")
    var closest = atEntry
    var frames = 0
    while h.last.phase == .teaserStalking && frames < 240 {
        h.step(cursor: center)
        closest = min(closest, h.last.distanceToCursor)
        frames += 1
    }
    #expect(h.last.phase == .teaserWindup)
    #expect(closest >= atEntry - 0.001,
            "潛行從 \(atEntry) px 靠近到 \(closest) px，停止距離沒有生效")

    // 貓在 windup 期間不移動，所以起飛點就是潛行停住的位置，
    // 而彈道是直線且末帧精確落在鎖定點，因此飛行距離恰等於停住時的距離。
    let launch = h.last.body.position
    #expect(h.run(until: .teaserPouncing, cursor: center, maxSeconds: 2))
    let flightFrames = stepWhile(h, phase: .teaserPouncing, cursor: center)
    let flown = hypot(h.last.body.position.x - launch.x, h.last.body.position.y - launch.y)
    #expect(flightFrames > 5, "撲擊只飛了 \(flightFrames) 帧")
    #expect(abs(flown - atEntry) < 0.001, "撲擊飛了 \(flown) px，停住時距離是 \(atEntry) px")
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

/// 鎖定後鼠標小幅漂移（< teaserHitRadius）仍算命中——命中半徑的**下界**。
///
/// 這條與 `pounceMissesWhenTheDriftIsJustOutsideHitRadius` 是一對：0.9 倍半徑命中、
/// 1.1 倍半徑撲空，兩條合起來把判定邊界夾在 `teaserHitRadius` 的 ±10% 內。
///
/// drift 原本取 30——半徑（60）的正好一半，而判定是嚴格 `>`。於是把判定式改成
/// `> teaserHitRadius * 0.5` 時 `30 > 30` 為 false，這一次仍判命中，整批全綠：
/// 有效命中半徑被砍半（貓變得很難抓到）而零訊號。改成 0.9 倍就落在任何縮小的
/// 門檻之外。它原本要防的「把 `> hitRadius` 寫成 `> 0`」在 0.9 倍下同樣會紅。
///
/// 半徑本身的數值（60）由 `defaultsMatchSpec` 釘住，所以這裡的 drift 從設定推導，
/// 只驗「命中判定真的拿那個半徑在比」。
@Test func pounceStillHitsWhenCursorDriftsWithinHitRadius() {
    let h = Harness()
    let (lock, _) = lockOnFromAfar(h)
    let drift = h.config.value.teaserHitRadius * 0.9   // 預設 54 px
    let moved = CGPoint(x: lock.x + drift, y: lock.y)

    #expect(stepWhile(h, phase: .teaserPouncing, cursor: moved) > 1)
    #expect(h.last.body.position == lock)
    #expect(abs(h.last.distanceToCursor - drift) < 0.001)
    #expect(h.last.phase == .teaserTumbling,
            "落點離鼠標只有 \(h.last.distanceToCursor) px（hitRadius \(h.config.value.teaserHitRadius)）卻被判成撲空")
}

/// 鎖定後鼠標漂到 teaserHitRadius 之外就是撲空——命中半徑的**上界**。
///
/// 既有的 `pounceMissesWhenCursorMovesAwayAfterLockOn` 把鼠標挪 400 px、
/// `retreatMovesStraightAwayFromCursorAfterAMiss` 撲過頭 70 px，兩者離邊界都太遠：
/// 半徑放大到 1.1 倍（66）以內照樣全綠。這條只挪出 10%，讓「半徑悄悄變大」
/// ——撲擊變成百發百中，spec 第 4.5 節說那等於毀掉逗貓棒——也有訊號。
@Test func pounceMissesWhenTheDriftIsJustOutsideHitRadius() {
    let h = Harness()
    let (lock, _) = lockOnFromAfar(h)
    let drift = h.config.value.teaserHitRadius * 1.1   // 預設 66 px
    let moved = CGPoint(x: lock.x + drift, y: lock.y)

    #expect(stepWhile(h, phase: .teaserPouncing, cursor: moved) > 1)
    #expect(h.last.body.position == lock)
    #expect(abs(h.last.distanceToCursor - drift) < 0.001)
    #expect(h.last.phase == .teaserRetreating,
            "落點離鼠標 \(h.last.distanceToCursor) px 已超過 hitRadius \(h.config.value.teaserHitRadius)，卻被判成命中")
    #expect(h.phases.contains(.teaserTumbling) == false, "出現翻滾：\(h.phases)")
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

/// 不變式：`teaserEnabled` 為真時，phase 必為 teaser 階段。
///
/// 沒有任何一行程式碼在執行這條不變式——它是三條進 `.hunting` 的路徑各自的性質
/// 疊出來的結果。M1 有兩處倚賴它：`teaserNeverDims`（暗幕不出現的真正原因）
/// 與 `armSpotlight` 的 `!teaserEnabled` 為什麼餵不到輸入。所以它需要自己的測試，
/// 否則哪天被打破了不會有任何訊號，而那條防禦條件會靜默變成 load-bearing。
@Test func teaserEnabledImpliesTeaserPhase() {
    // 手工序列：三條進 .hunting 的路徑各自為什麼與 teaser 不共存
    let onSummon = Harness()
    onSummon.step(cursor: center, commands: [.setTeaser(true)])
    #expect(onSummon.run(until: .teaserStalking, cursor: center))
    onSummon.step(cursor: center, commands: [.summon])
    #expect(onSummon.last.teaserEnabled)
    #expect(onSummon.last.phase.isTeaser, "summon 把貓拉出了 teaser：\(onSummon.last.phase)")

    let onToggle = Harness()
    onToggle.step(cursor: center, commands: [.setTeaser(true)])
    #expect(onToggle.run(until: .teaserStalking, cursor: center))
    onToggle.step(cursor: center, commands: [.toggle])
    #expect(onToggle.last.teaserEnabled == false, "toggle 沒有關掉逗貓棒")
    #expect(onToggle.last.phase == .exiting)

    // 休息中開逗貓棒，同時把鼠標跳遠：rehunt 的距離條件成立但走不到，
    // 因為 setTeaser 在同一帧的命令階段就把 phase 換成 teaser 階段了
    let onRehunt = Harness()
    onRehunt.step(cursor: center, commands: [.summon])
    #expect(onRehunt.run(until: .resting, cursor: center))
    let farAway = CGPoint(x: center.x + 800, y: center.y)
    onRehunt.step(cursor: farAway, commands: [.setTeaser(true)])
    #expect(onRehunt.last.teaserEnabled)
    #expect(onRehunt.last.phase.isTeaser, "rehunt 搶先了：\(onRehunt.last.phase)")

    // 亂序掃描：手工序列只覆蓋我想到的路徑，而這條不變式的價值在於沒想到的那些
    let deck: [Command] = [.summon, .dismiss, .toggle,
                           .setTeaser(true), .setTeaser(false), .toggleTeaser]
    var violations: [String] = []
    var teaserFrames = 0
    for seed in UInt64(1)...200 {
        let h = Harness(seed: seed)
        let rng = SeededRandomizer(seed: seed &* 2_654_435_761)
        for _ in 0..<200 {
            let cursor = CGPoint(x: rng.double(in: 0...1920), y: rng.double(in: 0...1080))
            h.step(cursor: cursor, commands: rng.pick(deck).map { [$0] } ?? [])
            guard h.last.teaserEnabled else { continue }
            teaserFrames += 1
            if !h.last.phase.isTeaser {
                violations.append("seed \(seed) phase=\(h.last.phase)")
            }
        }
    }
    #expect(violations.isEmpty, "不變式被打破：\(violations.prefix(5))")
    // 掃描若從未讓 teaser 開起來，violations 會恆為空——那是恆真句不是驗證
    #expect(teaserFrames > 1000,
            "40000 帧裡只有 \(teaserFrames) 帧 teaserEnabled 為真，掃描沒有實際檢查到不變式")
}

/// spec 第 5.2 節：逗貓棒的任何階段暗幕都是 0。
///
/// 注意這個測試**沒有**釘住 `armSpotlight` 裡的 `!teaserEnabled`——把那個條件
/// 拿掉本測試照樣綠。真正讓 teaser 不變暗的是
/// `updateSpotlight(fadingIn: phase == .hunting)` 加上「teaser 開著時 phase 必為
/// teaser 階段」這個不變式，見 `teaserEnabledImpliesTeaserPhase`。
@Test func teaserNeverDims() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    for _ in 0..<300 {
        h.step(cursor: center)
        #expect(h.last.spotlight.isActive == false)
    }
}

// MARK: - M5：spec 第 3.2 / 4.5 節逐條補上的守衛
//
// 以下每一條都由 mutation 反推：先破壞它要守的那一行，確認既有 330 條**全綠**，
// 才把測試寫下來。沒有這一步的話，「多一條測試」與「多一條恆真句」分不出來。

/// 命中之後不能永遠抱著滾——翻滾播完要退開，退開完要重新潛伏（spec 第 4.5 節）。
///
/// 這是整條命中路徑唯一沒被走完的一段：`pounceHitsWhenCursorStaysPut`、
/// `pounceFliesRealDistanceAndLandsOnLockedPoint`、
/// `pounceStillHitsWhenCursorDriftsWithinHitRadius` 三條都停在 `teaserTumbling`
/// 就結束，而唯一驗到 `teaserRetreating` 的 `retreatEndsOnArrivalWhenRetreatClipIsLong`
/// 走的是**撲空**那條。實測把 `clipFinished(.tumble)` 的判定關掉（貓永遠抱著滾），
/// 330 條測試一條都不紅。
///
/// 這裡刻意**不**斷言退開的方向與距離：命中且鼠標靜止時落點正好等於鼠標，
/// `retreatDestination` 的方向向量退化，那是 `CatSessionUseCase` 註解裡記載的
/// 已知限制，不是這條要守的東西。
@Test func aHitTumblesThenBacksOffAndReturnsToStalking() {
    let h = Harness()
    let (lock, _) = lockOnFromAfar(h)
    #expect(stepWhile(h, phase: .teaserPouncing, cursor: lock) > 1)
    #expect(h.last.phase == .teaserTumbling, "鼠標停在鎖定點上應判命中：phase=\(h.last.phase)")

    let clipFrames = Int((h.catalog.clip(for: .tumble)?.duration ?? 0) * 60)
    #expect(clipFrames > 1, "tumble clip 只有 \(clipFrames) 帧，測不到「播完」")
    let frames = stepWhile(h, phase: .teaserTumbling, cursor: lock)
    #expect(h.last.phase == .teaserRetreating,
            "翻滾了 \(frames) 帧仍然沒有退開：phase=\(h.last.phase)")
    #expect(frames <= clipFrames + 1,
            "翻滾跑了 \(frames) 帧，tumble clip 只有 \(clipFrames) 帧")
    #expect(h.run(until: .teaserStalking, cursor: lock, maxSeconds: 3),
            "退開之後沒有回到潛伏：phase=\(h.last.phase)")
}

/// spec 第 4.5 節「播放動作」那一欄：六個逗貓棒階段各自播自己的 clip。
///
/// 只有 `teaserPouncing` 被釘住（`RobustnessTests` 的 frameIndex 測試順手斷言了
/// `action == .pounce`）；其餘五個對應改成 `.sitIdle` 都不會有任何測試轉紅。
/// 這條同時是命中循環的完整性檢查——`seen` 少了任何一個階段就代表循環斷在那裡。
@Test func everyTeaserPhasePlaysTheActionTheSpecAssignsIt() {
    let expected: [CatPhase: CatAction] = [
        .teaserApproach: .run,
        .teaserStalking: .stalk,
        .teaserWindup: .windup,
        .teaserPouncing: .pounce,
        .teaserTumbling: .tumble,
        .teaserRetreating: .retreat,
    ]
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])

    var seen = Set<CatPhase>()
    var wrong: [String] = []
    // 鼠標全程不動：靠 stalkTimeout 觸發撲擊，落點等於鎖定點 → 必定命中，
    // 所以一輪就走得完「接近 → 潛伏 → 屁股搖 → 撲擊 → 翻滾 → 退開 → 潛伏」。
    // 600 帧（10 秒）對這一輪（實測約 280 帧）有兩倍餘裕。
    for _ in 0..<600 {
        h.step(cursor: center)
        guard let want = expected[h.last.phase] else { continue }
        seen.insert(h.last.phase)
        if h.last.action != want {
            wrong.append("\(h.last.phase) 播的是 \(h.last.action)，spec 說 \(want)")
        }
    }
    #expect(wrong.isEmpty, "\(wrong.prefix(3))")
    #expect(seen == Set(expected.keys),
            "這一輪沒走到的階段：\(Set(expected.keys).subtracting(seen))")
}

/// 潛伏時「朝向跟隨鼠標」（spec 第 3.2 節第 2 條、第 4.5 節）。
///
/// 實作靠的是 `move(toward: cursor, speed: 0)`——只轉不走。既有測試只斷言
/// 「距離沒有變小」，所以把整個 `move` 拿掉（朝向凍結）或把目標換成貓自己
/// （朝向一律轉向 +x）都照樣全綠：停止距離與朝向是同一行的兩個效果，
/// 只驗前者等於沒驗後者。
///
/// 構造：讓鼠標**繞著貓**轉。半徑取進入潛伏時的距離（實測 229 px < stalkRange 250），
/// 所以潛行速度恆為 0、貓一步都不會動，唯一會變的就是朝向。角速度 1.2 rad/s
/// 讓切線速度約 275 px/s，低於 teaserPounceTriggerSpeed(400) 而不會提早觸發屁股搖；
/// 150 帧（2.5 秒）也還沒到 stalkTimeout(3 秒)。
@Test func stalkingKeepsFacingTheCursorWhileStandingStill() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.run(until: .teaserStalking, cursor: center))

    let cat = h.last.body.position
    let radius = h.last.distanceToCursor
    #expect(radius < h.config.value.teaserStalkRange,
            "進入潛伏時距離 \(radius) 已超過 stalkRange，貓會爬行而不是原地轉")
    let startAngle = atan2(center.y - cat.y, center.x - cat.x)
    let startHeading = h.last.body.heading

    let omega: CGFloat = 1.2
    var cursor = center
    var frames = 0
    while frames < 150 && h.last.phase == .teaserStalking {
        frames += 1
        let angle = startAngle + omega * CGFloat(frames) / 60
        cursor = CGPoint(x: cat.x + cos(angle) * radius, y: cat.y + sin(angle) * radius)
        h.step(cursor: cursor)
    }
    #expect(frames == 150, "只轉了 \(frames) 帧就離開潛伏：phase=\(h.last.phase)")
    #expect(h.last.phase == .teaserStalking)
    #expect(h.last.body.position == cat,
            "潛伏時貓移動了：\(cat) → \(h.last.body.position)")

    let bearing = atan2(cursor.y - h.last.body.position.y, cursor.x - h.last.body.position.x)
    let offBy = abs(Kinematics.normalizeAngle(bearing - h.last.body.heading))
    #expect(offBy < 0.02, "朝向落後鼠標 \(offBy * 180 / .pi)°")
    // 鼠標繞了 172°，朝向若沒跟著轉，上面那條就是恆真句
    let turned = abs(Kinematics.normalizeAngle(h.last.body.heading - startHeading))
    #expect(turned > 1.0, "朝向只轉了 \(turned * 180 / .pi)°，構造沒逼它轉")
}

/// 潛行速度是 `cat.speed × 0.15`（spec 第 4.5 節末段的衍生值）。
///
/// 這個係數只在**鼠標跑到 stalkRange 之外**時才生效——既有測試全都讓鼠標停在
/// 原地，貓一直落在停止距離內、速度恆為 0，所以把 0.15 改成 1.0 不會有任何訊號。
///
/// 構造：進入潛伏後把鼠標沿著「貓 → 鼠標」的延長線每帧拉遠 5 px（300 px/s，
/// 低於撲擊觸發速度 400），於是前幾帧仍在範圍內（貓不動），之後每一帧都在範圍外
/// （貓爬行）。兩段都要斷言，否則「一律用全速」與「一律不動」各能矇混一半。
@Test func stalkingCreepsAtFifteenPercentWhenTheCursorSlipsOutOfRange() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.run(until: .teaserStalking, cursor: center))

    let cat = h.last.body.position
    let entry = h.last.distanceToCursor
    let ux = (center.x - cat.x) / entry
    let uy = (center.y - cat.y) / entry
    let creepStep = h.config.value.catSpeed * Timings.stalkSpeedFactor / 60

    var creeps: [CGFloat] = []
    var stills: [CGFloat] = []
    for i in 1...150 {
        let cursor = CGPoint(x: center.x + ux * 5 * CGFloat(i),
                             y: center.y + uy * 5 * CGFloat(i))
        let before = h.last.body.position
        // 狀態機用的是**移動前**的距離，所以這裡自己算同一個值，
        // 不能用移動後的 `distanceToCursor` 去回推它當時走的是哪一支。
        let used = hypot(cursor.x - before.x, cursor.y - before.y)
        h.step(cursor: cursor)
        guard h.last.phase == .teaserStalking else { break }
        let moved = hypot(h.last.body.position.x - before.x,
                          h.last.body.position.y - before.y)
        if used > h.config.value.teaserStalkRange { creeps.append(moved) } else { stills.append(moved) }
    }

    #expect(stills.count >= 3, "只量到 \(stills.count) 帧「還在範圍內」")
    #expect(stills.allSatisfy { $0 == 0 }, "範圍內的貓移動了：\(stills.prefix(3))")
    #expect(creeps.count >= 50, "只量到 \(creeps.count) 帧爬行，樣本太少")
    #expect(creeps.allSatisfy { abs($0 - creepStep) < 1e-6 },
            "爬行速度不是 cat.speed × \(Timings.stalkSpeedFactor)（每帧應 \(creepStep) px）：\(creeps.prefix(3))")
}

/// 撲擊用 `teaser.pounceSpeed`、退開用 `cat.speed × 0.6`（spec 第 4.5 節末段）。
///
/// 既有測試只斷言「飛了幾帧」「飛了多遠」「退開後距離增加多少」，那些量在速度被
/// 換成 `cat.speed` 之後全都還成立（只是慢了、帧數變多），所以兩個速度都沒有被釘住。
/// 這裡量的是**每一帧的位移**，它就是 speed × dt 本身。
///
/// 走撲空路徑（撲過頭 70 px）而不是命中路徑：命中時落點等於鼠標，退開方向退化，
/// 帧數會被 `arrivedAtRetreat` 干擾；撲空讓退開全程由 clip 長度決定。
@Test func pouncingAndRetreatingEachRunAtTheirOwnSpeed() {
    let h = Harness()
    let (lock, launch) = lockOnFromAfar(h)
    let flightLength = hypot(lock.x - launch.x, lock.y - launch.y)
    let ux = (lock.x - launch.x) / flightLength
    let uy = (lock.y - launch.y) / flightLength
    let behind = CGPoint(x: lock.x - ux * 70, y: lock.y - uy * 70)

    let pounceStep = h.config.value.teaserPounceSpeed / 60
    var pounces: [CGFloat] = []
    for _ in 0..<240 where h.last.phase == .teaserPouncing {
        let before = h.last.body.position
        h.step(cursor: behind)
        // 最後一帧被 `ballisticStep` 夾在鎖定點上（走不滿一步），不計入
        guard h.last.phase == .teaserPouncing else { break }
        pounces.append(hypot(h.last.body.position.x - before.x,
                             h.last.body.position.y - before.y))
    }
    #expect(pounces.count >= 5, "只量到 \(pounces.count) 帧飛行")
    #expect(pounces.allSatisfy { abs($0 - pounceStep) < 1e-6 },
            "撲擊每帧應飛 \(pounceStep) px（teaser.pounceSpeed \(h.config.value.teaserPounceSpeed)）：\(pounces.prefix(3))")

    #expect(h.last.phase == .teaserRetreating, "撲過頭 70 px 應判撲空：phase=\(h.last.phase)")
    let retreatStep = h.config.value.catSpeed * Timings.retreatSpeedFactor / 60
    var retreats: [CGFloat] = []
    for _ in 0..<240 where h.last.phase == .teaserRetreating {
        let before = h.last.body.position
        h.step(cursor: behind)
        retreats.append(hypot(h.last.body.position.x - before.x,
                              h.last.body.position.y - before.y))
    }
    #expect(retreats.count >= 5, "只量到 \(retreats.count) 帧退開")
    #expect(retreats.allSatisfy { abs($0 - retreatStep) < 1e-6 },
            "退開每帧應走 \(retreatStep) px（cat.speed × \(Timings.retreatSpeedFactor)）：\(retreats.prefix(3))")
}

/// 貓不在畫面上時開逗貓棒要**從畫面外的入場點**進場，而且接近用 `cat.speed`
/// （spec 第 3.2 節第 1 條、第 4.5 節）。
///
/// 既有的 `teaserFromHiddenApproachesThenStalks` 只斷言 phase 與最終距離，
/// 所以把 `body = edgePoint(...)` 那行拿掉（貓從上一次停的地方憑空出現）
/// 或把接近速度砍到 0.2 倍都照樣綠——`run(until:)` 只是多跑幾帧而已。
@Test func teaserFromHiddenEntersFromOffScreenAtFullCatSpeed() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.last.phase == .teaserApproach)

    // 命令與推進在同一次 tick 裡，所以讀到的已經是「入場點走了一步之後」。
    // 因此斷言寫成「仍在畫面外，且離邊緣還有將近一個貓身」，而不是精確座標。
    let entry = h.last.body.position
    let bodyLength = h.catalog.logicalHeight * h.config.value.catScale
    let perFrame = h.config.value.catSpeed / 60
    #expect(Harness.screen.contains(entry) == false, "入場點 \(entry) 在畫面裡")
    #expect(Harness.screen.minY - entry.y > bodyLength - perFrame - 1,
            "貓只在畫面下緣外 \(Harness.screen.minY - entry.y) px，不足一個貓身 \(bodyLength)")

    var steps: [CGFloat] = []
    for _ in 0..<240 where h.last.phase == .teaserApproach {
        let before = h.last.body.position
        h.step(cursor: center)
        steps.append(hypot(h.last.body.position.x - before.x,
                           h.last.body.position.y - before.y))
    }
    #expect(h.last.phase == .teaserStalking)
    #expect(steps.count >= 5, "接近只跑了 \(steps.count) 帧")
    #expect(steps.allSatisfy { abs($0 - perFrame) < 1e-6 },
            "接近每帧應跑 \(perFrame) px（cat.speed）：\(steps.prefix(3))")
}

/// 屁股搖 0.5 秒（spec 第 3.2 節第 3 條、第 4.5 節）。
///
/// 既有測試只驗「windup 之後會進 pouncing」，把門檻改成 `>= 0` 讓屁股搖變成
/// 一帧也全綠——而那正是使用者唯一看得到的那段蓄力。
@Test func windupLastsHalfASecondBeforeTheLockOn() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.run(until: .teaserWindup, cursor: center, maxSeconds: 8))

    let frames = stepWhile(h, phase: .teaserWindup, cursor: center)
    #expect(h.last.phase == .teaserPouncing)
    let wanted = Int((Timings.windup * 60).rounded())
    #expect(abs(frames - wanted) <= 1,
            "屁股搖了 \(frames) 帧（\(Double(frames) / 60) 秒），spec 說 \(Timings.windup) 秒")
}

/// 逗貓棒模式下貓不會自動退場（spec 第 3.2 節第 7 條後半）。
///
/// 這是結構性保證：`restTimer` / `sleepTimer` 只在 `.resting` / `.sleeping` 裡累加，
/// teaser 階段碰不到。但「結構上做不到」與「有測試守著」是兩件事——把
/// `restTimer += dt` 搬進潛伏、再加一條 `restTimer >= restDuration → goHome`
/// （也就是把主流程的自動退場接進逗貓棒），330 條測試一條都不紅。
///
/// 跑 (rest + sleep) × 2 + 10 秒，涵蓋兩輪完整的「休息 → 睡著 → 退場」時程。
@Test func teaserModeNeverSendsTheCatHomeOnItsOwn() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    let cfg = h.config.value
    let seconds = (cfg.restDuration + cfg.sleepDuration) * 2 + 10

    var leftTeaser: [String] = []
    var timerRan: [String] = []
    var windups = 0
    var previous = h.last.phase
    for _ in 0..<Int(seconds * 60) {
        h.step(cursor: center)
        if !h.last.phase.isTeaser { leftTeaser.append("\(h.last.phase)") }
        if h.last.restTimer != 0 || h.last.sleepTimer != 0 {
            timerRan.append("\(h.last.phase) rest=\(h.last.restTimer) sleep=\(h.last.sleepTimer)")
        }
        if h.last.phase == .teaserWindup && previous != .teaserWindup { windups += 1 }
        previous = h.last.phase
    }
    #expect(leftTeaser.isEmpty, "\(seconds) 秒內離開了逗貓棒：\(leftTeaser.prefix(3))")
    #expect(timerRan.isEmpty, "退場計時器在逗貓棒階段跑了：\(timerRan.prefix(3))")
    // 沒有這條，「貓卡在某個 teaser 階段完全不動」也會讓上面兩條通過
    #expect(windups >= 3, "\(seconds) 秒只撲了 \(windups) 次，貓其實卡住了")
}

/// 從休息中切進逗貓棒，`status --json` 不得再回報休息計時器（spec 第 8.4 節）。
///
/// 上一條也斷言逗貓棒期間兩個計時器都是 0，但它從 `.hidden` 開逗貓棒——那時計時器
/// 本來就是 0，所以把清除拿掉照樣綠。真正會帶著殘值切進來的是「貓已經坐下休息了
/// 5 秒」這條路徑：計時器只在 `.resting` 累加，卻只在 `enter(.hidden)` 與
/// `restartHunt` 歸零，於是整段逗貓棒都回報 `rest=5`——一個根本沒在跑的計時器。
///
/// **不能只驗切進去那一帧。** 「進去時清了、下一帧又被加回來」是另一種壞法，
/// 所以後面要再跑一整段，並用撲擊次數確認貓不是卡在某個階段不動。
@Test func startingTheTeaserFromRestStopsReportingTheRestTimer() {
    let h = Harness()
    h.step(cursor: center, commands: [.summon])
    #expect(h.run(until: .resting, cursor: center))
    h.run(seconds: 5, cursor: center)
    // 前提：計時器真的累積了。沒有這條，下面整條是恆真句。
    #expect(h.last.restTimer > 4, "休息才累積 \(h.last.restTimer) 秒，殘值看不出來")

    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.last.phase.isTeaser, "沒進逗貓棒：phase=\(h.last.phase)")
    #expect(h.last.restTimer == 0, "切進逗貓棒的那一帧還在回報 rest=\(h.last.restTimer)")

    var stale: [String] = []
    var windups = 0
    var previous = h.last.phase
    for _ in 0..<900 {
        h.step(cursor: center)
        if h.last.restTimer != 0 || h.last.sleepTimer != 0 {
            stale.append("\(h.last.phase) rest=\(h.last.restTimer) sleep=\(h.last.sleepTimer)")
        }
        if h.last.phase == .teaserWindup && previous != .teaserWindup { windups += 1 }
        previous = h.last.phase
    }
    #expect(h.last.phase.isTeaser, "15 秒後離開了逗貓棒：phase=\(h.last.phase)")
    // 貓若卡在某個階段完全不動，「計時器一路都是 0」也會通過
    #expect(windups >= 2, "15 秒只撲了 \(windups) 次，貓其實卡住了")
    #expect(stale.isEmpty, "逗貓棒期間回報了沒在跑的計時器：\(stale.prefix(3))")
}

/// 追蹤中途切到逗貓棒，暗幕要**當帧**熄掉（spec 第 3.2 節第 7 條前半）。
///
/// `teaserNeverDims` 是從 `hidden` 開逗貓棒，那時暗幕本來就是 0，所以把
/// `setTeaser` 裡的 `spotlightOpacity = 0` 拿掉照樣綠——真正會亮著暗幕切進來的
/// 是「貓正在追、暗幕已淡入」這條路徑，而它沒有任何測試走過。
@Test func switchingToTeaserMidHuntKillsTheSpotlightAtOnce() {
    let h = Harness()
    h.step(cursor: center, commands: [.summon])
    var lit = false
    for _ in 0..<60 {
        h.step(cursor: center)
        if h.last.spotlight.opacity > 0.1 { lit = true; break }
    }
    #expect(lit, "前提：召喚時暗幕要先亮起來")
    #expect(h.last.phase == .hunting, "前提：貓還在追，暗幕才會是淡入中")

    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.last.phase == .teaserApproach)
    #expect(h.last.spotlight.isActive == false,
            "切進逗貓棒的那一帧暗幕還亮著：opacity=\(h.last.spotlight.opacity)")
}

/// 重複開啟逗貓棒是 no-op，不會把潛伏中的貓丟回入場（`setTeaser` 的
/// `guard !teaserEnabled`）。
///
/// `findmouse teaser on` 連下兩次是使用者做得到的事；沒有這條守衛的話，
/// 第二次會重新 `enter(.teaserApproach)`，貓當場從潛伏彈回接近。
/// 拿掉那個 guard，330 條測試一條都不紅。
///
/// **不能只斷言 phase。** 實測過：拿掉 guard 之後 phase 讀起來仍是
/// `teaserStalking`——重新進入的 `teaserApproach` 在同一帧就發現距離已在
/// stalkRange 內，當場又轉回潛伏，所以只比 phase 的版本是恆真句。真正被打斷的是
/// 潛伏本身：計時歸零（撲擊被延後）、而且那一帧用**接近速度**多走了一步。
@Test func turningTeaserOnAgainDoesNotRestartTheApproach() {
    let h = Harness()
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.run(until: .teaserStalking, cursor: center))
    h.run(seconds: 1, cursor: center)
    #expect(h.last.phase == .teaserStalking)

    let before = h.last.body.position
    let elapsed = h.last.phaseElapsed
    #expect(elapsed > 0.9, "潛伏才累積 \(elapsed) 秒，構造沒讓「歸零」看得出來")

    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.last.teaserEnabled)
    #expect(h.last.phase == .teaserStalking, "重複開啟把貓丟回了 \(h.last.phase)")
    #expect(h.last.phaseElapsed > elapsed,
            "潛伏計時被重設成 \(h.last.phaseElapsed)（原本 \(elapsed)），撲擊被延後了")
    #expect(h.last.body.position == before,
            "重複開啟讓貓用接近速度多走了一步：\(before) → \(h.last.body.position)")
}

/// 撲擊觸發速度**就是** `teaser.pounceTriggerSpeed`：比它快 10% 會撲、慢 10% 不會。
///
/// 既有測試只覆蓋「有這條離開條件」，沒覆蓋「門檻是多少」。`lockOnFromAfar` 一帧
/// 把鼠標跳 150 px（9000 px/s，門檻的 22 倍），所以把門檻乘 10 改成 4000 px/s
/// 之後整批照樣全綠——使用者甩鼠標再也叫不出撲擊，只剩 3 秒逾時那條路，
/// 逗貓棒退化成「等三秒才撲一次」而零訊號。反方向原本也只守到 275 px/s
/// （`stalkingKeepsFacingTheCursorWhileStandingStill` 繞圈的切線速度）。
///
/// **兩半都要。** 只有上界的話「門檻降到 0」矇混得過去，只有下界的話「門檻升到天上」
/// 矇混得過去；兩條合起來才把邊界夾在門檻的 ±10% 內。位移量從設定推導，
/// 門檻的數值（400）由 `defaultsMatchSpec` 釘住——這裡驗的是判定式拿它在比。
///
/// 下界那半刻意只跑 2 秒：潛伏另有 `teaserStalkTimeout`（3 秒）那條路，取樣超過它
/// 之後「進了屁股搖」會是逾時造成的，看起來像門檻沒守住其實不是。
@Test func aFlickJustAboveTheTriggerSpeedPouncesAndOneJustBelowDoesNot() {
    let fast = Harness()
    let threshold = fast.config.value.teaserPounceTriggerSpeed

    // 上界：一帧的位移相當於門檻的 1.1 倍（預設 440 px/s）→ 當帧就進屁股搖
    fast.step(cursor: center, commands: [.setTeaser(true)])
    #expect(fast.run(until: .teaserStalking, cursor: center))
    let elapsed = fast.last.phaseElapsed
    #expect(elapsed + 1.0 / 60 < fast.config.value.teaserStalkTimeout,
            "潛伏已經跑了 \(elapsed) 秒，接下來進屁股搖可能是逾時而不是速度")
    fast.step(cursor: CGPoint(x: center.x, y: center.y + threshold * 1.1 / 60))
    #expect(fast.session.currentCursorSpeed > threshold)
    #expect(fast.last.phase == .teaserWindup,
            "鼠標 \(fast.session.currentCursorSpeed) px/s 已超過門檻 \(threshold) 卻沒撲：phase=\(fast.last.phase)")

    // 下界：0.9 倍（預設 360 px/s）連續 120 帧都不許觸發。鼠標在相距 hop 的兩點
    // 之間來回跳，每帧位移固定，而且距離不會愈拉愈遠——拉遠了貓會開始爬行，
    // 那是另一條規則（`stalkingCreepsAtFifteenPercentWhenTheCursorSlipsOutOfRange`）。
    let slow = Harness()
    slow.step(cursor: center, commands: [.setTeaser(true)])
    #expect(slow.run(until: .teaserStalking, cursor: center))
    let hop = threshold * 0.9 / 60
    var speeds: [CGFloat] = []
    for i in 0..<120 {
        slow.step(cursor: CGPoint(x: center.x, y: center.y + (i.isMultiple(of: 2) ? hop : 0)))
        speeds.append(slow.session.currentCursorSpeed)
    }
    // 沒有這條，「鼠標其實沒在動」也會讓下面那條通過
    #expect(speeds.allSatisfy { $0 > threshold * 0.85 && $0 < threshold },
            "鼠標速度沒有穩定落在門檻下緣：\(speeds.prefix(3))")
    #expect(slow.last.phaseElapsed < slow.config.value.teaserStalkTimeout,
            "潛伏跑了 \(slow.last.phaseElapsed) 秒，已經碰到逾時那條路")
    #expect(slow.last.phase == .teaserStalking,
            "鼠標只有 \(threshold * 0.9) px/s（門檻 \(threshold)）就撲了：phase=\(slow.last.phase)")
}

/// 退場淡出途中開逗貓棒，貓必須恢復不透明——而且整段逗貓棒都維持不透明。
///
/// `summon` 對 `.hidden` 與 `.exiting` 兩支都重設 alpha（後者由
/// `RobustnessTests.summonDuringExitBringsCatBack` 釘住），但 `setTeaser` 的開啟分支
/// 原本只處理 `.hidden`，而逗貓棒的六個階段沒有任何一處會把 alpha 加回去。
/// 於是在退場的 `Timings.exitFade` 窗口內按 ⌥⌘T，整段逗貓棒都是半透明的，
/// 而且不會自己恢復——直到下一次 `goHome`／`enter(.hidden)` 才被補回來。
///
/// **不能只驗進入當下那一帧。** 「進去時設了 1、下一帧又被扣掉」是另一種壞法
/// （例如復原寫在 `enter` 之前、而 `.exiting` 的衰減在同一帧又跑了一次），
/// 只比第一帧的版本抓不到，所以後面要再跑一整段。
@Test func startingTheTeaserWhileTheCatIsFadingOutRestoresFullOpacity() {
    let h = Harness()
    h.step(cursor: center, commands: [.summon])
    #expect(h.run(until: .resting, cursor: center))
    h.step(cursor: center, commands: [.dismiss])
    #expect(h.last.phase == .exiting)

    // 前提：真的淡到一半。貓若根本沒開始淡出，下面整條就是恆真句。
    h.run(seconds: Timings.exitFade / 2, cursor: center)
    let faded = h.last.alpha
    #expect(h.last.phase == .exiting, "還沒切進逗貓棒就退場完畢：phase=\(h.last.phase)")
    #expect(faded > 0.1 && faded < 0.9, "退場只淡到 alpha=\(faded)，構造沒讓「半透明」看得出來")

    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.last.phase.isTeaser, "沒進逗貓棒：phase=\(h.last.phase)")
    #expect(h.last.alpha == 1, "切進逗貓棒的那一帧貓還是半透明：alpha=\(h.last.alpha)")

    var lowest: CGFloat = 1
    var windups = 0
    var previous = h.last.phase
    for _ in 0..<900 {
        h.step(cursor: center)
        lowest = min(lowest, h.last.alpha)
        if h.last.phase == .teaserWindup && previous != .teaserWindup { windups += 1 }
        previous = h.last.phase
    }
    #expect(h.last.phase.isTeaser, "15 秒後離開了逗貓棒：phase=\(h.last.phase)")
    // 貓若卡在某個階段完全不動，「alpha 一路都是 1」也會通過
    #expect(windups >= 2, "15 秒只撲了 \(windups) 次，貓其實卡住了")
    #expect(lowest == 1, "逗貓棒期間貓是半透明的：最低 alpha=\(lowest)")
}

/// spec 第 4.5 節寫 `teaserRetreating` 的離開條件是「播完」——退開走不到目標點時，
/// 是 retreat clip 播完把貓叫回潛伏的。
///
/// 既有的 `retreatEndsOnArrivalWhenRetreatClipIsLong` 只釘住 `arrivedAtRetreat`
/// 那一支（它刻意把 clip 拉長到 fps 5 讓抵達先發生）。把 `clipFinished(.retreat) ||`
/// 整段拿掉、只留 repo 自己加的抵達判定，整批照樣全綠——而退開目標因轉向上限
/// 繞不進那個 4 px 窗口時，貓會永遠留在 `teaserRetreating`。
///
/// 構造：預設 pack（fps 10）的 retreat clip 只有 0.2 s，13 帧 × 9 px = 117 px，
/// 走不完 `teaserRetreatDistance`（150），所以抵達那一支結構上不可能成立。
/// 走撲空路徑（撲過頭 70 px）讓退開方向與貓的 heading 一致、全程直線，
/// 退開目標因此算得出來：落點加上飛行方向 × retreatDistance。
@Test func retreatEndsOnClipFinishWhenItCannotReachTheRetreatPoint() {
    let h = Harness()
    let (lock, launch) = lockOnFromAfar(h)
    let flightLength = hypot(lock.x - launch.x, lock.y - launch.y)
    let ux = (lock.x - launch.x) / flightLength
    let uy = (lock.y - launch.y) / flightLength
    let behind = CGPoint(x: lock.x - ux * 70, y: lock.y - uy * 70)

    #expect(stepWhile(h, phase: .teaserPouncing, cursor: behind) > 1)
    #expect(h.last.phase == .teaserRetreating, "撲過頭 70 px 應判撲空：phase=\(h.last.phase)")
    #expect(h.last.body.position == lock, "落點不是鎖定點，下面的退開目標就算不準")
    let retreatPoint = CGPoint(x: lock.x + ux * h.config.value.teaserRetreatDistance,
                               y: lock.y + uy * h.config.value.teaserRetreatDistance)

    let clipFrames = Int(((h.catalog.clip(for: .retreat)?.duration ?? 0) * 60).rounded())
    #expect(clipFrames > 5, "retreat clip 只有 \(clipFrames) 帧，測不出「播完」與「抵達」的差別")
    let frames = stepWhile(h, phase: .teaserRetreating, cursor: behind)
    #expect(h.last.phase == .teaserStalking)
    // 差一帧的餘裕：actionElapsed 累加 13 次才會浮點上碰到 0.2 s
    #expect(abs(frames - clipFrames) <= 1,
            "退開跑了 \(frames) 帧，retreat clip 只有 \(clipFrames) 帧——結束的原因不是播完")
    let remaining = hypot(retreatPoint.x - h.last.body.position.x,
                          retreatPoint.y - h.last.body.position.y)
    #expect(remaining > 20,
            "退開結束時離退開目標只剩 \(remaining) px，落在 4 px 的抵達窗口附近——這一輪是抵達結束的，沒測到「播完」")
}
