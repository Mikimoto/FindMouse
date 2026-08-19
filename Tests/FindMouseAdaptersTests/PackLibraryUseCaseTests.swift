// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FindMouseAdapters
@testable import FindMouseDomain
import FindMouseWire

private func tempDir() throws -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("packlibrary-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// 造一個最小的合法來源目錄，回傳 pack 目錄本身。
private func makeSource(id: String, version: String? = nil, in root: URL) throws -> URL {
    let pack = root.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
    let versionField = version.map { "\"version\":\"\($0)\"," } ?? ""
    let manifest = """
    {"schemaVersion":1,"id":"\(id)","name":"測試",\(versionField)"logicalHeight":96,
     "anchor":{"x":0.5,"y":0.94},"facing":"right","mirrorForOpposite":true,
     "actions":{"run":{"frames":1,"fps":14,"loop":true}}}
    """
    try Data(manifest.utf8).write(to: pack.appendingPathComponent("pack.json"))
    return pack
}

private func summary(_ id: String, builtIn: Bool) -> PackSummary {
    PackSummary(id: id, isBuiltIn: builtIn, logicalHeight: 96,
                errors: [], warnings: [], teaserAvailable: true)
}

@Test func installingANewPackReportsTheID() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    let source = try makeSource(id: "brand-new", in: root)

    let library = PackLibraryUseCase(packsDirectory: { packs }, installedPacks: { [] })
    #expect(library.install(source: source, force: false) == .installed(id: "brand-new"))
    #expect(FileManager.default.fileExists(
        atPath: packs.appendingPathComponent("brand-new/pack.json").path))
}

/// 同 id 已存在時**不動任何檔案**，只回問句。
///
/// 斷言「目的地還是舊內容」而不只是回傳值：確認這一步若寫在複製之後，
/// 回傳值照樣正確而東西已經被覆蓋了。
@Test func aCollidingIDAsksBeforeTouchingAnything() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    let installed = packs.appendingPathComponent("cat")
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    try Data("原本的".utf8).write(to: installed.appendingPathComponent("pack.json"))

    let source = try makeSource(id: "cat", version: "2.0", in: root)
    let library = PackLibraryUseCase(packsDirectory: { packs },
                                     installedPacks: { [summary("cat", builtIn: false)] })

    let outcome = library.install(source: source, force: false)
    guard case let .needsConfirmation(id, prompt) = outcome else {
        Issue.record("預期 needsConfirmation，得到 \(outcome)"); return
    }
    #expect(id == "cat")
    #expect(prompt.contains("2.0"), "問句要帶上兩邊的版本：\(prompt)")
    #expect(!prompt.contains("--force"), "處方是入口自己的事，use case 不講")
    #expect(try String(contentsOf: installed.appendingPathComponent("pack.json"),
                       encoding: .utf8) == "原本的", "問之前不該動到目的地")
}

@Test func forceReplacesWithoutAsking() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    let installed = packs.appendingPathComponent("cat")
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    try Data("原本的".utf8).write(to: installed.appendingPathComponent("pack.json"))

    let source = try makeSource(id: "cat", in: root)
    let library = PackLibraryUseCase(packsDirectory: { packs },
                                     installedPacks: { [summary("cat", builtIn: false)] })

    #expect(library.install(source: source, force: true) == .installed(id: "cat"))
    #expect(try String(contentsOf: installed.appendingPathComponent("pack.json"),
                       encoding: .utf8) != "原本的", "force 就是真的換掉")
}

/// 撞到內建一律拒絕，`--force` 也不例外——語意是 remove ＋ install，而內建移除不了。
@Test func aBuiltInIDIsReservedEvenWithForce() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    let source = try makeSource(id: "mycat", in: root)
    let library = PackLibraryUseCase(packsDirectory: { packs },
                                     installedPacks: { [summary("mycat", builtIn: true)] })

    for force in [false, true] {
        let outcome = library.install(source: source, force: force)
        guard case let .failed(code, _) = outcome else {
            Issue.record("預期 failed，得到 \(outcome)"); return
        }
        #expect(code == .packIDReserved, "force=\(force)")
    }
    #expect(!FileManager.default.fileExists(atPath: packs.appendingPathComponent("mycat").path),
            "被拒絕就不該留下任何東西")
}

/// id 完全來自不受信任的 `pack.json`，而它會變成目的地的路徑組件。
@Test func anEscapingIDIsRejectedBeforeAnyFileIsTouched() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
    let victim = root.appendingPathComponent("victim")
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    try Data("重要".utf8).write(to: victim.appendingPathComponent("keep.txt"))

    let source = root.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("""
    {"schemaVersion":1,"id":"../victim","name":"壞","logicalHeight":96,
     "anchor":{"x":0.5,"y":0.94},"facing":"right","mirrorForOpposite":true,
     "actions":{"run":{"frames":1,"fps":14,"loop":true}}}
    """.utf8).write(to: source.appendingPathComponent("pack.json"))

    let library = PackLibraryUseCase(packsDirectory: { packs }, installedPacks: { [] })
    guard case let .failed(code, _) = library.install(source: source, force: false) else {
        Issue.record("預期 failed"); return
    }
    #expect(code == .packSourceInvalid)
    #expect(FileManager.default.fileExists(atPath: victim.appendingPathComponent("keep.txt").path),
            "Packs 外面的目錄不該被碰到")
}

/// 值域檢查在**衝突決策之前**，而那不只是順序好看。
///
/// `PackCatalogRepository.scan` 是用 manifest 的 id 列 pack 的，不是目錄名，所以一個
/// manifest id 為 `../victim` 的目錄**會**出現在清單裡（帶著 idDirectoryMismatch）。
/// 少了這道守衛，同 id 的來源會命中它而走到 needsConfirmation，而那條路會去讀
/// `Packs/../victim/pack.json`——`Packs` 外面。
///
/// 所以這道守衛守的是它的**位置**，不是錯誤碼：`PackInstaller.requireSafeID` 那道
/// 在更裡面，攔得住寫入，攔不住這條讀取。
@Test func anEscapingIDIsRejectedBeforeTheConflictDecision() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)

    let source = root.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("""
    {"schemaVersion":1,"id":"../victim","name":"壞","logicalHeight":96,
     "anchor":{"x":0.5,"y":0.94},"facing":"right","mirrorForOpposite":true,
     "actions":{"run":{"frames":1,"fps":14,"loop":true}}}
    """.utf8).write(to: source.appendingPathComponent("pack.json"))

    // 清單裡已經有一筆同 id 的——manifest id 與目錄名不符的 pack 照樣會被 scan 列出來。
    let library = PackLibraryUseCase(
        packsDirectory: { packs },
        installedPacks: { [PackSummary(id: "../victim", isBuiltIn: false, logicalHeight: 96,
                                       errors: ["目錄名與 pack.json 的 id 不符"],
                                       warnings: [], teaserAvailable: false)] })

    let outcome = library.install(source: source, force: false)
    guard case let .failed(code, _) = outcome else {
        Issue.record("預期 failed，得到 \(outcome)——走到 needsConfirmation 就代表守衛不在決策之前")
        return
    }
    #expect(code == .packSourceInvalid)
}

@Test func aMissingSourceIsItsOwnFailure() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = PackLibraryUseCase(packsDirectory: { root.appendingPathComponent("Packs") },
                                     installedPacks: { [] })
    guard case let .failed(code, message) =
            library.install(source: root.appendingPathComponent("nope.fmpack"), force: false) else {
        Issue.record("預期 failed"); return
    }
    #expect(code == .packSourceInvalid)
    #expect(message.contains("nope.fmpack"), "訊息要指名找不到的是誰：\(message)")
    // **`hasPrefix` 才是這道守衛的語意。** 少了存在檢查，來源會一路走到
    // `manifestID`，那裡解不開一個不存在的檔案、回「讀不出這個來源的 pack.json」
    // ——錯誤碼相同，而 ditto 的 stderr 也含檔名，所以上面那條 `contains` 兩種
    // 情況都過。「檔案不在」與「檔案在但讀不出來」的處方不同，要分得出來。
    #expect(message.hasPrefix("找不到"), "要講的是不存在，不是讀不出來：\(message)")
}

/// 來源裡沒有 `pack.json` → `ExtractedTree.Failure.noManifest` 那條 catch。
@Test func aSourceWithoutAManifestSaysSo() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("不是 manifest".utf8).write(to: source.appendingPathComponent("readme.txt"))

    let library = PackLibraryUseCase(packsDirectory: { root.appendingPathComponent("Packs") },
                                     installedPacks: { [] })
    guard case let .failed(code, message) = library.install(source: source, force: false) else {
        Issue.record("預期 failed"); return
    }
    #expect(code == .packSourceInvalid)
    #expect(message.contains("沒有 pack.json"), "要講出它為什麼不是一套 pack：\(message)")
}

/// 來源夾帶 symlink → `ExtractedTree.Failure.notARegularFile` 那條 catch。
@Test func aSourceWithASymlinkIsRejected() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try makeSource(id: "sneaky", in: root)
    try FileManager.default.createSymbolicLink(
        atPath: source.appendingPathComponent("link.png").path,
        withDestinationPath: "/etc/passwd")

    let library = PackLibraryUseCase(packsDirectory: { root.appendingPathComponent("Packs") },
                                     installedPacks: { [] })
    guard case let .failed(code, message) = library.install(source: source, force: false) else {
        Issue.record("預期 failed"); return
    }
    #expect(code == .packSourceInvalid)
    #expect(message.contains("不是普通檔案"), "要講出是哪一種東西不對：\(message)")
}

/// 解壓後超過上限 → `.tooLarge` 對到 `packTooLarge`（不是通用的 sourceInvalid）。
/// 錯誤碼分開才讓「檔案太大」與「檔案壞掉」的處方分得出來。
@Test func anOversizedPackGetsItsOwnCode() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    let source = try makeSource(id: "chunky", in: root)

    let library = PackLibraryUseCase(packsDirectory: { packs }, installedPacks: { [] })
    // manifest 本身就比 10 bytes 大，所以這個上限一定踩得到。
    guard case let .failed(code, _) = library.install(source: source, force: false,
                                                      byteLimit: 10) else {
        Issue.record("預期 failed"); return
    }
    #expect(code == .packTooLarge)
    #expect(!FileManager.default.fileExists(atPath: packs.appendingPathComponent("chunky").path),
            "擋下就不該留下半套")
}

// MARK: - 移除

@Test func removingAUserPackDeletesTheDirectory() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    let dir = packs.appendingPathComponent("cat")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let library = PackLibraryUseCase(packsDirectory: { packs },
                                     installedPacks: { [summary("cat", builtIn: false)] })
    #expect(library.remove(id: "cat", currentPackID: { "mycat" }, swapTarget: { nil }) == .removed(id: "cat"))
    #expect(!FileManager.default.fileExists(atPath: dir.path))
}

@Test func removingTheCurrentPackIsRefused() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    let dir = packs.appendingPathComponent("cat")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let library = PackLibraryUseCase(packsDirectory: { packs },
                                     installedPacks: { [summary("cat", builtIn: false)] })
    guard case let .failed(code, message) = library.remove(id: "cat", currentPackID: { "cat" }, swapTarget: { nil }) else {
        Issue.record("預期 failed"); return
    }
    #expect(code == .packInvalid)
    #expect(message.contains("換成別的"), "訊息要講出下一步：\(message)")
    #expect(FileManager.default.fileExists(atPath: dir.path), "被擋下就不該刪")
}

@Test func removingAnUnknownIDReportsNotFound() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = PackLibraryUseCase(packsDirectory: { root.appendingPathComponent("Packs") },
                                     installedPacks: { [] })
    guard case let .failed(code, _) = library.remove(id: "ghost", currentPackID: { "mycat" }, swapTarget: { nil }) else {
        Issue.record("預期 failed"); return
    }
    #expect(code == .packNotFound)
}

/// 被內建遮蔽的使用者目錄拿得掉——`scan` 去重且內建排前面，所以它只以內建那一筆
/// 的形式出現在清單裡。這條在 C-1 已經修過（`RequestRouter`），搬家不能弄丟。
@Test func aUserDirectoryShadowedByABuiltInIsStillRemovable() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    let dir = packs.appendingPathComponent("mycat")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let library = PackLibraryUseCase(packsDirectory: { packs },
                                     installedPacks: { [summary("mycat", builtIn: true)] })
    #expect(library.remove(id: "mycat", currentPackID: { "mycat" }, swapTarget: { nil }) == .removed(id: "mycat"))
    #expect(!FileManager.default.fileExists(atPath: dir.path))
}

/// `remove` 的 `PackInstaller.Failure → packSourceInvalid` 那條 catch **走得到**，
/// 而註解宣稱的就是這件事。
///
/// 構造：清單裡有一筆 id 為 `../victim` 的（`scan` 用 manifest 的 id 列 pack，
/// 所以那是做得到的），而 `Packs` 底下**沒有任何目錄自報這個 id**——於是
/// `sourceDirectoryName` 回 nil、退回「目錄名 == id」，那個危險字串才真的
/// 走到 `PackInstaller.remove`，被它的路徑組件檢查擋下（不是 `requireSafeID`，
/// 那道只在 `install` 那一側）。斷言**目錄沒被刪**：`../victim` 標準化之後
/// 指到 `Packs` 外面。
///
/// 這條同時是退回路徑的唯一覆蓋：磁碟上真的有一個自報該 id 的目錄時，
/// 解析得出來、刪的就是它（`removeDeletesTheDirectoryTheListingCameFrom…`）。
@Test func removingAnEscapingIDIsCaughtByTheInstaller() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
    let victim = root.appendingPathComponent("victim")
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    try Data("重要".utf8).write(to: victim.appendingPathComponent("keep.txt"))

    let library = PackLibraryUseCase(packsDirectory: { packs },
                                     installedPacks: { [summary("../victim", builtIn: false)] })
    guard case let .failed(code, _) = library.remove(id: "../victim",
                                                    currentPackID: { "mycat" },
                                                    swapTarget: { nil }) else {
        Issue.record("預期 failed"); return
    }
    #expect(code == .packSourceInvalid)
    #expect(FileManager.default.fileExists(atPath: victim.appendingPathComponent("keep.txt").path),
            "Packs 外面的目錄不該被刪掉")
}

/// `currentPackID` 收 closure 是為了**惰性**，不是為了好看：`RequestRouter` 傳的是
/// `status()`，而它會列舉 `NSScreen.screens` 並查一次 `SMAppService`。被更早的守衛
/// 擋下的移除不該白跑那些。把它 hoist 到 `remove` 開頭在行為上看不出差別，
/// 所以要數呼叫次數才釘得住。
@Test func currentPackIDIsNotAskedOnPathsThatRejectEarlier() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)

    final class Counter: @unchecked Sendable { var n = 0 }
    let counter = Counter()
    let ask: () -> String = { counter.n += 1; return "whatever" }

    // 不在清單裡 → packNotFound，最早那條
    let empty = PackLibraryUseCase(packsDirectory: { packs }, installedPacks: { [] })
    _ = empty.remove(id: "ghost", currentPackID: ask, swapTarget: { nil })
    #expect(counter.n == 0, "packNotFound 那條不該問")

    // 真的內建 → packBuiltIn，第二條
    let builtIn = PackLibraryUseCase(packsDirectory: { packs },
                                     installedPacks: { [summary("mycat", builtIn: true)] })
    _ = builtIn.remove(id: "mycat", currentPackID: ask, swapTarget: { nil })
    #expect(counter.n == 0, "packBuiltIn 那條也不該問")

    // 走到「是不是當前」才問，而且只問一次
    let dir = packs.appendingPathComponent("spare")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let user = PackLibraryUseCase(packsDirectory: { packs },
                                  installedPacks: { [summary("spare", builtIn: false)] })
    _ = user.remove(id: "spare", currentPackID: ask, swapTarget: { nil })
    #expect(counter.n == 1, "走到那條才問，而且只問一次")
}

/// **正要換過去的那一套拿不掉，CLI 也一樣。** 空窗裡 `currentPackID()` 還是舊的，
/// 所以沒有 `swapTarget` 就認不出目標——守衛只放在設定視窗的話，
/// `findmouse pack use spare` 之後緊接 `findmouse pack remove spare` 照樣刪得掉。
@Test func theSwapTargetCannotBeRemoved() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    let dir = packs.appendingPathComponent("spare")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let library = PackLibraryUseCase(packsDirectory: { packs },
                                     installedPacks: { [summary("spare", builtIn: false)] })
    // currentPackID 仍是舊的那一套——這正是空窗的形狀
    let outcome = library.remove(id: "spare", currentPackID: { "mycat" },
                                 swapTarget: { "spare" })
    guard case let .failed(code, message) = outcome else {
        Issue.record("預期 failed，得到 \(outcome)"); return
    }
    #expect(code == .packInvalid)
    #expect(message.contains("正在切換"), "要講出為什麼：\(message)")
    #expect(FileManager.default.fileExists(atPath: dir.path), "被擋下就不該刪")
}

/// **兩個條件同時成立時要說「正在使用中」。** 對著當前那一套再按一次它自己，
/// `PackSwapUseCase.request` 照樣記一筆 pending（它不管 id 是不是已經是當前的），
/// 於是 `currentPackID()` 與 `swapTarget()` 會是同一個 id。這時「正在切換過去，
/// 等它換好再試」是句空話——不會有「換好」的那一刻。
///
/// 釘的是**守衛的順序**，兩條路都拒絕移除，差別只在使用者讀到哪一句。
@Test func thePackThatIsBothCurrentAndTheSwapTargetReadsAsInUse() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    try FileManager.default.createDirectory(at: packs.appendingPathComponent("spare"),
                                            withIntermediateDirectories: true)

    let library = PackLibraryUseCase(packsDirectory: { packs },
                                     installedPacks: { [summary("spare", builtIn: false)] })
    let outcome = library.remove(id: "spare", currentPackID: { "spare" },
                                 swapTarget: { "spare" })
    guard case let .failed(_, message) = outcome else {
        Issue.record("預期 failed，得到 \(outcome)"); return
    }
    #expect(message.contains("正在使用中"), "順序反了就會讀到「正在切換過去」：\(message)")
}

@Test func removingARealBuiltInIsRefused() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)

    let library = PackLibraryUseCase(packsDirectory: { packs },
                                     installedPacks: { [summary("mycat", builtIn: true)] })
    guard case let .failed(code, _) = library.remove(id: "mycat", currentPackID: { "other" }, swapTarget: { nil }) else {
        Issue.record("預期 failed"); return
    }
    #expect(code == .packBuiltIn)
}

/// 從這個檔往上找到 `Package.swift` 所在的目錄。與
/// `ArchitectureBoundaryTests.packageRoot` 同一招，但那支是別的 target 的 private。
private func packageRoot() -> URL {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while dir.path != "/" {
        if FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
        dir = dir.deletingLastPathComponent()
    }
    fatalError("從 \(#filePath) 往上找不到 Package.swift")
}

/// **那兩個接線參數不可以有預設值。**
///
/// 它們是「換 pack 的空窗期不准移除目標」那道守衛的接線，而有預設值就等於
/// 「漏傳＝守衛關著」。2026-08-14 實測（**在補這條測試之前**）：把 `= { nil }`
/// 加回去、再刪掉 `AppDelegate` 那兩處引數，`swift build --product FindMouseApp`
/// 成功、五個 target 全綠——零編譯訊號、零測試訊號。所以那時擋得住漏傳的只有
/// 「沒有預設值」造成的編譯錯誤，而沒有任何東西擋得住有人把預設值加回去。
///
/// 掃原始碼而不是寫行為測試：Swift 沒辦法在執行期問「這個參數有沒有預設值」。
///
/// **它守的是那一行宣告的文字，不是「守衛一定接得上」。** 不改那一行卻讓呼叫端
/// 可以省略的手法都躲得過——實測過的一種是另開一個省略該參數的 `convenience
/// init`（designated init 一字不改，五個 target 全綠）。與
/// `ArchitectureBoundaryTests` 同一類：擋的是不小心，不是刻意規避。
///
/// 先斷言那一行**恰好**找得到一次：找不到（改名、宣告跨行）或找到多個
/// （pattern 太寬）都當成紅燈，而不是靜默變成一條什麼都不驗的測試。
@Test func theSwapTargetWiringHasNoDefaultValue() throws {
    let declarations = [
        ("Sources/FindMouseAdapters/RequestRouter.swift",
         "packSwapTarget: @escaping () -> String?"),
        ("Sources/FindMouseAdapters/PackLibraryUseCase.swift",
         "swapTarget: () -> String?"),
    ]
    for (path, declaration) in declarations {
        let source = try String(contentsOf: packageRoot().appendingPathComponent(path),
                                encoding: .utf8)
        // **每一行先砍掉註解再看。** 註解在這裡有兩種害處：`/// …` 引用同一段簽名
        // 會被算成第二個命中（誤報），而**行尾**的註解會讓「宣告後面還有東西」
        // 成立，於是下面的前瞻不往下看（漏報）。砍掉之後兩種一起消失，連
        // 「`//` 開頭的整行」都不必另外濾——它砍完就是空字串。
        //
        // 砍在第一個 `//`：字串字面值裡的 `//` 會被誤砍，但那只會讓命中數變動，
        // 而命中數不是 1 就是紅燈，方向是安全的。
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { ($0.components(separatedBy: "//").first ?? "")
                .trimmingCharacters(in: .whitespaces) }
        let hits = lines.indices.filter { lines[$0].contains(declaration) }
        #expect(hits.count == 1,
                "\(path)：預期恰好一行宣告 `\(declaration)`，找到 \(hits.count) 行。pattern 過時了（改名？宣告跨行？字串字面值引用了同一段簽名？），這條測試已經不在守任何東西。")
        for i in hits {
            // 看宣告後面**接的是不是 `=`**，而不是找 `= {`：預設值可以寫成
            // `=  { nil }`（多一個空格）、`= ({ nil })`、`= Optional…`，
            // 逐一列舉寫法只會漏。
            //
            // 看**每一個**出現位置後面的片段而不只是最後一段：同一行寫兩次時
            // 預設值會掛在第一次後面，而最後一段是乾淨的。
            var tails = lines[i].components(separatedBy: declaration).dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // 宣告後那一行就結束時，`=` 可以寫在下一行——而中間還可以隔著空行與
            // 整行註解。**重新加預設值的人最可能順手寫一句註解說明**，所以這裡
            // 要往下找到第一行有東西的，不能只看緊接的那一行。
            if tails.allSatisfy(\.isEmpty),
               let next = lines[(i + 1)...].first(where: { !$0.isEmpty }) {
                tails.append(next)
            }
            #expect(!tails.contains { $0.hasPrefix("=") },
                    "\(path)：`\(declaration)` 又有預設值了 → \(lines[i])")
        }
    }
}

// MARK: - 目錄名與 manifest id 不符

/// 造一個目錄名與 manifest id 可以不同的 pack。
private func makePackDirectory(named name: String, declaring id: String,
                               in packs: URL) throws {
    let dir = packs.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("""
    {"schemaVersion":1,"id":"\(id)","name":"測試","logicalHeight":96,
     "anchor":{"x":0.5,"y":0.94},"facing":"right","mirrorForOpposite":true,
     "actions":{"run":{"frames":1,"fps":14,"loop":true}}}
    """.utf8).write(to: dir.appendingPathComponent("pack.json"))
}

/// 依真實的 `scan` 建一個 use case——**這幾條的重點正是「清單怎麼來的」與
/// 「刪除刪哪個」要對得上**，餵一份手寫的 installedPacks 就把待驗的東西假設掉了。
private func libraryOverRealScan(_ packs: URL) -> PackLibraryUseCase {
    PackLibraryUseCase(packsDirectory: { packs },
                       installedPacks: { PackCatalogRepository.scan(directories: [(packs, false)]) })
}

/// **刪掉的要是清單上那一列住的目錄，不是與 id 同名的那個。**
///
/// `scan` 依 manifest 的 id 去重、同一個目錄內依名稱字典序，所以 `alpha`（自稱
/// `bar`）排在 `bar` 前面而贏得那一列。拿 id 當目錄名刪的話，刪掉的是**使用者
/// 沒看到的**那個健康 pack，而畫面說「已移除」——2026-08-14 實測過那個行為。
@Test func removeDeletesTheDirectoryTheListingCameFromNotTheOneNamedAfterTheID() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    try makePackDirectory(named: "alpha", declaring: "bar", in: packs)
    try makePackDirectory(named: "bar", declaring: "bar", in: packs)

    let library = libraryOverRealScan(packs)
    #expect(library.remove(id: "bar", currentPackID: { "mycat" }, swapTarget: { nil })
            == .removed(id: "bar"))
    #expect(!FileManager.default.fileExists(atPath: packs.appendingPathComponent("alpha").path),
            "清單那一列來自 alpha，刪的就要是 alpha")
    #expect(FileManager.default.fileExists(atPath: packs.appendingPathComponent("bar").path),
            "使用者沒看到的那個不該被刪")
}

/// **沒有與 id 同名的目錄時，那一列也要拿得掉。** 拿 id 組路徑會刪一個不存在的
/// 東西而回「刪不掉」，於是它從 GUI 與 CLI 都永遠拿不掉。
@Test func removeWorksWhenNoDirectoryIsNamedAfterTheID() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    try makePackDirectory(named: "alpha", declaring: "bar", in: packs)

    let library = libraryOverRealScan(packs)
    #expect(library.remove(id: "bar", currentPackID: { "mycat" }, swapTarget: { nil })
            == .removed(id: "bar"))
    #expect(!FileManager.default.fileExists(atPath: packs.appendingPathComponent("alpha").path))
}

/// **半途失敗留下的 `<id>.incoming` 拿得掉。** 它的目錄名不是合法 id，所以這條
/// 同時釘住 `PackInstaller.remove` 驗的是路徑組件而不是 `isValidID`。
@Test func removeCanCleanUpAnIncomingLeftover() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    try makePackDirectory(named: "bar.incoming", declaring: "bar", in: packs)

    let library = libraryOverRealScan(packs)
    #expect(library.remove(id: "bar", currentPackID: { "mycat" }, swapTarget: { nil })
            == .removed(id: "bar"))
    #expect(!FileManager.default.fileExists(
        atPath: packs.appendingPathComponent("bar.incoming").path))
}

/// **遮蔽內建的那種，目錄名不符時也要拿得掉。** 遮蔽判定原本只看 `Packs/<id>`
/// 存不存在，名稱不符時它不存在，於是落進「是內建圖組，拿不掉」——而使用者
/// 目錄底下確實有一個他清得掉的東西。
@Test func removeCanCleanUpAMismatchedDirectoryThatShadowsABuiltIn() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    try makePackDirectory(named: "alpha", declaring: "mycat", in: packs)

    // 清單那一列是內建的（真實環境裡內建排前面而贏得去重）
    let library = PackLibraryUseCase(packsDirectory: { packs },
                                     installedPacks: { [summary("mycat", builtIn: true)] })
    #expect(library.remove(id: "mycat", currentPackID: { "other" }, swapTarget: { nil })
            == .removed(id: "mycat"))
    #expect(!FileManager.default.fileExists(atPath: packs.appendingPathComponent("alpha").path))
}

/// 對照組：目錄名與 id 一致時，行為與修改前完全一樣。少了它，上面那三條
///（`removeWorksWhenNoDirectoryIsNamedAfterTheID` 起）在「remove 永遠刪掉整個
/// Packs」這種突變下也會通過——第一條不受影響，因為它自己就斷言 `bar` 要留著。
///
/// **刪的是 `keep` 而不是 `bar`，那是刻意的。** `sourceDirectoryName` 依名稱字典序
/// 走訪，所以要移除的 id 若總是對應排最前面的目錄，「比對 manifest id」那一段
/// 拿掉也會全綠（實測過：把 `== id` 改成恆真，183 條全數通過）。這裡讓答案落在
/// 第二個目錄，那一段才真的被驗到。
@Test func removeStillDeletesTheMatchingDirectoryInTheOrdinaryCase() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    try makePackDirectory(named: "bar", declaring: "bar", in: packs)
    try makePackDirectory(named: "keep", declaring: "keep", in: packs)

    let library = libraryOverRealScan(packs)
    #expect(library.remove(id: "keep", currentPackID: { "mycat" }, swapTarget: { nil })
            == .removed(id: "keep"))
    #expect(!FileManager.default.fileExists(atPath: packs.appendingPathComponent("keep").path))
    #expect(FileManager.default.fileExists(atPath: packs.appendingPathComponent("bar").path),
            "排在前面的那個不該被牽連")
}

/// 讀不到的來源要說「讀不到」，不能說「這裡面沒有 pack.json」。
///
/// **後者是與真相相反的一句話**：它宣稱來源的內容不對，而實際上我們根本沒看到
/// 內容。沙盒下容器外的路徑正是這個形狀——`fileExists` 過、`opendir` 回 EPERM
/// （2026-08-17 實測），於是後面每一步都看到一個空目錄。分不開的話，使用者會
/// 去改一個沒有問題的 pack。
///
/// 用 `chmod 000` 構造：實測對**擁有者自己**也回 `access(R_OK) == false`。
/// defer 要先 chmod 回去再刪，否則刪不掉。
@Test func anUnreadableSourceSaysSoInsteadOfBlamingTheManifest() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    let source = root.appendingPathComponent("blocked")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: source.path) }

    let library = PackLibraryUseCase(packsDirectory: { packs }, installedPacks: { [] })
    guard case let .failed(code, message) = library.install(source: source, force: false) else {
        Issue.record("預期 failed"); return
    }
    #expect(code == .packSourceInvalid)
    #expect(message.contains("讀不到"), "訊息是「\(message)」")
    #expect(!message.contains("沒有 pack.json"),
            "這正是要避免的那句話：它把權限問題說成內容問題")
}

// MARK: - 從沙盒之前的位置搬移

/// 搬移把舊目錄底下的**每一套**都裝進去，並且不會被雜物絆倒。
///
/// 雜物是刻意放的：舊家底下一定有 `.DS_Store`，而使用者常常還留著當初的 zip。
/// 沒有那道「只看目錄」的過濾時，它們各自換來一句「這個來源裡沒有 pack.json」，
/// 而那三句會把真正搬不成的那一套淹掉。
@Test func migratingALegacyFolderInstallsEveryPackInside() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("legacy")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    _ = try makeSource(id: "alpha", in: legacy)
    _ = try makeSource(id: "beta", in: legacy)
    FileManager.default.createFile(atPath: legacy.appendingPathComponent(".DS_Store").path,
                                   contents: Data("垃圾".utf8))
    FileManager.default.createFile(atPath: legacy.appendingPathComponent("old.zip").path,
                                   contents: Data("不是 pack".utf8))

    let packs = root.appendingPathComponent("Packs")
    let library = PackLibraryUseCase(packsDirectory: { packs }, installedPacks: { [] })
    let report = library.migrate(from: legacy, legacyDirectory: legacy)

    #expect(report.installed == ["alpha", "beta"])
    #expect(report.skipped.isEmpty, "檔案不該變成搬不成的一筆：\(report.skipped)")
    for id in ["alpha", "beta"] {
        #expect(FileManager.default.fileExists(
            atPath: packs.appendingPathComponent("\(id)/pack.json").path))
    }
}

/// 新家已經有同 id 時**不覆蓋**，而且要說得出是哪一套。
///
/// 斷言目的地的內容原封不動，理由與 `aCollidingIDAsksBeforeTouchingAnything`
/// 同一條：只看回傳值的話，「先覆蓋再回報跳過」照樣會通過。
@Test func migrationNeverOverwritesWhatIsAlreadyInTheNewHome() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("legacy")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    _ = try makeSource(id: "cat", version: "1.0", in: legacy)

    let packs = root.appendingPathComponent("Packs")
    let installed = packs.appendingPathComponent("cat")
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    try Data("新家原本的".utf8).write(to: installed.appendingPathComponent("pack.json"))

    let library = PackLibraryUseCase(packsDirectory: { packs },
                                     installedPacks: { [summary("cat", builtIn: false)] })
    let report = library.migrate(from: legacy, legacyDirectory: legacy)

    #expect(report.installed.isEmpty)
    #expect(report.skipped.count == 1)
    #expect(report.skipped.first?.name == "cat")
    #expect(report.skipped.first?.reason.contains("cat") == true,
            "訊息要指名是哪一套：\(report.skipped)")
    let survived = try String(contentsOf: installed.appendingPathComponent("pack.json"),
                              encoding: .utf8)
    #expect(survived == "新家原本的", "新家那一份被覆蓋了")
}

/// 「已經搬過」的記號**只在使用者真的選了舊資料夾時**才落下。
///
/// 兩個方向都要釘。少了「選別的地方就不落記號」那一邊，使用者在面板裡逛去
/// 錯的資料夾按下選取之後，那一列提示會永遠消失——而他一套都還沒搬到。
@Test func theDoneMarkerFollowsWhichFolderTheUserPicked() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("legacy")
    let elsewhere = root.appendingPathComponent("somewhere-else")
    for dir in [legacy, elsewhere] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let packs = root.appendingPathComponent("Packs")
    let marker = PackCatalogRepository.migrationMarker(in: packs)
    let library = PackLibraryUseCase(packsDirectory: { packs }, installedPacks: { [] })

    _ = library.migrate(from: elsewhere, legacyDirectory: legacy)
    #expect(FileManager.default.fileExists(atPath: marker.path) == false,
            "選的不是舊資料夾，不該記成已經搬過")

    _ = library.migrate(from: legacy, legacyDirectory: legacy)
    #expect(FileManager.default.fileExists(atPath: marker.path),
            "選了舊資料夾就要記下來，否則那一列提示每次啟動都回來")
}

/// **列不出來的資料夾不能當成空的。**
///
/// 這是這條路上最難救的失敗：記號一旦落下，`legacyPacksNeedMigration()` 從此永遠
/// 回 false，那一列提示再也不出現、一套都沒搬，而使用者收到的訊息是「這個資料夾裡
/// 沒有圖組」——他不會知道要去刪一個他不知道存在的記號。
@Test func anUnreadableLegacyFolderIsReportedInsteadOfMarkedDone() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("legacy")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    // 還原權限要排在刪除之前才刪得掉（defer 是 LIFO，所以寫在後面）。
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: legacy.path)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0],
                                          ofItemAtPath: legacy.path)

    let packs = root.appendingPathComponent("Packs")
    let library = PackLibraryUseCase(packsDirectory: { packs }, installedPacks: { [] })

    let result = library.migrate(from: legacy, legacyDirectory: legacy)

    #expect(result.installed.isEmpty)
    #expect(result.skipped.count == 1, "讀不到要說出來，不能靜靜當成空的")
    #expect(FileManager.default.fileExists(
        atPath: PackCatalogRepository.migrationMarker(in: packs).path) == false,
        "一套都沒搬卻落下記號，等於把那一列提示永久關掉")
}
