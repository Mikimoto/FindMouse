// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FindMouseAdapters
@testable import FindMouseDomain

private func tempDir() throws -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("packinstaller-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// 用 python 造 zip：`zip(1)` 會拒絕存 `../` 這種 entry name，而那正是要測的輸入。
private func makeZip(at url: URL, entries: [(String, String)]) throws {
    let script = """
    import sys, zipfile
    out = sys.argv[1]
    with zipfile.ZipFile(out, "w") as z:
        for i in range(2, len(sys.argv), 2):
            z.writestr(sys.argv[i], sys.argv[i + 1])
    """
    var args = [url.path]
    for (name, body) in entries { args += [name, body] }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = ["-c", script] + args
    try p.run(); p.waitUntilExit()
    #expect(p.terminationStatus == 0)
}

private let minimalManifest = """
{"schemaVersion":1,"id":"cat","name":"貓","logicalHeight":96,
 "anchor":{"x":0.5,"y":0.94},"facing":"right","mirrorForOpposite":true,
 "actions":{"run":{"frames":1,"fps":14,"loop":true}}}
"""

@Test func aDirectorySourceIsWalkedWithoutExtracting() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let pack = root.appendingPathComponent("orange-cat")
    try FileManager.default.createDirectory(
        at: pack.appendingPathComponent("run"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: pack.appendingPathComponent("pack.json"))
    try Data(repeating: 0, count: 300)
        .write(to: pack.appendingPathComponent("run/000.png"))

    let tree = try PackInstaller.tree(of: pack)
    #expect(try tree.packRoot() == "")
    #expect(tree.totalBytes == 302)
}

/// 2026-08-12 實測：`ditto -x -k` 把 `../escaped.txt` **攤平到解壓根**
/// （沒有逃出去，但也沒有被拒絕）。這條是那個行為的回歸測試——它是外部工具的
/// 行為，會隨系統更新變。
@Test func dittoFlattensParentTraversalInsteadOfEscaping() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let zip = root.appendingPathComponent("evil.zip")
    try makeZip(at: zip, entries: [("../escaped.txt", "pwned"),
                                   ("cat/pack.json", "{}")])

    let dest = root.appendingPathComponent("dest")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    try PackInstaller.extract(zip, into: dest)

    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("escaped.txt").path),
        "沒有逃到 dest 之外")
    #expect(FileManager.default.fileExists(
        atPath: dest.appendingPathComponent("escaped.txt").path),
        "而是被攤平到 dest 裡")
}

/// **這條才是「只挑我要的」那個守衛的測試。** 上一條在「整個暫存目錄搬過去」
/// 這個突變下仍然通過（那些檔案確實沒逃出暫存目錄）。
@Test func onlyThePackRootIsInstalledNotTheStrayFiles() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let zip = root.appendingPathComponent("s.zip")
    try makeZip(at: zip, entries: [("stray.txt", "x"),
                                   ("cat/pack.json", minimalManifest),
                                   ("cat/run/000.png", "y")])
    let packs = root.appendingPathComponent("Packs")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)

    try PackInstaller.install(source: zip, id: "cat", into: packs)

    let installed = packs.appendingPathComponent("cat")
    let names = try FileManager.default
        .contentsOfDirectory(atPath: installed.path).sorted()
    #expect(names == ["pack.json", "run"], "夾帶的 stray.txt 不該被裝進去")
    #expect(!FileManager.default.fileExists(
        atPath: packs.appendingPathComponent("stray.txt").path))
}

/// Finder 的「壓縮所選項目的內容」會把 `pack.json` 放在 zip 根，於是 pack 根是
/// 空字串、「只搬根底下」等於搬全部——cruft 會跟著進去，而 `__MACOSX/` 會讓
/// `PackValidator` 報一筆 undeclaredDirectory。這條釘住逐筆複製有把它們濾掉。
@Test func macOSCruftIsNotInstalledWhenTheManifestSitsAtTheZipRoot() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let zip = root.appendingPathComponent("finder.zip")
    try makeZip(at: zip, entries: [("pack.json", minimalManifest),
                                   (".DS_Store", "x"),
                                   ("__MACOSX/junk.txt", "y"),
                                   ("run/000.png", "z")])
    let packs = root.appendingPathComponent("Packs")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)

    try PackInstaller.install(source: zip, id: "cat", into: packs)

    let installed = packs.appendingPathComponent("cat")
    let names = try FileManager.default
        .contentsOfDirectory(atPath: installed.path).sorted()
    #expect(names == ["pack.json", "run"], "cruft 不該被裝進去：\(names)")

    // 那個 cruft 目錄**實際的後果**，不是只斷言檔名：`SpritePackRepository.listing`
    // 收的是 pack 底下的每一個子目錄，而 `PackValidator` 對沒宣告的每一個報一筆
    // undeclaredDirectory——所以留著 `__MACOSX/` 的話，使用者裝完會看到一行
    // 「目錄 __MACOSX 沒有在 pack.json 宣告」。
    let loaded = try #require(SpritePackRepository.load(at: installed))
    let report = PackValidator.validate(manifest: loaded.manifest,
                                        directoryName: loaded.directoryName,
                                        listing: loaded.listing)
    #expect(!report.warnings.contains {
        if case .undeclaredDirectory = $0 { return true } else { return false }
    }, "裝完不該帶著未宣告的目錄：\(report.warnings)")
}

/// **已知邊界，刻意釘住。** 同一個佈局下，被 ditto 攤平的 `../escaped.txt` 與
/// 作者真的放在 pack 根的檔案無法區分，所以它會被裝進 `Packs/<id>/`。
/// 守住的是「不會跑到 `Packs` 外面」——這條同時證明那件事仍然成立。
@Test func aFlattenedStrayLandsInsideThePackWhenTheManifestSitsAtTheZipRoot() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let zip = root.appendingPathComponent("evil.zip")
    try makeZip(at: zip, entries: [("../escaped.txt", "pwned"),
                                   ("pack.json", minimalManifest)])
    let packs = root.appendingPathComponent("Packs")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)

    try PackInstaller.install(source: zip, id: "cat", into: packs)

    #expect(FileManager.default.fileExists(
        atPath: packs.appendingPathComponent("cat/escaped.txt").path),
        "根是空字串時擋不掉——註解與 CLAUDE.md 都是這樣寫的")
    #expect(!FileManager.default.fileExists(
        atPath: packs.appendingPathComponent("escaped.txt").path),
        "但它不該落在 Packs 底下、pack 目錄之外")
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("escaped.txt").path),
        "更不該逃到 Packs 之外")
}

// MARK: - 大小上限

/// 超過上限就拒絕，而且**什麼都不留**——半套 pack 比裝不起來更難查。
@Test func aSourceOverTheLimitIsRejectedAndLeavesNothing() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let pack = root.appendingPathComponent("cat")
    try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
    try Data(minimalManifest.utf8).write(to: pack.appendingPathComponent("pack.json"))
    try Data(repeating: 0, count: 300).write(to: pack.appendingPathComponent("big.png"))
    let packs = root.appendingPathComponent("Packs")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)

    // 斷言的是**確切的 bytes** 不只是「有丟例外」：量錯範圍時例外照丟，
    // 而使用者看到的那個數字會是錯的。
    #expect(throws: PackInstaller.Failure.tooLarge(
        bytes: 300 + minimalManifest.utf8.count, limit: 100)) {
        try PackInstaller.install(source: pack, id: "cat", into: packs, byteLimit: 100)
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: packs.path)
    #expect(leftovers.isEmpty, "被拒絕就不該留下任何東西：\(leftovers)")
}

/// **夾帶的大檔案不計入。** 它不會被裝進去，拿它的大小去擋一次合法的安裝
/// 就是錯的理由。這條在「量整個解壓結果」這個突變下會紅。
@Test func aStrayOutsideThePackRootDoesNotCountTowardTheLimit() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let zip = root.appendingPathComponent("s.zip")
    try makeZip(at: zip, entries: [("huge.bin", String(repeating: "x", count: 5_000)),
                                   ("cat/pack.json", minimalManifest)])
    let packs = root.appendingPathComponent("Packs")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)

    // 上限只容得下 manifest，容不下那個 5000 bytes 的夾帶檔。
    try PackInstaller.install(source: zip, id: "cat", into: packs, byteLimit: 1_000)
    #expect(FileManager.default.fileExists(
        atPath: packs.appendingPathComponent("cat/pack.json").path))
}

@Test func aSymlinkInTheSourceIsRejected() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let pack = root.appendingPathComponent("cat")
    try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: pack.appendingPathComponent("pack.json"))
    // 字串版：URL 版的第二個參數是 `withDestinationURL:`，混用會編不過。
    try FileManager.default.createSymbolicLink(
        atPath: pack.appendingPathComponent("evil").path,
        withDestinationPath: "/etc/passwd")

    let tree = try PackInstaller.tree(of: pack)
    #expect(throws: ExtractedTree.Failure.notARegularFile("evil")) {
        try tree.rejectIrregularEntries()
    }
}

/// 指向**目錄**的 symlink 也要被拒絕，而且走訪不能跟著進去。
///
/// 兩件事分開講：走訪不跟隨是 `enumerator` 自己的行為（2026-08-13 實測），
/// 分類成 `.other` 則是 `tree(of:)` 的三元。**這條在「拿掉那個 isSymbolicLink
/// 判斷」的突變下仍然綠**（`isDirectoryKey` 對 symlink 同樣回 false），所以它
/// 釘的是 `rejectIrregularEntries` 這條規則本身，不是那一段三元。
@Test func aSymlinkPointingAtADirectoryIsRejectedAndNotDescendedInto() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("機密".utf8).write(to: outside.appendingPathComponent("secret.txt"))

    let pack = root.appendingPathComponent("cat")
    try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: pack.appendingPathComponent("pack.json"))
    try FileManager.default.createSymbolicLink(
        atPath: pack.appendingPathComponent("dirlink").path,
        withDestinationPath: outside.path)

    let tree = try PackInstaller.tree(of: pack)
    #expect(!tree.entries.contains { $0.relativePath.hasSuffix("secret.txt") },
            "走訪不該跟著連結進去：\(tree.entries.map(\.relativePath))")
    #expect(throws: ExtractedTree.Failure.notARegularFile("dirlink")) {
        try tree.rejectIrregularEntries()
    }
}

/// 安裝失敗不能留下 `.incoming` 殘骸——下一次安裝會撞到它。
///
/// 這條走的是**早期失敗**（沒有 pack.json，`.incoming` 還沒被建立）。
/// 「建了 `.incoming` 之後才失敗」那條路（`moveItem` 因權限或磁碟滿而失敗）
/// 沒有被涵蓋：構造它需要一個會讓 rename 失敗的目的地，而那比它守住的東西還脆弱。
/// 那個 catch 分支因此是**沒有測試的防禦**，理由寫在它自己的註解裡。
@Test func aFailedInstallLeavesNoIncomingDirectory() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let zip = root.appendingPathComponent("bad.zip")
    try makeZip(at: zip, entries: [("run/000.png", "x")])   // 沒有 pack.json
    let packs = root.appendingPathComponent("Packs")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)

    #expect(throws: ExtractedTree.Failure.noManifest) {
        try PackInstaller.install(source: zip, id: "cat", into: packs)
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: packs.path)
    #expect(leftovers.isEmpty, "留下的殘骸：\(leftovers)")
}

/// id 取自 manifest 而不是檔名：檔名可以是任何東西（下載時被瀏覽器改名是常態）。
@Test func theIDComesFromTheManifestNotTheFileName() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let pack = root.appendingPathComponent("whatever")
    try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
    try Data(minimalManifest.utf8).write(to: pack.appendingPathComponent("pack.json"))

    #expect(try PackInstaller.manifestID(of: pack) == "cat")
    #expect(try PackInstaller.manifestVersion(of: pack) == nil)
}

@Test func theVersionIsReadVerbatimFromTheManifest() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let pack = root.appendingPathComponent("cat")
    try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
    let withVersion = minimalManifest.replacingOccurrences(
        of: "\"id\":\"cat\"", with: "\"id\":\"cat\",\"version\":\"2026.08\"")
    try Data(withVersion.utf8).write(to: pack.appendingPathComponent("pack.json"))

    #expect(try PackInstaller.manifestVersion(atPackDirectory: pack) == "2026.08")
}

// MARK: - id 是路徑組件（review 抓到的 Critical）

/// **這是路徑注入的守衛。** id 完全來自不受信任的 `pack.json`，而它會被當成
/// 目的地的路徑組件：`appendingPathComponent("../victim")` 標準化後指到
/// `Packs` 外面，於是 `install` 的 `removeItem(at: final)` 會遞迴刪掉那個目錄。
///
/// 這條測試**必須斷言目標目錄還在**，不能只斷言 install 丟例外——守衛在錯的
/// 位置（例如放在 removeItem 之後）時，例外照丟而東西已經被刪了。
@Test func installRefusesAnIDThatWouldEscapeThePacksDirectory() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    let victim = root.appendingPathComponent("victim")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    try Data("重要".utf8).write(to: victim.appendingPathComponent("keep.txt"))

    let source = root.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data(minimalManifest.utf8).write(to: source.appendingPathComponent("pack.json"))

    #expect(throws: PackInstaller.Failure.invalidID("../victim")) {
        try PackInstaller.install(source: source, id: "../victim", into: packs)
    }
    #expect(FileManager.default.fileExists(
        atPath: victim.appendingPathComponent("keep.txt").path),
        "Packs 外面的目錄不該被碰到")
}

@Test func removeRefusesAnIDThatWouldEscapeThePacksDirectory() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    let victim = root.appendingPathComponent("victim")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)

    #expect(throws: PackInstaller.Failure.invalidID("../victim")) {
        try PackInstaller.remove(id: "../victim", from: packs)
    }
    #expect(FileManager.default.fileExists(atPath: victim.path), "目錄不該被刪")
}

/// 絕對路徑同樣是逃逸：`appendingPathComponent("/etc")` 會變成
/// `Packs/etc`（不是 `/etc`），但 id 規則本來就該擋掉斜線。
@Test func installRefusesOtherShapesOfBadID() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let packs = root.appendingPathComponent("Packs")
    try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data(minimalManifest.utf8).write(to: source.appendingPathComponent("pack.json"))

    for bad in ["/etc", "a/b", "..", ".", "Cat", "cat_1", "", "cat.json"] {
        #expect(throws: PackInstaller.Failure.invalidID(bad)) {
            try PackInstaller.install(source: source, id: bad, into: packs)
        }
    }
}

/// 錯誤訊息不能是英文樣板：`Failure` 實作 `LocalizedError`，否則
/// `localizedDescription` 會吐 "The operation couldn't be completed."
@Test func failuresCarryATraditionalChineseMessage() {
    #expect(PackInstaller.Failure.invalidID("../x").localizedDescription.contains("不合法"))
    #expect(PackInstaller.Failure.tooLarge(bytes: 300 * 1_048_576, limit: 200 * 1_048_576)
        .localizedDescription.contains("300 MB"))
    #expect(PackInstaller.Failure.extractionFailed("ditto: 不是 zip\n")
        .localizedDescription.contains("ditto: 不是 zip"), "ditto 的 stderr 不能遺失")
}
