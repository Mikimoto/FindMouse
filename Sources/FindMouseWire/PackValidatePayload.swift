// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// `pack validate <path>` 的回應。
///
/// **這個命令即使判定 pack 不合格，`ok` 仍然是 true**（spec 第 8.5 節）：
/// 「驗證成功地判定這套 pack 不合格」不是命令失敗。
/// 分不開的話，CLI 就無法區分「這套 pack 有問題」與「驗證這件事本身壞了」，
/// 而那兩者要修的東西完全不同。exit code 1 由 CLI 從 `valid` 決定，不是從 `ok`。
///
/// `ok` 為 false 的只有兩種：路徑不存在（`PACK_NOT_FOUND`）、
/// 以及路徑存在但根本讀不出 manifest（同樣是 `PACK_NOT_FOUND`——
/// 對使用者而言「那裡沒有一套 pack」是同一件事）。
public struct PackValidatePayload: Codable, Sendable, Equatable {
    /// manifest 宣告的 id。讀得到 manifest 才有這個命令的結果，所以一定有值。
    public let id: String
    public let valid: Bool
    public let errors: [String]
    public let warnings: [String]

    public init(id: String, valid: Bool, errors: [String], warnings: [String]) {
        self.id = id
        self.valid = valid
        self.errors = errors
        self.warnings = warnings
    }
}
