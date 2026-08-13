// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation

/// pack.json 的解碼型別。actions 以 String 為鍵，因為 manifest 可能含
/// 未知的動作名——那是 warning 的情境，不能在解碼階段就丟掉資訊。
public struct PackManifest: Sendable, Equatable, Codable {

    public struct ActionSpec: Sendable, Equatable, Codable {
        public var frames: Int
        public var fps: Double
        public var loop: Bool

        public init(frames: Int, fps: Double, loop: Bool) {
            self.frames = frames
            self.fps = fps
            self.loop = loop
        }
    }

    public struct Anchor: Sendable, Equatable, Codable {
        public var x: CGFloat
        public var y: CGFloat

        public init(x: CGFloat, y: CGFloat) {
            self.x = x
            self.y = y
        }
    }

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var author: String?
    public var license: String?
    /// pack 自己的版本，作者填的。**optional 且不驗格式**——spec 第 6.2 節只規範
    /// `id`，這個欄位可能是 `2.0`、`2026.08`、`v3`，也可能根本沒有。
    /// 匯入時只用它組確認訊息（`PackVersion.replacementPrompt`）。
    ///
    /// 加它不用動 `schemaVersion`：`JSONDecoder` 忽略未知欄位、而缺少 optional
    /// 欄位不是錯誤，所以既有三套 pack 的 `pack.json` 一個字都不用改。
    public var version: String?
    public var logicalHeight: CGFloat
    public var anchor: Anchor
    public var facing: Facing
    public var mirrorForOpposite: Bool
    public var actions: [String: ActionSpec]

    public init(schemaVersion: Int, id: String, name: String,
                author: String? = nil, license: String? = nil,
                version: String? = nil,
                logicalHeight: CGFloat, anchor: Anchor, facing: Facing,
                mirrorForOpposite: Bool, actions: [String: ActionSpec]) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.author = author
        self.license = license
        self.version = version
        self.logicalHeight = logicalHeight
        self.anchor = anchor
        self.facing = facing
        self.mirrorForOpposite = mirrorForOpposite
        self.actions = actions
    }
}
