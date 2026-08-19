// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import Testing
@testable import FindMouseAdapters
import FindMouseCore
@testable import FindMouseDomain

private func makeRepository(_ packID: String = "test-blocks") throws -> SpriteRepository {
    let url: URL
    // test-blocks 與 test-blocks-tall 已搬到 Fixtures；只有 mycat 留在出貨資源裡。
    if packID == PackDefaults.factory {
        let packs = try #require(SpritePackRepository.builtInPacksDirectory())
        url = packs.appendingPathComponent(packID)
    } else {
        let base = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        url = base.appendingPathComponent(packID)
    }
    let loaded = try #require(SpritePackRepository.load(at: url))
    let report = PackValidator.validate(manifest: loaded.manifest,
                                        directoryName: loaded.directoryName,
                                        listing: loaded.listing)
    let caps = try #require(report.capabilities)
    return try #require(SpriteRepository(loaded: loaded, capabilities: caps))
}

@Test func clipsMatchTheManifest() throws {
    let repo = try makeRepository()
    #expect(repo.logicalHeight == 96)

    let run = try #require(repo.clip(for: .run))
    #expect(run.frames == 2)
    #expect(run.fps == 10)
    #expect(run.loops, "run 在 manifest 宣告 loop: true")

    let sit = try #require(repo.clip(for: .sit))
    #expect(sit.loops == false, "sit 是一次性的轉換動作")

    // 14 個動作都要有 clip，缺一個都會讓狀態機在某個 phase 沒東西可播
    for action in CatAction.allCases {
        #expect(repo.clip(for: action) != nil, "\(action) 沒有 clip")
    }
}

/// 能力來自 validator，不是 repository 自己數目錄——
/// 兩邊各算一次的話遲早會分歧，而分歧的那一刻沒有任何訊號。
@Test func capabilitiesComeFromTheValidator() throws {
    let repo = try makeRepository()
    #expect(repo.capabilities.teaserAvailable)
    #expect(repo.capabilities.available == Set(CatAction.allCases))

    let crippled = try makeRepository("bad-missing-teaser")
    #expect(crippled.capabilities.teaserAvailable == false)
    // 但缺的那個動作仍然沒有 clip，兩件事要一致
    #expect(crippled.clip(for: .pounce) == nil)
}

/// manifest 的 anchor 與 mirrorForOpposite 要原樣傳給 presenter。
@Test func manifestGeometryIsExposedForThePresenter() throws {
    let repo = try makeRepository()
    #expect(repo.anchor == CGPoint(x: 0.5, y: 0.9))
    #expect(repo.spriteFacing == .right, "test-blocks 的 manifest 宣告 facing: right")
    #expect(repo.mirrorForOpposite)
    // test-blocks 是正方形，所以寬高比為 1
    #expect(repo.spriteAspect == 1)
}

/// spec 第 7.4 節：`image(action:frame:)` 回傳**快取的參考**而不是新物件。
/// 60fps 下每帧解一張 PNG 會直接吃掉整個時間預算。
@Test func imagesAreCachedAcrossCalls() throws {
    let repo = try makeRepository()
    let first = try #require(repo.image(action: .run, frame: 0))
    let again = try #require(repo.image(action: .run, frame: 0))
    #expect(first === again, "同一格重複取要拿到同一個 CGImage 實例")
}

/// spec 第 7.4 節：一次只有當前與上一個動作的圖在記憶體。
///
/// 保留「上一個」而不是只留當前，是因為換動作的那一帧 presenter 可能還在讀
/// 舊動作的最後一格；只留一個會讓那一帧沒圖可畫。
@Test func onlyTwoActionsStayCached() throws {
    let repo = try makeRepository()
    #expect(repo.cachedActions.isEmpty, "還沒取過圖就不該有快取")

    _ = repo.image(action: .run, frame: 0)
    #expect(repo.cachedActions == [.run])

    _ = repo.image(action: .sit, frame: 0)
    #expect(repo.cachedActions == [.run, .sit])

    // 第三個動作進來，最舊的要被丟掉
    _ = repo.image(action: .sleep, frame: 0)
    #expect(repo.cachedActions.count == 2)
    #expect(repo.cachedActions.contains(.run) == false, "最舊的 run 應該被逐出")
    #expect(repo.cachedActions == [.sit, .sleep])
}

/// 重複取同一個動作不該把它重新排到隊尾之外，也不該讓快取長大。
@Test func repeatedAccessDoesNotGrowTheCache() throws {
    let repo = try makeRepository()
    for _ in 0..<50 {
        _ = repo.image(action: .run, frame: 0)
        _ = repo.image(action: .run, frame: 1)
    }
    #expect(repo.cachedActions == [.run])
}

@Test func frameIndexOutOfRangeReturnsNil() throws {
    let repo = try makeRepository()
    #expect(repo.image(action: .run, frame: 2) == nil, "只有 0 與 1 兩格")
    #expect(repo.image(action: .run, frame: 99) == nil)
    #expect(repo.image(action: .run, frame: -1) == nil)
    // 缺席的動作沒有圖，也不能 crash
    let crippled = try makeRepository("bad-missing-teaser")
    #expect(crippled.image(action: .pounce, frame: 0) == nil)
}
