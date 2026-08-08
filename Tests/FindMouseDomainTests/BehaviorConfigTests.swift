import CoreGraphics
import Testing
@testable import FindMouseDomain

@Test func timingsAreSane() {
    #expect(Timings.maxTickDelta > 0)
    #expect(Timings.spotlightFadeOut > Timings.spotlightFadeIn)
    #expect(Timings.flourishInterval.lowerBound < Timings.flourishInterval.upperBound)
}

@Test func defaultsMatchSpec() {
    let c = BehaviorConfig()
    #expect(c.restDuration == 10)
    #expect(c.sleepDuration == 5)
    #expect(c.rehuntThreshold == 160)
    #expect(c.catSpeed == 900)
    #expect(c.spotlightTrigger == .onSummonOnly)
    #expect(c.spotlightEnabled == true)

    // 逗貓棒的六個設定項（spec 第 9 節的表）。
    //
    // 為什麼要在這裡再釘一次：Core 的行為測試全部是「從設定讀出值、算出期望值、
    // 再比對」，所以改設定值本身它們一律照樣綠——兩邊一起縮放。實測把
    // teaser.pounceSpeed 從 2200 砍成 1100，Core 加 Domain 189 條測試一條都不紅
    // （猛撲變成滑行，而 spec 第 4.5 節的整個樂趣就在那一下）。
    // 行為測試釘的是「判定式用的是不是這個設定項」，這裡釘的才是「值是多少」。
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
