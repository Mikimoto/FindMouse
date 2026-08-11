// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一行一個 JSON，request → response → 關閉連線（spec 第 8.2 節）。
///
/// `args` 刻意用 `[String: String]` 而不是任意 JSON：所有命令的參數都是
/// 從命令列來的字串，型別轉換與值域檢查是 `SettingsUseCase` 的責任。
/// 用 `Any` 會讓「42」與 42 變成兩種情況，而 CLI 那一端只有字串。
public struct WireRequest: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let command: String
    public let args: [String: String]

    public init(protocolVersion: Int = WireProtocol.version,
                command: String, args: [String: String] = [:]) {
        self.protocolVersion = protocolVersion
        self.command = command
        self.args = args
    }

    /// 對外的鍵是 "protocol"。Swift 不能用 `protocol` 當屬性名，
    /// 所以屬性叫 protocolVersion 而 JSON 鍵維持 spec 寫的樣子。
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case command, args
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String: String].self, forKey: .args) ?? [:]
    }
}
