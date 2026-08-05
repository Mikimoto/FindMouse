import Testing
@testable import FindMouseDomain

@Test func timingsAreSane() {
    #expect(Timings.maxTickDelta > 0)
    #expect(Timings.spotlightFadeOut > Timings.spotlightFadeIn)
    #expect(Timings.flourishInterval.lowerBound < Timings.flourishInterval.upperBound)
}
