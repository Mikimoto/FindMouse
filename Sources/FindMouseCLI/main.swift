import Foundation
import FindMouseCLICore
import FindMouseWire

/// `findmouse` 的入口。這裡只做 I/O 與 exit code——
/// 參數解析在 `Arguments`、輸出在 `Output`，兩者都是純函式，所以測得到。
///
/// target 叫 `FindMouseCLI` 而產品叫 `findmouse`：macOS 的檔案系統不分大小寫，
/// `Sources/findmouse` 與 `Sources/FindMouse` 是**同一個目錄**，
/// 照計畫命名的話 CLI 的原始碼會直接掉進 App target 裡（實測踩過）。

/// socket 路徑。與 App 端的 `UnixSocketServer.defaultPath` 必須一致，
/// 但 CLI 只能依賴 `FindMouseWire`（spec 第 7.1 節），所以這裡自己算一次。
///
/// 兩份計算漂開的話會怎樣：`Scripts/e2e.sh` 真的啟動 App 再跑真的 CLI，
/// 路徑一旦不一致，第一個案例就會回 APP_NOT_RUNNING。
let socketPath: String = {
    if let override = ProcessInfo.processInfo.environment["FINDMOUSE_SOCKET"] { return override }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("FindMouse/control.sock").path
}()

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
    // 沒給任何參數是用法錯誤（2）；明確要 --help 是成功（0）
    emit(Arguments.usageText)
    exit(argv.isEmpty ? 2 : 0)
} catch let Arguments.ParseError.usage(message) {
    fail(.invalidArgument, message, json: wantsJSON)
} catch {
    fail(.invalidArgument, "\(error)", json: wantsJSON)
}

let line: Data
do {
    line = try WireClient.send(parsed.request, to: socketPath)
} catch WireClient.ClientError.appNotRunning {
    fail(.appNotRunning, "FindMouse 沒在執行（\(socketPath)）", json: parsed.json)
} catch WireClient.ClientError.noResponse {
    fail(.appNotRunning, "連上了但 FindMouse 沒有回應（可能卡住了）", json: parsed.json)
} catch {
    fail(.appNotRunning, "連不上 FindMouse：\(error)", json: parsed.json)
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
