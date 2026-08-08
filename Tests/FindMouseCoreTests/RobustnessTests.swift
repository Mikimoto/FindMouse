import CoreGraphics
import Foundation
import Testing
@testable import FindMouseCore
import FindMouseDomain

private let center = CGPoint(x: 960, y: 540)

// MARK: - dt 的邊界

/// 釘住 dt clamp 的**可觀察後果**：單帧位移上限與單帧時間推進上限。
///
/// 這裡刻意不斷言「phase 不可能一帧跑完整個狀態機」——那種寫法在 clamp 被拿掉時
/// 照樣通過：dt = 3600 未 clamp 時貓一帧飛到離鼠標數百萬 px 的地方，phase 因此
/// **仍是** `.hunting`（在任何「允許清單」裡），而 hunting 期間 restTimer 恆為 0。
/// 唯一真正被 clamp 決定的量是「這一帧走了多遠」與「這一帧推進了多少時間」。
@Test func hugeDeltaIsClampedSoOneTickCannotTeleportTheCat() {
    let h = Harness()
    h.step(cursor: center, commands: [.summon])
    let before = h.last.body.position
    let elapsedBefore = h.last.phaseElapsed

    // 模擬系統睡眠一小時後喚醒
    h.step(dt: 3600, cursor: center)

    let travelled = hypot(h.last.body.position.x - before.x,
                          h.last.body.position.y - before.y)
    #expect(travelled <= h.config.config.catSpeed * CGFloat(Timings.maxTickDelta) + 0.001)
    #expect(h.last.phaseElapsed - elapsedBefore <= Timings.maxTickDelta + 0.001)
}

@Test func negativeDeltaIsTreatedAsZero() {
    let h = Harness()
    h.step(cursor: center, commands: [.summon])
    let before = h.last.body.position
    h.step(dt: -5, cursor: center)
    #expect(h.last.body.position == before)
}

/// NaN 通不過 `min`/`max`（兩者對 NaN 是恆等），所以 clamp 前必須先擋 `isFinite`。
/// 沒有這道守衛，`Int(actionElapsed * fps)` 會直接 trap（crash，不是斷言失敗）。
@Test func nonFiniteDeltaIsTreatedAsZero() {
    let h = Harness()
    h.step(cursor: center, commands: [.summon])
    let before = h.last.body.position
    h.step(dt: .nan, cursor: center)
    #expect(h.last.body.position == before)
    h.step(dt: .infinity, cursor: center)
    #expect(h.last.body.position == before)
}

// MARK: - 命令的幂等性

/// 退場途中被召喚要立刻回到狩獵，且 alpha 要被重設回 1（不然貓半透明地跑）。
///
/// 召喚時把鼠標放遠是必要的：貓在 `.resting` 時離鼠標只有 65–80 px，
/// `dismiss` 後只走一帧（15 px，且轉向速率上限讓牠幾乎沒轉身），
/// 距離仍在 `arriveRadius`（80）內——鼠標就在腳邊時同一帧直接進 `.arriving`
/// 才是對的行為，那樣就測不到「回到狩獵」。
@Test func summonDuringExitBringsCatBack() {
    let h = Harness()
    h.step(cursor: center, commands: [.summon])
    #expect(h.run(until: .resting, cursor: center))
    h.step(cursor: center, commands: [.dismiss])
    #expect(h.last.phase == .exiting)

    let faraway = CGPoint(x: 200, y: 200)
    h.step(cursor: faraway, commands: [.summon])
    #expect(h.last.phase == .hunting)
    #expect(h.last.alpha == 1)
}

@Test func summonIsIdempotentWhileToggleIsNot() {
    let h = Harness()
    h.step(cursor: center, commands: [.summon])
    #expect(h.run(until: .resting, cursor: center))

    h.step(cursor: center, commands: [.summon, .summon, .summon])
    #expect(h.last.phase == .resting)   // 幂等，沒有被重新召喚

    h.step(cursor: center, commands: [.toggle])
    #expect(h.last.phase == .exiting)   // toggle 有方向性
}

@Test func dismissOnHiddenCatIsNoOp() {
    let h = Harness()
    h.step(cursor: center, commands: [.dismiss])
    #expect(h.last.phase == .hidden)
}

// MARK: - 不變式

/// 貓可見且不在 `.exiting` 時，alpha 必為 1。
///
/// `.exiting` 的衰減是**唯一**會扣 alpha 的地方，而把它加回去的責任散在四處：
/// `summon` 的 `.hidden`／`.exiting` 兩支、`goHome`、`enter(.hidden)`、
/// 以及 `setTeaser` 的開啟分支。少掉其中一支不會有任何直接訊號——貓只是
/// 半透明地跑，而既有測試沒有一條在看 alpha。實際漏過一次：`setTeaser` 原本
/// 只在 `phase == .hidden` 時復原，於是在退場的 0.4 秒窗口內按 ⌥⌘T，
/// 整段逗貓棒都是半透明的（見
/// `TeaserTests.startingTheTeaserWhileTheCatIsFadingOutRestoresFullOpacity`）。
///
/// 那條測試釘的是已知的那一格；這條用亂序命令掃，釘的是**下一個新入口又漏掉**。
@Test func aVisibleCatIsFullyOpaqueUnlessItIsLeaving() {
    let deck: [Command] = [.summon, .dismiss, .toggle,
                           .setTeaser(true), .setTeaser(false), .toggleTeaser]
    var violations: [String] = []
    var visibleFrames = 0
    var fadedFrames = 0
    for seed in UInt64(1)...200 {
        let h = Harness(seed: seed)
        let rng = SeededRandomizer(seed: seed &* 2_246_822_519)
        for _ in 0..<200 {
            let cursor = CGPoint(x: rng.double(in: 0...1920), y: rng.double(in: 0...1080))
            h.step(cursor: cursor, commands: rng.pick(deck).map { [$0] } ?? [])
            if h.last.alpha < 1 { fadedFrames += 1 }
            guard h.last.phase.isVisible, h.last.phase != .exiting else { continue }
            visibleFrames += 1
            if h.last.alpha != 1 {
                violations.append("seed \(seed) phase=\(h.last.phase) alpha=\(h.last.alpha)")
            }
        }
    }
    #expect(violations.isEmpty, "半透明的貓：\(violations.prefix(5))")
    #expect(visibleFrames > 1000,
            "40000 帧裡只有 \(visibleFrames) 帧貓可見且非退場，掃描沒實際檢查到不變式")
    // 掃描若從未讓 alpha 掉下來，上面那條就是恆真句
    #expect(fadedFrames > 100, "40000 帧裡只有 \(fadedFrames) 帧 alpha < 1，掃描沒走過淡出")
}

// MARK: - frameIndex 的邊界

@Test func frameIndexStaysInBounds() {
    let h = Harness(catalog: StubCatalog(frames: 3))
    h.step(cursor: center, commands: [.summon])
    for _ in 0..<2000 {
        h.step(cursor: center)
        #expect(h.last.frameIndex >= 0)
        #expect(h.last.frameIndex < h.last.frameCount)
    }
}

/// 餵一次真的會踩到 `clip.frames > 0` 那半邊守衛的輸入。
///
/// `StubCatalog` 最少 2 格，所以上面那個測試永遠走不到 `frames > 0` 這個條件；
/// 走不到的程式碼＝未測試的程式碼。`AnimationClip` 對 frames 沒有前置條件，
/// 0 是合法的（`duration` 變 0，所有 clip 立刻視為播完）。
/// 沒有守衛時 `raw % 0` 會 trap，非 loop 的 clip 則回 `min(raw, -1) = -1`。
@Test func frameIndexSurvivesAZeroFrameClip() {
    let h = Harness(catalog: StubCatalog(frames: 0))
    h.step(cursor: center, commands: [.summon])
    for _ in 0..<600 {
        h.step(cursor: center)
        #expect(h.last.frameCount > 0)
        #expect(h.last.frameIndex >= 0)
        #expect(h.last.frameIndex < h.last.frameCount)
    }
}

/// 餵一次「非 loop 的 clip 比它所在的 phase 更短」的輸入。
///
/// `frameIndexStaysInBounds` 走不到 `min(raw, clip.frames - 1)` 那個上限：
/// `.arriving`／`.sitting`／`.lyingDown` 這些 phase 的離開條件**就是** `clipFinished`，
/// 所以 `actionElapsed` 一碰到 duration 同一帧就換 action、`actionElapsed` 歸零，
/// `raw` 永遠不會超過 `frames - 1`。實測拿掉那個 `min` 上限，
/// `frameIndexStaysInBounds` 仍然全綠。
///
/// 唯一會超出的是 `.teaserPouncing`：它的離開條件是「飛到鎖定點」（距離），與 clip
/// 長度無關。把 fps 拉到 100（clip 只有 0.03 秒）而撲擊飛行約 7 帧（0.117 秒），
/// `raw` 於是達到 11，遠超 `frames - 1 = 2`。
@Test func frameIndexIsClampedWhenANonLoopingClipOutlastsItsPhase() {
    let h = Harness(catalog: StubCatalog(fps: 100, frames: 3))
    h.step(cursor: center, commands: [.setTeaser(true)])
    #expect(h.run(until: .teaserStalking, cursor: center))
    // 靠 stalk timeout 進 windup，再飛出去
    #expect(h.run(until: .teaserPouncing, cursor: center, maxSeconds: 12))
    var frames = 0
    while h.last.phase == .teaserPouncing && frames < 240 {
        #expect(h.last.action == .pounce)
        #expect(h.last.frameIndex >= 0)
        #expect(h.last.frameIndex < h.last.frameCount)
        h.step(cursor: center)
        frames += 1
    }
    #expect(frames > 1, "撲擊只飛了 \(frames) 帧，測不到 clip 播完之後的那幾帧")
}

// MARK: - 入場點

/// 入場點本身必須精確落在「最近邊緣外一個貓身」。
///
/// 用 `dt: 0` 觀察：`tick` 是「先套用命令、再 advance」，
/// dt > 0 時貓在同一帧已經跑了一步（初始 heading 是 0，轉向上限讓牠一帧只轉 9°，
/// 所以會往 +x 偏移約 14.8 px），精確浮點比較會失敗。
/// dt = 0 時 `Kinematics.step` 的位移與轉向都是 0，位置精確等於入場點。
@Test func catEntersFromNearestEdgeAtTheExactEdgePoint() {
    let h = Harness()
    // 鼠標靠近上緣
    let nearTop = CGPoint(x: 960, y: 1040)
    h.step(dt: 0, cursor: nearTop, commands: [.summon])
    #expect(h.last.body.position.y > Harness.screen.maxY)
    #expect(h.last.body.position.x == nearTop.x)
}

/// 入場用的是 `stage.cursorScreen`，不是 `stage.union`。
///
/// 這個測試不能用 `Harness`：它的 `union` 與 `cursorScreen` 是同一個矩形，
/// 所以把實作裡的 `stage.cursorScreen` 換成 `stage.union` 照樣全綠。
/// `Stage` 有兩個矩形就是為了多螢幕，這是第一個真的餵兩個不同矩形的測試。
@Test func catEntersFromTheCursorScreenNotTheUnion() {
    let leftScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let rightScreen = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    let stage = Stage(union: leftScreen.union(rightScreen), cursorScreen: rightScreen)
    let catalog = StubCatalog()
    let session = CatSessionUseCase(config: StubConfig(), catalog: catalog,
                                    randomizer: SeededRandomizer(seed: 1))
    // 鼠標離「右螢幕左緣」只有 80，離「union 左緣」有 2000：
    // 用錯矩形的話最近邊會變成下緣（540），位置完全不同。
    let cursor = CGPoint(x: 2000, y: 540)
    let state = session.tick(dt: 0, cursor: cursor, stage: stage, commands: [.summon])
    // 入場 inset 是 effectiveHeight = logicalHeight × catScale，
    // 這裡等於 logicalHeight 的前提是預設 catScale == 1。
    #expect(state.body.position.x == rightScreen.minX - catalog.logicalHeight)
    #expect(state.body.position.y == cursor.y)
}
