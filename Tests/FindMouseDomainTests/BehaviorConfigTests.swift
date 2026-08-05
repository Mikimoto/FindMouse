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
