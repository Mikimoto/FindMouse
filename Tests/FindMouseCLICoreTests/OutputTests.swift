// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

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
    display: .init(screenIndex: 0, scale: 2),
    loginItem: .init(state: "notRegistered"))

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
            display: .init(screenIndex: 0, scale: 1),
            loginItem: .init(state: "notRegistered"))
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
        display: .init(screenIndex: 0, scale: 1),
        loginItem: .init(state: "notRegistered"))
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

// MARK: - pack list / pack use

private let packList = PackListPayload(packs: [
    .init(id: "test-blocks", builtIn: true, logicalHeight: 96, usable: true,
          current: true, teaserAvailable: true, errors: [], warnings: []),
    .init(id: "test-blocks-tall", builtIn: true, logicalHeight: 240, usable: true,
          current: false, teaserAvailable: false, errors: [],
          warnings: ["缺少逗貓棒動作"]),
    // 不可用的 pack 仍有體高：manifest 讀得出來才會被列進清單，
    // 它是**宣告值**（`PackCatalogRepository.scan` 直接抄 manifest），
    // 壞的是格數對不上這種事。
    .init(id: "my-broken-pack", builtIn: false, logicalHeight: 128, usable: false,
          current: false, teaserAvailable: false,
          errors: ["run 宣告 8 格，實際 2 個檔案"], warnings: []),
])

/// 清單裡的每一套都要印出來，包含**不能用的那些**。
///
/// 三種漏法各自沒有訊號，所以三個都要斷言：只印 usable 的（使用者會以為
/// 自己放進去的 pack 不見了）、丟掉 errors（只知道不能用、不知道缺什麼）、
/// 丟掉 current 標記（清單看起來完全正常，只是不知道現在用的是哪套）。
@Test func packListShowsEveryPackIncludingTheUnusableOnes() {
    let rendered = Output.render(encode(WireResponse(data: packList)),
                                 for: WireRequest(command: "pack.list"))
    #expect(rendered.exitCode == 0)
    let lines = rendered.text.split(separator: "\n", omittingEmptySubsequences: false)

    // 三套各一行 ＋ 一個錯誤 ＋ 一個警告；行數對不上就是有東西被吃掉了
    #expect(lines.count == 5, "實際輸出：\n\(rendered.text)")
    for id in ["test-blocks", "test-blocks-tall", "my-broken-pack"] {
        #expect(rendered.text.contains(id), "少了 \(id)：\n\(rendered.text)")
    }
    #expect(rendered.text.contains("run 宣告 8 格，實際 2 個檔案"))
    #expect(rendered.text.contains("缺少逗貓棒動作"))
    #expect(rendered.text.contains("不可用"))
    // 內建與使用者安裝要分得出來：後者才是使用者自己能修的
    #expect(rendered.text.contains("內建") && rendered.text.contains("使用者"))
    // 體高會決定貓有多大，是換之前唯一看得到的線索
    #expect(rendered.text.contains("96") && rendered.text.contains("240"))

    // 只有當前那一套帶標記。`test-blocks` 是 `test-blocks-tall` 的前綴，
    // 所以用「哪一行含這個 id」找會抓到兩行——要從行首的標記本身判斷。
    let marked = lines.filter { $0.hasPrefix(Output.currentPackMarker) }
    #expect(marked.count == 1)
    #expect(marked.first?.contains("test-blocks ") == true, "標記落在錯的一行：\(marked)")

    // 標記只在用法裡解釋一次；符號改了而用法沒改，CLI 就在說謊
    #expect(Arguments.usageText.contains(Output.currentPackMarker.trimmingCharacters(in: .whitespaces)))
}

/// id 是使用者取的目錄名，對齊不能把它切壞。
///
/// `padding(toLength:)` 數的是 UTF-16 單元而 `count` 數字元，兩者對 `a🐱`
/// 分別是 3 與 2——拿字元數去 `padding` 會從代理對中間切下去，印出 `a\u{FFFD}`
/// （實測過）。內建 pack 的 id 全是 ASCII，所以這條只有使用者自己放的 pack 會踩到。
@Test func packIDsSurviveColumnAlignmentIntact() {
    let payload = PackListPayload(packs: [
        .init(id: "a🐱", builtIn: false, logicalHeight: 96, usable: true,
              current: false, teaserAvailable: false, errors: [], warnings: []),
        .init(id: "ab", builtIn: true, logicalHeight: 96, usable: true,
              current: true, teaserAvailable: false, errors: [], warnings: []),
    ])
    let text = Output.render(encode(WireResponse(data: payload)),
                             for: WireRequest(command: "pack.list")).text
    #expect(text.contains("a🐱"), "id 被切壞了：\n\(text)")
    #expect(text.contains("\u{FFFD}") == false, "輸出裡有替代字元：\n\(text)")
}

/// 一套都沒有時要說出來，不能印一個空字串。
///
/// 空輸出與「命令壞掉了」在終端機上長得一模一樣。實務上內建 pack 隨 bundle
/// 出貨、掃不到才是真的有問題，所以更不能靜靜地印零行。
@Test func emptyPackListStillSaysSomething() {
    let rendered = Output.render(encode(WireResponse(data: PackListPayload(packs: []))),
                                 for: WireRequest(command: "pack.list"))
    #expect(rendered.exitCode == 0)
    #expect(rendered.text.isEmpty == false)
}

/// `pack use` 的 exit code 由錯誤碼決定，**沒有** `pack validate` 那個特例。
///
/// 兩個命令都是 `pack.*` 且都會回 PACK_NOT_FOUND，所以最容易犯的錯是把特例
/// 寫成 `hasPrefix("pack.")`。那樣 `pack use 打錯的id` 會回 2（用法錯誤），
/// 但打的字沒有錯——錯的是那套 pack 不存在，該做的事是先 `pack list`。
@Test func packUseHasNoExitCodeSpecialCase() {
    let use = WireRequest(command: "pack.use", args: ["id": "nope"])
    #expect(Output.render(errorLine(.packNotFound), for: use).exitCode == 1)
    #expect(Output.render(errorLine(.packInvalid), for: use).exitCode == 1)
    // id 根本沒送到（本地擋不住的形狀）仍是用法錯誤
    #expect(Output.render(errorLine(.invalidArgument), for: use).exitCode == 2)

    // 成功走的是通用 ack 那條路
    let ack = Output.render(encode(WireResponse(data: AckPayload(queued: "pack.use"))), for: use)
    #expect(ack.text.contains("pack.use"))
    #expect(ack.exitCode == 0)
}

/// PACK_INVALID 帶著 `details`（缺什麼），那是使用者唯一能拿去修的東西。
///
/// 只印 message 的話畫面上是「不合格，不能使用」——然後呢？
@Test func errorDetailsAreShownNotSwallowed() {
    let line = encode(WireResponse<AckPayload>(error: WireError(
        code: .packInvalid, message: "my-pack 不合格，不能使用",
        details: ["run 宣告 8 格，實際 2 個檔案", "缺少 sitIdle"])))
    let rendered = Output.render(line, for: WireRequest(command: "pack.use",
                                                        args: ["id": "my-pack"]))
    #expect(rendered.text.contains("run 宣告 8 格，實際 2 個檔案"))
    #expect(rendered.text.contains("缺少 sitIdle"))
    #expect(rendered.exitCode == 1)
}

/// 動作命令的回應簡短但要說出排進去的是什麼。
@Test func ackTextNamesTheQueuedCommand() {
    let rendered = Output.render(encode(WireResponse(data: AckPayload(queued: "summon"))),
                                 for: WireRequest(command: "summon"))
    #expect(rendered.text.contains("summon"))
    #expect(rendered.exitCode == 0)
}

/// client 端的連線失敗要分成三種 exit code，因為**該做的事完全不同**。
///
/// 全部收斂成 3（原本的做法）有具體代價：腳本看到 3 會去啟動 App，
/// 而 App 卡住時那只會多開一個實例、多跳一個要人按的提示視窗。
@Test func clientFailuresMapToThreeDifferentExitCodes() {
    let path = "/tmp/whatever.sock"

    let notRunning = Output.failure(for: .appNotRunning, socketPath: path)
    #expect(notRunning.code == .appNotRunning)
    #expect(notRunning.code.exitCode == 3, "3 = 去把它打開")

    let wedged = Output.failure(for: .noResponse, socketPath: path)
    #expect(wedged.code == .appNotResponding)
    #expect(wedged.code.exitCode == 1, "它已經開著了，再開一次沒有用")

    let refused = Output.failure(for: .connectionFailed(errno: 13), socketPath: path)
    #expect(refused.code == .appNotResponding)
    #expect(refused.message.contains("13"), "errno 要留在訊息裡，否則查不下去")

    let tooLong = Output.failure(for: .pathTooLong(path), socketPath: path)
    #expect(tooLong.code == .invalidArgument)
    #expect(tooLong.code.exitCode == 2, "路徑是呼叫端給的，屬用法錯誤")

    // 四種都要給出不同的組合，否則這個分類等於沒做
    let codes = [notRunning, wedged, refused, tooLong].map(\.code)
    #expect(Set(codes).count == 3)
    #expect(Set(codes.map(\.exitCode)) == [1, 2, 3])
}

// MARK: - login-item

@Test func unknownLoginItemStateIsShownVerbatim() {
    // 認不得的狀態不可以被當成「關」——那會把版本不同步偽裝成正常。
    let text = Output.loginItemText("somethingNew")
    #expect(text.contains("somethingNew"))
}

@Test func loginItemStatesEachSayWhatToDoNext() {
    #expect(Output.loginItemText("enabled") == "開")
    // notFound 是全新安裝的狀態，對使用者而言就是「還沒開」
    #expect(Output.loginItemText("notFound") == Output.loginItemText("notRegistered"))
    #expect(Output.loginItemText("requiresApproval").contains("系統設定"))
    #expect(Output.loginItemText("ineligible").contains("應用程式"))
}

/// 舊位置還有 socket 時，「沒在執行」要換一句話。
///
/// 這是升級到沙盒版之後最容易發生的困惑：CLI 說沒在執行，而選單列上那隻貓
/// 正看著你。**兩種情況的下一步完全不同**，所以訊息必須分得開；exit code
/// 仍然是 3（去把它弄成在跑的狀態），那一點沒有變。
@Test func aSocketAtTheOldLocationChangesWhatWeSay() {
    let path = "/tmp/whatever.sock"

    let plain = Output.failure(for: .appNotRunning, socketPath: path)
    let stale = Output.failure(for: .appNotRunning, socketPath: path,
                               legacySocketPresent: true)

    #expect(plain.message != stale.message, "兩種情況講了同一句話")
    #expect(stale.code == .appNotRunning, "仍然是 3——要做的事還是讓它跑起來")
    #expect(stale.message.contains("舊版"), "沒講出「對面是舊版」就等於沒說明")
    #expect(stale.message.contains("upgrade"), "訊息要講接下來能做什麼")
    // **不能宣稱它正在跑。** 那個檔案也可能是上次崩潰的殘留（stop() 會 unlink，
    // 被 SIGKILL 不會），所以句子只能是條件句。
    #expect(stale.message.contains("如果"), "不可以斷言舊版正在跑，那件事我們沒有量到")

    // 旗標只該改這一種。連上了卻沒回應、路徑太長都與舊位置無關，
    // 順手一起改掉的話，使用者會在四種毫不相干的失敗上看到同一句升級建議。
    for error: WireClient.ClientError in [.noResponse, .connectionFailed(errno: 13),
                                          .pathTooLong(path)] {
        #expect(Output.failure(for: error, socketPath: path).message
                == Output.failure(for: error, socketPath: path,
                                  legacySocketPresent: true).message,
                "\(error) 不該受舊位置影響")
    }
}
