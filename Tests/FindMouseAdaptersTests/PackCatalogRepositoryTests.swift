// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FindMouseAdapters
import FindMouseDomain

/// fixtures 是 SwiftPM resources，靠 `Bundle.module` 定位。
/// 用 `#require` 而不是 `#expect`：路徑找不到時後面每一條斷言都會是誤導。
private func fixtures() throws -> URL {
    try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
}

/// 造一個空的「使用者 pack 目錄」。呼叫端負責刪。
///
/// 名字帶亂數：整個 target 的測試在同一個 process 裡平行跑，
/// 固定名字會讓兩條測試互相踩到對方正在建立或刪除的檔案。
private func makeUserPacksDirectory() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fm-packs-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 複製一份 fixture 到 `parent` 並換成新的 id。
///
/// 目錄名與 pack.json 裡的 id 必須一起換：`PackValidator` 把兩者不符判成 error，
/// 只換一邊的話這套 pack 會變成不可用，就測不到「合格的使用者 pack 長什麼樣」。
private func copyFixture(_ id: String, into parent: URL, as newID: String) throws {
    let source = try fixtures().appendingPathComponent(id)
    let destination = parent.appendingPathComponent(newID)
    try FileManager.default.copyItem(at: source, to: destination)
    let manifest = destination.appendingPathComponent("pack.json")
    let rewritten = try String(contentsOf: manifest, encoding: .utf8)
        .replacingOccurrences(of: "\"\(id)\"", with: "\"\(newID)\"")
    try rewritten.write(to: manifest, atomically: true, encoding: .utf8)
}

/// 壞掉的 pack 要出現在清單上、標成不可用，**而不是從清單消失**。
///
/// 消失的話使用者完全無法理解——他明明把目錄放進去了。spec 第 10 節要求
/// 「缺必要動作 → 設定裡紅字不可選」，紅字的前提是它列得出來。
@Test func brokenPacksAreListedAsUnusableRatherThanHidden() throws {
    let packs = PackCatalogRepository.scan(directories: [(try fixtures(), false)])
    let ids = packs.map(\.id)
    #expect(ids.contains("bad-missing-core"))
    // 同一個目錄內依 id 排序。`contentsOfDirectory` 的順序沒有保證，
    // 不排的話設定視窗的清單每次開都可能換一個順序。
    #expect(ids == ids.sorted())

    let broken = try #require(packs.first { $0.id == "bad-missing-core" })
    #expect(broken.isUsable == false)
    #expect(broken.errors.contains { $0.contains("必要動作") })
}

/// 缺 teaser 的 pack 是**合格**的，只是 teaserAvailable 為 false。
@Test func aPackMissingTeaserIsStillUsable() throws {
    let packs = PackCatalogRepository.scan(directories: [(try fixtures(), false)])
    let noTeaser = try #require(packs.first { $0.id == "bad-missing-teaser" })
    #expect(noTeaser.isUsable)
    #expect(noTeaser.teaserAvailable == false)
}

/// 內建與使用者目錄的來源要分得出來——UI 要用它決定能不能刪，
/// 而且**同 id 時內建的優先**（使用者不該能用同名 pack 蓋掉內建的）。
@Test func builtInWinsWhenBothDirectoriesHaveTheSameID() throws {
    let builtIn = try fixtures()
    let user = try makeUserPacksDirectory()
    defer { try? FileManager.default.removeItem(at: user) }
    try FileManager.default.copyItem(
        at: builtIn.appendingPathComponent("bad-missing-core"),
        to: user.appendingPathComponent("bad-missing-core"))

    let packs = PackCatalogRepository.scan(directories: [(builtIn, true), (user, false)])
    let matching = packs.filter { $0.id == "bad-missing-core" }
    #expect(matching.count == 1, "同一個 id 只能出現一次")
    #expect(matching.first?.isBuiltIn == true)
}

/// 第二個目錄也要真的掃到，而且 `isBuiltIn` 是**逐目錄**決定的。
///
/// 沒有這一條，「只掃 directories.first」與「isBuiltIn 一律填 true」兩種寫法
/// 都能通過上面每一條測試——「內建優先」剛好也是「取第一個」，
/// 而其餘測試都只餵一個目錄。
@Test func userPacksAreListedAndMarkedAsNotBuiltIn() throws {
    let builtIn = try fixtures()
    let user = try makeUserPacksDirectory()
    defer { try? FileManager.default.removeItem(at: user) }
    try copyFixture("bad-missing-teaser", into: user, as: "user-blocks")

    let packs = PackCatalogRepository.scan(directories: [(builtIn, true), (user, false)])
    let mine = try #require(packs.first { $0.id == "user-blocks" })
    #expect(mine.isBuiltIn == false)
    #expect(mine.isUsable, "只是換了 id 的合格 pack")

    // 另一邊也要如實標成內建，否則「isBuiltIn 一律填 false」也會通過
    let othersAreBuiltIn = packs.filter { $0.id != "user-blocks" }.allSatisfy(\.isBuiltIn)
    #expect(othersAreBuiltIn)
    #expect(packs.count == PackCatalogRepository.scan(directories: [(builtIn, true)]).count + 1,
            "兩個目錄的 pack 都要在清單上")
}

/// 目錄不存在不是錯誤——使用者 pack 目錄一開始本來就不存在。
///
/// 不存在的那個排**前面**：排後面的話，「讀不到目錄就把已收集的結果丟回去」
/// 這種寫法照樣會通過，而它在使用者目錄缺席時會讓內建 pack 全部消失。
@Test func aMissingDirectoryContributesNothingAndDoesNotThrow() throws {
    let existing = try fixtures()
    let absent = URL(fileURLWithPath: "/nonexistent/packs-\(UUID().uuidString.prefix(8))")
    let baseline = PackCatalogRepository.scan(directories: [(existing, false)])
    let withAbsent = PackCatalogRepository.scan(
        directories: [(absent, false), (existing, false)])

    #expect(baseline.isEmpty == false, "fixtures 目錄本來就有 pack，不然這條測不到東西")
    #expect(withAbsent == baseline, "既有目錄的 pack 一筆不多一筆不少")
}

/// 目錄裡的非 pack 目錄（沒有 pack.json）要略過，不要變成一筆壞掉的 pack。
@Test func directoriesWithoutAManifestAreSkipped() throws {
    let dir = try makeUserPacksDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("not-a-pack"), withIntermediateDirectories: true)

    #expect(PackCatalogRepository.scan(directories: [(dir, false)]).isEmpty)
}

/// `pack use` 要靠它把 id 換成目錄，而且**必須跟清單同一套優先序**：
/// 清單顯示內建那套、切換卻切到使用者的同名目錄，畫面與實際就對不起來了。
@Test func packDirectoryLookupPrefersTheBuiltInCopy() throws {
    let builtIn = try fixtures()
    let user = try makeUserPacksDirectory()
    defer { try? FileManager.default.removeItem(at: user) }
    try FileManager.default.copyItem(
        at: builtIn.appendingPathComponent("bad-missing-core"),
        to: user.appendingPathComponent("bad-missing-core"))

    let directories: [(URL, Bool)] = [(builtIn, true), (user, false)]
    #expect(PackCatalogRepository.directory(for: "bad-missing-core", in: directories)
            == builtIn.appendingPathComponent("bad-missing-core"))
    #expect(PackCatalogRepository.directory(for: "no-such-pack", in: directories) == nil)
}

/// id 會被 `appendingPathComponent` 拿去組路徑，所以它必須先過值域。
///
/// 為什麼擋在這裡而不是各個呼叫端：啟動時的 `pack.id` 是從 UserDefaults 直讀的
/// （`AppDelegate` 那一步拿不到 `SettingsUseCase`——它要一個 catalog，而 catalog
/// 正是那一步要載出來的東西），所以 spec 第 9 節「值域驗證只有一份」在**讀取路徑**
/// 上有缺口。`directory(for:in:)` 是 id 變成路徑的唯一入口，擋住它就不必寄望
/// 每個呼叫端各自記得驗一次。
@Test func anIDThatEscapesTheScanDirectoryNeverBecomesAPath() throws {
    // 兄弟目錄裡要放一套**讀得起來**的 pack。`directory(for:in:)` 是靠
    // `SpritePackRepository.load` 成不成功決定回不回傳的，所以穿越到一個沒有
    // pack.json 的路徑本來就會回 nil——拿那種輸入當測試，守衛拿掉照樣綠，
    // 它為了錯的理由通過。第一版就是這樣寫的，跑起來直接是綠的才發現。
    let base = try makeUserPacksDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let scanDir = base.appendingPathComponent("packs")
    try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
    let good = try fixtures().appendingPathComponent("bad-missing-core")
    try FileManager.default.copyItem(at: good, to: base.appendingPathComponent("outside"))

    #expect(PackCatalogRepository.directory(for: "../outside", in: [(scanDir, true)]) == nil,
            "../outside 穿越出掃描目錄，而那裡真的有一套讀得起來的 pack")

    for bad in ["", "..", "a/b", "UPPER", "with space", "./x"] {
        #expect(PackCatalogRepository.directory(for: bad, in: [(scanDir, true)]) == nil,
                "\(bad) 不該組得出路徑")
    }

    // 對照組：合法 id 仍然找得到。少了這條，「一律回 nil」也會讓上面全過。
    try FileManager.default.copyItem(at: good, to: scanDir.appendingPathComponent("bad-missing-core"))
    #expect(PackCatalogRepository.directory(for: "bad-missing-core", in: [(scanDir, true)]) != nil,
            "合法 id 仍然要找得到，否則這條測試只是把全部都擋掉")
}

/// 偵測器的兩個條件**缺一不可**，第三個條件（記號）能把它關掉。
///
/// 四個 case 對應四種真實狀態：全新安裝（沒有舊目錄）、非沙盒建置（舊家就是新家、
/// 讀得到）、從沙盒之前升級上來（在那裡但讀不到）、以及已經搬過一次。
///
/// **這裡的三個布林值全部來自真的檔案系統**，不是假的 FileManager：`chmod 000`
/// 對擁有者自己也會讓 `isReadableFile` 回 false（同一招在
/// `anUnreadableSourceSaysSoInsteadOfBlamingTheManifest` 用過），所以沙盒下
/// 「存在但讀不到」那個不對稱在這裡造得出來，不必為了測試發明一層抽象。
@Test func theLegacyMigrationDetectorNeedsEveryCondition() throws {
    let base = try makeUserPacksDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let newHome = base.appendingPathComponent("Containers/Packs")
    try FileManager.default.createDirectory(at: newHome, withIntermediateDirectories: true)

    // 1. 沒有舊目錄＝全新安裝。
    let missing = base.appendingPathComponent("nothing-here")
    #expect(PackCatalogRepository.legacyPacksNeedMigration(
        legacy: missing, packsDirectory: newHome) == false)

    // 2. 舊目錄在、而且讀得到＝非沙盒建置（那時舊家就是新家）。
    let readable = base.appendingPathComponent("readable")
    try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
    #expect(PackCatalogRepository.legacyPacksNeedMigration(
        legacy: readable, packsDirectory: newHome) == false)

    // 3. 在、但讀不到＝沙盒下的舊家。這是唯一該提示的狀態。
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: readable.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: readable.path)
    }
    // 前置條件自己也要驗：`chmod 000` 若對擁有者無效（例如以 root 跑），
    // 下面那條就會是為了錯的理由失敗，而訊息會指向偵測器。
    #expect(FileManager.default.isReadableFile(atPath: readable.path) == false,
            "chmod 000 沒有讓它變成讀不到，這條測試的前提不成立")
    #expect(PackCatalogRepository.legacyPacksNeedMigration(
        legacy: readable, packsDirectory: newHome) == true)

    // 4. 使用者已經走過一次搬移——舊目錄仍然讀不到，但不該再提示。
    FileManager.default.createFile(
        atPath: PackCatalogRepository.migrationMarker(in: newHome).path, contents: nil)
    #expect(PackCatalogRepository.legacyPacksNeedMigration(
        legacy: readable, packsDirectory: newHome) == false)
}

/// 記號是點開頭的檔案，所以它不會自己變成清單上的一列。
///
/// 釘住的是「記號住在 Packs 底下」這個決定的代價：那個目錄的每一個項目都會被
/// `scan` 走過一次。它若被當成一套 pack，使用者會看到一列叫
/// `.legacy-migration-done` 的東西。
@Test func theMigrationMarkerDoesNotShowUpAsAPack() throws {
    let packs = try makeUserPacksDirectory()
    defer { try? FileManager.default.removeItem(at: packs) }
    try copyFixture("bad-missing-teaser", into: packs, as: "real-one")
    FileManager.default.createFile(
        atPath: PackCatalogRepository.migrationMarker(in: packs).path, contents: nil)

    let ids = PackCatalogRepository.scan(directories: [(packs, false)]).map(\.id)
    #expect(ids == ["real-one"], "記號不該出現在清單上：\(ids)")
}
