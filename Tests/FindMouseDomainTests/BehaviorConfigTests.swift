import CoreGraphics
import Testing
@testable import FindMouseDomain

@Test func timingsAreSane() {
    #expect(Timings.maxTickDelta > 0)
    #expect(Timings.spotlightFadeOut > Timings.spotlightFadeIn)
    #expect(Timings.flourishInterval.lowerBound < Timings.flourishInterval.upperBound)
}

/// spec 第 9 節那張表**預設欄**的獨立抄本（範圍欄的抄本在 `FindMouseCoreTests`
/// 的 `specRanges`，理由同一個：從實作推導出來的期望值會跟著實作一起錯）。
@Test func defaultsMatchSpec() {
    let c = BehaviorConfig()
    #expect(c.catScale == 1.0)
    #expect(c.restDuration == 10)
    #expect(c.sleepDuration == 5)
    #expect(c.rehuntThreshold == 160)
    #expect(c.catSpeed == 900)
    #expect(c.catTurnRate == 540)
    #expect(c.spotlightTrigger == .onSummonOnly)
    #expect(c.spotlightEnabled == true)
    #expect(c.spotlightDimOpacity == 0.75)
    #expect(c.spotlightMargin == 24)
    #expect(c.spotlightFeather == 0.65)

    // 兩個衍生預設（`wake.threshold` 的 ×3、`arrive.radius` 的 ×0.8）沒有自己的
    // 儲存欄位，係數釘在 `wakeThresholdDerivesFromRehunt` 與
    // `arriveRadiusDerivesFromEffectiveHeight`；那兩條的期望值也是手寫死的。

    // 逗貓棒的六個設定項（spec 第 9 節的表）。
    //
    // 為什麼要在這裡再釘一次：Core 的行為測試全部是「從設定讀出值、算出期望值、
    // 再比對」，所以改設定值本身它們一律照樣綠——兩邊一起縮放。實測把
    // teaser.pounceSpeed 從 2200 砍成 1100，Core 加 Domain 189 條測試一條都不紅
    // （猛撲變成滑行，而 spec 第 4.5 節的整個樂趣就在那一下）。
    // 行為測試釘的是「判定式用的是不是這個設定項」，這裡釘的才是「值是多少」。
    //
    // M6 把 teaser.* 以外的欄位補齊。實測真的沒被釘住的是三個：
    // cat.turnRate 540 → 270、spotlight.margin 24 → 60、spotlight.feather
    // 0.65 → 0.4，各自整批全綠。三個 mutation 的新值都刻意選在 spec 該 key 的
    // **值域內**，否則轉紅的是 `rangesRejectJustOutsideAndAcceptJustInside`
    // 那道值域守衛，而不是「有人在看這個值」。
    // cat.scale 與 spotlight.dimOpacity 改了本來就會紅，但紅的是入場點體寬與
    // 暗幕淡入目標值那些**別的**斷言順手撞到的，不是有人在釘 spec 的預設；
    // 一併寫進來讓這份抄本與 spec 的表一列一列對得上。
    #expect(c.teaserStalkRange == 250)
    #expect(c.teaserStalkTimeout == 3)
    #expect(c.teaserPounceTriggerSpeed == 400)
    #expect(c.teaserPounceSpeed == 2200)
    #expect(c.teaserHitRadius == 60)
    #expect(c.teaserRetreatDistance == 150)
}

/// 逗貓棒的三個常數（spec 第 3.2 節第 3 條、第 4.5 節末段）。
///
/// 理由與 `defaultsMatchSpec` 裡那段相同：`windupLastsHalfASecondBeforeTheLockOn`、
/// `stalkingCreepsAtFifteenPercentWhenTheCursorSlipsOutOfRange`、
/// `pouncingAndRetreatingEachRunAtTheirOwnSpeed` 的期望值都是從這三個常數讀出來
/// 再算的，所以值本身怎麼改都不會有訊號——實測 0.5→0.2、0.15→0.5、0.6→1.0 全綠。
/// 上面的 `timingsAreSane` 只驗關係（誰比誰大），驗不到數值。
@Test func teaserTimingsMatchSpec() {
    #expect(Timings.windup == 0.5)
    #expect(Timings.stalkSpeedFactor == 0.15)
    #expect(Timings.retreatSpeedFactor == 0.6)
}

/// `Timings` 裡 spec 有給數值的其餘常數（逗貓棒那三個在 `teaserTimingsMatchSpec`）。
///
/// 理由與 `defaultsMatchSpec` 相同：消費端一律「讀常數、算期望值、再比對」，
/// 值本身怎麼改都沒有訊號。M6 實測的缺口有四條，全綠：
/// spotlightFadeIn 0.25 → 0.1、spotlightFadeOut 0.4 → 0.3、maxTickDelta 0.1 → 0.25、
/// flourishInterval 2...4 → 1...8。上面的 `timingsAreSane` 攔不住它們——它只驗
/// **關係**（誰比誰大、下界小於上界），而這四個改動全都保持那些關係成立，
/// 挑值的時候也是刻意這樣挑的，不然轉紅的會是那道關係守衛。
///
/// spotlightHeightFactor 改了本來就會紅（`SpotlightGeometryTests` 手寫死了半徑
/// 公式的期望值），一併列進來讓這份抄本涵蓋整個 `Timings`。
@Test func timingsMatchSpec() {
    #expect(Timings.spotlightFadeIn == 0.25)       // spec 第 3.1 節第 2 條、第 5.2 節
    #expect(Timings.spotlightFadeOut == 0.4)       // spec 第 3.1 節第 4 條、第 5.2 節
    #expect(Timings.maxTickDelta == 0.1)           // spec 第 10 節「dt 一律 clamp 在 0.1 秒」
    #expect(Timings.flourishInterval == 2...4)     // spec 第 3.1 節第 5 條、第 4.4 節
    #expect(Timings.spotlightHeightFactor == 0.6)  // spec 第 5.1 節的半徑公式
}

/// `exitFade` **不在 spec 裡**：spec 只說退場時淡出（第 3.1 節第 8 條、第 4.1 節的
/// `exiting` 那列），沒有給秒數。所以這條不是規格符合性檢查，而是變更偵測器。
///
/// 還是要釘，因為它是使用者看得到的一段動畫長度而**沒有任何測試量得到它**：
/// 實測 0.4 → 1.2 整批全綠（`advance` 的衰減量與 `RobustnessTests` 的斷言都是從
/// 同一個常數推出來的，兩邊一起縮放）。
///
/// 要調它就連這一行一起改；順帶想一下那個窗口裡還有什麼——
/// `TeaserTests.startingTheTeaserWhileTheCatIsFadingOutRestoresFullOpacity`
/// 守的正是「在這 0.4 秒之內按 ⌥⌘T」。
@Test func theExitFadeIsPinnedEvenThoughTheSpecGivesNoNumber() {
    #expect(Timings.exitFade == 0.4)
}

@Test func wakeThresholdDerivesFromRehunt() {
    var c = BehaviorConfig()
    c.rehuntThreshold = 200
    #expect(c.wakeThreshold == 600)

    c.wakeThresholdOverride = 50
    #expect(c.wakeThreshold == 50)
}

@Test func arriveRadiusDerivesFromEffectiveHeight() {
    var c = BehaviorConfig()
    c.catScale = 2.0
    // effectiveHeight = 100 × 2 = 200；arriveRadius = 200 × 0.8 = 160
    #expect(c.arriveRadius(logicalHeight: 100) == 160)

    c.arriveRadiusOverride = 42
    #expect(c.arriveRadius(logicalHeight: 100) == 42)
}
