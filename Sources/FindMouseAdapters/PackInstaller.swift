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
        /// 這個名字不能拿去當路徑組件。**這是路徑注入的守衛**，不只是格式檢查。
        /// 兩支的標準不同：`install` 走 `requireSafeID`（`[a-z0-9-]+`，因為它在
        /// **造**目錄名），`remove` 走比較寬的路徑組件檢查（因為它要刪的名字是
        /// 從磁碟上列舉來的，見它的 doc）。
        case invalidID(String)

        /// 決定 id 的那一次讀取與真正裝進去的那一次讀到不同的 pack。
        case sourceChanged(expected: String, actual: String)

        /// `pack.json` 讀不出來——不存在，或不是合法的 JSON。
        case manifestUnreadable

        public var errorDescription: String? {
            switch self {
            case let .tooLarge(bytes, limit):
                return "解開之後有 \(bytes / 1_048_576) MB，超過上限 \(limit / 1_048_576) MB。"
            case let .extractionFailed(text):
                return "解不開這個檔案：\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            case let .invalidID(id):
                return "pack.json 的 id「\(id)」不合法。只能用小寫英數與連字號"
                     + "（`[a-z0-9-]+`），因為它會被當成資料夾名稱。"
            case let .sourceChanged(expected, actual):
                return "來源在安裝途中被換掉了：一開始讀到的 id 是「\(expected)」，"
                     + "真正要裝的是「\(actual)」。沒有裝進去任何東西，再試一次。"
            case .manifestUnreadable:
                return "pack.json 讀不出來——它不存在，或不是合法的 JSON。"
                     + "這個檔案可能不完整，跟提供的人要一份新的。"
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
    /// 而目的地側才是攻擊者真正控制的東西。`PackCatalogRepository.swift` 的 `directory(for:)`
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
    /// **明確問 `isSymbolicLinkKey`**，雖然拿掉它結果不變（實測）。
    ///
    /// 2026-08-13 量過的三件事：`enumerator(at:options: [])` **不**跟隨 symlink
    /// （指向另一個目錄的連結只算一筆訪問，那個目錄裡的檔案從未被走到）；
    /// `isDirectoryKey` 與 `isRegularFileKey` 對 symlink 也都回 false，所以少了
    /// 這一段仍然落到 `.other`；但**相鄰的 `FileManager.fileExists(atPath:isDirectory:)`
    /// 會跟隨**，對指向目錄的連結回 `isDirectory=true`——兩支 API 行為相反。
    ///
    /// 留著是因為「拒絕 symlink」是安全規則，而它不該靠「那兩個 key 恰好不跟隨」
    /// 這個隱含性質成立：哪天分類換成問會跟隨的那一支，指向目錄的 symlink 就會
    /// 被判成 `.directory` 而通過 `rejectIrregularEntries`。
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
    ///
    /// 讀不出來一律轉成自己的 `Failure`：`DecodingError` 與 `NSError` 都不是
    /// `LocalizedError`，`localizedDescription` 會吐「The data couldn't be read…」
    /// 那串英文樣板，而這支的兩個呼叫端（決定 id 的那次讀取、裝進去之前的複驗）
    /// 都會把它一路顯示給使用者。原因不再帶出去——`Failure` 的訊息要講「接下來
    /// 能做什麼」，而 JSON 解析器的抱怨對拿到壞 pack 的人沒有用。
    public static func manifest(atPackDirectory directory: URL) throws -> PackManifest {
        guard let data = try? Data(contentsOf: directory
                .appendingPathComponent(ExtractedTree.manifestName)),
              let manifest = try? JSONDecoder().decode(PackManifest.self, from: data)
        else { throw Failure.manifestUnreadable }
        return manifest
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
    /// - Parameter byteLimit: 解壓後的大小上限。**開成參數只為了測得到**——
    ///   200MB 的預設值要用真的 200MB 素材才踩得到，那種測試會慢到沒人跑，
    ///   於是這個守衛在加上這個參數之前等於零覆蓋（當時實測：把它改成
    ///   `Int.max` 全綠）。呼叫端一律不傳。
    public static func install(source: URL, id: String, into packsDirectory: URL,
                               byteLimit: Int = PackInstaller.byteLimit) throws {
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
        // `withIntermediateDirectories` 順帶把 `Packs` 自己建出來。**那不是順手**：
        // 全新安裝的機器上那個目錄不存在（沒有別的地方會建它），而舊的
        // `copyItem` 在父目錄缺席時會失敗，訊息還指著來源檔——第一次匯入
        // 必定失敗且看不出原因。`aMissingPacksDirectoryIsCreated` 釘住這件事。
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        do {
            for e in items {
                let rel = root.isEmpty ? e.relativePath
                                       : String(e.relativePath.dropFirst(root.count + 1))
                let destination = incoming.appendingPathComponent(rel)
                if e.kind == .directory {
                    // 目錄走 `createDirectory` 而不是 `copyItem`，於是目錄的 mode
                    // 與 xattr 不跟著來源走（改用 umask，實測來源 0777 裝出 0755）；
                    // **檔案的 mode 照樣原封不動**（實測來源 0400 裝出 0400），
                    // 這個不對稱是兩支 API 的差別，不是政策。兩邊都不必修：目錄
                    // 拿 umask 只會比來源更保守，而檔案沒有 owner-read 的話在上面
                    // 那行 `copyItem` 就先失敗了，裝不進來。
                    try FileManager.default.createDirectory(
                        at: destination, withIntermediateDirectories: true)
                } else {
                    // 父目錄可能是被 cruft 過濾掉的，所以每個檔案都自己確保一次。
                    // 走訪實測是 pre-order（父必先於子），但那不是 `enumerator` 的
                    // 契約，不倚賴它。`.other` 在上面的 rejectIrregularEntries 已經
                    // 全部擋掉，走到這裡只剩 file 與 directory。
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try FileManager.default.copyItem(
                        at: payload.appendingPathComponent(e.relativePath), to: destination)
                }
            }
        } catch {
            // 複製到一半失敗（來源某個檔案讀不到、磁碟滿）同樣不能留下 `.incoming`。
            // 理由與下面 rename 失敗那條相同，只是症狀分兩種：`pack.json` 已經
            // 複製過去的話，殘留目錄會以 idDirectoryMismatch 出現在 `pack list`
            // 裡；還沒複製到的話 `SpritePackRepository.load` 回 nil，那個目錄被
            // 靜默略過、更沒人告訴使用者它是什麼。哪一種取決於失敗落在哪一筆。
            try? FileManager.default.removeItem(at: incoming)
            throw error
        }

        // **驗的是已經複製過去的那一份，不是來源。**
        //
        // `id` 是呼叫端從**上一次**讀取決定的（`PackLibraryUseCase.install` 先
        // `manifestID(of:)` 再走 `PackInstallDecision`），而複製迴圈是**又一次**讀取
        // ——來源在這幾次之間可以被抽換（那個窗口見 `PackLibraryUseCase.swift:132-141`；
        // 2026-08-14 用目錄型來源實測構造成功三次）。所以驗來源沒有用：驗完到複製完
        // 之間還有一段。改成驗 `incoming`，驗的位元組就是要裝進去的那些，中間沒有縫。
        //
        // 不驗的話，目錄名來自舊的 id、內容來自新的 manifest，裝出一個目錄名與
        // manifest id 不符的 pack。那種目錄 `remove` 要靠 `sourceDirectoryName` 才認得
        // 出來，而且如果新的 id 撞到內建，`PACK_ID_RESERVED` 那道閘門完全繞過去了
        // ——它擋的是**第一次**讀到的 id。
        // **這個「讀哪裡」沒有決定性的測試釘得住**：把 `incoming` 換回來源，非競態
        // 的測試兩邊讀到一樣的位元組，突變是綠的。釘得住的是「不符就不裝」那一半
        //（`installRefusesWhenTheSourceNoLongerDeclaresTheExpectedID`）。位置的理由
        // 只能靠上面那段推論，所以刪它之前先讀完那段。
        do {
            let actualID = try manifest(atPackDirectory: incoming).id
            guard actualID == id else {
                throw Failure.sourceChanged(expected: id, actual: actualID)
            }
        } catch {
            // 與上面兩條一樣：不能留下 `.incoming`。
            try? FileManager.default.removeItem(at: incoming)
            throw error
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
    /// - Parameter directoryName: 要刪的**目錄名**，不是 id。兩者只在一致時等價，
    ///   而清單是依 manifest 的 id 列的——拿 id 當目錄名刪會刪到別人（見 CLAUDE.md）。
    ///   呼叫端要先用 `PackCatalogRepository.sourceDirectoryName(forID:in:)` 問出來。
    public static func remove(directoryName: String, from packsDirectory: URL) throws {
        // 這支的後果是直接刪目錄，所以名稱同樣要驗——但驗的是**路徑組件**而不是
        // `isValidID`。名稱有兩種來源：`Packs/` 的列舉（必然是單一組件）與退回時
        // 用的 manifest id（不受信任），所以照最壞的驗。
        //
        // 擋掉的其實是兩件事：`..` 與含 `/` 的會跑到 `Packs` **之外**，而 `""` 與
        // `"."` 會讓 `appendingPathComponent` 指回 `Packs` **自己**——那不是逃逸，
        // 是一次刪掉全部（2026-08-14 實測）。後者從錯誤碼看不出差別，所以寫在這裡。
        //
        // 比 `isValidID` 寬是刻意的：列舉得到的合法目錄名可以含 `.`，
        // 半途失敗留下的 `<id>.incoming` 就是——照 `[a-z0-9-]+` 驗會讓那種殘留
        // 目錄從 GUI 與 CLI 都永遠拿不掉（實測過，見 CLAUDE.md）。
        guard !directoryName.isEmpty, !directoryName.contains("/"),
              directoryName != ".", directoryName != ".." else {
            throw Failure.invalidID(directoryName)
        }
        try FileManager.default.removeItem(
            at: packsDirectory.appendingPathComponent(directoryName))
    }
}
