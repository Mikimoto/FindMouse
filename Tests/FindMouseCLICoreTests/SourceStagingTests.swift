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
