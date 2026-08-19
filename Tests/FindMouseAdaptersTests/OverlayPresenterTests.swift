// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import Testing
@testable import FindMouseAdapters
import FindMouseDomain

/// 刻意用一個原點為負的視窗 frame：副螢幕在主螢幕左方或下方時就是這樣，
/// 而那正是「忘了平移」唯一會現形的情境。
private let windowFrame = CGRect(x: -1920, y: -200, width: 3840, height: 1280)

private func makeState(
    phase: CatPhase = .hunting,
    position: CGPoint = .zero,
    heading: CGFloat = 0,
    action: CatAction = .run,
    frameIndex: Int = 0,
    alpha: CGFloat = 1,
    spotlight: SpotlightState = .inactive
) -> CatFrameState {
    CatFrameState(phase: phase, phaseElapsed: 0,
                  body: CatBody(position: position, heading: heading),
                  action: action, frameIndex: frameIndex, frameCount: 2, alpha: alpha,
                  spotlight: spotlight, cursor: CGPoint(x: 100, y: 100),
                  teaserEnabled: false, teaserAvailable: true,
                  restTimer: 0, sleepTimer: 0)
}

private func makePresenter(catScale: CGFloat = 1,
                           spriteFacing: Facing = .right,
                           mirrorForOpposite: Bool = true,
                           spriteAspect: CGFloat = 1) -> OverlayPresenter {
    OverlayPresenter(logicalHeight: 96, catScale: catScale,
                     anchor: CGPoint(x: 0.5, y: 0.9),
                     spriteFacing: spriteFacing, mirrorForOpposite: mirrorForOpposite,
                     spriteAspect: spriteAspect, feather: 0.65)
}

/// 視窗 frame 的原點是負的，所以「全域座標直接當視窗座標」會把貓畫到畫面外。
@Test func globalPositionIsTranslatedIntoWindowCoordinates() {
    let vm = makePresenter().viewModel(for: makeState(position: .zero), in: windowFrame)
    #expect(vm.cat.position == CGPoint(x: 1920, y: 200))
}

/// manifest 的 anchor.y 由上往下（0 = 頭頂），CALayer 的 anchorPoint.y 由下往上。
/// 漏掉這個翻轉，貓會陷進桌面或浮在半空。
@Test func manifestAnchorIsFlippedForCALayer() {
    let vm = makePresenter().viewModel(for: makeState(), in: windowFrame)
    #expect(vm.cat.anchorPoint.x == 0.5)
    #expect(abs(vm.cat.anchorPoint.y - 0.1) < 0.000_001,
            "anchor.y = 0.9（由上往下）應該變成 anchorPoint.y = 0.1，實際 \(vm.cat.anchorPoint.y)")
}

@Test func drawSizeIsLogicalHeightTimesScaleWithSpriteAspect() {
    let vm = makePresenter(catScale: 2, spriteAspect: 0.5)
        .viewModel(for: makeState(), in: windowFrame)
    #expect(vm.cat.size.height == 192)
    #expect(vm.cat.size.width == 96)
}

/// 素材朝右時，貓朝左才鏡像。
@Test func headingToTheLeftMirrorsARightFacingSprite() {
    let p = makePresenter(spriteFacing: .right)
    #expect(p.viewModel(for: makeState(heading: 0), in: windowFrame).cat.mirrored == false)
    #expect(p.viewModel(for: makeState(heading: .pi), in: windowFrame).cat.mirrored)
    // 正上方（π/2）：cos 為 0，CatBody.facing 判為 .right，所以不鏡像
    #expect(p.viewModel(for: makeState(heading: .pi / 2), in: windowFrame).cat.mirrored == false)
}

/// 素材朝左的 pack，鏡像的方向要反過來。
///
/// 這條測試存在的理由：把判定寫死成「朝左就鏡像」在朝右素材上完全正確，
/// 要換一套朝左的 pack 才會現形——而那是 M4 才會發生的事。
@Test func aLeftFacingSpriteMirrorsForTheOppositeHeading() {
    let p = makePresenter(spriteFacing: .left)
    #expect(p.viewModel(for: makeState(heading: .pi), in: windowFrame).cat.mirrored == false,
            "素材本來就朝左，貓朝左時不該鏡像")
    #expect(p.viewModel(for: makeState(heading: 0), in: windowFrame).cat.mirrored,
            "素材朝左而貓朝右，才需要鏡像")
}

@Test func mirroringIsSuppressedWhenThePackForbidsIt() {
    let p = makePresenter(mirrorForOpposite: false)
    #expect(p.viewModel(for: makeState(heading: .pi), in: windowFrame).cat.mirrored == false)
}

@Test func inactiveSpotlightProducesNoDim() {
    #expect(makePresenter().viewModel(for: makeState(spotlight: .inactive), in: windowFrame).dim == nil)
}

@Test func activeSpotlightCentreIsAlsoTranslated() throws {
    let spotlight = SpotlightState(center: .zero, radius: 300, opacity: 0.75)
    let vm = makePresenter().viewModel(for: makeState(spotlight: spotlight), in: windowFrame)
    let dim = try #require(vm.dim)
    #expect(dim.center == CGPoint(x: 1920, y: 200), "光圈圓心也要平移，不只貓")
    #expect(dim.radius == 300)
    #expect(dim.opacity == 0.75)
    #expect(dim.feather == 0.65)
}

@Test func visibilityFollowsThePhase() {
    let p = makePresenter()
    #expect(p.viewModel(for: makeState(phase: .hidden), in: windowFrame).visible == false)
    #expect(p.viewModel(for: makeState(phase: .hunting), in: windowFrame).visible)
    #expect(p.viewModel(for: makeState(phase: .exiting), in: windowFrame).visible)
}

/// 逐格與透明度原樣傳遞——退場淡出靠的就是 alpha。
@Test func frameAndAlphaArePassedThrough() {
    let vm = makePresenter().viewModel(
        for: makeState(action: .sleep, frameIndex: 1, alpha: 0.25), in: windowFrame)
    #expect(vm.cat.action == .sleep)
    #expect(vm.cat.frameIndex == 1)
    #expect(vm.cat.alpha == 0.25)
}

// MARK: - 從 pack ＋ 設定建構

private func loadTestBlocks() throws -> SpriteRepository {
    let base = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let loaded = try #require(SpritePackRepository.load(
        at: base.appendingPathComponent("test-blocks")))
    let report = PackValidator.validate(manifest: loaded.manifest,
                                        directoryName: loaded.directoryName,
                                        listing: loaded.listing)
    let capabilities = try #require(report.capabilities)
    return try #require(SpriteRepository(loaded: loaded, capabilities: capabilities))
}

/// `cat.scale` 是 presenter **建構時**吃進去的，而 `CatSessionUseCase` 每帧重讀設定。
/// 改了設定卻沒重建 presenter，貓的移動幾何立刻變、畫出來的大小沒變。
/// 這條釘住「重建就會拿到新的 scale」——沒有它，`AppDelegate.refreshPresenter`
/// 可以完全不讀設定而沒有任何訊號。
@Test func theSizeComesFromTheConfigNotFromThePack() throws {
    let sprites = try loadTestBlocks()
    var config = BehaviorConfig()

    config.catScale = 1
    let normal = OverlayPresenter(sprites: sprites, config: config)
        .viewModel(for: makeState(), in: windowFrame).cat.size

    config.catScale = 2
    let doubled = OverlayPresenter(sprites: sprites, config: config)
        .viewModel(for: makeState(), in: windowFrame).cat.size

    #expect(normal.height == sprites.logicalHeight)
    #expect(doubled.height == sprites.logicalHeight * 2)
    #expect(doubled.width == normal.width * 2, "寬度也要跟著縮放，不然貓會被拉扁")
}

/// 其餘幾何一律取自 pack，不是設定。混淆了的話換 pack 會被使用者的
/// `cat.scale` 蓋掉，或反過來。
@Test func theGeometryComesFromThePackNotFromTheConfig() throws {
    let sprites = try loadTestBlocks()
    var config = BehaviorConfig()
    config.spotlightFeather = 0.42

    let vm = OverlayPresenter(sprites: sprites, config: config)
        .viewModel(for: makeState(spotlight: SpotlightState(center: .zero, radius: 100,
                                                            opacity: 0.5)),
                   in: windowFrame)
    #expect(vm.cat.anchorPoint.y == 1 - sprites.anchor.y)
    #expect(try #require(vm.dim).feather == 0.42, "feather 來自設定，不是 pack")
}
