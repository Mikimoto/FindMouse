import Foundation
import FindMouseWire

/// 命令列參數 → `WireRequest`（spec 第 8.3 節）。
///
/// 手寫解析而不引入 `ArgumentParser`：CLI 的依賴目前**只有一個**
/// （`FindMouseWire`，spec 第 7.1 節要求的），加一個套件就會把它變成一串，
/// 而這裡要解析的是 9 個固定形狀的命令。
///
/// 拆成純函式是為了可測：`main.swift` 只負責 I/O 與 exit code。
public enum Arguments {

    public struct Parsed: Equatable {
        public let request: WireRequest
        public let json: Bool
    }

    public enum ParseError: Error, Equatable {
        case usage(String)
        /// 完全沒給命令或給了 --help
        case help
    }

    public static let usageText = """
        用法：findmouse <命令> [參數] [--json]

          summon | dismiss | toggle        叫貓咪 / 讓牠回家 / 切換
          teaser on | off | toggle         逗貓棒模式
          status                           目前狀態
          config get [key]                 讀設定（不給 key 就列全部）
          config set <key> <value>         寫設定
          config reset <key> | --all       還原設定
          pack validate <path>             驗證一套 sprite pack

        全域旗標：
          --json    輸出機器可讀的 JSON

        注意：toggle 不是幂等的。自動化請用 summon / dismiss——
        方向明確的命令重複執行結果一致，重試時不會把貓叫回來又趕走。

        exit code：0 成功、1 命令失敗、2 用法錯誤、3 App 沒在跑。
        """

    public static func parse(_ argv: [String]) throws -> Parsed {
        var args = argv
        // --json 可以出現在任何位置，先抽掉再看剩下的形狀
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" }

        guard let command = args.first else { throw ParseError.help }
        if command == "--help" || command == "-h" || command == "help" { throw ParseError.help }
        let rest = Array(args.dropFirst())

        func request(_ name: String, _ params: [String: String] = [:]) -> Parsed {
            Parsed(request: WireRequest(command: name, args: params), json: json)
        }

        switch command {
        case "summon", "dismiss", "toggle":
            try expectNoExtra(rest, command)
            return request(command)

        case "teaser":
            guard let mode = rest.first, ["on", "off", "toggle"].contains(mode) else {
                throw ParseError.usage("teaser 要接 on、off 或 toggle")
            }
            try expectNoExtra(Array(rest.dropFirst()), command)
            return request("teaser.\(mode)")

        case "status":
            try expectNoExtra(rest, command)
            return request("status")

        case "config":
            return try parseConfig(rest, json: json)

        case "pack":
            guard rest.first == "validate" else {
                // pack list / pack use 是 M4。明講它不在，比回「未知命令」清楚——
                // 後者會讓人以為自己打錯字。
                if let sub = rest.first, ["list", "use"].contains(sub) {
                    throw ParseError.usage("pack \(sub) 尚未實作（M4）")
                }
                throw ParseError.usage("pack 目前只支援 validate <path>")
            }
            guard rest.count == 2 else {
                throw ParseError.usage("pack validate 要接一個路徑")
            }
            return request("pack.validate", ["path": rest[1]])

        default:
            throw ParseError.usage("未知命令：\(command)")
        }
    }

    private static func parseConfig(_ rest: [String], json: Bool) throws -> Parsed {
        func parsed(_ name: String, _ params: [String: String]) -> Parsed {
            Parsed(request: WireRequest(command: name, args: params), json: json)
        }

        switch rest.first {
        case "get":
            let keys = Array(rest.dropFirst())
            guard keys.count <= 1 else { throw ParseError.usage("config get 最多接一個 key") }
            return parsed("config.get", keys.first.map { ["key": $0] } ?? [:])

        case "set":
            let params = Array(rest.dropFirst())
            guard params.count == 2 else {
                throw ParseError.usage("config set 要接 <key> <value>")
            }
            return parsed("config.set", ["key": params[0], "value": params[1]])

        case "reset":
            let params = Array(rest.dropFirst())
            if params == ["--all"] { return parsed("config.reset", ["all": "true"]) }
            guard params.count == 1, !params[0].hasPrefix("--") else {
                throw ParseError.usage("config reset 要接一個 key 或 --all")
            }
            return parsed("config.reset", ["key": params[0]])

        default:
            throw ParseError.usage("config 要接 get、set 或 reset")
        }
    }

    private static func expectNoExtra(_ rest: [String], _ command: String) throws {
        guard rest.isEmpty else {
            throw ParseError.usage("\(command) 不接受參數：\(rest.joined(separator: " "))")
        }
    }
}
