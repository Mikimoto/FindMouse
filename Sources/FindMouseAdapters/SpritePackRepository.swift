// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import FindMouseDomain

/// 磁碟上的 pack 目錄 → Domain 的 `PackManifest` ＋ `PackFileListing`。
///
/// 這一層只負責「把檔案系統的事實蒐集起來」，一個合格與否的判斷都不做——
/// 那是 `PackValidator`（Domain 純函式）的職責。分工這樣切，
/// `findmouse pack validate`、App 啟動檢查、設定視窗的清單三處才是同一份判定。
public enum SpritePackRepository {

    public struct Loaded: Sendable {
        public let manifest: PackManifest
        public let listing: PackFileListing
        /// 目錄名。`PackValidator` 要拿它跟 `manifest.id` 比對。
        public let directoryName: String
        /// pack 目錄本身。`SpriteRepository` 要靠它載圖。
        public let directoryURL: URL
    }

    /// 讀不到或解不開 `pack.json` 就回 nil。
    /// 不丟例外：呼叫端要的是「這個目錄能不能用」，而細部原因由 `PackValidator`
    /// 從已解出的 manifest 判斷——連 JSON 都解不開時沒有東西可以判。
    public static func load(at url: URL) -> Loaded? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("pack.json")),
              let manifest = try? JSONDecoder().decode(PackManifest.self, from: data)
        else { return nil }

        return Loaded(manifest: manifest,
                      listing: listing(in: url),
                      directoryName: url.lastPathComponent,
                      directoryURL: url)
    }

    /// 內建 pack 的所在目錄。
    ///
    /// `Bundle.module` 是**每個 target 各自的**——在 app target 裡呼叫
    /// `Bundle.module` 會指向 app 自己的資源而找不到這裡的 Packs，
    /// 所以這個查詢必須由持有資源的這一層提供。
    public static func builtInPacksDirectory() -> URL? {
        Bundle.module.url(forResource: "Packs", withExtension: nil)
    }

    /// 掃目錄：每個子目錄算一個動作，PNG 依檔名排序，逐檔取尺寸。
    ///
    /// `ImageFile.size == nil` 就是「這張解不開」。**不能**把讀不到尺寸的檔案
    /// 略過不放進清單：略過會讓 `PackValidator` 把它判成「格數不符」，
    /// 錯誤訊息就指錯地方了。
    ///
    /// 排序不可省。`frameIndex` 是位置索引，`contentsOfDirectory` 的順序
    /// 沒有保證，不排序的話動畫的格序會是隨機的。
    private static func listing(in packDir: URL) -> PackFileListing {
        var directories: [String: [PackFileListing.ImageFile]] = [:]

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: packDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            let frames = ((try? FileManager.default.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            directories[entry.lastPathComponent] = frames.map {
                PackFileListing.ImageFile(name: $0.lastPathComponent,
                                          size: SpriteFileStore.pixelSize($0))
            }
        }

        return PackFileListing(directories: directories)
    }
}
