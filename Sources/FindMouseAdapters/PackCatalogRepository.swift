// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FindMouseDomain
import FindMouseWire

/// 掃出所有可用的 pack（spec 第 6.1 節的兩個位置）。
///
/// 掃描吃**目錄清單**而不是自己去問 `Bundle.module` 與家目錄，理由與
/// `StageReader.stage(screens:cursor:)` 相同：真實環境測不了，注入才測得到。
public enum PackCatalogRepository {

    /// 使用者放自己 pack 的地方。與 control socket 同一個 App Support 目錄。
    public static var userPacksDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("FindMouse/Packs")
    }

    /// 沙盒**之前** pack 住的地方。
    ///
    /// 不能用 `applicationSupportDirectory` 算：沙盒下它**已經**指向容器，
    /// 而那正是新家。舊家只有從真家目錄算得出來——`getpwuid` 不被沙盒重導
    /// （見 `ControlSocket.realHome`）。
    ///
    /// 非沙盒建置下這個值與 `userPacksDirectory` 逐字相同，那不是 bug：
    /// 那時本來就只有一個家。偵測器因此也不會誤報，理由見
    /// `legacyPacksNeedMigration(legacy:packsDirectory:)`。
    public static var legacyUserPacksDirectory: URL {
        URL(fileURLWithPath: ControlSocket.realHome)
            .appendingPathComponent("Library/Application Support/FindMouse/Packs")
    }

    /// 「使用者已經走過一次搬移」的記號。
    ///
    /// 需要它，是因為**搬完之後偵測器仍然為真**：舊目錄還在那裡，而我們照樣讀不到
    /// 它——powerbox 發的授權只活在那一個 process 裡，下次開 App 就沒了。沒有這個
    /// 記號的話，那一列提示每次啟動都回來，而按下去只會換得「三套都已經有了」。
    ///
    /// 用檔案而不是設定鍵：它描述的是**這個容器**的狀態，容器沒了它就該跟著沒。
    /// 開頭的點讓 `scan` 自然略過它（那裡只認得出目錄裡的 `pack.json`）。
    static func migrationMarker(in packsDirectory: URL) -> URL {
        packsDirectory.appendingPathComponent(".legacy-migration-done")
    }

    /// 舊目錄在那裡、我們讀不到它、而且使用者還沒走過搬移。
    ///
    /// **前兩個條件缺一不可**（2026-08-17 探針）：沙盒下容器外的目錄是
    /// 「`fileExists` 成功、內容 EPERM」這個不對稱，所以只看 `fileExists` 會在
    /// 非沙盒建置一律為真（那時舊家就是新家、讀得到），只看 `isReadableFile`
    /// 則分不出「根本沒有舊目錄」與「有但讀不到」——前者是全新安裝的正常狀態。
    static func legacyPacksNeedMigration(legacy: URL, packsDirectory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return false }
        guard !fm.isReadableFile(atPath: legacy.path) else { return false }
        return !fm.fileExists(atPath: migrationMarker(in: packsDirectory).path)
    }

    public static func legacyPacksNeedMigration() -> Bool {
        legacyPacksNeedMigration(legacy: legacyUserPacksDirectory,
                                 packsDirectory: userPacksDirectory)
    }

    /// 真實環境：內建優先，使用者的排後面。
    public static func current() -> [PackSummary] {
        scan(directories: currentDirectories())
    }

    /// - Parameter directories: (目錄, 是否為內建)。**順序即優先序**：
    ///   同一個 id 出現兩次時保留先出現的那個，所以內建要排在前面——
    ///   使用者不該能用同名目錄蓋掉內建 pack。
    static func scan(directories: [(URL, Bool)]) -> [PackSummary] {
        var seen = Set<String>()
        var result: [PackSummary] = []

        for (directory, isBuiltIn) in directories {
            // 目錄不存在是正常狀態（使用者 pack 目錄一開始就沒有），不是錯誤。
            // 讀不到只讓這一個目錄貢獻零筆，不能中斷整趟掃描，否則使用者目錄
            // 缺席時內建 pack 會跟著消失。
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

            // 依目錄名排序：`contentsOfDirectory` 的順序沒有保證，
            // 不排的話設定視窗的清單每次開都可能換一個順序。
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                // 沒有 pack.json 的目錄不是 pack，略過而不是報錯——
                // .DS_Store 與使用者隨手放的東西都會落在這裡
                guard let loaded = SpritePackRepository.load(at: entry) else { continue }
                guard !seen.contains(loaded.manifest.id) else { continue }
                seen.insert(loaded.manifest.id)

                let report = PackValidator.validate(manifest: loaded.manifest,
                                                    directoryName: loaded.directoryName,
                                                    listing: loaded.listing)
                // 不合格的 pack 也照列，只是 errors 非空（`isUsable` 為 false）。
                // 濾掉的話使用者會看到「我放進去的 pack 不見了」，
                // 而 spec 第 10 節要的是設定裡一列紅字告訴他哪裡壞了。
                result.append(PackSummary(
                    id: loaded.manifest.id,
                    isBuiltIn: isBuiltIn,
                    logicalHeight: loaded.manifest.logicalHeight,
                    errors: report.errors.map(\.wireText),
                    warnings: report.warnings.map(\.wireText),
                    teaserAvailable: report.capabilities?.teaserAvailable ?? false))
            }
        }
        return result
    }

    /// 清單上那一列 id **是哪個目錄產生的**。移除要用它。
    ///
    /// `scan` 列的是 manifest 的 id，而目錄名不保證等於它。拿 id 當目錄名組路徑
    /// 去刪，刪到的可能是另一個目錄（使用者沒看到的那一個），或是一個根本不存在
    /// 的路徑（於是清單上那一列永遠拿不掉）。兩種都實測過，見 CLAUDE.md。
    ///
    /// **順序必須與 `scan` 的同一個目錄內迴圈一致**（依名稱字典序），否則同一個 id
    /// 有兩個來源時，「清單顯示 A、刪掉 B」還是會發生，只是換一種形態。
    ///
    /// 回 `nil` 表示這個目錄底下沒有任何一個 pack 自報這個 id。呼叫端要退回
    /// 「目錄名 == id」，而那條退路**不是**為了 `pack.json` 讀不出來的垃圾目錄
    ///（`scan` 對那種直接 `continue`，它們根本不會出現在清單上，移除會先回
    /// `PACK_NOT_FOUND`）。真正走得到的是**遮蔽內建**那條：id 來自內建那一筆，
    /// 使用者目錄底下那個同名目錄自己說不出自己是誰，而它正是要被清掉的東西。
    ///
    /// 只看**一個**目錄（實務上是使用者的 pack 目錄）：刪除只動得到那裡，
    /// 把內建也掃進來只會回一個刪不得的答案。
    static func sourceDirectoryName(forID id: String, in directory: URL) -> String? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let loaded = SpritePackRepository.load(at: entry) else { continue }
            if loaded.manifest.id == id { return entry.lastPathComponent }
        }
        return nil
    }

    /// 依 id 找出 pack 目錄。`pack use` 要用它。
    ///
    /// 直接拿 id 當目錄名組路徑，不重掃整個目錄：id 與目錄名不符是
    /// `PackValidator` 的 error，那種 pack 本來就不可選。優先序與 `scan`
    /// 同樣是「清單順序的第一個」，否則清單顯示內建那套、切換卻切到
    /// 使用者的同名目錄。
    static func directory(for id: String, in directories: [(URL, Bool)]) -> URL? {
        // id 在下一行就變成路徑組件，所以值域要在這裡把關，而不是寄望呼叫端。
        //
        // spec 第 9 節說「值域驗證只有一份」，但那一份住在 `SettingsUseCase`，
        // 而 App 啟動時讀 `pack.id` 走的是 UserDefaults 直讀——那一步拿不到
        // `SettingsUseCase`（它要一個 catalog，而 catalog 正是那一步要載出來的東西）。
        // 於是 `defaults write … pack.id "../outside"` 就能讓它去載掃描目錄外的 pack。
        // 這裡是 id 變成路徑的唯一入口，擋住它就不必在每個呼叫端各記得一次。
        guard PackValidator.isValidID(id) else { return nil }
        for (directory, _) in directories {
            let candidate = directory.appendingPathComponent(id)
            if SpritePackRepository.load(at: candidate) != nil { return candidate }
        }
        return nil
    }

    public static func currentDirectory(for id: String) -> URL? {
        directory(for: id, in: currentDirectories())
    }

    /// `current()` 與 `currentDirectory(for:)` 必須看同一組目錄與同一個順序，
    /// 不然清單列得出來的 pack 會切不過去。
    private static func currentDirectories() -> [(URL, Bool)] {
        var dirs: [(URL, Bool)] = []
        if let builtIn = SpritePackRepository.builtInPacksDirectory() {
            dirs.append((builtIn, true))
        }
        dirs.append((userPacksDirectory, false))
        return dirs
    }
}
