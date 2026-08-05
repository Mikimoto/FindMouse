import CoreGraphics
import Testing
@testable import FindMouseDomain

@Test func phaseVisibilityAndTeaserClassification() {
    #expect(CatPhase.hidden.isVisible == false)
    #expect(CatPhase.resting.isVisible == true)
    #expect(CatPhase.teaserPouncing.isTeaser == true)
    #expect(CatPhase.hunting.isTeaser == false)
}

@Test func actionTiersPartitionAllActions() {
    let union = CatAction.core.union(CatAction.flourish).union(CatAction.teaser)
    #expect(union == Set(CatAction.allCases))
    #expect(CatAction.core.isDisjoint(with: CatAction.teaser))
    #expect(CatAction.restPool.isSubset(of: CatAction.flourish))
}

@Test func bodyFacingFollowsHeading() {
    #expect(CatBody(position: .zero, heading: 0).facing == .right)
    #expect(CatBody(position: .zero, heading: .pi).facing == .left)
}

@Test func clipDurationIsFramesOverFPS() {
    let clip = AnimationClip(action: .run, frames: 8, fps: 16, loops: true)
    #expect(abs(clip.duration - 0.5) < 1e-9)
}
