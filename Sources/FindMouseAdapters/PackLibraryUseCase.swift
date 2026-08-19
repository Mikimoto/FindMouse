// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FindMouseCore
import FindMouseDomain
import FindMouseWire

/// 匯入與移除一套使用者 pack 的**完整決策鏈**，與入口無關。
///
/// 為什麼不住 Core：擋住的**不是** `PackValidator`／`PackVersion`／
/// `PackInstallDecision`——那些都住 `FindMouseDomain`，而 Core 的 import 允許清單
/// （`Foundation`／`CoreGraphics`／`FindMouseDomain`）含它。真正碰不到的是兩個：
/// `PackInstaller`（住 Adapters，實際動檔案的那支）與 `WireErrorCode`（住 Wire，
/// `failed` 那個 case 用它）。允許清單由 `ArchitectureBoundaryTests` 強制。
///
/// 為什麼不留在 `RequestRouter`：C-2 的另外兩個入口（設定視窗拖放、雙擊
/// `.fmpack`）不走 socket，把這四步留在 wire adapter 裡等於要它們各自重寫
/// 一次「id 取自 manifest → 值域 → 同 id 衝突 → 錯誤分類」，而漂掉的那一天
/// 症狀是「CLI 擋得住的東西 GUI 裝得進去」。
///
/// **回結構化的 outcome 而不是文字。** `needsConfirmation` 的處方每個入口都不同
/// （CLI 說「加 --force」、GUI 彈確認框），揉進訊息裡就沒有人能重用它。
public struct PackLibraryUseCase {

    /// 匯入的結果。**與移除各自一個型別**，不共用一個大的：共用的話兩邊都得處理
    /// 對方的 case，而 `install` 回不了 `removed`、`remove` 回不了
    /// `needsConfirmation`，那些分支只能寫成「內部錯誤」——一個永遠走不到、對使用者
    /// 毫無意義的訊息。拆開之後兩邊的 switch 都窮盡且沒有死分支。
    ///
    /// - `needsConfirmation`：同 id 已存在，**還沒動任何檔案**。`prompt` 是給人看的
    ///   問句，不含任何入口專屬的處方。
    /// - `failed`：帶 wire 錯誤碼，因為 CLI 那條路本來就要一個碼，而 GUI 只用訊息。
    public enum InstallOutcome: Equatable {
        case installed(id: String)
        case needsConfirmation(id: String, prompt: String)
        case failed(code: WireErrorCode, message: String)
    }

    public enum RemoveOutcome: Equatable {
        case removed(id: String)
        case failed(code: WireErrorCode, message: String)
    }

    private let packsDirectory: () -> URL
    private let installedPacks: () -> [PackSummary]

    /// - Parameter packsDirectory: 使用者 pack 的落腳處。注入而不是直接讀
    ///   `PackCatalogRepository.userPacksDirectory`——這支會真的寫檔案。
    /// - Parameter installedPacks: 當下掃得到的每一套（內建在前）。每次呼叫都重取，
    ///   不快取：使用者可能剛在 Finder 裡動過那個目錄。
    public init(packsDirectory: @escaping () -> URL,
                installedPacks: @escaping () -> [PackSummary]) {
        self.packsDirectory = packsDirectory
        self.installedPacks = installedPacks
    }

    // MARK: - 匯入

    /// - Parameter byteLimit: 解壓後的大小上限，直接往下傳給 `PackInstaller.install`。
    ///   **開成參數只為了測得到**——200MB 的預設值要用真的 200MB 素材才踩得到，
    ///   於是 `.tooLarge → .packTooLarge` 那條對應在沒有這個參數時等於零覆蓋。
    ///   呼叫端一律不傳。
    public func install(source: URL, force: Bool,
                        byteLimit: Int = PackInstaller.byteLimit) -> InstallOutcome {
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .failed(code: .packSourceInvalid, message: "找不到 \(source.path)。")
        }
        // **`fileExists` 過不代表讀得到。** 沙盒下容器外的路徑是
        // 「stat 成功、內容 EPERM」（2026-08-17 實測），於是後面那些步驟看到的是
        // 一個空目錄，回報「這個來源裡沒有 pack.json」——一句**與真相相反**的話：
        // 它說來源的內容不對，實際上是我們根本沒看到內容。
        //
        // 兩者的下一步完全不同（換一個來源／處理權限），所以在這裡分開。
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            return .failed(code: .packSourceInvalid,
                           message: "讀不到 \(source.path)（沒有權限）。"
                               + "從命令列匯入時請用 findmouse pack install，不要自己把路徑送進來；"
                               + "拖進設定視窗或雙擊 .fmpack 也可以。")
        }

        // id 取自 manifest 而不是檔名：spec 第 6.2 節要求 id 與目錄名一致，
        // 而檔名可以是任何東西（下載時被瀏覽器改名是常態）。
        let incomingID: String
        do {
            incomingID = try PackInstaller.manifestID(of: source)
        } catch let e as ExtractedTree.Failure {
            return .failed(code: .packSourceInvalid, message: Self.describe(e))
        } catch {
            return .failed(code: .packSourceInvalid,
                           message: "讀不出這個來源的 pack.json：\(error.localizedDescription)")
        }

        // id 會變成目的地的路徑組件，而它完全來自不受信任的 pack.json。
        //
        // **這道守衛守的是它的位置，不是錯誤碼。** 錯誤碼那個理由是假的（C-1 的
        // 註解這樣寫）——`PackInstaller.requireSafeID` 那道也回 packSourceInvalid，
        // 訊息更只差「（a-z 0-9 -）」與「（`[a-z0-9-]+`）」那一段。真正的理由是它
        // 站在**衝突決策之前**：`PackCatalogRepository.scan` 用 manifest 的 id 列
        // pack 而不是目錄名，所以一個 manifest id 為 `../victim` 的目錄會出現在
        // `installedPacks()` 裡（帶著 idDirectoryMismatch）。少了這一行，同 id 的
        // 來源會命中它而走到 needsConfirmation，那條路接著去讀
        // `packsDirectory()/../victim/pack.json`——`Packs` 外面。裡面那道攔得住
        // 寫入，攔不住這個讀取。釘住的是 anEscapingIDIsRejectedBeforeTheConflictDecision。
        guard PackValidator.isValidID(incomingID) else {
            return .failed(code: .packSourceInvalid,
                message: "pack.json 的 id「\(incomingID)」不合法。只能用小寫英數與連字號"
                       + "（a-z 0-9 -），因為它會被當成資料夾名稱。")
        }

        let existing = installedPacks().map {
            PackInstallDecision.Existing(id: $0.id, isBuiltIn: $0.isBuiltIn)
        }
        switch PackInstallDecision.decide(incomingID: incomingID,
                                          existing: existing, force: force) {
        case .rejectedIDReserved:
            return .failed(code: .packIDReserved,
                message: "「\(incomingID)」是內建圖組的 id，裝進去的那套永遠不會被載入"
                       + "（內建的優先）。請改一個 id——pack.json 的 id 要與目錄名一致。")

        case .needsConfirmation:
            // 讀不到版本不是錯誤（欄位是 optional），所以兩邊都用 `try?`。
            // 讀注入的目錄而不是問真實環境；走到這裡表示撞到的不是內建
            // （那條在上面回 rejectedIDReserved），所以要找的本來就在這裡。
            let installedVersion = (try? PackInstaller.manifestVersion(
                atPackDirectory: packsDirectory().appendingPathComponent(incomingID))) ?? nil
            let incomingVersion = (try? PackInstaller.manifestVersion(of: source)) ?? nil
            return .needsConfirmation(id: incomingID,
                prompt: PackVersion.replacementPrompt(packName: incomingID,
                                                      installed: installedVersion,
                                                      incoming: incomingVersion))

        case .install, .replace:
            do {
                try PackInstaller.install(source: source, id: incomingID,
                                          into: packsDirectory(), byteLimit: byteLimit)
            } catch let e as PackInstaller.Failure {
                // 型別分類決定錯誤碼；訊息一律用 Failure 自己的 errorDescription
                // （它是 LocalizedError），這樣 ditto 的 stderr 不會遺失。
                switch e {
                case .tooLarge: return .failed(code: .packTooLarge, message: e.localizedDescription)
                default:        return .failed(code: .packSourceInvalid,
                                               message: e.localizedDescription)
                }
            } catch let e as ExtractedTree.Failure {
                // **這一條只有 TOCTOU 走得到，所以沒有測試。** 上面的 `manifestID`
                // 已經對同一個來源跑過 `packRoot()` 與 `rejectIrregularEntries()`
                //（`PackInstaller.manifest(of:)` 內含那兩步），而 `install` 是**第二次**
                // 解壓——兩次之間來源被抽換掉才可能在這裡才炸。實測：把這行換掉
                // 是綠的，而那條 symlink 測試轉紅的是上面 manifest 那個 catch。
                //
                // 留著是因為少了它會落到下面的泛用 catch，而 `ExtractedTree.Failure`
                // 不是 `LocalizedError`，`localizedDescription` 會吐
                // 「The operation couldn't be completed.…」那串英文樣板。
                return .failed(code: .packSourceInvalid, message: Self.describe(e))
            } catch {
                return .failed(code: .packSourceInvalid, message: error.localizedDescription)
            }
            return .installed(id: incomingID)
        }
    }

    // MARK: - 移除

    /// - Parameter currentPackID: **實際跑著的**那一套。移除它一律拒絕，不自動切走：
    ///   `pack.use` 是排隊由 App 處理的，刪了目錄而 App 還在用它就掉進 spec 第 6.5 節
    ///   那條「執行期失效 → 靜默退回」的路。
    ///
    ///   **收 closure 而不是值**：`RequestRouter` 那邊它是 `status()`，而 `status()`
    ///   會列舉 `NSScreen.screens` 並查一次 `SMAppService`。收值的話每一次被拒絕的
    ///   移除（不存在的 id、內建、遮蔽）都白跑那些——舊的 router 版本是在最內層才
    ///   呼叫它的，收值會靜默改掉那個時機。
    /// - Parameter swapTarget: 已經請求換過去、但還沒換成功的那一套（沒有就回 nil）。
    ///   **`currentPackID()` 在那段空窗裡還是舊的**，所以沒有它就認不出目標——
    ///   刪掉之後換 pack 完成時目標已經不在磁碟上，`performSwap` 載不起來就留在
    ///   原本那套並在選單列掛一筆降級（spec 第 10 節）。不是靜默，但使用者剛下的
    ///   那個指令等於被吃掉。
    ///   守衛放這裡而不是只放設定視窗：CLI 的 `pack remove` 也走這條路。
    ///
    ///   **沒有預設值是刻意的。** 有預設值的話，漏傳就是「守衛關著」，而 2026-08-14
    ///   實測過那個組合完全沒有訊號：把 `= { nil }` 加回去、再刪掉 `AppDelegate`
    ///   那兩處接線（這一支的 `swapTarget:` 與 `RequestRouter.init` 的
    ///   `packSwapTarget:`），`swift build --product FindMouseApp` 成功、五個 target
    ///   全綠，而後果是空窗裡真的刪掉目標目錄。呼叫端寫 `{ nil }` 是一句「我知道
    ///   這裡沒有換 pack 這回事」的宣告。預設值本身由
    ///   `theSwapTargetWiringHasNoDefaultValue` 釘住（它的 doc 記了守不住的部分）。
    public func remove(id: String, currentPackID: () -> String,
                       swapTarget: () -> String?) -> RemoveOutcome {
        guard let summary = installedPacks().first(where: { $0.id == id }) else {
            return .failed(code: .packNotFound,
                           message: "沒有叫「\(id)」的圖組（用 pack list 看有哪些）。")
        }

        // **被內建遮蔽的使用者目錄要放行。** `scan` 用 seen set 去重且內建排在前面，
        // 所以同 id 時清單只報得出內建那一筆、`isBuiltIn` 為 true——而使用者目錄底下
        // 確實有一個拿得掉的東西。照 `isBuiltIn` 一律擋掉的話那種目錄永遠移除不了。
        // 放行不會碰到內建：`PackInstaller.remove` 只動 `packsDirectory()`。
        //
        // 這裡不重驗值域：組出來的路徑只餵給唯讀的 `fileExists`，而真正會刪東西的
        // `PackInstaller.remove` 自己驗（驗的是路徑組件，理由見它的 doc）。
        //
        // **不要在這裡寫「名稱不符的目錄只能怎麼來」**——寫過兩個版本都被反例
        // 推翻。來源與後果都在 CLAUDE.md 那條「目錄名與 `pack.json` 的 id 可以
        // 不一致」，那裡是唯一一份。
        //
        // 清單上這一列**實際住在哪個目錄**。回 nil 就退回「目錄名 == id」，而那條
        // 退路實際上只有遮蔽內建那種走得到（見 `sourceDirectoryName` 的 doc：
        // `pack.json` 讀不出來的目錄根本不會進清單）。
        let sourceName = PackCatalogRepository.sourceDirectoryName(
            forID: id, in: packsDirectory()) ?? id
        // 遮蔽判定也用它：目錄名與 id 不符時 `Packs/<id>` 根本不存在，
        // 只看 fileExists 會判成「沒有遮蔽」而落進「是內建圖組，拿不掉」，
        // 於是那個目錄從 GUI 與 CLI 都永遠拿不掉。
        let shadowsABuiltIn = summary.isBuiltIn && FileManager.default.fileExists(
            atPath: packsDirectory().appendingPathComponent(sourceName).path)
        if !shadowsABuiltIn {
            guard !summary.isBuiltIn else {
                return .failed(code: .packBuiltIn, message: "「\(id)」是內建圖組，拿不掉。")
            }
            // 被遮蔽的那種不必問：載入的是內建那一份，刪掉被遮蔽的目錄動不到它。
            guard currentPackID() != id else {
                return .failed(code: .packInvalid,
                    message: "「\(id)」正在使用中。請先換成別的圖組，再移除它。")
            }
            // 排在「正在使用中」**之後**：對著當前那一套再請求一次換過去時，
            // 兩個條件會同時成立（`request` 不管 id 是不是已經是當前那個），
            // 而那時使用者需要知道的是「它正在用」。
            guard swapTarget() != id else {
                return .failed(code: .packInvalid,
                    message: "「\(id)」正在切換過去，還不能移除。等它換好再試。")
            }
        }

        do {
            try PackInstaller.remove(directoryName: sourceName, from: packsDirectory())
        } catch let e as PackInstaller.Failure {
            // 走得到 invalidID，但**不是**因為 id 本身壞——那種現在會被
            // `sourceDirectoryName` 解析成真正的目錄名（實測：`Packs/weird` 宣告
            // id `../victim`，移除的是 weird，`Packs` 外面的 victim 完好）。
            // 剩下的路徑是「清單相對磁碟過時」：解析不到而退回的那個 id 恰好
            // 不是合法的路徑組件。
            return .failed(code: .packSourceInvalid, message: e.localizedDescription)
        } catch {
            return .failed(code: .packInvalid, message: "刪不掉：\(error.localizedDescription)")
        }
        return .removed(id: id)
    }

    // MARK: - 從沙盒之前的位置搬移

    /// 把使用者在**沙盒之前**放的圖組整批搬進容器。
    ///
    /// 為什麼要一支專門的：`install` 一次收一個來源，而舊目錄底下是一整批。
    /// 逐一走 `install` 是刻意的——每一套都得過同一組值域、衝突與錯誤分類
    /// （CLAUDE.md：匯入的判斷只有一份）。
    ///
    /// - Parameter source: 使用者在 `NSOpenPanel` 裡**選中**的那個目錄。授權跟著
    ///   這個 URL 走，所以呼叫端不可以改用自己組出來的等價路徑——沙盒下容器外是
    ///   「`stat` 成功、內容 EPERM」，那樣會安靜地搬出零套（2026-08-17 探針前提 1）。
    /// - Parameter legacyDirectory: 舊家的正規位置。**只**用來判斷要不要落下
    ///   「已經搬過」的記號：使用者在面板裡逛去別的地方時不落記號，那一列提示
    ///   才不會在他選錯資料夾之後永遠消失。
    /// - Returns: 直接回 Core 的型別。`install`／`remove` 之所以先回 Adapters 型別
    ///   再由 `AppDelegate` 翻譯，是因為 CLI 那條路需要 wire 錯誤碼；搬移沒有 CLI
    ///   入口（它要的是一個檔案面板），多一層只是多一份要同步的東西。
    public func migrate(from source: URL, legacyDirectory: URL) -> PackMigrationResult {
        var result = PackMigrationResult()

        // **列不出來就不要當成空的。**
        //
        // 用 `try?` 吃掉錯誤的話，「讀不到」與「這裡真的沒有圖組」給出同一句話
        // ——而下面那個記號**照樣會落下**。後果是這條路上最難救的一種：
        // `legacyPacksNeedMigration()` 從此永遠回 false，那一列提示再也不出現，
        // 一套都沒搬，而使用者收到的訊息是「這個資料夾裡沒有圖組」。他不會知道
        // 要去刪一個他不知道存在的記號。
        //
        // 所以列目錄失敗要當成一筆 skipped 並**直接返回**（跳過落記號那一步）。
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: source, includingPropertiesForKeys: [.isDirectoryKey])
        } catch {
            result.skipped.append(.init(
                name: source.lastPathComponent,
                reason: "讀不到這個資料夾（\(error.localizedDescription)）。"))
            return result
        }

        // 排序理由與 `PackCatalogRepository.scan` 同一條：`contentsOfDirectory`
        // 沒有順序保證，而搬移結果那句話會逐一列出 id。
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // 只看目錄。舊家底下的檔案（`.DS_Store`、使用者順手留的 zip）餵給
            // `install` 只會換來一句對他毫無意義的「這個來源裡沒有 pack.json」，
            // 而那會淹掉真正搬不成的那幾套。
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            switch install(source: entry, force: false) {
            case let .installed(id):
                result.installed.append(id)
            case let .needsConfirmation(id, _):
                // **不自動覆蓋。** 搬移是補救，不該把使用者已經裝在新家的那一套
                // 換成舊的——他要的話還有拖放那條路，而且那條會先問他。
                result.skipped.append(.init(name: entry.lastPathComponent,
                                            reason: "新家已經有一套「\(id)」了，沒有覆蓋它。"))
            case let .failed(_, message):
                result.skipped.append(.init(name: entry.lastPathComponent, reason: message))
            }
        }

        if source.standardizedFileURL == legacyDirectory.standardizedFileURL {
            markLegacyMigrationDone()
        }
        return result
    }

    /// 落下「已經走過搬移」的記號。理由在
    /// `PackCatalogRepository.migrationMarker(in:)`。
    ///
    /// 目錄可能還不存在（全新容器，而使用者一套都沒裝成功）。不建的話記號寫不進去，
    /// 那一列提示下次啟動又回來——而使用者剛剛明明處理過了。
    private func markLegacyMigrationDone() {
        let dir = packsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: PackCatalogRepository.migrationMarker(in: dir).path, contents: nil)
    }

    /// `ExtractedTree.Failure` → 繁中句子。訊息要講出「有幾套」這種數字，
    /// 「格式不對」讓人無從下手。
    static func describe(_ failure: ExtractedTree.Failure) -> String {
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
}
