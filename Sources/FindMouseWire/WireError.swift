import Foundation

/// spec 第 8.5 節的錯誤碼。**rawValue 是對外契約**，AI 會把它寫死在腳本裡。
public enum WireErrorCode: String, Codable, Sendable, CaseIterable {
    case appNotRunning = "APP_NOT_RUNNING"
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
