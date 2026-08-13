// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

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

    private let control: () -> ControlUseCase
    private let settings: () -> SettingsUseCase
    private let status: () -> StatusPayload
    private let packs: () -> [PackSummary]
    private let usePack: (String) -> Void
    private let onSettingsChanged: () -> Void
    private let packsDirectory: () -> URL
    private let loginItem: LoginItemGateway

    /// - Parameter control: 當下的命令佇列。**每次呼叫都重取，不在 init 綁死**——
    ///   換 pack 會連 `ControlUseCase` 一起換掉（它的 `catalog` 是 `private let`），
    ///   而綁死的那一份會變成沒有人排空的孤兒佇列：`findmouse summon` 回 ok、
    ///   命令進了佇列、貓永遠不出現。M3 的 `wakeIfWorkPending` 就是同一個形狀的 bug。
    /// - Parameter settings: 當下的設定。同樣不綁死——`SettingsUseCase` 持有
    ///   pack 的 catalog，`arrive.radius` 的衍生預設要用它的 `logicalHeight`。
    /// - Parameter status: 產生當下狀態的快照。注入而不是自己算：
    ///   它需要 `CatFrameState`、螢幕清單與 pack 資訊，那些都住在 App 層。
    /// - Parameter packs: 當下掃得到的 pack。每次呼叫都重掃，不快取：
    ///   使用者把 pack 丟進目錄之後不該還要重開 App 才看得到。
    /// - Parameter usePack: 換 pack 的請求交給誰。**router 不自己換**——
    ///   換一套 pack 要一起換掉 App 那七個從 pack 衍生出來的持有者，
    ///   而 router 一個都碰不到。與 `status` 注入快照是同一個模式。
    /// - Parameter onSettingsChanged: 設定**真的變了**之後通知一次。今天只有
    ///   `hotkey.*` 需要它（M4 Task 8：改了不必重啟就生效），但這裡刻意不帶 key
    ///   ——「哪些 key 改了要做什麼」是 App 的政策，router 只知道「有東西變了」。
    ///   **失敗的 set 不會呼叫它**：值域擋下的寫入沒有改變任何東西，通知了只會讓
    ///   App 白白重新註冊一次快捷鍵（那期間快捷鍵是不存在的）。
    /// - Parameter loginItem: 開機啟動的系統面。**注入而不是自己 new**——
    ///   `SystemLoginItem` 會去問 `SMAppService`，而 router 的測試不該碰系統。
    /// - Parameter packsDirectory: 使用者 pack 的落腳處。**注入而不是直接用
    ///   `PackCatalogRepository.userPacksDirectory`**——`pack.install` 會真的寫檔案，
    ///   而單元測試不該寫進使用者真正的 pack 目錄。給了預設值，所以既有呼叫點
    ///   一個字都不用改。
    public init(control: @escaping () -> ControlUseCase,
                settings: @escaping () -> SettingsUseCase,
                status: @escaping () -> StatusPayload,
                packs: @escaping () -> [PackSummary],
                usePack: @escaping (String) -> Void,
                onSettingsChanged: @escaping () -> Void,
                packsDirectory: @escaping () -> URL = { PackCatalogRepository.userPacksDirectory },
                loginItem: LoginItemGateway) {
        self.control = control
        self.settings = settings
        self.status = status
        self.packs = packs
        self.usePack = usePack
        self.onSettingsChanged = onSettingsChanged
        self.packsDirectory = packsDirectory
        self.loginItem = loginItem
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
        case "pack.install":  return packInstall(request.args)
        case "pack.remove":   return packRemove(request.args)
        case "login-item.status": return loginItemCommand(.query)
        case "login-item.on":     return loginItemCommand(.on)
        case "login-item.off":    return loginItemCommand(.off)
        default:
            return encode(WireResponse<AckPayload>(error: WireError(
                code: .unknownCommand, message: "未知命令：\(request.command)")))
        }
    }

    // MARK: - 命令

    /// 開機啟動。決策全在 `LoginItem.decide`（Domain，有窮舉測試），
    /// 這裡只負責照它說的碰系統、把結構化的失敗翻成繁中句子。
    private func loginItemCommand(_ command: LoginItem.Command) -> Data {
        let before = loginItem.state
        let outcome = LoginItem.decide(command, from: before)

        // 先做副作用，再重讀狀態。**不能假設 register() 成功就等於 enabled**
        // ——requiresApproval 正是「呼叫成功但結果不是你要的」。
        do {
            switch outcome.effect {
            case .none:       break
            case .register:   try loginItem.register()
            case .unregister: try loginItem.unregister()
            }
        } catch {
            // 訊息要分方向。走得到 .unregister 表示狀態是 enabled 或
            // requiresApproval，而兩者都已經通過合格性閘門——App **必然**已經
            // 在「應用程式」資料夾裡，這時叫人把它拖進去是可證明無用的建議。
            let advice = outcome.effect == .unregister
                ? "關閉開機啟動時失敗了：\(error.localizedDescription)。"
                    + "到「系統設定 → 一般 → 登入項目」可以直接關掉它。"
                : "跟 macOS 註冊開機啟動時失敗了：\(error.localizedDescription)。"
                    + "把 FindMouse 重新拖進「應用程式」資料夾再試一次。"
            return encode(WireResponse<LoginItemPayload>(
                error: WireError(code: .loginItemRegisterFailed, message: advice)))
        }

        let after = loginItem.state
        // 副作用之後要重新判一次：register() 之後可能落在 requiresApproval，
        // 那時該回的是 1 而不是 outcome 當初算的 0。
        let final = outcome.effect == .none
            ? outcome
            : LoginItem.decide(command, from: after)

        if let failure = final.failure {
            return encode(WireResponse<LoginItemPayload>(
                error: WireError(code: code(for: failure),
                                 message: message(for: failure))))
        }
        // register 跑完之後狀態若沒動，代表呼叫沒丟例外但也沒達成——那是
        // 「成功了但沒達成」，不能回 0，否則 `login-item on && …` 會誤判。
        //
        // **只罩 register，不罩 unregister。** 這條的依據是「register() 立刻
        // 反映」那個實測，而它只量過 register。unregister 之後狀態會回報什麼
        // 沒有量過——`requiresApproval` 那格的 BTM 記錄從來沒有被 allow 過，
        // 取消之後很可能仍讀到 requiresApproval，那時這條會把一個成功的操作
        // 判成失敗，而決策表明文寫它回 0。要擴到 unregister 就得先量那兩格。
        if outcome.effect == .register && final.effect == .register {
            return encode(WireResponse<LoginItemPayload>(error: WireError(
                code: .loginItemRegisterFailed,
                message: "跟 macOS 註冊時沒有回報錯誤，但開機啟動仍然沒有生效。"
                       + "到「系統設定 → 一般 → 登入項目」看一下 FindMouse 的狀態。")))
        }
        return encode(WireResponse(data: LoginItemPayload(state: after.rawValue)))
    }

    private func code(for failure: LoginItem.Failure) -> WireErrorCode {
        switch failure {
        case .ineligible:    return .loginItemIneligible
        case .needsApproval: return .loginItemNeedsApproval
        }
    }

    /// 每一句都要講「接下來能做什麼」（`CLAUDE.md` 的規範）。
    private func message(for failure: LoginItem.Failure) -> String {
        switch failure {
        case .ineligible:
            return "FindMouse 要放在「應用程式」資料夾裡才能設定開機啟動。"
                 + "把它拖進去之後從那裡打開，再試一次。"
                 + "（若你已經裝好了一份，請到那一份去改——登入項目是以 App 的"
                 + "識別碼為準，從這一份改會動到那一份。）"
        case .needsApproval:
            return "已經跟 macOS 註冊了，但還要你核准才會生效："
                 + "打開「系統設定 → 一般 → 登入項目」，把 FindMouse 打開。"
        }
    }

    private func enqueue(_ command: Command, named name: String) -> Data {
        do {
            try control().enqueue(command)
            return encode(WireResponse(data: AckPayload(queued: name)))
        } catch {
            return encode(WireResponse<AckPayload>(error: wireError(for: error)))
        }
    }

    /// 不給 key 就回全部。`getAll()` 已經照字典序排好。
    private func configGet(_ args: [String: String]) -> Data {
        guard let key = args["key"] else {
            return encode(WireResponse(data: ConfigPayload(
                entries: settings().getAll().map { .init(key: $0.key, value: $0.value) })))
        }
        do {
            return encode(WireResponse(data: ConfigPayload(
                entries: [.init(key: key, value: try settings().get(key))])))
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
            try settings().set(key, to: value)
            onSettingsChanged()
            return encode(WireResponse(data: ConfigPayload(
                entries: [.init(key: key, value: try settings().get(key))])))
        } catch {
            return encode(WireResponse<ConfigPayload>(error: wireError(for: error)))
        }
    }

    private func configReset(_ args: [String: String]) -> Data {
        if args["all"] == "true" {
            settings().resetAll()
            onSettingsChanged()
            return encode(WireResponse(data: ConfigPayload(
                entries: settings().getAll().map { .init(key: $0.key, value: $0.value) })))
        }
        guard let key = args["key"] else {
            return encode(WireResponse<ConfigPayload>(error: WireError(
                code: .invalidArgument, message: "config.reset 需要 key 或 all=true")))
        }
        do {
            try settings().reset(key)
            // `reset` 與 `set` 是兩條路，只接一條的話「改壞了想 reset 回來」
            // 會失效——而那正是使用者最需要它當場生效的時刻。
            onSettingsChanged()
            return encode(WireResponse(data: ConfigPayload(
                entries: [.init(key: key, value: try settings().get(key))])))
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

    // MARK: - 匯入與移除（分發 C）

    private func fail(_ code: WireErrorCode, _ message: String) -> Data {
        encode(WireResponse<AckPayload>(error: WireError(code: code, message: message)))
    }

    /// 裝一套 pack。**檔案 I/O 同步做**：它不碰 UI 也不需要 main actor，
    /// 與 `pack.use` 那條排隊路徑不同（那個要換掉 App 的七個持有者）。
    private func packInstall(_ args: [String: String]) -> Data {
        guard let path = args["path"] else {
            return fail(.invalidArgument, "pack install 要一個路徑")
        }
        let source = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return fail(.packSourceInvalid, "找不到 \(path)。")
        }

        // id 取自 manifest 而不是檔名：spec 第 6.2 節要求 id 與目錄名一致，
        // 而檔名可以是任何東西（下載時被瀏覽器改名是常態）。
        let incomingID: String
        do {
            incomingID = try PackInstaller.manifestID(of: source)
        } catch let e as ExtractedTree.Failure {
            return fail(.packSourceInvalid, describe(e))
        } catch {
            return fail(.packSourceInvalid,
                        "讀不出這個來源的 pack.json：\(error.localizedDescription)")
        }

        // id 會變成目的地的路徑組件，而它完全來自不受信任的 pack.json。
        // `PackInstaller` 內部也擋（縱深），這裡先擋是為了給出對的錯誤碼與訊息，
        // 而且**在問衝突決策之前**——一個 `../victim` 這種 id 連比對都不該進行。
        guard PackValidator.isValidID(incomingID) else {
            return fail(.packSourceInvalid,
                "pack.json 的 id「\(incomingID)」不合法。只能用小寫英數與連字號"
                + "（a-z 0-9 -），因為它會被當成資料夾名稱。")
        }

        let existing = packs().map {
            PackInstallDecision.Existing(id: $0.id, isBuiltIn: $0.isBuiltIn)
        }
        switch PackInstallDecision.decide(incomingID: incomingID,
                                          existing: existing,
                                          force: args["force"] == "true") {
        case .rejectedIDReserved:
            return fail(.packIDReserved,
                "「\(incomingID)」是內建圖組的 id，裝進去的那套永遠不會被載入"
                + "（內建的優先）。請改一個 id——pack.json 的 id 要與目錄名一致。")

        case .needsConfirmation:
            // 訊息帶上兩邊的版本。這是 `PackVersion.replacementPrompt` 的消費者。
            // 讀不到版本不是錯誤（欄位是 optional），所以兩邊都用 `try?`。
            //
            // 讀**注入的**那個目錄，不走 `PackCatalogRepository.currentDirectory(for:)`
            // ——後者去問真實環境，於是單元測試會在這一行讀到使用者真正的 Packs
            // 目錄，與 `packsDirectory` 注入的理由直接牴觸。走到這裡表示撞到的不是
            // 內建（那條在上面回 rejectedIDReserved），所以要找的本來就在這個目錄裡；
            // id 也已經在上面驗過值域。
            let installedVersion = (try? PackInstaller.manifestVersion(
                atPackDirectory: packsDirectory().appendingPathComponent(incomingID))) ?? nil
            let incomingVersion = (try? PackInstaller.manifestVersion(of: source)) ?? nil
            let prompt = PackVersion.replacementPrompt(packName: incomingID,
                                                       installed: installedVersion,
                                                       incoming: incomingVersion)
            return fail(.packAlreadyInstalled, prompt + "要覆蓋請加 --force。")

        case .install, .replace:
            do {
                try PackInstaller.install(source: source, id: incomingID,
                                          into: packsDirectory())
            } catch let e as PackInstaller.Failure {
                // 型別分類決定錯誤碼；訊息一律用 Failure 自己的 errorDescription
                // （它是 LocalizedError），這樣 ditto 的 stderr 不會遺失。
                switch e {
                case .tooLarge: return fail(.packTooLarge, e.localizedDescription)
                default:        return fail(.packSourceInvalid, e.localizedDescription)
                }
            } catch let e as ExtractedTree.Failure {
                return fail(.packSourceInvalid, describe(e))
            } catch {
                return fail(.packSourceInvalid, error.localizedDescription)
            }
            return encode(WireResponse(data: AckPayload(queued: "pack.install")))
        }
    }

    /// 移除一套使用者 pack。
    ///
    /// **當前使用中的那套一律拒絕**，不自動切走。`pack.use` 是排隊由 App 處理的
    /// （回 `queued`），所以「切回內建」在這支回應時還沒發生——刪了目錄而 App 還在
    /// 用它，就掉進 spec 第 6.5 節那條「執行期失效 → 靜默退回」的路。要正確等待就得
    /// 把佇列完成的訊號接出來，那是為了省使用者一步而引入非同步協調。
    private func packRemove(_ args: [String: String]) -> Data {
        guard let id = args["id"] else {
            return fail(.invalidArgument, "pack remove 要一個 id")
        }
        guard let summary = packs().first(where: { $0.id == id }) else {
            return fail(.packNotFound, "沒有叫「\(id)」的圖組（用 pack list 看有哪些）。")
        }
        // **被內建遮蔽的使用者目錄要放行。** `scan` 用 seen set 去重且內建排在
        // 前面，所以同 id 時 `packs()` 只報得出內建那一筆、`isBuiltIn` 為 true
        // ——而使用者目錄底下確實有一個拿得掉的東西。照 `isBuiltIn` 一律擋掉的話
        // 那種目錄**永遠移除不了**（正是 `PACK_ID_RESERVED` 要防的狀態，但既存的
        // 解不掉，因為那個守衛是後來才加的）。放行不會碰到內建：`remove` 只動
        // `packsDirectory()`。
        //
        // 這裡不重驗 id 的值域：組出來的路徑只餵給唯讀的 `fileExists`，而真正
        // 會刪東西的 `PackInstaller.remove` 自己 `requireSafeID`。多驗一次沒有
        // 任何可觀測的差別——那種擋不出東西的守衛不留。
        //
        // 判定用的是「目錄名 == id」，而 `scan` 去重用的是 **manifest 的 id**，
        // 兩者只在目錄名與 id 一致時等價。不一致的那種遮蔽目錄仍然移除不了，
        // 但 `install` 一律以 id 命名目錄，所以那種目錄只可能是手動放進去的。
        let shadowsABuiltIn = summary.isBuiltIn && FileManager.default.fileExists(
            atPath: packsDirectory().appendingPathComponent(id).path)
        if !shadowsABuiltIn {
            guard !summary.isBuiltIn else {
                return fail(.packBuiltIn, "「\(id)」是內建圖組，拿不掉。")
            }
            // 用 `status().pack.id`——`packList` 判斷 `current` 也是這個來源，
            // 兩處共用同一個才不會出現「status 說在用 A、remove 說 A 不是當前」。
            //
            // 被遮蔽的那種不必問：載入的是內建那一份，刪掉被遮蔽的目錄動不到它。
            guard status().pack.id != id else {
                return fail(.packInvalid,
                    "「\(id)」正在使用中。請先 pack use 換成別的圖組，再移除它。")
            }
        }
        do {
            try PackInstaller.remove(id: id, from: packsDirectory())
        } catch let e as PackInstaller.Failure {
            // 走得到 invalidID：id 來自呼叫端，而 `pack list` 若曾列出一個壞 id
            // （目錄名合法但 manifest 不合法），使用者會照著它打。
            return fail(.packSourceInvalid, e.localizedDescription)
        } catch {
            return fail(.packInvalid, "刪不掉：\(error.localizedDescription)")
        }
        return encode(WireResponse(data: AckPayload(queued: "pack.remove")))
    }

    /// `ExtractedTree.Failure` → 繁中句子。訊息要講出「有幾套」這種數字，
    /// 「格式不對」讓人無從下手。
    private func describe(_ failure: ExtractedTree.Failure) -> String {
        switch failure {
        case .noManifest:
            return "這個來源裡沒有 pack.json，不是一套 sprite pack。"
        case .multiplePacks(let roots):
            return "這個來源裡有 \(roots.count) 套 pack（\(roots.joined(separator: "、"))），"
                 + "一次只能裝一套。"
        case .notARegularFile(let path):
            return "「\(path)」不是普通檔案（可能是連結）。pack 只該有 PNG 與 pack.json。"
        }
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
