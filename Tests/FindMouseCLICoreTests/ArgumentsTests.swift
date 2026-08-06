import Foundation
import Testing
@testable import FindMouseCLICore
import FindMouseWire

private func parse(_ line: String) throws -> Arguments.Parsed {
    try Arguments.parse(line.split(separator: " ").map(String.init))
}

private func request(_ line: String) throws -> WireRequest {
    try parse(line).request
}

/// spec 第 8.3 節的每一個命令都要對到一個 wire 命令名。
///
/// 逐條列出而不是從表格推導：這張對照就是 CLI 與 App 之間的契約，
/// 兩邊各自從同一份資料算出來的話，改壞了也不會有訊號。
@Test func everyDocumentedCommandMapsToItsWireName() throws {
    #expect(try request("summon") == WireRequest(command: "summon"))
    #expect(try request("dismiss") == WireRequest(command: "dismiss"))
    #expect(try request("toggle") == WireRequest(command: "toggle"))
    #expect(try request("teaser on") == WireRequest(command: "teaser.on"))
    #expect(try request("teaser off") == WireRequest(command: "teaser.off"))
    #expect(try request("teaser toggle") == WireRequest(command: "teaser.toggle"))
    #expect(try request("status") == WireRequest(command: "status"))
    #expect(try request("config get") == WireRequest(command: "config.get"))
    #expect(try request("config get cat.speed")
            == WireRequest(command: "config.get", args: ["key": "cat.speed"]))
    #expect(try request("config set cat.speed 900")
            == WireRequest(command: "config.set", args: ["key": "cat.speed", "value": "900"]))
    #expect(try request("config reset cat.speed")
            == WireRequest(command: "config.reset", args: ["key": "cat.speed"]))
    #expect(try request("config reset --all")
            == WireRequest(command: "config.reset", args: ["all": "true"]))
    #expect(try request("pack validate /tmp/p")
            == WireRequest(command: "pack.validate", args: ["path": "/tmp/p"]))
}

/// `--json` 是全域旗標：位置不影響解析結果。
///
/// 「只認最後一個位置」的實作在 `findmouse status --json` 上完全正確，
/// 所以夾具要把它放在前面與中間。
@Test func jsonFlagIsPositionIndependent() throws {
    #expect(try parse("status --json").json)
    #expect(try parse("--json status").json)
    #expect(try parse("config set cat.speed --json 900").json)
    #expect(try parse("status").json == false)

    // 抽掉旗標之後剩下的形狀要與沒有旗標時完全相同
    #expect(try request("config set cat.speed --json 900")
            == WireRequest(command: "config.set", args: ["key": "cat.speed", "value": "900"]))
}

/// 每一種用法錯誤都要是 `usage`，不能靜默送出一個半殘的請求。
///
/// 這條防的是最糟的形狀：`config set cat.speed`（漏了值）若送出去，
/// App 端會收到一個沒有 value 的請求，錯誤訊息就從「你少打一個參數」
/// 變成 App 回的 INVALID_ARGUMENT——一樣的碼，但要查的地方差很遠。
@Test func malformedUsageIsRejectedLocally() {
    for line in ["nonsense", "summon extra", "teaser", "teaser maybe",
                 "teaser on off", "status now",
                 "config", "config frobnicate", "config get a b",
                 "config set cat.speed", "config set", "config reset",
                 "config reset --everything", "pack", "pack validate",
                 "pack validate a b"] {
        #expect(throws: (any Error).self, "「\(line)」應該被擋下來") { try parse(line) }
    }
}

/// M4 的命令要明講「還沒實作」，不能回「未知命令」。
///
/// 後者會讓人以為自己打錯字，然後去查拼寫。
@Test func notYetImplementedPackCommandsSayS() {
    for sub in ["list", "use"] {
        var message = ""
        #expect(throws: (any Error).self) {
            do { _ = try parse("pack \(sub)") }
            catch let Arguments.ParseError.usage(text) { message = text; throw Arguments.ParseError.usage(text) }
        }
        #expect(message.contains("M4"), "實際訊息：\(message)")
    }
}

/// 沒有參數、或明確要說明時走 help，而不是「未知命令」。
@Test func helpIsItsOwnOutcome() {
    for line in [[], ["--help"], ["-h"], ["help"]] {
        #expect(throws: Arguments.ParseError.help) { try Arguments.parse(line) }
    }
}

/// 使用說明必須寫明 toggle 不是幂等的（spec 第 8.3 節明文要求）。
///
/// 這是 CLI 唯一會提醒自動化使用者的地方，而 `RobustnessTests` 的
/// `summonIsIdempotentWhileToggleIsNot` 是這句話的依據。
@Test func usageWarnsThatToggleIsNotIdempotent() {
    #expect(Arguments.usageText.contains("toggle 不是幂等"))
    #expect(Arguments.usageText.contains("summon"))
    // 四種 exit code 都要列出來，腳本才知道 3 與 1 的差別
    for code in ["0", "1", "2", "3"] {
        #expect(Arguments.usageText.contains(code))
    }
}

/// 值裡面有等號、負號、空字串都不能被當成旗標或分隔符。
///
/// `hotkey.summon` 這種設定的值長得就像旗標。
@Test func awkwardValuesSurviveParsing() throws {
    let parsed = try Arguments.parse(["config", "set", "hotkey.summon", "--opt-cmd-f"])
    #expect(parsed.request.args["value"] == "--opt-cmd-f")

    let empty = try Arguments.parse(["config", "set", "pack.id", ""])
    #expect(empty.request.args["value"] == "")
}
