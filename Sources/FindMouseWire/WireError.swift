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
