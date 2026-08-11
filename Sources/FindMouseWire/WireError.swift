// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// spec 第 8.5 節的錯誤碼。**rawValue 是對外契約**，AI 會把它寫死在腳本裡。
public enum WireErrorCode: String, Codable, Sendable, CaseIterable {
    case appNotRunning = "APP_NOT_RUNNING"
    /// 連上了，但對方沒有在期限內回應，或連線因為其他原因失敗。
    ///
    /// 與 `APP_NOT_RUNNING` 分開的理由是**腳本會拿 exit 3 去啟動 App**。
    /// App 卡住時回 3，腳本就會去開第二個實例——而第二實例偵測到有人在聽，
    /// 跳一個要人按的提示視窗，把「卡住」變成「卡住又多一個對話框」。
    case appNotResponding = "APP_NOT_RESPONDING"
    case protocolMismatch = "PROTOCOL_MISMATCH"
    case unknownCommand = "UNKNOWN_COMMAND"
    case invalidArgument = "INVALID_ARGUMENT"
    case packNotFound = "PACK_NOT_FOUND"
    case packInvalid = "PACK_INVALID"
    case teaserUnavailable = "TEASER_UNAVAILABLE"
    case configKeyUnknown = "CONFIG_KEY_UNKNOWN"
    case configValueOutOfRange = "CONFIG_VALUE_OUT_OF_RANGE"
    /// App 不在 `/Applications` 或 `~/Applications` 底下。`on` 與 `off` 都擋
    /// ——`off` 也擋是因為登入項目以 **bundle id** 為鍵（實測），從一份不合格
    /// 的拷貝關掉會連使用者正式安裝的那份一起關。
    case loginItemIneligible = "LOGIN_ITEM_INELIGIBLE"
    /// 已經註冊成功，但 macOS 還要使用者到系統設定按核准，現在不會啟動。
    case loginItemNeedsApproval = "LOGIN_ITEM_NEEDS_APPROVAL"
    /// `SMAppService` 的呼叫真的丟了例外。
    ///
    /// 不叫 `LOGIN_ITEM_NOT_FOUND`：`notFound` 那個狀態實測是「全新安裝、
    /// BTM 裡還沒有記錄」，是正常起點而不是失敗，所以沒有對應的錯誤碼。
    case loginItemRegisterFailed = "LOGIN_ITEM_REGISTER_FAILED"

    /// spec 第 8.5 節：3 與 1 分開，腳本才能區分「命令失敗」與「程式沒開」；
    /// 2 是用法錯誤（參數不對），與命令執行失敗也要分開。
    public var exitCode: Int32 {
        switch self {
        case .appNotRunning: return 3
        case .unknownCommand, .invalidArgument: return 2
        // 3 的語意是「去把它打開」。App 在跑只是沒回應，打開它沒有用，所以是 1。
        case .appNotResponding: return 1
        default: return 1
        }
    }
}

public struct WireError: Codable, Sendable, Equatable {
    public let code: WireErrorCode
    public let message: String
    /// 額外細節（例如 pack validate 的 errors 清單）。
    public let details: [String]?

    public init(code: WireErrorCode, message: String, details: [String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}
