import Foundation
import FindMouseDomain

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

    /// 依 id 找出 pack 目錄。`pack use` 要用它。
    ///
    /// 直接拿 id 當目錄名組路徑，不重掃整個目錄：id 與目錄名不符是
    /// `PackValidator` 的 error，那種 pack 本來就不可選。優先序與 `scan`
    /// 同樣是「清單順序的第一個」，否則清單顯示內建那套、切換卻切到
    /// 使用者的同名目錄。
    static func directory(for id: String, in directories: [(URL, Bool)]) -> URL? {
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
