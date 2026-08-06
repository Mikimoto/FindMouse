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

let line: Data
do {
    line = try WireClient.send(parsed.request, to: socketPath)
} catch let error as WireClient.ClientError {
    // 對應住在 Output.failure（CLICore），因為 exit code 的分岔是對外契約，
    // 而 main.swift 沒有任何測試碰得到。
    let wire = Output.failure(for: error, socketPath: socketPath)
    fail(wire.code, wire.message, json: parsed.json)
} catch {
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
