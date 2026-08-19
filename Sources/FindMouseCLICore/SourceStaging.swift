// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FindMouseWire

/// 把「App 要自己去讀的路徑」先搬進 App 的沙盒容器。
///
/// **為什麼需要這一層。** `pack install` 與 `pack validate` 都是 CLI 把一個路徑
/// 字串用 socket 遞過去、App 自己去開。雙擊與拖放之所以在沙盒下仍然可行，是因為
/// LaunchServices 與拖放各自發了一張 sandbox extension；**CLI 遞過來的字串什麼
/// 都沒有**（2026-08-17 實測：來源在容器外回 `PACK_SOURCE_INVALID`，同一套 pack
/// 放進容器就成功）。
///
/// 修法選了「CLI 先複製進容器」而不是「把 bytes 串過 socket」：wire 是一行一個
/// JSON，多 MB 的 zip 要 base64 進去，等於為了一個入口改掉整個協定的形狀。
/// CLI 不沙盒，寫得進容器，所以複製這條便宜得多。
///
/// 這個型別放**判斷**（哪些請求要搬、該不該搬、搬去哪、搬完之後的請求長什麼樣）——
/// 真的複製與刪除在 `main.swift`，那裡沒有測試，所以能推進來的都推進來。
/// `shouldStage` 會問檔案系統，但只問不改，所以照樣測得到。
public enum SourceStaging {

    /// 帶著「App 會自己去讀」的路徑的命令。
    ///
    /// **這是一份清單，不是一個模式**——`pack.use` 也有 `id` 參數但那不是路徑，
    /// 而 `config.set` 的值可以長得像路徑卻不是。加新命令時要回來想一次：
    /// 「App 會拿這個字串去開檔案嗎？」
    public static let commandsCarryingASourcePath: Set<String> = [
        "pack.install",
        "pack.validate",
    ]

    /// 這個請求要搬的路徑，不必搬就回 nil。
    public static func sourcePath(of request: WireRequest) -> String? {
        guard commandsCarryingASourcePath.contains(request.command) else { return nil }
        return request.args["path"]
    }

    /// 這個來源該不該搬。三個條件缺一不可。
    ///
    /// **「讀不到就不搬」是契約的一部分，不是效能考量。** 搬的話 `copyItem` 會拋，
    /// 於是「沒有權限」變成「複製失敗」而 CLI 回 `PACK_SOURCE_INVALID`（exit 1）
    /// ——但 spec 第 8.5 節把 `pack validate` 的「路徑不存在**或無法讀取**」定為 2，
    /// App 端的 `RequestRouter.packValidate` 也正是那樣回答的。staging 是運輸機制，
    /// 讓它自己發明分類，同一個來源就會因為「有沒有被搬」而拿到兩種 exit code。
    ///
    /// **容器不存在時也不搬**：容器由系統在 App 首次啟動時建立，不存在就代表這台
    /// 機器沒跑過沙盒版的 FindMouse，那時該回的是 APP_NOT_RUNNING（送出去自然會
    /// 拿到），而不是自己造一個 containermanagerd 不認得的目錄。
    ///
    /// `isReadableFile` 只問最上層那一個路徑，所以「目錄讀得到、裡面某個檔案讀不到」
    /// 仍然會走到複製失敗那條。那一種**真的是複製失敗**，講成複製失敗沒有說謊。
    public static func shouldStage(source: String, containerData: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: source)
            && fm.isReadableFile(atPath: source)
            && fm.fileExists(atPath: containerData)
    }

    // **這一層刻意不擋「來源太大」。**
    //
    // 代價是真的：staging 先複製再問，而 App 的 `install` 先讀 `pack.json` 才動
    // 任何檔案，所以 `pack install ~/Movies` 這種手滑在 App 那邊是即刻拒絕，
    // 在這裡卻會遞迴複製整個資料夾。
    //
    // 試過在這裡加一道上限，量整棵樹——**那個守衛會拒絕 App 會接受的來源**：
    // `PackInstaller.install` 只量 `installableEntries(under: packRoot)`，夾帶的
    // 大檔案刻意不計（`aStrayOutsideThePackRootDoesNotCountTowardTheLimit` 釘住
    // 那個方向），而 `pack.validate` 那條路根本沒有上限。要在這裡量對，等於把
    // packRoot 的判定整套搬進 CLI。
    //
    // 保守估計的代價必須是多做一次無害的事，不能是拒絕合法輸入。所以寧可留著這個
    // 手滑代價，也不要一個會擋掉真 pack 的守衛——複製失敗或裝不成時 staging 目錄
    // 都會被刪掉，磁碟不會永久被佔住。

    /// 換掉路徑之後的請求。其餘欄位原樣保留（`--force` 就住在那裡面）。
    public static func rewritten(_ request: WireRequest, sourcePath: String) -> WireRequest {
        var args = request.args
        args["path"] = sourcePath
        // protocolVersion 一起帶過去：這是同一個請求換了路徑，不是新的請求。
        return WireRequest(protocolVersion: request.protocolVersion,
                           command: request.command, args: args)
    }

    /// 複本要用的檔名，來源的最後一段不是一個檔名就回 nil。
    ///
    /// **`lastPathComponent` 不保證是檔名。** `URL(fileURLWithPath: "/a/b/..")`
    /// 的最後一段就是 `".."`（2026-08-19 實測），接到 staging 目錄後面會指到它的
    /// **上一層**——也就是所有 CLI 共用的 `<container>/Data/tmp`。
    ///
    /// 那條路目前每一次都乾淨失敗，但原因是 `tmp` 一定已經被 `createDirectory`
    /// 建出來了、而 `copyItem` 對既有目的地一律拋：**靠巧合而不是靠設計**，
    /// 而且使用者拿到的是一句與真相無關的「File exists」。
    ///
    /// 驗的條件與 `PackInstaller.remove` 那道一樣（它同樣是「名字直接變成路徑
    /// 組件」的處境）：擋 `..` 與含 `/` 的是怕跑到別的地方，擋 `""` 與 `"."`
    /// 是因為它們會讓路徑指回**目錄自己**。
    public static func stagedFileName(for source: String) -> String? {
        let name = URL(fileURLWithPath: source).lastPathComponent
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".."
        else { return nil }
        return name
    }

    /// staging 目錄。**帶 pid 是為了讓收拾判得出「哪些是別人的」**——
    /// 同時跑兩個 CLI 不該互相刪。
    public static func stagingDirectory(container: String, pid: Int32) -> String {
        "\(container)/tmp/\(stagingPrefix)\(pid)"
    }

    /// 掃除舊 staging 時用的前綴。CLI 半途被殺就沒有人收拾（與 CLAUDE.md 記的
    /// `<id>.incoming` 同一類：清除點都在正常路徑上，SIGKILL 一個都不會跑），
    /// 所以下一次啟動要順手掃掉**不是自己的**那些。
    public static let stagingPrefix = "fm-cli-"

    /// 從 staging 目錄名解出 pid。不是我們的格式就回 nil。
    ///
    /// **只接受自己造得出來的形狀。** 唯一的產生者是 `getpid()`，所以那個形狀就是
    /// 「十進位、大於 0、沒有前導零、沒有正負號」。判準寫成 `String(pid) == digits`
    /// 而不是逐字元檢查：來回一致一次涵蓋 `-1`、`+5`、`0001` 與任何前導零，
    /// 而且下次 `Int32(_:)` 又多接受一種寫法時它不必跟著改。
    ///
    /// **這條守的是契約，不是掃除效果。** 逐行重現掃除迴圈實測（2026-08-19）：
    ///
    /// | 目錄名 | 寬鬆解析 | 嚴格解析 |
    /// |---|---|---|
    /// | `fm-cli-0` | 留著（`kill(0,0)` 回 0） | 留著（解不出 pid） |
    /// | `fm-cli-0001` | 留著（`kill(1,0)` 是 EPERM，不是 ESRCH） | 留著 |
    /// | `fm-cli-01234`（死 pid） | **刪掉** | 留著 |
    ///
    /// 也就是說嚴格化一個都沒讓「掃得掉」，反而少掃一種。換到的是別的東西：
    /// `Int32(_:)` 會把 `-1` 交出來當 pid，而這個值唯一的用途是餵給 `kill`。
    /// 現在的呼叫端送信號 0（只做存在性檢查）所以無害，但下一個人把它改成真的
    /// 信號時，`kill(-1, …)` 是「送給所有送得到的 process」——那個地雷值得現在拆。
    ///
    /// **不是我們造的那些目錄仍然沒有人清。** 要收那個缺口得換一種判準（例如
    /// mtime 夠舊就掃），不在這支的職責裡。
    public static func pid(ofStagingDirectoryNamed name: String) -> Int32? {
        guard name.hasPrefix(stagingPrefix) else { return nil }
        let digits = String(name.dropFirst(stagingPrefix.count))
        guard let pid = Int32(digits), pid > 0, String(pid) == digits else { return nil }
        return pid
    }
}
