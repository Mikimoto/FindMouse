import Foundation
import FindMouseWire

/// App 回來的那一行 → 印給人看的文字 ＋ exit code。
///
/// `--json` 走另一條路：**原樣輸出 App 回的那一行**，這一層完全不碰。
/// 重新編碼會讓 CLI 有機會改欄位，而對外契約只能有一個來源。
public enum Output {

    /// 只讀信封，不管 `data` 長什麼樣。
    ///
    /// 不能拿 `WireResponse<AckPayload>` 當通用探針：`data` 是 status payload 時
    /// 解不出 `queued`，整個解碼會失敗，於是「成功的回應」看起來像壞掉的回應。
    private struct Envelope: Decodable {
        let ok: Bool
        let error: WireError?
    }

    public struct Rendered {
        public let text: String
        public let exitCode: Int32
    }

    /// client 端的連線失敗 → 錯誤碼。
    ///
    /// 住在這裡而不是 `main.swift`，是為了測得到：exit code 的分岔是對外契約，
    /// 而 `main.swift` 只有 I/O，沒有任何測試碰得到它。
    ///
    /// 三條分岔對應三種**該做的事完全不同**的情況：把 App 打開（3）、
    /// App 在跑但有問題（1）、你給的 socket 路徑不對（2）。
    /// 全部收斂成 3 的話，`WireClient` 那份 errno 分類就完全觀察不到，
    /// 而腳本看到 3 會去啟動第二個實例——對一個卡住的 App 那只會多一個提示視窗。
    public static func failure(for error: WireClient.ClientError,
                               socketPath: String) -> WireError {
        switch error {
        case .appNotRunning:
            return WireError(code: .appNotRunning, message: "FindMouse 沒在執行（\(socketPath)）")
        case .noResponse:
            return WireError(code: .appNotResponding,
                             message: "連上了但 FindMouse 沒有回應（可能卡住了）")
        case .connectionFailed(let code):
            return WireError(code: .appNotResponding,
                             message: "連線失敗（errno \(code)）：\(socketPath)")
        case .pathTooLong(let path):
            // 呼叫端給錯了（多半是 FINDMOUSE_SOCKET 設太長），屬用法錯誤
            return WireError(code: .invalidArgument,
                             message: "socket 路徑超過 sun_path 的長度上限：\(path)")
        }
    }

    public static func render(_ line: Data, for request: WireRequest) -> Rendered {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else {
            return Rendered(text: "App 回了看不懂的東西：\(String(decoding: line, as: UTF8.self))",
                            exitCode: 1)
        }

        if let error = envelope.error {
            return Rendered(text: "錯誤 [\(error.code.rawValue)] \(error.message)"
                            + (error.details.map { "\n  " + $0.joined(separator: "\n  ") } ?? ""),
                            exitCode: exitCode(for: error, request: request))
        }
        guard envelope.ok else {
            return Rendered(text: "命令失敗，但 App 沒有說明原因", exitCode: 1)
        }
        return success(line, for: request)
    }

    /// spec 第 8.5 節：`pack validate` 的 exit code 語意**單獨定義**。
    /// 路徑不存在／讀不到是「用法錯誤」（2），不是「命令失敗」（1）——
    /// 前者要改的是打的路徑，後者要改的是 pack 本身。
    private static func exitCode(for error: WireError, request: WireRequest) -> Int32 {
        if request.command == "pack.validate" && error.code == .packNotFound { return 2 }
        return error.code.exitCode
    }

    private static func success(_ line: Data, for request: WireRequest) -> Rendered {
        let decoder = JSONDecoder()

        switch request.command {
        case "status":
            guard let s = try? decoder.decode(WireResponse<StatusPayload>.self, from: line).data
            else { return malformed(line) }
            return Rendered(text: describe(s), exitCode: 0)

        case "config.get", "config.set", "config.reset":
            guard let c = try? decoder.decode(WireResponse<ConfigPayload>.self, from: line).data
            else { return malformed(line) }
            let width = c.entries.map(\.key.count).max() ?? 0
            return Rendered(
                text: c.entries
                    .map { $0.key.padding(toLength: width, withPad: " ", startingAt: 0)
                            + " = " + $0.value }
                    .joined(separator: "\n"),
                exitCode: 0)

        case "pack.list":
            guard let p = try? decoder.decode(WireResponse<PackListPayload>.self,
                                              from: line).data
            else { return malformed(line) }
            // 清單裡有不可用的 pack **不是**命令失敗（對比 `pack.validate`：
            // 那個命令問的就是「這套能不能用」）。這裡問的是「有哪些」，
            // 答出來就是 0；換不過去要等 `pack use` 自己回錯。
            return Rendered(text: describe(p), exitCode: 0)

        case "pack.validate":
            guard let p = try? decoder.decode(WireResponse<PackValidatePayload>.self,
                                              from: line).data
            else { return malformed(line) }
            var lines = ["pack \(p.id)：\(p.valid ? "合格" : "不合格")"]
            lines += p.errors.map { "  錯誤：\($0)" }
            lines += p.warnings.map { "  警告：\($0)" }
            // 「驗證成功地判定這套 pack 不合格」不是命令失敗，所以 ok 是 true；
            // 但對呼叫端而言 pack 不能用，exit 1（spec 第 8.5 節）。
            return Rendered(text: lines.joined(separator: "\n"), exitCode: p.valid ? 0 : 1)

        default:
            guard let a = try? decoder.decode(WireResponse<AckPayload>.self, from: line).data
            else { return malformed(line) }
            return Rendered(text: "已排入：\(a.queued)", exitCode: 0)
        }
    }

    /// 正在用的那一套的行首標記。
    ///
    /// 抽成常數是因為它出現在兩個地方：這裡印，`Arguments.usageText` 解釋它。
    /// 只改一邊，CLI 就會印一個沒人解釋過的符號。
    static let currentPackMarker = "* "

    /// 一套一行，不能用的那些也列，理由跟在下一行。
    ///
    /// 「標紅字」在終端機裡用**文字**表達而不是 ANSI 顏色：這支 CLI 全程沒有
    /// 跳脫序列，而導進管線或檔案時那些序列會變成雜訊（`grep` 也就跟著白費）。
    private static func describe(_ p: PackListPayload) -> String {
        // 印零行與「命令壞掉了」在終端機上長得一模一樣。內建 pack 隨 bundle
        // 出貨，掃不到反而是最該說出口的狀況。
        guard !p.packs.isEmpty else { return "找不到任何 pack" }

        let width = p.packs.map(\.id.count).max() ?? 0
        let blank = String(repeating: " ", count: currentPackMarker.count)
        return p.packs.flatMap { pack -> [String] in
            // 不可用擺第一個：那一列使用者唯一要做的事是看下一行的原因。
            var details: [String] = pack.usable ? [] : ["不可用"]
            details.append("體高 " + fixed(pack.logicalHeight))
            if pack.teaserAvailable { details.append("逗貓棒") }

            // 補空白而不用 `padding(toLength:)`：後者數的是 UTF-16 單元，
            // 而 id 是**使用者取的目錄名**——`a🐱` 的 count 是 2、UTF-16 是 3，
            // 對齊到 2 會從代理對中間切下去，印出一個 U+FFFD（實測）。
            // 「內建」比「使用者」少一個字，補兩格：等寬終端機一個 CJK 字佔兩格，
            // 而任何以字元數為單位的補法都對不齊它。
            let head = (pack.current ? currentPackMarker : blank)
                + pack.id + String(repeating: " ", count: max(0, width - pack.id.count))
                + "  " + (pack.builtIn ? "內建  " : "使用者")
                + "  " + details.joined(separator: "、")
            // 縮排比 `pack validate` 深一層：那邊只有一套，這邊要看得出
            // 這行理由屬於上面哪一列。
            return [head]
                + pack.errors.map { "      錯誤：\($0)" }
                + pack.warnings.map { "      警告：\($0)" }
        }.joined(separator: "\n")
    }

    private static func malformed(_ line: Data) -> Rendered {
        Rendered(text: "App 的回應解不開：\(String(decoding: line, as: UTF8.self))", exitCode: 1)
    }

    private static func describe(_ s: StatusPayload) -> String {
        let rows: [(String, String)] = [
            ("phase", "\(s.phase)（\(fixed(s.phaseElapsed)) s）"),
            ("visible", s.visible ? "是" : "否"),
            ("teaser", "\(s.teaser.enabled ? "開" : "關")"
                + "（\(s.teaser.available ? "可用" : "此 pack 不支援")）"),
            ("cat", "(\(fixed(s.cat.position.x)), \(fixed(s.cat.position.y))) 朝\(s.cat.facing == "left" ? "左" : "右")"),
            ("action", "\(s.cat.action) 第 \(s.cat.frame + 1)/\(s.cat.frameCount) 格"),
            ("cursor", "(\(fixed(s.cursor.x)), \(fixed(s.cursor.y)))"),
            ("distance", fixed(s.distance)),
            ("spotlight", s.spotlight.active
                ? "半徑 \(fixed(s.spotlight.radius))、暗度 \(fixed(s.spotlight.opacity))"
                : "關"),
            ("timers", "rest \(fixed(s.timers.rest)) s、sleep \(fixed(s.timers.sleep)) s"),
            ("pack", "\(s.pack.id)（體高 \(fixed(s.pack.logicalHeight))）"),
            ("display", "螢幕 #\(s.display.screenIndex)、scale \(fixed(s.display.scale))"),
            ("version", s.appVersion),
        ]
        let width = rows.map(\.0.count).max() ?? 0
        return rows
            .map { $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.1 }
            .joined(separator: "\n")
    }

    /// 座標印到小數點後一位就夠，整數就不印小數。
    /// `String(describing:)` 會印出 `663.5000000000001` 這種東西。
    private static func fixed(_ value: Double) -> String {
        // `abs(value) < 1e15` 不是保守，是必要：`Int(1e300)` 直接 trap
        // （"Double value cannot be converted to Int"），CLI 會崩而不是印東西。
        // 同一個慣用法在 SettingsUseCase.render 有這道守衛，這份複本原本漏了。
        // 非有限值（NaN／inf）也走同一條退路。
        guard value.isFinite, value == value.rounded(), abs(value) < 1e15 else {
            return value.isFinite ? String(format: "%.1f", value) : String(value)
        }
        return String(Int(value))
    }
}
