import CoreGraphics
import Foundation

/// spec 第 6.4 節。純函式：吃 manifest ＋ 實際檔案清單，吐 errors / warnings / capabilities。
/// findmouse pack validate、App 啟動檢查、設定視窗清單三處共用這一份判定。
public enum PackValidator {

    public static let supportedSchemaVersion = 1
    public static let logicalHeightRange: ClosedRange<CGFloat> = 24...400

    public static func validate(manifest: PackManifest,
                                directoryName: String,
                                listing: PackFileListing) -> PackValidationReport {
        var errors: [PackIssue] = []
        var warnings: [PackIssue] = []

        // --- metadata ---
        if manifest.schemaVersion != supportedSchemaVersion {
            errors.append(.unsupportedSchemaVersion(manifest.schemaVersion))
        }
        if !isValidID(manifest.id) {
            errors.append(.invalidID(manifest.id))
        } else if manifest.id != directoryName {
            errors.append(.idDirectoryMismatch(id: manifest.id, directory: directoryName))
        }
        if !(0...1).contains(manifest.anchor.x) || !(0...1).contains(manifest.anchor.y) {
            errors.append(.anchorOutOfRange(x: manifest.anchor.x, y: manifest.anchor.y))
        }
        if !logicalHeightRange.contains(manifest.logicalHeight) {
            errors.append(.logicalHeightOutOfRange(manifest.logicalHeight))
        }

        // --- 逐一檢查宣告的動作。actions 是唯一權威。---
        var usable: Set<CatAction> = []
        // 不能用 Set<CGSize>：CGSize 對 Hashable 的 conformance 要 macOS 15+，
        // 而本套件宣告 .macOS("14.0")。改用陣列＋手動判重（見 uniqueCGSizes）。
        var sizesAcrossActions: [CGSize] = []

        for name in manifest.actions.keys.sorted() {
            let spec = manifest.actions[name]!

            guard let action = CatAction(rawValue: name) else {
                warnings.append(.unknownActionName(name))
                continue
            }
            guard let dirFiles = listing.directories[name] else {
                errors.append(.declaredActionMissingDirectory(name))
                continue
            }

            var actionOK = true

            if spec.frames < 1 {
                errors.append(.invalidFrameCount(action: name, frames: spec.frames))
                actionOK = false
            }
            if spec.fps <= 0 {
                errors.append(.invalidFPS(action: name, fps: spec.fps))
                actionOK = false
            }
            if dirFiles.count != spec.frames {
                errors.append(.frameCountMismatch(action: name,
                                                  declared: spec.frames,
                                                  found: dirFiles.count))
                actionOK = false
            }

            for file in dirFiles where file.size == nil {
                errors.append(.undecodableImage(path: "\(name)/\(file.name)"))
                actionOK = false
            }

            let fileSizes = dirFiles.compactMap(\.size)
            if !fileSizes.isEmpty && !fileSizes.allSatisfy({ $0 == fileSizes[0] }) {
                errors.append(.inconsistentSizeWithinAction(action: name))
                actionOK = false
            }
            // 帶入該動作的全部尺寸而不只是第一個：某個動作內部尺寸就不一致時，
            // 跨動作比對也該看到它的每一種尺寸
            sizesAcrossActions.append(contentsOf: fileSizes)

            if actionOK { usable.insert(action) }
        }

        // --- 目錄存在但未宣告 → warning 並忽略 ---
        for name in listing.directories.keys.sorted() where manifest.actions[name] == nil {
            warnings.append(.undeclaredDirectory(name))
        }

        if uniqueCGSizes(sizesAcrossActions).count > 1 {
            warnings.append(.inconsistentSizeAcrossActions)
        }

        // --- 三級動作契約 ---
        let missingCore = CatAction.core.subtracting(usable)
        if !missingCore.isEmpty {
            errors.append(.missingCoreActions(sorted(missingCore)))
        }

        let missingFlourish = CatAction.flourish.subtracting(usable)
        if !missingFlourish.isEmpty {
            warnings.append(.missingFlourishActions(sorted(missingFlourish)))
        }

        let missingTeaser = CatAction.teaser.subtracting(usable)
        if !missingTeaser.isEmpty {
            warnings.append(.missingTeaserActions(sorted(missingTeaser)))
        }

        guard errors.isEmpty else {
            return PackValidationReport(errors: errors, warnings: warnings, capabilities: nil)
        }

        let capabilities = PackCapabilities(
            available: usable,
            teaserAvailable: missingTeaser.isEmpty,
            restPool: sorted(CatAction.restPool.intersection(usable)))

        return PackValidationReport(errors: errors, warnings: warnings, capabilities: capabilities)
    }

    /// 規則是 ASCII 的 `[a-z0-9-]+`，所以不能用 `Character.isLowercase` / `isNumber`——
    /// 那些是 Unicode 全域屬性，會放行 `ünïcode`、`ß`、`½`、`٣`、`Ⅷ`。
    /// 這不只是寬鬆：pack id 必須等於磁碟上的目錄名，而 Swift 的 String 相等是
    /// 正規化等價，NFC 的 id 對 NFD 的目錄名會比較成相等，於是 idDirectoryMismatch
    /// 看不出正規化差異。限制成 ASCII 就從構造上消掉整個類別。
    /// 不是 private：`PackCatalogRepository.directory(for:in:)` 要用同一條規則把關
    /// 「id 變成路徑」那一步。各寫一份的話，放寬其中一邊時另一邊不會有訊號。
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    private static func sorted(_ actions: Set<CatAction>) -> [CatAction] {
        actions.sorted { $0.rawValue < $1.rawValue }
    }

    /// CGSize 在 macOS 14 部署目標下不是 Hashable，所以自己判重
    private static func uniqueCGSizes(_ sizes: [CGSize]) -> [CGSize] {
        var unique: [CGSize] = []
        for size in sizes {
            if !unique.contains(where: { $0 == size }) {
                unique.append(size)
            }
        }
        return unique
    }
}
