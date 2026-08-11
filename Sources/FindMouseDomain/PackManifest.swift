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
    public var logicalHeight: CGFloat
    public var anchor: Anchor
    public var facing: Facing
    public var mirrorForOpposite: Bool
    public var actions: [String: ActionSpec]

    public init(schemaVersion: Int, id: String, name: String,
                author: String? = nil, license: String? = nil,
                logicalHeight: CGFloat, anchor: Anchor, facing: Facing,
                mirrorForOpposite: Bool, actions: [String: ActionSpec]) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.author = author
        self.license = license
        self.logicalHeight = logicalHeight
        self.anchor = anchor
        self.facing = facing
        self.mirrorForOpposite = mirrorForOpposite
        self.actions = actions
    }
}
