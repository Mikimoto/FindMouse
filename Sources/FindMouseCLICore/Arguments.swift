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
          pack list                        列出所有 pack（* 是正在用的那套）
          pack use <id>                    換成另一套 pack
          pack validate <path>             驗證一套 sprite pack
          login-item [on|off]              開機時是否啟動（不帶動詞就是查詢）

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
            return try parsePack(rest, json: json)

        case "login-item":
            guard let mode = rest.first else {
                try expectNoExtra(rest, command)
                return request("login-item.status")
            }
            guard ["on", "off"].contains(mode) else {
                // 刻意不提 toggle：那個動詞不存在，而錯誤訊息若列出它，
                // 使用者會去試一個永遠不會有的東西。
                throw ParseError.usage("login-item 只接 on 或 off（不帶動詞就是查詢）")
            }
            try expectNoExtra(Array(rest.dropFirst()), command)
            return request("login-item.\(mode)")

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

    private static func parsePack(_ rest: [String], json: Bool) throws -> Parsed {
        func parsed(_ name: String, _ params: [String: String] = [:]) -> Parsed {
            Parsed(request: WireRequest(command: name, args: params), json: json)
        }

        switch rest.first {
        case "list":
            try expectNoExtra(Array(rest.dropFirst()), "pack list")
            return parsed("pack.list")

        case "use":
            // 少了 id 就在這裡停。送出去的話 App 會回 INVALID_ARGUMENT，
            // 於是「你少打一個 id」變成 App 端的抱怨，要查的地方差很遠。
            guard rest.count == 2 else {
                throw ParseError.usage("pack use 要接一個 pack id（用 pack list 看有哪些）")
            }
            // id 原樣送出去，不補前綴也不轉小寫：哪些 id 存在只有 App 那份
            // 掃描結果知道，在這裡猜只會讓 PACK_NOT_FOUND 指向錯的原因。
            return parsed("pack.use", ["id": rest[1]])

        case "validate":
            guard rest.count == 2 else {
                throw ParseError.usage("pack validate 要接一個路徑")
            }
            return parsed("pack.validate", ["path": rest[1]])

        default:
            throw ParseError.usage("pack 要接 list、use <id> 或 validate <path>")
        }
    }

    private static func expectNoExtra(_ rest: [String], _ command: String) throws {
        guard rest.isEmpty else {
            throw ParseError.usage("\(command) 不接受參數：\(rest.joined(separator: " "))")
        }
    }
}
