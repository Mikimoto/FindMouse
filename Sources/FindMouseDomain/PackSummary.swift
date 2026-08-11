// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics

/// 一套 pack 的中介資料。`pack list` 與設定視窗的清單共用同一份。
///
/// 錯誤與警告是**已經翻成人話的字串**，不是 `PackIssue`：Domain 不該決定
/// 使用者看到什麼文字，而這個型別要同時餵給 CLI 與 UI，兩邊都需要字串。
/// 翻譯在 Adapters（`PackIssue.wireText`）。
public struct PackSummary: Sendable, Equatable {
    public let id: String
    public let isBuiltIn: Bool
    public let logicalHeight: CGFloat
    public let errors: [String]
    public let warnings: [String]
    public let teaserAvailable: Bool

    public init(id: String, isBuiltIn: Bool, logicalHeight: CGFloat,
                errors: [String], warnings: [String], teaserAvailable: Bool) {
        self.id = id
        self.isBuiltIn = isBuiltIn
        self.logicalHeight = logicalHeight
        self.errors = errors
        self.warnings = warnings
        self.teaserAvailable = teaserAvailable
    }

    /// 只有 error 讓一套 pack 不能選。警告（缺點綴、缺 teaser）不影響——
    /// spec 第 6.4 節把「缺任一 core 動作」與「缺 teaser」分成兩級就是為了這件事。
    public var isUsable: Bool { errors.isEmpty }
}
