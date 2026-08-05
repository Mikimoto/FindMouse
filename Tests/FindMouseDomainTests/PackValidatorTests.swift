import CoreGraphics
import Foundation
import Testing
@testable import FindMouseDomain

// MARK: - fixtures

private let size = CGSize(width: 256, height: 256)

private func files(_ count: Int, size: CGSize? = size) -> [PackFileListing.ImageFile] {
    (0..<count).map { .init(name: String(format: "%03d.png", $0), size: size) }
}

/// 完整的 14 組動作，每組 4 格
private func fullPack(
    id: String = "test-blocks",
    logicalHeight: CGFloat = 96,
    anchor: PackManifest.Anchor = .init(x: 0.5, y: 0.94),
    dropping: Set<CatAction> = [],
    schemaVersion: Int = 1
) -> (PackManifest, PackFileListing) {
    var actions: [String: PackManifest.ActionSpec] = [:]
    var directories: [String: [PackFileListing.ImageFile]] = [:]
    for action in CatAction.allCases where !dropping.contains(action) {
        actions[action.rawValue] = .init(frames: 4, fps: 10, loop: action == .run)
        directories[action.rawValue] = files(4)
    }
    let manifest = PackManifest(
        schemaVersion: schemaVersion, id: id, name: "Test",
        logicalHeight: logicalHeight, anchor: anchor,
        facing: .right, mirrorForOpposite: true, actions: actions)
    return (manifest, PackFileListing(directories: directories))
}

// MARK: - tests

@Test func fullPackIsValidWithAllCapabilities() {
    let (manifest, listing) = fullPack()
    let report = PackValidator.validate(manifest: manifest, directoryName: "test-blocks", listing: listing)
    #expect(report.isValid)
    #expect(report.errors.isEmpty)
    #expect(report.capabilities?.teaserAvailable == true)
    #expect(report.capabilities?.restPool == [.scratch, .stretch, .yawn])  // rawValue 排序
    #expect(report.capabilities?.available.count == CatAction.allCases.count)
    // 乾淨的 pack 不該有任何警告；少了這行，任何新增的假警告都不會被發現
    #expect(report.warnings.isEmpty)
}

@Test func missingCoreActionInvalidatesPack() {
    let (manifest, listing) = fullPack(dropping: [.sitIdle])
    let report = PackValidator.validate(manifest: manifest, directoryName: "test-blocks", listing: listing)
    #expect(report.isValid == false)
    #expect(report.errors.contains(.missingCoreActions([.sitIdle])))
    #expect(report.capabilities == nil)
}

@Test func missingFlourishIsWarningAndShrinksRestPool() {
    let (manifest, listing) = fullPack(dropping: [.yawn, .brake])
    let report = PackValidator.validate(manifest: manifest, directoryName: "test-blocks", listing: listing)
    #expect(report.isValid)
    #expect(report.warnings.contains(.missingFlourishActions([.brake, .yawn])))
    #expect(report.capabilities?.restPool == [.scratch, .stretch])
    #expect(report.capabilities?.available.contains(.brake) == false)
}

@Test func missingSingleTeaserActionDisablesTeaserEntirely() {
    let (manifest, listing) = fullPack(dropping: [.pounce])
    let report = PackValidator.validate(manifest: manifest, directoryName: "test-blocks", listing: listing)
    #expect(report.isValid)
    #expect(report.capabilities?.teaserAvailable == false)
    #expect(report.warnings.contains(.missingTeaserActions([.pounce])))
}

@Test func frameCountMismatchIsError() {
    var (manifest, listing) = fullPack()
    listing.directories["run"] = files(2)   // 宣告 4，實際 2
    let report = PackValidator.validate(manifest: manifest, directoryName: "test-blocks", listing: listing)
    #expect(report.isValid == false)
    #expect(report.errors.contains(.frameCountMismatch(action: "run", declared: 4, found: 2)))
    _ = manifest
}

@Test func inconsistentSizeWithinActionIsError() {
    var (manifest, listing) = fullPack()
    listing.directories["sit"] = [
        .init(name: "000.png", size: size),
        .init(name: "001.png", size: CGSize(width: 128, height: 128)),
        .init(name: "002.png", size: size),
        .init(name: "003.png", size: size),
    ]
    let report = PackValidator.validate(manifest: manifest, directoryName: "test-blocks", listing: listing)
    #expect(report.errors.contains(.inconsistentSizeWithinAction(action: "sit")))
    // 同一個動作內部尺寸不一致時，那些尺寸也會進到跨動作比對。
    // 沒有這一行，「只帶第一個尺寸」的錯誤實作會靜默通過——實際發生過一次。
    #expect(report.warnings.contains(.inconsistentSizeAcrossActions))
    _ = manifest
}

@Test func undecodableImageIsError() {
    var (manifest, listing) = fullPack()
    listing.directories["sleep"] = [
        .init(name: "000.png", size: nil),
        .init(name: "001.png", size: size),
        .init(name: "002.png", size: size),
        .init(name: "003.png", size: size),
    ]
    let report = PackValidator.validate(manifest: manifest, directoryName: "test-blocks", listing: listing)
    #expect(report.errors.contains(.undecodableImage(path: "sleep/000.png")))
    _ = manifest
}

@Test func undeclaredDirectoryIsWarningAndIgnored() {
    var (manifest, listing) = fullPack()
    listing.directories["dance"] = files(4)
    let report = PackValidator.validate(manifest: manifest, directoryName: "test-blocks", listing: listing)
    #expect(report.isValid)
    #expect(report.warnings.contains(.undeclaredDirectory("dance")))
    _ = manifest
}

@Test func declaredActionWithoutDirectoryIsError() {
    var (manifest, listing) = fullPack()
    listing.directories.removeValue(forKey: "tumble")
    let report = PackValidator.validate(manifest: manifest, directoryName: "test-blocks", listing: listing)
    #expect(report.errors.contains(.declaredActionMissingDirectory("tumble")))
    _ = manifest
}

@Test func unknownActionNameIsWarning() {
    var (manifest, listing) = fullPack()
    manifest.actions["dance"] = .init(frames: 4, fps: 10, loop: true)
    listing.directories["dance"] = files(4)
    let report = PackValidator.validate(manifest: manifest, directoryName: "test-blocks", listing: listing)
    #expect(report.warnings.contains(.unknownActionName("dance")))
}

@Test func metadataRangeChecks() {
    let (badAnchor, l1) = fullPack(anchor: .init(x: 0.5, y: 1.4))
    #expect(PackValidator.validate(manifest: badAnchor, directoryName: "test-blocks", listing: l1)
        .errors.contains(.anchorOutOfRange(x: 0.5, y: 1.4)))

    let (badHeight, l2) = fullPack(logicalHeight: 4000)
    #expect(PackValidator.validate(manifest: badHeight, directoryName: "test-blocks", listing: l2)
        .errors.contains(.logicalHeightOutOfRange(4000)))

    let (badVersion, l3) = fullPack(schemaVersion: 99)
    #expect(PackValidator.validate(manifest: badVersion, directoryName: "test-blocks", listing: l3)
        .errors.contains(.unsupportedSchemaVersion(99)))

    let (badID, l4) = fullPack(id: "Bad_ID")
    #expect(PackValidator.validate(manifest: badID, directoryName: "Bad_ID", listing: l4)
        .errors.contains(.invalidID("Bad_ID")))

    let (mismatch, l5) = fullPack(id: "one")
    #expect(PackValidator.validate(manifest: mismatch, directoryName: "two", listing: l5)
        .errors.contains(.idDirectoryMismatch(id: "one", directory: "two")))

    // 規則是 ASCII 的 [a-z0-9-]+。Unicode 屬性版本會放行這個 id，而它與磁碟目錄名
    // 的正規化差異在 String 相等下看不出來，所以必須在 invalidID 就攔掉。
    let (unicodeID, l6) = fullPack(id: "café-cat")
    #expect(PackValidator.validate(manifest: unicodeID, directoryName: "café-cat", listing: l6)
        .errors.contains(.invalidID("café-cat")))
}

@Test func invalidFrameCountAndFPSAreErrors() {
    var (manifest, listing) = fullPack()
    manifest.actions["yawn"] = .init(frames: 0, fps: 0, loop: false)
    listing.directories["yawn"] = []   // 宣告 0 格、目錄也空，所以不會另外觸發 frameCountMismatch
    let report = PackValidator.validate(manifest: manifest, directoryName: "test-blocks", listing: listing)
    #expect(report.isValid == false)
    #expect(report.errors.contains(.invalidFrameCount(action: "yawn", frames: 0)))
    #expect(report.errors.contains(.invalidFPS(action: "yawn", fps: 0)))
    // 這兩個守衛是唯一阻止「零格動作進入 restPool」的東西：
    // 刪掉它們，該 pack 會以 isValid=true 通過且 .yawn 出現在 restPool 裡
    #expect(report.capabilities == nil)
}

@Test func inconsistentSizeAcrossActionsIsOnlyWarning() {
    var (manifest, listing) = fullPack()
    listing.directories["yawn"] = files(4, size: CGSize(width: 512, height: 512))
    let report = PackValidator.validate(manifest: manifest, directoryName: "test-blocks", listing: listing)
    #expect(report.isValid)
    #expect(report.warnings.contains(.inconsistentSizeAcrossActions))
    _ = manifest
}
