import CoreGraphics
import Foundation
import FindMouseCore
import FindMouseDomain
import FindMouseWire

/// `WireRequest` → 對 use case 的呼叫 → 編碼好的 `WireResponse`。
///
/// 這一層是**純轉譯**：它不持有任何狀態，socket 只是它的傳輸方式。
/// 所以它完全可測——`UnixSocketServer` 的測試不需要重測一次命令語意。
///
/// 命令名對應 CLI 的子命令，有子命令的就用點分（`config.set`）。
/// 不用 `command: "config"` ＋ `args["action"]` 的理由：那樣「不認識的動作」
/// 得在第二層再回一次錯，而 `UNKNOWN_COMMAND` 這個碼會變得含糊。
public final class RequestRouter {

    private let control: ControlUseCase
    private let settings: SettingsUseCase
    private let status: () -> StatusPayload
    private let packs: () -> [PackSummary]
    private let usePack: (String) -> Void

    /// - Parameter status: 產生當下狀態的快照。注入而不是自己算：
    ///   它需要 `CatFrameState`、螢幕清單與 pack 資訊，那些都住在 App 層。
    /// - Parameter packs: 當下掃得到的 pack。每次呼叫都重掃，不快取：
    ///   使用者把 pack 丟進目錄之後不該還要重開 App 才看得到。
    /// - Parameter usePack: 換 pack 的請求交給誰。**router 不自己換**——
    ///   換一套 pack 要一起換掉 App 那七個從 pack 衍生出來的持有者，
    ///   而 router 一個都碰不到。與 `status` 注入快照是同一個模式。
    public init(control: ControlUseCase, settings: SettingsUseCase,
                status: @escaping () -> StatusPayload,
                packs: @escaping () -> [PackSummary],
                usePack: @escaping (String) -> Void) {
        self.control = control
        self.settings = settings
        self.status = status
        self.packs = packs
        self.usePack = usePack
    }

    public func handle(_ request: WireRequest) -> Data {
        // 版號先檢查，比命令還早。版號不對時連 command 都不該被看——
        // 「未來版本的新命令」會回 UNKNOWN_COMMAND，而那個訊息會叫人去查
        // 拼字，真正該做的是升級其中一邊。
        guard request.protocolVersion == WireProtocol.version else {
            return encode(WireResponse<AckPayload>(error: WireError(
                code: .protocolMismatch,
                message: "CLI 用協定 \(request.protocolVersion)，App 用 \(WireProtocol.version)")))
        }

        switch request.command {
        case "summon":   return enqueue(.summon, named: "summon")
        case "dismiss":  return enqueue(.dismiss, named: "dismiss")
        case "toggle":   return enqueue(.toggle, named: "toggle")
        case "teaser.on":     return enqueue(.setTeaser(true), named: "teaser.on")
        case "teaser.off":    return enqueue(.setTeaser(false), named: "teaser.off")
        case "teaser.toggle": return enqueue(.toggleTeaser, named: "teaser.toggle")
        case "status":        return encode(WireResponse(data: status()))
        case "config.get":    return configGet(request.args)
        case "config.set":    return configSet(request.args)
        case "config.reset":  return configReset(request.args)
        case "pack.validate": return packValidate(request.args)
        case "pack.list":     return packList()
        case "pack.use":      return packUse(request.args)
        default:
            return encode(WireResponse<AckPayload>(error: WireError(
                code: .unknownCommand, message: "未知命令：\(request.command)")))
        }
    }

    // MARK: - 命令

    private func enqueue(_ command: Command, named name: String) -> Data {
        do {
            try control.enqueue(command)
            return encode(WireResponse(data: AckPayload(queued: name)))
        } catch {
            return encode(WireResponse<AckPayload>(error: wireError(for: error)))
        }
    }

    /// 不給 key 就回全部。`getAll()` 已經照字典序排好。
    private func configGet(_ args: [String: String]) -> Data {
        guard let key = args["key"] else {
            return encode(WireResponse(data: ConfigPayload(
                entries: settings.getAll().map { .init(key: $0.key, value: $0.value) })))
        }
        do {
            return encode(WireResponse(data: ConfigPayload(
                entries: [.init(key: key, value: try settings.get(key))])))
        } catch {
            return encode(WireResponse<ConfigPayload>(error: wireError(for: error)))
        }
    }

    /// 寫入後回讀，回的是**存進去的正規化值**而不是使用者打的字。
    /// `set spotlight.enabled yes` 回 `true`，腳本因此看得到自己寫的東西
    /// 被怎麼理解，不必再打一次 `get` 確認。
    private func configSet(_ args: [String: String]) -> Data {
        guard let key = args["key"], let value = args["value"] else {
            return encode(WireResponse<ConfigPayload>(error: WireError(
                code: .invalidArgument, message: "config.set 需要 key 與 value")))
        }
        do {
            try settings.set(key, to: value)
            return encode(WireResponse(data: ConfigPayload(
                entries: [.init(key: key, value: try settings.get(key))])))
        } catch {
            return encode(WireResponse<ConfigPayload>(error: wireError(for: error)))
        }
    }

    private func configReset(_ args: [String: String]) -> Data {
        if args["all"] == "true" {
            settings.resetAll()
            return encode(WireResponse(data: ConfigPayload(
                entries: settings.getAll().map { .init(key: $0.key, value: $0.value) })))
        }
        guard let key = args["key"] else {
            return encode(WireResponse<ConfigPayload>(error: WireError(
                code: .invalidArgument, message: "config.reset 需要 key 或 all=true")))
        }
        do {
            try settings.reset(key)
            return encode(WireResponse(data: ConfigPayload(
                entries: [.init(key: key, value: try settings.get(key))])))
        } catch {
            return encode(WireResponse<ConfigPayload>(error: wireError(for: error)))
        }
    }

    /// pack 不合格時 `ok` 仍是 true——見 `PackValidatePayload` 的說明。
    private func packValidate(_ args: [String: String]) -> Data {
        guard let path = args["path"] else {
            return encode(WireResponse<PackValidatePayload>(error: WireError(
                code: .invalidArgument, message: "pack.validate 需要 path")))
        }
        guard let loaded = SpritePackRepository.load(at: URL(fileURLWithPath: path)) else {
            return encode(WireResponse<PackValidatePayload>(error: WireError(
                code: .packNotFound, message: "讀不到 pack：\(path)")))
        }
        let report = PackValidator.validate(manifest: loaded.manifest,
                                            directoryName: loaded.directoryName,
                                            listing: loaded.listing)
        return encode(WireResponse(data: PackValidatePayload(
            id: loaded.manifest.id,
            valid: report.isValid,
            errors: report.errors.map(\.wireText),
            warnings: report.warnings.map(\.wireText))))
    }

    /// 清單維持 `packs()` 給的順序（掃描的優先序，內建在前），不重排。
    private func packList() -> Data {
        let currentID = status().pack.id
        return encode(WireResponse(data: PackListPayload(packs: packs().map {
            .init(id: $0.id, builtIn: $0.isBuiltIn,
                  logicalHeight: Double($0.logicalHeight), usable: $0.isUsable,
                  current: $0.id == currentID, teaserAvailable: $0.teaserAvailable,
                  errors: $0.errors, warnings: $0.warnings)
        })))
    }

    /// 驗證在這裡做完才交給 App：App 那一側要動七個持有者，
    /// 不該還要負責判斷「這個 id 能不能用」。
    ///
    /// 「沒這套」與「這套壞了」分成兩個碼，因為要修的事不同：一個是打錯 id，
    /// 另一個是那套 pack 真的缺檔案——後者還要附上缺什麼，否則使用者只知道
    /// 不能用、不知道為什麼。
    private func packUse(_ args: [String: String]) -> Data {
        guard let id = args["id"] else {
            return encode(WireResponse<AckPayload>(error: WireError(
                code: .invalidArgument, message: "pack.use 需要 id")))
        }
        guard let summary = packs().first(where: { $0.id == id }) else {
            return encode(WireResponse<AckPayload>(error: WireError(
                code: .packNotFound, message: "沒有這套 pack：\(id)")))
        }
        guard summary.isUsable else {
            return encode(WireResponse<AckPayload>(error: WireError(
                code: .packInvalid, message: "\(id) 不合格，不能使用",
                details: summary.errors)))
        }
        usePack(id)
        // `queued` 只放命令名，不夾帶 id：那是 `AckPayload` 對這個欄位的定義，
        // 而 id 本來就是呼叫端自己送來的，回給它沒有新資訊。想知道換成功沒有
        // 就打一次 `status`——換 pack 跟其他命令一樣要等到下一帧才發生。
        return encode(WireResponse(data: AckPayload(queued: "pack.use")))
    }

    // MARK: - 錯誤對應

    /// `SettingsError` 與 `ControlError` 各自是 Core 的型別（Core 不能 import Wire），
    /// 所以對應在這裡做。三個 SettingsError 分別對到三個不同的碼是刻意的：
    /// 「key 打錯」「值的格式錯」「值超出範圍」要修的東西完全不同。
    private func wireError(for error: Error) -> WireError {
        switch error {
        case ControlError.teaserUnavailable:
            return WireError(code: .teaserUnavailable, message: "當前 pack 缺 teaser 動作")
        case SettingsError.unknownKey(let key):
            return WireError(code: .configKeyUnknown, message: "未知設定：\(key)")
        case SettingsError.invalidValue(let key, let value, let expected):
            return WireError(code: .invalidArgument,
                             message: "\(key) 不接受 \(value)，要的是 \(expected)")
        case SettingsError.outOfRange(let key, let value, let range):
            return WireError(code: .configValueOutOfRange,
                             message: "\(key) 的 \(value) 超出 \(range.lowerBound)–\(range.upperBound)")
        default:
            return WireError(code: .invalidArgument, message: "\(error)")
        }
    }

    private func encode<T>(_ response: WireResponse<T>) -> Data {
        do {
            return try JSONEncoder().encode(response)
        } catch {
            // 編不出來就必須送出點什麼，否則 CLI 會等到逾時。
            // 這裡不能再用 JSONEncoder（它剛剛就是失敗的那個）。
            return Data(#"{"protocol":1,"ok":false,"error":{"code":"INVALID_ARGUMENT","message":"回應編碼失敗"}}"#.utf8)
        }
    }
}

extension PackIssue {
    /// 送上 wire 的文字。`String(describing:)` 會印出 Swift 的 enum 字面
    /// （`frameCountMismatch(action: "run", declared: 8, found: 2)`），
    /// 那對使用者是天書，而且會隨著重構默默改變。
    var wireText: String {
        switch self {
        case .unsupportedSchemaVersion(let v): return "不支援的 schemaVersion：\(v)"
        case .invalidID(let id): return "pack id 不合法：\(id)（只能是 a-z、0-9、-）"
        case .idDirectoryMismatch(let id, let dir): return "pack id \(id) 與目錄名 \(dir) 不符"
        case .missingCoreActions(let a): return "缺少必要動作：\(names(a))"
        case .declaredActionMissingDirectory(let a): return "宣告了 \(a) 但沒有對應目錄"
        case .frameCountMismatch(let a, let declared, let found):
            return "\(a) 宣告 \(declared) 格，實際 \(found) 個檔案"
        case .invalidFrameCount(let a, let frames): return "\(a) 的格數不合法：\(frames)"
        case .invalidFPS(let a, let fps): return "\(a) 的 fps 不合法：\(fps)"
        case .inconsistentSizeWithinAction(let a): return "\(a) 各格尺寸不一致"
        case .undecodableImage(let path): return "PNG 解不開：\(path)"
        case .anchorOutOfRange(let x, let y): return "anchor 超出 0–1：(\(x), \(y))"
        case .logicalHeightOutOfRange(let h): return "logicalHeight 超出範圍：\(h)"
        case .undeclaredDirectory(let d): return "目錄 \(d) 沒有在 pack.json 宣告"
        case .unknownActionName(let a): return "不認得的動作名：\(a)"
        case .inconsistentSizeAcrossActions: return "不同動作之間的尺寸不一致"
        case .missingFlourishActions(let a): return "缺少點綴動作（會降級）：\(names(a))"
        case .missingTeaserActions(let a): return "缺少逗貓棒動作（該模式不可用）：\(names(a))"
        }
    }

    private func names(_ actions: [CatAction]) -> String {
        actions.map(\.rawValue).sorted().joined(separator: "、")
    }
}
