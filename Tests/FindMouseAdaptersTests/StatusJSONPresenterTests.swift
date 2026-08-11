// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import Testing
@testable import FindMouseAdapters
import FindMouseDomain
import FindMouseWire

/// 每個欄位都給**互不相同**的值。
///
/// 這不是龜毛：兩個欄位若共用同一個值（例如 restTimer 與 sleepTimer 都是 0），
/// 把它們接反的 bug 就完全看不出來，而那正是這種一長串 `.init(…)`
/// 最容易犯的錯。
private func makeState(
    phase: CatPhase = .resting,
    heading: CGFloat = 0,
    position: CGPoint = CGPoint(x: 111, y: 222),
    cursor: CGPoint = CGPoint(x: 333, y: 444),
    spotlight: SpotlightState = SpotlightState(center: CGPoint(x: 555, y: 666),
                                               radius: 77, opacity: 0.88)
) -> CatFrameState {
    CatFrameState(
        phase: phase, phaseElapsed: 7.75,
        body: CatBody(position: position, heading: heading),
        action: .stretch, frameIndex: 2, frameCount: 5, alpha: 0.5,
        spotlight: spotlight, cursor: cursor,
        teaserEnabled: true, teaserAvailable: false,
        restTimer: 3.5, sleepTimer: 1.25)
}

private let oneScreen = [ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                    scale: 2)]

private func makePayload(_ state: CatFrameState,
                         screens: [ScreenInfo] = oneScreen) -> StatusPayload {
    StatusJSONPresenter.payload(state: state, appVersion: "9.9.9",
                                packID: "test-blocks", packLogicalHeight: 96,
                                screens: screens,
                                loginItemState: "notRegistered")
}

/// 每個欄位都對得上來源，沒有一個是這一層自己算的。
@Test func everyFieldProjectsFromTheFrameState() {
    let state = makeState()
    let p = makePayload(state)

    #expect(p.appVersion == "9.9.9")
    #expect(p.visible == true)
    #expect(p.phase == "resting")
    #expect(p.phaseElapsed == 7.75)

    #expect(p.teaser.enabled == true)
    #expect(p.teaser.available == false)   // 與 enabled 刻意相反，接反就會紅

    #expect(p.cat.position == .init(x: 111, y: 222))
    #expect(p.cat.action == "stretch")
    #expect(p.cat.frame == 2)
    #expect(p.cat.frameCount == 5)
    #expect(p.cursor == .init(x: 333, y: 444))

    #expect(p.spotlight.active == true)
    #expect(p.spotlight.radius == 77)
    #expect(p.spotlight.opacity == 0.88)

    #expect(p.timers.rest == 3.5)
    #expect(p.timers.sleep == 1.25)

    #expect(p.pack.id == "test-blocks")
    #expect(p.pack.logicalHeight == 96)
    #expect(p.display.scale == 2)
}

/// `phase` 用 rawValue，而 rawValue 是 spec 第 8.4 節對外承諾的字串。
/// 隨手把 enum 改名就會靜默改掉 AI 正在比對的值，所以每一個都列出來。
@Test func everyPhaseHasItsSpecifiedWireName() {
    let names = CatPhase.allCases.map { makePayload(makeState(phase: $0)).phase }
    #expect(names == ["hidden", "hunting", "arriving", "sitting", "resting",
                      "lyingDown", "sleeping", "exiting",
                      "teaserApproach", "teaserStalking", "teaserWindup",
                      "teaserPouncing", "teaserTumbling", "teaserRetreating"])
    // hidden 是唯一 visible == false 的
    #expect(makePayload(makeState(phase: .hidden)).visible == false)
}

/// `facing` 要與畫面畫出來的一致，而不是「看起來像對的」。
///
/// 所以斷言的對象是 `OverlayPresenter` 實際算出的鏡像旗標，不是再寫一次
/// `cos(heading) < 0`——重寫的話，兩份公式漂開的那一刻這條測試會跟著漂。
///
/// 3π/4 這個角度是刻意挑的：cos 為負（朝左）而 sin 為正，
/// 所以「不小心用了 sin」的實作會在這裡當場現形。
@Test func facingMatchesWhatTheOverlayDraws() {
    let overlay = OverlayPresenter(logicalHeight: 96, catScale: 1,
                                   anchor: CGPoint(x: 0.5, y: 0.9),
                                   spriteFacing: .right, mirrorForOpposite: true,
                                   spriteAspect: 1, feather: 0.2)

    for heading in [CGFloat(0), .pi / 4, 3 * .pi / 4, .pi, -3 * .pi / 4] {
        let state = makeState(heading: heading)
        let facing = makePayload(state).cat.facing
        let mirrored = overlay.viewModel(for: state, in: oneScreen[0].frame).cat.mirrored
        // 素材本來朝右，所以「畫面鏡像了」等價於「status 說朝左」
        #expect(mirrored == (facing == "left"),
                "heading \(heading)：畫面 mirrored=\(mirrored) 但 status 說 \(facing)")
    }

    #expect(makePayload(makeState(heading: 3 * .pi / 4)).cat.facing == "left")
    #expect(makePayload(makeState(heading: .pi / 4)).cat.facing == "right")
}

/// `distance` 用 `CatFrameState.distanceToCursor`（Domain 既有的計算屬性）。
///
/// 3-4-5 三角形：答案是 5 這個乾淨的整數，所以「少開根號」「算成曼哈頓距離」
/// 之類的錯誤都會得到明顯不同的數字，而不是一個差幾個 ulp 的近似值。
@Test func distanceComesFromTheFrameState() {
    let state = makeState(position: CGPoint(x: 100, y: 100),
                          cursor: CGPoint(x: 130, y: 140))
    #expect(makePayload(state).distance == 50)
    #expect(makePayload(state).distance == Double(state.distanceToCursor))
}

/// spotlight 不活躍時 radius 與 opacity 都是 0，不是上一次的殘值。
///
/// `isActive` 只看 opacity，所以「opacity 已歸零、radius 還留著」是真的會
/// 出現在淡出最後一帧的狀態——夾具刻意做成那個樣子，而不是用 `.inactive`
/// （那個兩者本來就都是 0，測不出任何東西）。
@Test func inactiveSpotlightReportsZeroes() {
    let fading = SpotlightState(center: CGPoint(x: 555, y: 666), radius: 340, opacity: 0)
    #expect(fading.isActive == false)

    let p = makePayload(makeState(spotlight: fading))
    #expect(p.spotlight.active == false)
    #expect(p.spotlight.radius == 0, "殘留的半徑會讓只讀 radius 的腳本以為聚光燈還在")
    #expect(p.spotlight.opacity == 0)
}

/// `display.screenIndex` 以**鼠標**為準，不是貓。
///
/// 貓與鼠標在不同螢幕上時這兩個答案才會不同，所以夾具讓它們不同——
/// 單螢幕、或兩者同螢幕時，「用貓的位置」是完全正確的，測不出來。
@Test func screenIndexFollowsTheCursorNotTheCat() {
    let screens = [ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2),
                   ScreenInfo(frame: CGRect(x: 1920, y: 0, width: 1280, height: 800), scale: 1)]
    let state = makeState(position: CGPoint(x: 500, y: 500),      // 貓在 0 號
                          cursor: CGPoint(x: 2400, y: 400))       // 鼠標在 1 號
    #expect(makePayload(state, screens: screens).display.screenIndex == 1)
}

/// `scale` 要來自**索引指到的那一片**，不是第一片、也不是主螢幕。
///
/// 兩片螢幕的 scale 刻意不同（Retina ＋ 外接 1080p 就是這個樣子）。
/// 相同的話，「拿錯螢幕的 scale」這個 bug 在任何斷言下都看不出來。
@Test func scaleComesFromTheScreenTheCursorIsOn() {
    let screens = [ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2),
                   ScreenInfo(frame: CGRect(x: 1920, y: 0, width: 1280, height: 800), scale: 1)]

    let onRetina = makeState(cursor: CGPoint(x: 900, y: 500))
    #expect(makePayload(onRetina, screens: screens).display.scale == 2)

    let onExternal = makeState(cursor: CGPoint(x: 2400, y: 400))
    #expect(makePayload(onExternal, screens: screens).display.scale == 1)
}

/// 鼠標落在螢幕之間的空隙時，索引要與貓的入場點是同一片螢幕。
///
/// 分開實作的話這裡會分歧：貓從最近那片的邊緣跑出來，
/// 而 status 說牠不在任何螢幕上。
@Test func screenIndexAgreesWithTheStageWhenCursorIsInAGap() {
    let screens = [ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000), scale: 1),
                   ScreenInfo(frame: CGRect(x: 2000, y: 0, width: 1000, height: 1000), scale: 1)]
    let cursor = CGPoint(x: 1900, y: 500)   // 空隙裡，離 1 號比較近
    let index = makePayload(makeState(cursor: cursor), screens: screens).display.screenIndex

    #expect(index == 1)
    // 先確認索引在範圍內再 subscript：直接 `screens[index]` 在索引錯掉時是
    // crash 而不是 fail，而 crash 會帶走整個 test run，把後面每一條都藏起來
    let frames = screens.map(\.frame)
    let indexed = frames.indices.contains(index) ? frames[index] : nil
    #expect(indexed == StageReader.stage(screens: frames, cursor: cursor).cursorScreen)
}

/// 螢幕全部睡著時沒有任何索引是對的，回 -1 而不是 0。
///
/// 0 是個看起來很正常的答案，腳本不會發現它是瞎猜的。
@Test func noScreensReportsMinusOneNotZero() {
    #expect(makePayload(makeState(), screens: []).display.screenIndex == -1)
    #expect(makePayload(makeState(), screens: []).display.scale == 1)
}
