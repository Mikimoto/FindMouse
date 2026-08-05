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
            if let firstSize = fileSizes.first {
                sizesAcrossActions.append(firstSize)
            }

            if actionOK { usable.insert(action) }
        }

        // --- 目錄存在但未宣告 → warning 並忽略 ---
        for name in listing.directories.keys.sorted() where manifest.actions[name] == nil {
            warnings.append(.undeclaredDirectory(name))
        }

        // Check if sizes vary across actions
        let uniqueSizes = uniqueCGSizes(sizesAcrossActions)
        if uniqueSizes.count > 1 {
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

    private static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isLowercase && $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private static func sorted(_ actions: Set<CatAction>) -> [CatAction] {
        actions.sorted { $0.rawValue < $1.rawValue }
    }

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
