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

    /// pack 根底下的每一筆。**這是整個安全論述的唯一守衛**：`ditto` 會把
    /// zip 裡的 `../escaped.txt` 攤平到解壓根（2026-08-12 實測），搬移時只取
    /// 這個範圍就與那些意外檔案無關。
    ///
    /// 前綴以 `/` 為界比對，否則 `cat` 會吃到 `catalog/`。
    public func entries(under root: String) -> [Entry] {
        guard !root.isEmpty else { return entries }
        let prefix = root + "/"
        return entries.filter { $0.relativePath.hasPrefix(prefix) }
    }

    /// macOS 打 zip 常夾 `__MACOSX/._x` 與 `.DS_Store`。它們不是 pack 的一部分，
    /// 也不該讓「恰好一個 manifest」的判定失敗。
    private func isCruft(_ path: String) -> Bool {
        path.hasPrefix("__MACOSX/") || basename(path) == ".DS_Store"
            || basename(path).hasPrefix("._")
    }

    private func basename(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    private func parent(of path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count <= 1 ? "" : parts.dropLast().joined(separator: "/")
    }
}
