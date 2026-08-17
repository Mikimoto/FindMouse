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
/// 這個型別只放**純函式**（哪些請求要搬、搬去哪、搬完之後的請求長什麼樣）——
/// 真的複製與刪除在 `main.swift`，那裡沒有測試，所以能推進來的都推進來。
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

    /// 換掉路徑之後的請求。其餘欄位原樣保留（`--force` 就住在那裡面）。
    public static func rewritten(_ request: WireRequest, sourcePath: String) -> WireRequest {
        var args = request.args
        args["path"] = sourcePath
        // protocolVersion 一起帶過去：這是同一個請求換了路徑，不是新的請求。
        return WireRequest(protocolVersion: request.protocolVersion,
                           command: request.command, args: args)
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
    public static func pid(ofStagingDirectoryNamed name: String) -> Int32? {
        guard name.hasPrefix(stagingPrefix) else { return nil }
        return Int32(name.dropFirst(stagingPrefix.count))
    }
}
