// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

/// 解壓結果的表示法。**刻意不用既有的 `PackFileListing`**：那個是
/// `[目錄: [PNG]]`、給 `PackValidator` 吃的，看不到 `pack.json` 的位置、
/// 看不到檔案類型、也看不到 bytes——這三件正是匯入這條路要判斷的東西。
public struct ExtractedTree: Sendable, Equatable {

    public struct Entry: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case file, directory, other }

        /// 相對於解壓根，不以 `/` 開頭。
        public var relativePath: String
        public var kind: Kind
        /// 目錄與非 regular file 一律 0。
        public var bytes: Int

        public init(relativePath: String, kind: Kind, bytes: Int) {
            self.relativePath = relativePath
            self.kind = kind
            self.bytes = bytes
        }
    }

    public enum Failure: Error, Equatable {
        case noManifest
        /// 帶著找到的每一個 pack 根，訊息才講得出「有幾套」。
        case multiplePacks([String])
        case notARegularFile(String)
    }

    public static let manifestName = "pack.json"

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// 恰好一個含 `pack.json` 的目錄；回傳它的相對路徑（根就是空字串）。
    ///
    /// **深度不是判準。** 巢狀的第二個 manifest 一樣算兩套——「使用者以為在裝一套」
    /// 這個前提一旦不成立，猜哪一個都可能猜錯，而猜錯的後果是裝了不是他要的東西。
    public func packRoot() throws -> String {
        let roots = entries
            .filter { $0.kind == .file && !isCruft($0.relativePath) }
            .filter { basename($0.relativePath) == Self.manifestName }
            .map { parent(of: $0.relativePath) }
            .sorted()
        switch roots.count {
        case 0: throw Failure.noManifest
        case 1: return roots[0]
        default: throw Failure.multiplePacks(roots)
        }
    }

    /// symlink、hard link、device 一律拒絕並指名路徑。
    ///
    /// 一個指向 `/etc/passwd` 的 symlink 進了 Packs 目錄之後，任何「掃描並讀取」
    /// 的程式碼都會跟著讀它——而 pack 的內容只該有 PNG 與 JSON。
    public func rejectIrregularEntries() throws {
        for e in entries where e.kind == .other {
            throw Failure.notARegularFile(e.relativePath)
        }
    }

    public var totalBytes: Int {
        entries.filter { $0.kind == .file }.reduce(0) { $0 + $1.bytes }
    }

    /// 會**真的被裝進去**的那些：pack 根底下、扣掉 macOS cruft。大小也照這個
    /// 範圍算——不會被裝進去的東西拿去擋一次合法的安裝就是錯的理由。
    ///
    /// **這是整個安全論述的唯一守衛**：`ditto` 會把 zip 裡的 `../escaped.txt`
    /// 攤平到解壓根（2026-08-12 實測），根不空時只取這個範圍就與它們無關。
    ///
    /// **根是空字串時擋不掉夾帶的檔案**，而那是 Finder「壓縮所選項目的內容」
    /// 的常見佈局（`pack.json` 直接在 zip 根）：那時「pack 根底下」就是全部，
    /// 而一個被攤平的 `../escaped.txt` 與一個作者真的放在 pack 根的檔案
    /// **無法區分**——ditto 解完之後兩者長得一模一樣。所以這種佈局下它會被裝進
    /// `Packs/<id>/`。守住的仍然是「不會跑到 `Packs` 外面」，不是「裡面很乾淨」。
    ///
    /// 前綴以 `/` 為界比對，否則 `cat` 會吃到 `catalog/`。
    public func installableEntries(under root: String) -> [Entry] {
        let underRoot = root.isEmpty ? entries
            : entries.filter { $0.relativePath.hasPrefix(root + "/") }
        return underRoot.filter { !isCruft($0.relativePath) }
    }

    /// macOS 打 zip 常夾 `__MACOSX/._x` 與 `.DS_Store`。它們不是 pack 的一部分，
    /// 也不該讓「恰好一個 manifest」的判定失敗。
    ///
    /// `__MACOSX` 這個**目錄本身**要單獨列：它的 `relativePath` 沒有結尾斜線，
    /// 只寫 `hasPrefix("__MACOSX/")` 的話裡面的檔案都被濾掉、空目錄卻照樣建出來，
    /// 而 `PackValidator` 會為那個空目錄報一筆 `undeclaredDirectory`。
    private func isCruft(_ path: String) -> Bool {
        path == "__MACOSX" || path.hasPrefix("__MACOSX/")
            || basename(path) == ".DS_Store" || basename(path).hasPrefix("._")
    }

    private func basename(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    private func parent(of path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count <= 1 ? "" : parts.dropLast().joined(separator: "/")
    }
}
