// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// `summon` / `dismiss` / `toggle` / `teaser` 的回應。
///
/// 回「已排入佇列的是哪個命令」而不是回當下的狀態：命令要到下一帧才會被
/// `tick` 消費，這時回傳的 status 是**執行前**的，看起來像命令沒生效。
/// 想知道結果就再打一次 `status`——那是誠實的兩步，勝過一個看似同步的謊。
public struct AckPayload: Codable, Sendable, Equatable {
    /// 排進佇列的命令名。就是 wire 上的命令字串本身，例如 `"summon"`、`"teaser.on"`
    public let queued: String

    public init(queued: String) { self.queued = queued }
}
