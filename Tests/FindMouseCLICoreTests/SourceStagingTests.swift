// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FindMouseCLICore
import FindMouseWire

/// 只有「App 會拿去開檔案」的那些命令要搬。
///
/// 兩個方向都要釘：漏掉一個要搬的 → 那條命令在沙盒下靜默失敗；多搬一個不該搬的
/// → CLI 會去複製一個根本不是路徑的字串（`pack use <id>` 的 id、
/// `config set` 的值都長得可以像路徑）。
@Test func onlyThePathCarryingCommandsAreStaged() {
    #expect(SourceStaging.sourcePath(
        of: WireRequest(command: "pack.install", args: ["path": "/tmp/a"])) == "/tmp/a")
    #expect(SourceStaging.sourcePath(
        of: WireRequest(command: "pack.validate", args: ["path": "/tmp/b"])) == "/tmp/b")

    #expect(SourceStaging.sourcePath(
        of: WireRequest(command: "pack.use", args: ["id": "/tmp/looks-like-a-path"])) == nil)
    #expect(SourceStaging.sourcePath(
        of: WireRequest(command: "config.set",
                        args: ["key": "pack.id", "value": "/tmp/nope"])) == nil)
    #expect(SourceStaging.sourcePath(of: WireRequest(command: "status")) == nil)
}

/// 換路徑不能弄丟其他參數。`--force` 就住在 args 裡，掉了的話「覆蓋同 id」
/// 會變成「已經裝過了」——而使用者明明加了旗標。
@Test func rewritingKeepsEveryOtherArgument() {
    let original = WireRequest(command: "pack.install",
                               args: ["path": "/outside/cat", "force": "true"])
    let moved = SourceStaging.rewritten(original, sourcePath: "/inside/cat")

    #expect(moved.args["path"] == "/inside/cat")
    #expect(moved.args["force"] == "true")
    #expect(moved.command == original.command)
    #expect(moved.protocolVersion == original.protocolVersion)
}

/// staging 目錄帶自己的 pid：同時跑兩個 CLI 不該互相刪。
@Test func stagingDirectoriesAreNamedByPID() {
    let a = SourceStaging.stagingDirectory(container: "/c", pid: 111)
    let b = SourceStaging.stagingDirectory(container: "/c", pid: 222)
    #expect(a != b)
    #expect(a.hasPrefix("/c/tmp/"))
}

/// 掃除要認得出「這是誰的」。認錯的兩個方向都會痛：把別人的 pid 解成 nil
/// 就永遠掃不掉，把不是我們的目錄解出一個 pid 就可能刪到別人的東西。
@Test func onlyOurOwnStagingDirectoriesAreRecognised() {
    #expect(SourceStaging.pid(ofStagingDirectoryNamed: "fm-cli-4242") == 4242)
    #expect(SourceStaging.pid(ofStagingDirectoryNamed: "fm-cli-") == nil)
    #expect(SourceStaging.pid(ofStagingDirectoryNamed: "fm-cli-abc") == nil)
    #expect(SourceStaging.pid(ofStagingDirectoryNamed: "TemporaryItems") == nil)
    #expect(SourceStaging.pid(ofStagingDirectoryNamed: "com.apple.something") == nil)
    // 前綴像但不是——`hasPrefix` 擋得住這個，但寫下來是因為它是最容易
    // 在「順手放寬成 contains」時破掉的一條。
    #expect(SourceStaging.pid(ofStagingDirectoryNamed: "not-fm-cli-1") == nil)
}

/// 目錄名解出來的 pid 要能餵回組出同一個名字——不然掃除與建立會對不上，
/// 而症狀是 staging 永遠累積（掃除認不得自己造的東西）。
@Test func theNameRoundTripsThroughThePID() {
    let dir = SourceStaging.stagingDirectory(container: "/c", pid: 987)
    let name = URL(fileURLWithPath: dir).lastPathComponent
    #expect(SourceStaging.pid(ofStagingDirectoryNamed: name) == 987)
}

/// `0` 與負數不是 pid，即使 `Int32(_:)` 解得出來。
///
/// 這條的後果不在解析而在**掃除**：`kill(0, 0)` 問的是呼叫端的整個 process group、
/// `kill(-1, 0)` 問的是所有送得到的 process，兩者都回 0（2026-08-19 實測），
/// 於是那種目錄永遠被判成「主人還活著」而掃不掉——正是掃除存在的理由要防的狀態。
@Test func zeroAndNegativeNumbersAreNotPIDs() {
    #expect(SourceStaging.pid(ofStagingDirectoryNamed: "fm-cli-0") == nil)
    #expect(SourceStaging.pid(ofStagingDirectoryNamed: "fm-cli--1") == nil)
    // `Int32("+5")` 是 5。我們自己永遠不會造出這個名字，所以它不是我們的。
    #expect(SourceStaging.pid(ofStagingDirectoryNamed: "fm-cli-+5") == nil)
    // 真的 pid 照樣要解得出來——不然掃除認不得自己造的東西，staging 永遠累積。
    #expect(SourceStaging.pid(ofStagingDirectoryNamed: "fm-cli-1") == 1)
}

/// 「存在但讀不到」的來源**不搬**——不是為了省事，是為了不改掉錯誤分類。
///
/// 搬的話 `copyItem` 會拋，CLI 回 `PACK_SOURCE_INVALID`（exit 1）；而
/// `pack validate` 對「讀不到」的答案是 `PACK_NOT_FOUND`（exit 2，spec 第 8.5 節，
/// `Output.exitCode(for:request:)` 也只對那一組給 2）。於是同一個來源會因為
/// 「有沒有被搬」而拿到兩種 exit code。不搬，讓 App 端那道守衛回答。
@Test func anUnreadableSourceIsNotStagedSoTheAppKeepsOwningTheDiagnosis() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fm-staging-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let container = root.appendingPathComponent("container")
    try fm.createDirectory(at: container, withIntermediateDirectories: true)

    let readable = root.appendingPathComponent("readable.fmpack")
    try Data("pack".utf8).write(to: readable)
    #expect(SourceStaging.shouldStage(source: readable.path, containerData: container.path))

    let unreadable = root.appendingPathComponent("unreadable.fmpack")
    try Data("pack".utf8).write(to: unreadable)
    try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
    // 存在**而且**讀不到——兩件事分開問才有這個分岔，這也正是沙盒下容器外
    // 路徑的形狀（stat 成功、內容 EPERM）。
    #expect(fm.fileExists(atPath: unreadable.path))
    #expect(SourceStaging.shouldStage(source: unreadable.path,
                                      containerData: container.path) == false)

    // 另外兩個條件：來源不存在、容器還沒建立。
    #expect(SourceStaging.shouldStage(source: root.appendingPathComponent("nope").path,
                                      containerData: container.path) == false)
    #expect(SourceStaging.shouldStage(
        source: readable.path,
        containerData: root.appendingPathComponent("no-container").path) == false)
}

/// 大得不可能是一套圖組的來源，在複製之前就停下。
///
/// App 的 `install` 先讀 `pack.json` 才動任何檔案，所以 `pack install ~/Movies`
/// 這種手滑在 App 那邊是即刻拒絕；staging 反過來（先複製再問），少了這一關同一個
/// 手滑會把整個資料夾遞迴複製進容器。
@Test func aSourceTooBigToBeAPackIsRejectedBeforeAnythingIsCopied() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fm-limit-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    // 目錄型來源：三個檔案共 300 bytes，還要分在兩層——走的是整棵樹，不是頂層。
    let dir = root.appendingPathComponent("bulky")
    let nested = dir.appendingPathComponent("deep/deeper")
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    for (i, place) in [dir, dir, nested].enumerated() {
        try Data(repeating: 0x41, count: 100)
            .write(to: place.appendingPathComponent("f\(i).bin"))
    }
    #expect(SourceStaging.exceedsByteLimit(dir.path, limit: 250))
    #expect(SourceStaging.exceedsByteLimit(dir.path, limit: 10_000) == false)

    // 單一檔案（zip／.fmpack）問一次 size 就夠。
    let file = root.appendingPathComponent("one.fmpack")
    try Data(repeating: 0x42, count: 500).write(to: file)
    #expect(SourceStaging.exceedsByteLimit(file.path, limit: 100))
    #expect(SourceStaging.exceedsByteLimit(file.path, limit: 10_000) == false)

    // 不存在的來源不是「太大」——那條由 `shouldStage` 回答，兩者不要重複發明答案。
    #expect(SourceStaging.exceedsByteLimit(
        root.appendingPathComponent("nope").path, limit: 1) == false)

    // 預設上限與 App 用的是同一個數字（`PackInstaller.byteLimit` 指向它）。
    #expect(PackLimits.byteLimit == 200 * 1024 * 1024)
}
