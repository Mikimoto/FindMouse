// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Testing
@testable import FindMouseDomain

@Test func radiusIsDistancePlusBodyAndMargin() {
    // 距離 300、體高 100（項為 60）、邊距 24 → 384
    let r = SpotlightGeometry.radius(
        cursor: CGPoint(x: 300, y: 0), cat: .zero, effectiveHeight: 100, margin: 24)
    #expect(abs(r - 384) < 1e-9)
}

@Test func radiusNeverReachesZeroEvenWhenCatIsOnCursor() {
    let r = SpotlightGeometry.radius(cursor: .zero, cat: .zero, effectiveHeight: 100, margin: 24)
    #expect(r > 0)
    #expect(abs(r - 84) < 1e-9)  // 100 × 0.6 + 24
}

@Test func radiusGrowsMonotonicallyWithDistance() {
    let near = SpotlightGeometry.radius(
        cursor: CGPoint(x: 50, y: 0), cat: .zero, effectiveHeight: 96, margin: 24)
    let far = SpotlightGeometry.radius(
        cursor: CGPoint(x: 800, y: 0), cat: .zero, effectiveHeight: 96, margin: 24)
    #expect(far > near)
}
