import Foundation
import Testing
@testable import FindMouseCLICore
import FindMouseWire

private func encode<T: Codable & Sendable>(_ response: WireResponse<T>) -> Data {
    (try? JSONEncoder().encode(response)) ?? Data()
}

private func errorLine(_ code: WireErrorCode, _ message: String = "…") -> Data {
    encode(WireResponse<AckPayload>(error: WireError(code: code, message: message)))
}

private let statusPayload = StatusPayload(
    appVersion: "1.2.3", visible: true, phase: "resting", phaseElapsed: 3.42,
    teaser: .init(enabled: false, available: true),
    cat: .init(position: .init(x: 1284, y: 663.5), facing: "left",
               action: "sitIdle", frame: 3, frameCount: 6),
    cursor: .init(x: 1310, y: 640), distance: 34.2,
    spotlight: .init(active: false, radius: 0, opacity: 0),
    timers: .init(rest: 3.42, sleep: 0),
    pack: .init(id: "fluffy-orange", logicalHeight: 96),
    display: .init(screenIndex: 0, scale: 2))

// MARK: - exit code

/// spec 第 8.5 節的四個 exit code。腳本靠 3 與 1 的差別決定「要不要先啟動 App」。
@Test func exitCodesFollowTheSpecTable() {
    func code(_ line: Data, _ command: String = "status") -> Int32 {
        Output.render(line, for: WireRequest(command: command)).exitCode
    }
    #expect(code(encode(WireResponse(data: statusPayload))) == 0)
    #expect(code(errorLine(.appNotRunning)) == 3)
    #expect(code(errorLine(.unknownCommand)) == 2)
    #expect(code(errorLine(.invalidArgument)) == 2)
    #expect(code(errorLine(.teaserUnavailable)) == 1)
    #expect(code(errorLine(.configValueOutOfRange)) == 1)
    #expect(code(errorLine(.configKeyUnknown)) == 1)
}

/// `pack validate` 的 exit code **單獨定義**（spec 第 8.5 節）。
///
/// 三個結果要落在三個不同的 code，因為要修的東西完全不同：
/// pack 合格 0、pack 不合格 1（改 pack）、路徑讀不到 2（改你打的路徑）。
/// 少了這個特例，路徑打錯會回 1，跟「pack 真的壞了」分不開。
@Test func packValidateHasItsOwnExitCodeSemantics() {
    let validate = WireRequest(command: "pack.validate", args: ["path": "/tmp/p"])

    let good = encode(WireResponse(data: PackValidatePayload(
        id: "p", valid: true, errors: [], warnings: ["缺少逗貓棒動作"])))
    #expect(Output.render(good, for: validate).exitCode == 0)

    let bad = encode(WireResponse(data: PackValidatePayload(
        id: "p", valid: false, errors: ["run 宣告 8 格，實際 2 個檔案"], warnings: [])))
    #expect(Output.render(bad, for: validate).exitCode == 1,
            "ok 是 true，但 pack 不能用——對呼叫端而言這是失敗")

    #expect(Output.render(errorLine(.packNotFound), for: validate).exitCode == 2)
    // 同一個錯誤碼在別的命令上仍是 1：特例只針對 pack.validate
    #expect(Output.render(errorLine(.packNotFound),
                          for: WireRequest(command: "status")).exitCode == 1)
}

/// App 回了解不開的東西時要有 exit code，不能當成成功。
@Test func unparseableResponsesFailRatherThanPassSilently() {
    let junk = Data("{ 不是 JSON".utf8)
    let rendered = Output.render(junk, for: WireRequest(command: "status"))
    #expect(rendered.exitCode == 1)
    #expect(rendered.text.isEmpty == false)

    // 信封解得開但 data 的形狀不對（App 端改了欄位而 CLI 沒跟上）
    let wrongShape = encode(WireResponse(data: AckPayload(queued: "summon")))
    #expect(Output.render(wrongShape, for: WireRequest(command: "status")).exitCode == 1)
}

// MARK: - 文字

/// 錯誤訊息要帶錯誤碼字面，那是使用者唯一能拿去查的東西。
@Test func errorTextCarriesTheCode() {
    let rendered = Output.render(errorLine(.teaserUnavailable, "當前 pack 缺 teaser 動作"),
                                 for: WireRequest(command: "teaser.on"))
    #expect(rendered.text.contains("TEASER_UNAVAILABLE"))
    #expect(rendered.text.contains("當前 pack 缺 teaser 動作"))
}

/// status 的每個欄位都要出現在人類可讀的輸出裡。
///
/// 少印一個欄位不會有任何訊號——輸出仍然「看起來很正常」。
@Test func statusTextShowsEveryField() {
    let text = Output.render(encode(WireResponse(data: statusPayload)),
                             for: WireRequest(command: "status")).text
    for expected in ["resting", "3.4", "1284", "663.5", "sitIdle",
                     "1310", "640", "34.2", "fluffy-orange", "1.2.3"] {
        #expect(text.contains(expected), "少了 \(expected)：\n\(text)")
    }
    // frame 對人類是 1-based（第 4/6 格），對 wire 是 0-based
    #expect(text.contains("4/6"))
}

/// 座標不能印成 `663.5000000000001`。
@Test func numbersArePrintedTidily() {
    let text = Output.render(encode(WireResponse(data: statusPayload)),
                             for: WireRequest(command: "status")).text
    #expect(text.contains("1284"))
    #expect(text.contains("1284.0") == false)
    #expect(text.contains("0000000") == false)
}

/// 極端數值不可以讓 CLI 崩掉。
///
/// `String(Int(value))` 對 1e300 是 **trap**（"Double value cannot be converted
/// to Int"），不是印出奇怪的字——CLI 會整個崩，而使用者只看到沒有輸出。
/// distance 與 phaseElapsed 都是從 App 來的 Double，CLI 不該假設它們有界。
@Test func absurdNumbersPrintInsteadOfTrapping() {
    // 只列**有限**的極端值：inf 與 NaN 根本過不了 wire（見下一條測試），
    // 把它們放進來測的是 JSONEncoder 而不是 Output。
    for value in [1e300, -1e300, 9e15, 1e15, -1e15] {
        let payload = StatusPayload(
            appVersion: "1", visible: true, phase: "resting", phaseElapsed: value,
            teaser: .init(enabled: false, available: true),
            cat: .init(position: .init(x: value, y: 0), facing: "left",
                       action: "sitIdle", frame: 0, frameCount: 1),
            cursor: .init(x: 0, y: 0), distance: value,
            spotlight: .init(active: false, radius: 0, opacity: 0),
            timers: .init(rest: 0, sleep: 0),
            pack: .init(id: "p", logicalHeight: 96),
            display: .init(screenIndex: 0, scale: 1))
        let rendered = Output.render(encode(WireResponse(data: payload)),
                                     for: WireRequest(command: "status"))
        #expect(rendered.exitCode == 0)
        #expect(rendered.text.isEmpty == false)
    }
}

/// inf 與 NaN 過不了 wire——所以 CLI 那一側不必為它們寫退路。
///
/// 寫下來是因為上一條測試原本把它們列進去，然後失敗了：`JSONEncoder` 對
/// 非有限的 Double 直接丟錯，編不出東西。也就是說 App 那端若真的算出 inf，
/// 症狀會是「回應編碼失敗」而不是「CLI 印出 inf」——要修的地方在 App 不在這裡。
@Test func nonFiniteNumbersCannotCrossTheWireAtAll() {
    let payload = StatusPayload(
        appVersion: "1", visible: true, phase: "resting", phaseElapsed: .infinity,
        teaser: .init(enabled: false, available: true),
        cat: .init(position: .init(x: 0, y: 0), facing: "left",
                   action: "sitIdle", frame: 0, frameCount: 1),
        cursor: .init(x: 0, y: 0), distance: .nan,
        spotlight: .init(active: false, radius: 0, opacity: 0),
        timers: .init(rest: 0, sleep: 0),
        pack: .init(id: "p", logicalHeight: 96),
        display: .init(screenIndex: 0, scale: 1))
    #expect(throws: (any Error).self) {
        try JSONEncoder().encode(WireResponse(data: payload))
    }
}

/// config 的輸出是 `key = value`，每行一項。
@Test func configTextIsOneKeyPerLine() {
    let payload = ConfigPayload(entries: [.init(key: "cat.speed", value: "900"),
                                          .init(key: "rest.duration", value: "10")])
    let rendered = Output.render(encode(WireResponse(data: payload)),
                                 for: WireRequest(command: "config.get"))
    let lines = rendered.text.split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[0].contains("cat.speed") && lines[0].contains("900"))
    #expect(lines[1].contains("rest.duration") && lines[1].contains("10"))
    #expect(rendered.exitCode == 0)
}

/// pack validate 的錯誤與警告都要印出來，而且分得出哪個是哪個。
@Test func packValidateTextSeparatesErrorsFromWarnings() {
    let payload = PackValidatePayload(id: "p", valid: false,
                                      errors: ["某個錯誤"], warnings: ["某個警告"])
    let text = Output.render(encode(WireResponse(data: payload)),
                             for: WireRequest(command: "pack.validate")).text
    #expect(text.contains("不合格"))
    #expect(text.contains("錯誤：某個錯誤"))
    #expect(text.contains("警告：某個警告"))
}

/// 動作命令的回應簡短但要說出排進去的是什麼。
@Test func ackTextNamesTheQueuedCommand() {
    let rendered = Output.render(encode(WireResponse(data: AckPayload(queued: "summon"))),
                                 for: WireRequest(command: "summon"))
    #expect(rendered.text.contains("summon"))
    #expect(rendered.exitCode == 0)
}
