import Foundation

/// 「開機時啟動」的純邏輯。碰系統的部分在 Adapters 的 `LoginItemGateway`。
///
/// 這一層之所以存在：狀態有五個、命令有三個，那張 15 格的表是唯一會出錯的地方，
/// 而它完全不需要碰 `SMAppService` 就能窮舉。
public enum LoginItem {

    /// 五個狀態。後四個對應 `SMAppService.Status`，`ineligible` 是我們加的。
    ///
    /// `ineligible` **優先於**系統狀態：App 不在穩定位置時我們連問都不問系統，
    /// 因為註冊下去的會是一個隨時會消失的路徑。
    public enum State: String, Sendable, Equatable, CaseIterable {
        case ineligible
        case notRegistered
        case enabled
        case requiresApproval
        /// BTM 裡沒有記錄。**這是全新安裝的狀態，不是壞掉**——2026-08-11 用探針
        /// 實測：從未註冊過的 app 讀到的是這個而不是 `notRegistered`，而
        /// `register()` 從這裡呼叫是成功的。行為上與 `notRegistered` 等價，
        /// 保留成獨立的 case 只是為了讓 `status --json` 如實呈現系統回的值。
        case notFound
    }

    /// App 在不在一個「值得註冊」的位置。
    ///
    /// 比對**路徑元件**而不是字串前綴：`hasPrefix("/Applications")` 會把
    /// `/ApplicationsFoo` 判成合格。
    ///
    /// - Parameter url: 已經解過 symlink 的 bundle URL。解析會碰磁碟，
    ///   所以那一步留在 Adapters，這裡只做純比對。
    /// - Parameter roots: 視為穩定的根目錄，通常是 `/Applications` 與
    ///   `~/Applications`。
    public static func isEligibleLocation(_ url: URL, under roots: [URL]) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        return roots.contains { root in
            let rootParts = root.standardizedFileURL.pathComponents
            // 必須**嚴格**長於根目錄：路徑等於根目錄本身時，那不是一個 app
            guard parts.count > rootParts.count else { return false }
            return Array(parts.prefix(rootParts.count)) == rootParts
        }
    }
}
