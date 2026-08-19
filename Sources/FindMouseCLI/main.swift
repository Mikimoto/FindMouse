// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FindMouseCLICore
import FindMouseWire

/// `findmouse` 的入口。這裡只做 I/O 與 exit code——
/// 參數解析在 `Arguments`、輸出在 `Output`，兩者都是純函式，所以測得到。
///
/// target 叫 `FindMouseCLI` 而產品叫 `findmouse`：macOS 的檔案系統不分大小寫，
/// `Sources/findmouse` 與 `Sources/FindMouse` 是**同一個目錄**，
/// 照計畫命名的話 CLI 的原始碼會直接掉進 App target 裡（實測踩過）。

/// socket 路徑。與 App 端共用 `ControlSocket.path`（住在 FindMouseWire），
/// 所以兩邊不可能漂開——這裡原本各算一次，而那正是「CLI 永遠回 APP_NOT_RUNNING
/// 而 App 一切正常」的那種 bug 的溫床。
let socketPath = ControlSocket.path

func emit(_ text: String, to handle: FileHandle = .standardOutput) {
    handle.write(Data((text + "\n").utf8))
}

/// `--json` 時的錯誤輸出也必須是合法 JSON。
///
/// 只印一句話的話，AI 解析輸出時拿到的是「不是 JSON」——那比拿到一個錯誤碼
/// 難處理得多，因為它無法區分「命令失敗」與「我呼叫錯了」。
func fail(_ code: WireErrorCode, _ message: String, json: Bool) -> Never {
    if json {
        let response = WireResponse<AckPayload>(error: WireError(code: code, message: message))
        if let data = try? JSONEncoder().encode(response) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    } else {
        emit("錯誤 [\(code.rawValue)] \(message)", to: .standardError)
    }
    exit(code.exitCode)
}

let argv = Array(CommandLine.arguments.dropFirst())
let wantsJSON = argv.contains("--json")

let parsed: Arguments.Parsed
do {
    parsed = try Arguments.parse(argv)
} catch Arguments.ParseError.help {
    // 明確要 --help 是成功（0），印說明文字即可——那是給人看的。
    // 但「沒給命令」是用法錯誤，而 --json 模式下錯誤也必須是合法 JSON：
    // agent 拿到不是 JSON 的東西，比拿到錯誤碼難處理得多。
    // 判斷「有沒有給命令」要看**抽掉旗標之後**還剩什麼：`findmouse --json` 的
    // argv 不是空的，但它同樣沒有指定命令。第一版寫成 argv.isEmpty，於是
    // `--json` 照樣走到印說明文字那條路——正是這個修正要防的事。
    if argv.allSatisfy({ $0 == "--json" }) {
        fail(.invalidArgument, "沒有指定命令。用 findmouse --help 看用法。", json: wantsJSON)
    }
    emit(Arguments.usageText)
    exit(0)
} catch let Arguments.ParseError.usage(message) {
    fail(.invalidArgument, message, json: wantsJSON)
} catch {
    fail(.invalidArgument, "\(error)", json: wantsJSON)
}

// --- 把來源搬進 App 的容器 ------------------------------------------------
//
// 沙盒 App 讀不到容器外的裸路徑（見 SourceStaging 的檔頭）。這一段把 pack 的
// 來源複製進去，再把請求裡的路徑換成複製後的位置。
var stagingToRemove: String?
var requestToSend = parsed.request

// **不存在、讀不到、容器還沒建立——三種都不搬**，理由寫在 `shouldStage` 上：
// staging 是運輸機制，讓它自己發明錯誤分類，同一個來源就會因為「有沒有被搬」
// 而拿到兩種 exit code。原樣送出去，讓 App 給出它一直以來給的那個答案。
if let source = SourceStaging.sourcePath(of: parsed.request),
   SourceStaging.shouldStage(source: source,
                             containerData: ControlSocket.containerData) {

    // 大得不可能是一套圖組就當場停下，不要先複製好幾 GB 再讓 App 說不。
    // 理由與成本見 `SourceStaging.exceedsByteLimit`。錯誤碼與訊息跟著 App 的
    // `.tooLarge → .packTooLarge`：這不是 staging 發明的分類，是同一條政策
    // 提早一步執行（上限的單一來源是 `PackLimits.byteLimit`）。
    if SourceStaging.exceedsByteLimit(source) {
        fail(.packTooLarge,
             "\(source) 超過 \(PackLimits.byteLimit / 1024 / 1024) MB，不像是一套圖組。"
             + "請指到 .fmpack 檔或圖組資料夾本身。",
             json: parsed.json)
    }

    // 先掃掉別人留下的 staging。CLI 被 SIGKILL 時下面那個 defer 不會跑，
    // 所以「上一次沒收拾的」只能由下一次來清——判準是那個 pid 已經不在了。
    let tmp = "\(ControlSocket.containerData)/tmp"
    for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? [] {
        guard let owner = SourceStaging.pid(ofStagingDirectoryNamed: name) else { continue }
        // kill(pid, 0) 只做存在性檢查，不送信號。ESRCH ＝ 那個 process 沒了。
        if kill(owner, 0) != 0 && errno == ESRCH {
            try? FileManager.default.removeItem(atPath: "\(tmp)/\(name)")
        }
    }

    let dir = SourceStaging.stagingDirectory(container: ControlSocket.containerData,
                                             pid: getpid())
    let staged = "\(dir)/\(URL(fileURLWithPath: source).lastPathComponent)"
    do {
        try? FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: source, toPath: staged)
    } catch {
        // 複製失敗要講得出是複製失敗。不講的話使用者拿到的是 App 對一個
        // 不存在路徑的抱怨，而那指向完全錯誤的方向。
        try? FileManager.default.removeItem(atPath: dir)
        fail(.packSourceInvalid,
             "把來源複製進 FindMouse 的沙盒容器時失敗：\(error.localizedDescription)",
             json: parsed.json)
    }
    stagingToRemove = dir
    requestToSend = SourceStaging.rewritten(parsed.request, sourcePath: staged)
}

/// 收拾 staging。**要等 App 回應之後**——它是在我們等回應的期間去讀那份複本的。
///
/// `@MainActor` 是必要的不是裝飾：top-level 程式碼隱含跑在 main actor 上，而
/// top-level 宣告的 `func` **不繼承那個隔離**，於是它碰不到上面那個變數。
@MainActor
func removeStaging() {
    if let dir = stagingToRemove { try? FileManager.default.removeItem(atPath: dir) }
    stagingToRemove = nil
}

let line: Data
do {
    line = try WireClient.send(requestToSend, to: socketPath)
    removeStaging()
} catch let error as WireClient.ClientError {
    removeStaging()
    // 對應住在 Output.failure（CLICore），因為 exit code 的分岔是對外契約，
    // 而 main.swift 沒有任何測試碰得到。
    //
    // 舊位置的 socket 只在**沒有覆寫**時才問：有 `FINDMOUSE_SOCKET` 時兩端都是
    // 呼叫端自己指定的，舊位置有什麼與這次連不上完全無關，答進去只會讓 e2e
    // 與測試看到一句莫名其妙的「你的 FindMouse 是舊版」。
    let overridden = ProcessInfo.processInfo.environment["FINDMOUSE_SOCKET"] != nil
    let wire = Output.failure(
        for: error, socketPath: socketPath,
        legacySocketPresent: !overridden
            && FileManager.default.fileExists(atPath: ControlSocket.legacyPath))
    fail(wire.code, wire.message, json: parsed.json)
} catch {
    removeStaging()
    fail(.appNotResponding, "連不上 FindMouse：\(error)", json: parsed.json)
}

let rendered = Output.render(line, for: parsed.request)

if parsed.json {
    // **原樣輸出 App 回的那一行。** 重新編碼會讓 CLI 有機會改欄位，
    // 而對外契約只能有一個來源。
    FileHandle.standardOutput.write(line)
    FileHandle.standardOutput.write(Data("\n".utf8))
} else {
    emit(rendered.text, to: rendered.exitCode == 0 ? .standardOutput : .standardError)
}
// exit code 兩種模式一致：腳本常常只看 exit code 而不解析 body
exit(rendered.exitCode)
