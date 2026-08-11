// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics

/// pack 目錄的實際內容。由 Adapters（M4）從檔案系統產生，
/// 驗證本身是純函式，所以 Domain 只吃這個值型別。
public struct PackFileListing: Sendable, Equatable {

    public struct ImageFile: Sendable, Equatable {
        public var name: String
        /// nil 表示無法解碼
        public var size: CGSize?

        public init(name: String, size: CGSize?) {
            self.name = name
            self.size = size
        }
    }

    /// 目錄名 → 該目錄下的 PNG（依檔名排序）
    public var directories: [String: [ImageFile]]

    public init(directories: [String: [ImageFile]]) {
        self.directories = directories
    }
}
