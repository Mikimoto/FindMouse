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
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
