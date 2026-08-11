// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics

/// spec 第 6.4 節列舉的全部驗證問題。
public enum PackIssue: Sendable, Equatable {
    // errors
    case unsupportedSchemaVersion(Int)
    case invalidID(String)
    case idDirectoryMismatch(id: String, directory: String)
    case missingCoreActions([CatAction])
    case declaredActionMissingDirectory(String)
    case frameCountMismatch(action: String, declared: Int, found: Int)
    case invalidFrameCount(action: String, frames: Int)
    case invalidFPS(action: String, fps: Double)
    case inconsistentSizeWithinAction(action: String)
    case undecodableImage(path: String)
    case anchorOutOfRange(x: CGFloat, y: CGFloat)
    case logicalHeightOutOfRange(CGFloat)

    // warnings
    case undeclaredDirectory(String)
    case unknownActionName(String)
    case inconsistentSizeAcrossActions
    case missingFlourishActions([CatAction])
    case missingTeaserActions([CatAction])
}
