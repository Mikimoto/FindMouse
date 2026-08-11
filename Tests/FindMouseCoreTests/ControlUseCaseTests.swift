// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import Testing
@testable import FindMouseCore
import FindMouseDomain

/// 三條入口（快捷鍵、選單列、CLI）投遞的命令要進同一個佇列，順序與重複都保持。
///
/// 「同一個佇列」是這個型別存在的**唯一**理由，所以它要有一條直接的斷言：
/// 三個互不知情的呼叫端各投一個，一次 drain 要三個都拿到。
/// 若哪天有人給 CLI 開第二條路，這條會紅。
///
/// 前兩個刻意相同且**相鄰**：命令的幂等性是**狀態機**的性質
/// （`summonIsIdempotentWhileToggleIsNot`），不是佇列的。佇列若自作聰明去重，
/// 「按一下快捷鍵再點一次選單」與「只按一下」就變成同一件事，
/// 而 toggle 的兩下是回到原點。
///
/// 序列刻意不對稱：`[toggle, toggle, summon]` 反過來是 `[summon, toggle, toggle]`。
/// 第一版寫成 `[toggle, summon, toggle]`，是個迴文——mutation 實測「drain 反序」
/// 與「相鄰去重」兩個破壞它都照樣全綠，這條斷言當時什麼都沒守住。
@Test func commandsFromEveryEntryPointShareOneQueue() throws {
    let control = ControlUseCase(catalog: StubCatalog())

    // 分別扮演快捷鍵、選單列、CLI——它們對 control 的用法一模一樣，這正是重點
    let hotkey = { try control.enqueue(.toggle) }
    let menuBar = { try control.enqueue(.toggle) }
    let cli = { try control.enqueue(.summon) }

    try hotkey()
    try menuBar()
    try cli()

    #expect(control.drain() == [.toggle, .toggle, .summon])
}

/// 取走佇列之後就清空，同一個命令不會被消費兩次。
///
/// 這條防的是很具體的災難：`toggle` 若每帧都被重放，貓會在 hunting 與 exiting
/// 之間以 60Hz 抽搐。
@Test func drainingTheQueueEmptiesIt() throws {
    let control = ControlUseCase(catalog: StubCatalog())
    try control.enqueue(.summon)

    #expect(control.drain() == [.summon])
    #expect(control.drain() == [])
}

/// `isEmpty` 要跟著佇列走。
///
/// 這不是湊數的 getter：`AppDelegate` 靠它決定「貓退場後可不可以停 display link」。
/// 它若恆為 true，一個在最後一帧投進來的命令會被冷凍到下一次按鍵。
@Test func isEmptyTracksTheQueue() throws {
    let control = ControlUseCase(catalog: StubCatalog())
    #expect(control.isEmpty)

    try control.enqueue(.dismiss)
    #expect(control.isEmpty == false)

    _ = control.drain()
    #expect(control.isEmpty)
}

/// pack 缺 teaser 動作時，teaser 命令要回 TEASER_UNAVAILABLE，而狀態不變。
///
/// M1 的 `teaserUnavailablePackIgnoresCommand` 釘住了「狀態不變」，
/// 但沒有人回報錯誤——使用者按了鍵什麼都沒發生，也不知道為什麼。
/// 這一層補的就是那個「為什麼」。
@Test func teaserCommandOnAnIncapablePackReportsUnavailable() {
    let catalog = StubCatalog(dropping: [.pounce])
    #expect(catalog.capabilities.teaserAvailable == false)
    let control = ControlUseCase(catalog: catalog)

    #expect(throws: ControlError.teaserUnavailable) { try control.enqueue(.setTeaser(true)) }
    #expect(throws: ControlError.teaserUnavailable) { try control.enqueue(.toggleTeaser) }

    // 被拒絕的命令不進佇列——否則 tick 還是會收到它，「拒絕」就只是嘴上說說
    #expect(control.drain() == [])
}

/// 但一般命令在同一個 pack 上照常運作：閘門只擋 teaser，不是整個 App 罷工。
@Test func nonTeaserCommandsStillPassOnAnIncapablePack() throws {
    let control = ControlUseCase(catalog: StubCatalog(dropping: [.pounce]))
    try control.enqueue(.summon)
    try control.enqueue(.toggle)
    try control.enqueue(.dismiss)
    #expect(control.drain() == [.summon, .toggle, .dismiss])
}

/// 「把 teaser 關掉」對沒有 teaser 的 pack 也要成功。
///
/// 這是刻意的決定，不是漏網：它要的後置條件（teaser 是關的）本來就成立。
/// 拒絕的話，`findmouse teaser off` 就得依 pack 而定成功與否，
/// 任何「先關掉再做事」的腳本都要為它寫例外。
@Test func turningTeaserOffSucceedsEvenWithoutTeaserFrames() throws {
    let control = ControlUseCase(catalog: StubCatalog(dropping: [.pounce]))
    try control.enqueue(.setTeaser(false))
    #expect(control.drain() == [.setTeaser(false)])
}

// spec 第 8.3 節「`toggle` 不是幂等的、`summon` 是」的依據不在這個檔案，
// 在 `RobustnessTests.summonIsIdempotentWhileToggleIsNot`——那是狀態機的性質。
// 這一層只保證命令原封不動送到那裡（見本檔第一條）。CLI 的文件要引那一條。
