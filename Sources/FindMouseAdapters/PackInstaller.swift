// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FindMouseDomain

/// pack 的安裝與移除。**只做 I/O，每個決策都問 Domain。**
public enum PackInstaller {

    /// 解壓後的總大小上限。`mycat` 是 7.1MB，spec 第 6 節的格數上限（約 80–100 格）
    /// 乘上合理的單格尺寸遠低於此。**這是判斷值，不是量出來的。**
    ///
    /// 只在解壓**之後**複查。原本要加「先讀 zip 自報的未壓縮大小早期拒絕」，
    /// 2026-08-13 實測把那一層的價值打掉了：把 central directory 的 uncompressed
    /// size 改成 1，`unzip -l` 照著報 1 byte 而 `ditto` 照解、吐出真正的 1000 bytes
    /// ——它不驗證那個欄位。所以自報值只擋得住誠實的大檔案，而誠實的大檔案本來
    /// 就會被這裡擋下。殘餘風險：惡意 zip 在被拒絕前確實會寫到那麼大，緩解是
    /// 暫存目錄用完立刻刪（`defer`）且它在 `NSTemporaryDirectory()` 底下。
    public static let byteLimit = 200 * 1024 * 1024

    /// **實作 `LocalizedError`**，否則 `error.localizedDescription` 會吐
    /// 「The operation couldn't be completed. (…Failure error 1.)」——英文樣板，
    /// 而且 `extract` 為了避免 deadlock 精心收下的 ditto stderr 會整段遺失
    /// （壞 zip 的使用者看不到「這不是一個 zip」）。
    public enum Failure: Error, Equatable, LocalizedError {
        case tooLarge(bytes: Int, limit: Int)
        case extractionFailed(String)
        /// id 不符 `[a-z0-9-]+`。**這是路徑注入的守衛**，不只是格式檢查——見 `requireSafeID`。
        case invalidID(String)

        public var errorDescription: String? {
            switch self {
            case let .tooLarge(bytes, limit):
                return "解開之後有 \(bytes / 1_048_576) MB，超過上限 \(limit / 1_048_576) MB。"
            case let .extractionFailed(text):
                return "解不開這個檔案：\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            case let .invalidID(id):
                return "pack.json 的 id「\(id)」不合法。只能用小寫英數與連字號"
                     + "（`[a-z0-9-]+`），因為它會被當成資料夾名稱。"
            }
        }
    }

    /// id 會被當成**目的地**的路徑組件，而它完全來自不受信任的 `pack.json`。
    ///
    /// `appendingPathComponent("../victim")` 標準化之後會指到 `Packs` 的**外面**
    /// （實測），於是 `install` 的 `removeItem(at: final)` 會遞迴刪掉那個目錄，
    /// 而 `Packs` 底下什麼都沒有、零錯誤。`../../../../Users/<u>/Documents`
    /// 就是刪家目錄。
    ///
    /// 整份安全論述原本只管**來源側**（zip 裡的 `../x`），目的地側被漏掉了——
    /// 而目的地側才是攻擊者真正控制的東西。`PackCatalogRepository.swift:80`
    /// 掃描那條路早就有一模一樣的守衛，匯入這條路補上它。
    ///
    /// 在 Adapters 這一層 throw 而不只在 `RequestRouter` guard：這兩支是 public，
    /// 未來的呼叫端（C-2 的 GUI 拖放）不該重新發明這個檢查。
    private static func requireSafeID(_ id: String) throws {
        guard PackValidator.isValidID(id) else { throw Failure.invalidID(id) }
    }

    /// 來源是目錄還是檔案。**要問檔案系統，不能用 `URL.hasDirectoryPath`**——
    /// 那個只看路徑字串有沒有結尾斜線，`URL(fileURLWithPath:)` 建出來的目錄 URL
    /// 通常沒有，於是目錄會被當成 zip 丟給 `ditto`，錯誤訊息是
    /// 「ditto: …/whatever: Is a directory」（實測踩過）。
    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    // MARK: - 讀

    /// 走訪一個目錄，產出 Domain 看得懂的樹。
    ///
    /// **明確問 `isSymbolicLinkKey`**：`FileManager` 的走訪預設會**跟隨** symlink，
    /// 於是一個指向 `/` 的連結會讓走訪炸開，而症狀看起來只是「很慢」。
    ///
    /// 不跳過隱藏檔（`options: []`）：`.DS_Store` 要被收進來才能被 `isCruft` 過濾，
    /// 而 `__MACOSX/._x` 這種也要看得到。
    public static func tree(of directory: URL) throws -> ExtractedTree {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey,
                                      .isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: []) else {
            return ExtractedTree(entries: [])
        }
        let base = directory.standardizedFileURL.path
        var entries: [ExtractedTree.Entry] = []
        for case let url as URL in walker {
            let v = try url.resourceValues(forKeys: Set(keys))
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count)
                                .drop(while: { $0 == "/" }))
            let kind: ExtractedTree.Entry.Kind =
                v.isSymbolicLink == true ? .other
                : v.isDirectory == true ? .directory
                : v.isRegularFile == true ? .file : .other
            entries.append(.init(relativePath: rel, kind: kind,
                                 bytes: kind == .file ? (v.fileSize ?? 0) : 0))
        }
        return ExtractedTree(entries: entries)
    }

    /// 讀來源的 manifest（zip 會先解到暫存目錄）。
    ///
    /// **與 `install` 各自解壓一次**，那是刻意的取捨：多一次解壓換「決策發生在動
    /// 任何目的地檔案之前」。兩次之間沒有共用狀態，各自的暫存目錄用完就刪。
    public static func manifest(of source: URL) throws -> PackManifest {
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-peek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let payload: URL
        if isDirectory(source) { payload = source }
        else { try extract(source, into: staging); payload = staging }

        let tree = try tree(of: payload)
        let root = try tree.packRoot()
        try tree.rejectIrregularEntries()
        return try manifest(atPackDirectory: root.isEmpty
                            ? payload : payload.appendingPathComponent(root))
    }

    /// 讀一個**已經是 pack 根**的目錄裡的 manifest。
    public static func manifest(atPackDirectory directory: URL) throws -> PackManifest {
        let data = try Data(contentsOf: directory
            .appendingPathComponent(ExtractedTree.manifestName))
        return try JSONDecoder().decode(PackManifest.self, from: data)
    }

    public static func manifestID(of source: URL) throws -> String {
        try manifest(of: source).id
    }

    public static func manifestVersion(of source: URL) throws -> String? {
        try manifest(of: source).version
    }

    public static func manifestVersion(atPackDirectory directory: URL) throws -> String? {
        try manifest(atPackDirectory: directory).version
    }

    // MARK: - 寫

    /// `ditto -x -k`。用它而不是自己解 zip：它是 Apple 的路徑、處理 macOS 的
    /// extended attributes。
    ///
    /// **不依賴它對 path traversal 安全**——2026-08-12 實測它把 `../x` 攤平到目標
    /// 根目錄（沒逃出去，但也沒拒絕），所以真正的守衛是 `install` 裡「只挑 pack 根
    /// 底下」那一步。
    public static func extract(_ zip: URL, into destination: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, destination.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        // 先讀完再 wait：ditto 的 stderr 寫滿 pipe buffer 時會卡在寫入，
        // 而我們卡在 wait——雙方互等，看起來像「解壓很慢」。
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(decoding: errorData, as: UTF8.self)
            throw Failure.extractionFailed(
                text.isEmpty ? "ditto 回 \(p.terminationStatus)" : text)
        }
    }

    /// 裝一套 pack 到 `packsDirectory/<id>`。
    ///
    /// 順序是刻意的：解到**空的**暫存目錄 → 認 pack 根 → 拒絕非 regular file →
    /// 量大小 → **只搬 pack 根底下的東西** → 原子 rename。
    ///
    /// `.incoming` 那一步讓失敗不留半套：直接寫進 `<id>` 的話，中途失敗會留下一個
    /// 「像是裝好了」的殘缺目錄，而 `PackValidator` 只會說它不合格——使用者看到的是
    /// 「我裝的 pack 壞了」而不是「安裝沒完成」。
    public static func install(source: URL, id: String, into packsDirectory: URL) throws {
        // 先驗 id，在動任何檔案之前。理由見 requireSafeID。
        try requireSafeID(id)
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let payload: URL
        if isDirectory(source) { payload = source }
        else { try extract(source, into: staging); payload = staging }

        let full = try tree(of: payload)
        let root = try full.packRoot()
        try full.rejectIrregularEntries()

        // 只量會被裝進去的那些，不量整個解壓結果：夾帶的檔案與 cruft 不會被
        // 裝進去，拿它們的大小去擋一次合法的安裝就是錯的理由。
        let items = full.installableEntries(under: root)
        let bytes = ExtractedTree(entries: items).totalBytes
        guard bytes <= byteLimit else {
            throw Failure.tooLarge(bytes: bytes, limit: byteLimit)
        }

        let incoming = packsDirectory.appendingPathComponent("\(id).incoming")
        try? FileManager.default.removeItem(at: incoming)
        // **逐筆複製，不是 `copyItem` 整個 pack 根。** 整個目錄搬過去的話，
        // 根為空字串（manifest 在 zip 根）時連 `__MACOSX/` 與 `.DS_Store` 都會
        // 一起進去，而 `__MACOSX/` 會讓 `PackValidator` 報一筆 undeclaredDirectory
        // ——Finder 的「壓縮所選項目的內容」正是這個佈局。逐筆走才讓「根空」與
        // 「根不空」兩種佈局裝出同樣的東西。
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        for e in items {
            let rel = root.isEmpty ? e.relativePath
                                   : String(e.relativePath.dropFirst(root.count + 1))
            let destination = incoming.appendingPathComponent(rel)
            if e.kind == .directory {
                try FileManager.default.createDirectory(
                    at: destination, withIntermediateDirectories: true)
            } else {
                // 父目錄可能是被 cruft 過濾掉的、也可能還沒被走訪到，所以每個
                // 檔案都自己確保一次。`.other` 在上面的 rejectIrregularEntries
                // 已經全部擋掉，走到這裡只剩 file 與 directory。
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try FileManager.default.copyItem(
                    at: payload.appendingPathComponent(e.relativePath), to: destination)
            }
        }

        let final = packsDirectory.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: final)
        do {
            try FileManager.default.moveItem(at: incoming, to: final)
        } catch {
            // **這條分支沒有測試涵蓋**：要走到它得讓 rename 失敗（權限、磁碟滿），
            // 而構造那個環境比它守住的東西還脆弱。留著是因為不留的話，一次失敗的
            // rename 會在 Packs 目錄裡留下 `<id>.incoming`，而下一次安裝的
            // `removeItem(at: incoming)` 雖然會清掉它，中間那段時間 `pack list`
            // 會掃到一個叫 `<id>.incoming` 的東西（目錄名與 manifest id 不符，
            // 於是它會以 idDirectoryMismatch 的形式出現在清單裡）。
            try? FileManager.default.removeItem(at: incoming)
            throw error
        }
    }

    /// 移除一套使用者 pack。
    ///
    /// **呼叫端要先確認它不是內建、也不是當前使用中的那套**
    /// （分別在 `PackInstallDecision` 與 `RequestRouter.packRemove`）。
    public static func remove(id: String, from packsDirectory: URL) throws {
        // remove 同樣拿 id 當路徑組件，同樣要驗——這支的後果是直接刪目錄。
        try requireSafeID(id)
        try FileManager.default.removeItem(at: packsDirectory.appendingPathComponent(id))
    }
}
