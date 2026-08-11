// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

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

    /// 三個動詞。刻意**沒有 toggle**：`CLAUDE.md` 記過「toggle 不是幂等的，
    /// 腳本一律用方向明確的動詞」，再造一個同樣的陷阱沒有道理。
    public enum Command: Sendable, Equatable {
        case query
        case on
        case off
    }

    /// 要不要碰系統、碰哪一邊。
    ///
    /// 與 `exitCode` **分開**是刻意的：這讓「回 1 且沒有碰系統」變成一個
    /// 可斷言的事實，而不是只能從「沒看到副作用」去推論。
    public enum Effect: Sendable, Equatable {
        case none
        case register
        case unregister
    }

    /// 失敗的種類。結構化而不是字串——繁中句子在 `RequestRouter` 才組出來，
    /// 與 `PackValidator` 的錯誤同一個規矩。
    ///
    /// **沒有 `notFound`**：實測那是全新安裝的狀態，`decide` 對它回 `register`
    /// 而不是失敗。系統呼叫真的丟例外時由 Adapters 直接組
    /// `LOGIN_ITEM_REGISTER_FAILED`，不經過這個型別。
    public enum Failure: Sendable, Equatable {
        case ineligible
        case needsApproval
    }

    public struct Outcome: Sendable, Equatable {
        public let effect: Effect
        public let exitCode: Int
        public let failure: Failure?

        public init(effect: Effect, exitCode: Int, failure: Failure? = nil) {
            self.effect = effect
            self.exitCode = exitCode
            self.failure = failure
        }
    }

    /// 說明那一行要講哪一件事。結構化而不是字串：繁中句子由 App 組。
    ///
    /// **沒有 `notFound`**：那個狀態不需要說明，它就是「還沒開」。
    public enum Note: Sendable, Equatable {
        case mustBeInApplications
        case needsApproval
    }

    public struct Presentation: Sendable, Equatable {
        /// 勾要不要打。**只有 `enabled`**——`requiresApproval` 的項目不會在
        /// 開機時啟動，畫成打勾就是說謊。
        public let checked: Bool
        /// 勾能不能點。只有不合格才不能——不合格是唯一「使用者在這個視窗裡
        /// 做什麼都沒用」的狀態。
        public let interactive: Bool
        public let note: Note?
    }

    public static func presentation(for state: State) -> Presentation {
        switch state {
        case .enabled:
            return Presentation(checked: true, interactive: true, note: nil)
        // notFound 與 notRegistered 長得一模一樣。2026-08-11 實測：notFound
        // 是全新安裝的狀態，畫成「灰掉＋找不到」等於把最正常的情境畫成壞掉。
        case .notRegistered, .notFound:
            return Presentation(checked: false, interactive: true, note: nil)
        case .requiresApproval:
            return Presentation(checked: false, interactive: true, note: .needsApproval)
        case .ineligible:
            return Presentation(checked: false, interactive: false, note: .mustBeInApplications)
        }
    }

    /// 那張 5×3 的表。
    ///
    /// `on` 在 `requiresApproval` 下回 1 是刻意的 fail-closed：`register()`
    /// 確實成功了，但使用者要的結果（開機會啟動）沒有達成，而
    /// `login-item on && …` 這種寫法在回 0 之下會誤判。完整狀態由
    /// `status --json` 的 `loginItem.state` 承載。
    public static func decide(_ command: Command, from state: State) -> Outcome {
        switch command {
        case .query:
            return Outcome(effect: .none, exitCode: 0)

        case .on:
            switch state {
            case .ineligible:       return Outcome(effect: .none, exitCode: 1, failure: .ineligible)
            // notFound 與 notRegistered 走同一條路。2026-08-11 實測：notFound
            // 是全新安裝的狀態，register() 從那裡呼叫是成功的。讓它回 1 會
            // 擋掉最主要的使用情境。若那個 app 真的壞了，register() 會丟例外，
            // 使用者走到有說明的錯誤路徑——比事先一律拒絕安全。
            case .notRegistered,
                 .notFound:         return Outcome(effect: .register, exitCode: 0)
            case .enabled:          return Outcome(effect: .none, exitCode: 0)
            case .requiresApproval: return Outcome(effect: .none, exitCode: 1, failure: .needsApproval)
            }

        case .off:
            switch state {
            // 以 bundle id 為鍵（2026-08-11 實測）：從這裡 unregister 會把使用者
            // 裝在 /Applications 那份一起關掉（實測確認：那份從 enabled 變成
            // notRegistered），而我們同時把狀態顯示成 ineligible——在沒有誠實
            // 顯示的狀態上做破壞性操作，不行。
            case .ineligible:       return Outcome(effect: .none, exitCode: 1, failure: .ineligible)
            // notFound 不呼叫 unregister：實測對它呼叫會丟
            // SMAppServiceErrorDomain Code=1 "Operation not permitted"。
            case .notRegistered,
                 .notFound:         return Outcome(effect: .none, exitCode: 0)
            case .enabled:          return Outcome(effect: .unregister, exitCode: 0)
            case .requiresApproval: return Outcome(effect: .unregister, exitCode: 0)
            }
        }
    }
}
