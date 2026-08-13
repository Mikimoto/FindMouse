// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import FindMouseDomain

/// `installed` 是 id → isBuiltIn。
private func decide(id: String, installed: [(String, Bool)], force: Bool)
    -> PackInstallDecision {
    PackInstallDecision.decide(
        incomingID: id,
        existing: installed.map { .init(id: $0.0, isBuiltIn: $0.1) },
        force: force)
}

@Test func aFreshIDInstallsStraightAway() {
    #expect(decide(id: "orange-cat", installed: [], force: false) == .install)
    #expect(decide(id: "orange-cat", installed: [("mycat", true)], force: false) == .install)
}

@Test func anExistingUserPackNeedsConfirmation() {
    #expect(decide(id: "orange-cat", installed: [("orange-cat", false)], force: false)
            == .needsConfirmation)
}

@Test func forceTurnsConfirmationIntoReplace() {
    #expect(decide(id: "orange-cat", installed: [("orange-cat", false)], force: true)
            == .replace)
}

/// 撞到內建 id **一律拒絕**。`PackCatalogRepository.scan` 用 seen set 去重而內建
/// 目錄排在前面，所以裝進去會「成功、檔案真的在、清單裡永遠看不到」。
@Test func aBuiltInIDIsRejectedBecauseItWouldBeShadowed() {
    #expect(decide(id: "mycat", installed: [("mycat", true)], force: false)
            == .rejectedIDReserved)
}

/// `--force` 對它無效：語意是 remove ＋ install，而內建移除不了，硬做只會回到
/// 同一個遮蔽狀態。這是 C 裡唯一連 --force 都不給過的情況。
@Test func forceDoesNotOverrideTheBuiltInRejection() {
    #expect(decide(id: "mycat", installed: [("mycat", true)], force: true)
            == .rejectedIDReserved)
}

/// 內建與使用者目錄同時有同一個 id（已經被遮蔽的既有狀態）——仍然是拒絕，
/// 而不是「已存在、要確認」。理由不變：裝了也不會生效。
@Test func builtInWinsEvenIfAUserPackWithThatIDSomehowExists() {
    #expect(decide(id: "mycat", installed: [("mycat", true), ("mycat", false)], force: false)
            == .rejectedIDReserved)
    #expect(decide(id: "mycat", installed: [("mycat", false), ("mycat", true)], force: true)
            == .rejectedIDReserved, "順序不影響判定")
}
