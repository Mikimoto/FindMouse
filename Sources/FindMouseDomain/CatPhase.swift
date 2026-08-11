// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

/// 貓的狀態。spec 第 4.1 與 4.5 節的狀態表。
public enum CatPhase: String, Sendable, CaseIterable {
    case hidden, hunting, arriving, sitting, resting, lyingDown, sleeping, exiting
    case teaserApproach, teaserStalking, teaserWindup, teaserPouncing, teaserTumbling, teaserRetreating

    public var isVisible: Bool { self != .hidden }

    public var isTeaser: Bool {
        switch self {
        case .teaserApproach, .teaserStalking, .teaserWindup,
             .teaserPouncing, .teaserTumbling, .teaserRetreating:
            return true
        default:
            return false
        }
    }
}
