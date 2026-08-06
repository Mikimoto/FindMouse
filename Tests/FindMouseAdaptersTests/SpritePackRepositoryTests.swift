import CoreGraphics
import Foundation
import Testing
@testable import FindMouseAdapters
import FindMouseDomain

/// fixtures 是 SwiftPM resources，靠 `Bundle.module` 定位。
/// 用 `#require` 而不是 `#expect`：路徑找不到時後面每一條斷言都會是誤導。
private func fixtureURL(_ id: String) throws -> URL {
    let base = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return base.appendingPathComponent(id)
}

@Test func readsManifestAndListingFromARealDirectory() throws {
    let url = try fixtureURL("bad-frame-count")
    let loaded = try #require(SpritePackRepository.load(at: url))

    #expect(loaded.manifest.id == "bad-frame-count")
    #expect(loaded.manifest.logicalHeight == 96)
    #expect(loaded.manifest.anchor.x == 0.5)
    #expect(loaded.manifest.anchor.y == 0.9)
    #expect(loaded.manifest.facing == .right)
    #expect(loaded.manifest.mirrorForOpposite)
    #expect(loaded.directoryName == "bad-frame-count")
    // SpriteRepository（Task 6）要靠這個路徑載圖
    #expect(loaded.directoryURL == url)

    // 14 個動作都有目錄，每個 2 張 PNG
    #expect(loaded.listing.directories.count == 14)
    #expect(loaded.listing.directories["sitIdle"]?.count == 2)
    // 檔名依序排好：frameIndex 是位置索引，順序錯了動畫就是亂的
    #expect(loaded.listing.directories["sitIdle"]?.map(\.name) == ["000.png", "001.png"])
    #expect(loaded.listing.directories["sitIdle"]?
        .allSatisfy { $0.size == CGSize(width: 64, height: 64) } == true)

    // manifest 謊報 run 有 8 格，實際目錄裡是 2 張——兩邊都要如實讀出來，
    // 「不一致」的判定是 PackValidator 的事，不是這一層的
    #expect(loaded.manifest.actions["run"]?.frames == 8)
    #expect(loaded.listing.directories["run"]?.count == 2)
}

/// 每個動作目錄的檔案數都要等於實際 PNG 數，不能只驗抽樣的那一個——
/// fixture 的每個動作剛好都是 2 張，只驗一個的話「回傳寫死的 2」也會通過。
@Test func everyActionDirectoryIsCountedFromItsActualFiles() throws {
    let url = try fixtureURL("bad-missing-core")
    let loaded = try #require(SpritePackRepository.load(at: url))

    let manager = FileManager.default
    for (action, files) in loaded.listing.directories {
        let onDisk = try manager.contentsOfDirectory(
            at: url.appendingPathComponent(action), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        #expect(files.count == onDisk.count,
                "\(action)：清單 \(files.count) 筆，磁碟上 \(onDisk.count) 個 PNG")
    }
    // bad-missing-core 少了 sit 這個動作，目錄與宣告都不存在
    #expect(loaded.listing.directories["sit"] == nil)
    #expect(loaded.manifest.actions["sit"] == nil)
    #expect(loaded.listing.directories.count == 13)
}

/// 動作目錄裡的非 PNG 檔案不算一格。
///
/// 這不是假想的情境：macOS 只要用 Finder 開過那個目錄就會留下 `.DS_Store`，
/// 而它若被算成一格，`PackValidator` 會回報「宣告 2 格實際 3 檔」——
/// 一個使用者完全無法理解、而且與他的操作看似無關的錯誤。
@Test func strayNonPNGFilesAreNotCountedAsFrames() throws {
    let source = try fixtureURL("bad-missing-teaser")
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fm-stray-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: source, to: temp)
    defer { try? FileManager.default.removeItem(at: temp) }

    let runDir = temp.appendingPathComponent("run")
    try Data().write(to: runDir.appendingPathComponent(".DS_Store"))
    try Data("readme".utf8).write(to: runDir.appendingPathComponent("notes.txt"))

    let loaded = try #require(SpritePackRepository.load(at: temp))
    #expect(loaded.listing.directories["run"]?.count == 2)
    #expect(loaded.listing.directories["run"]?.map(\.name) == ["000.png", "001.png"])
}

@Test func missingDirectoryReturnsNil() {
    #expect(SpritePackRepository.load(at: URL(fileURLWithPath: "/nonexistent/pack")) == nil)
}

/// 解不開的 PNG 以 `size == nil` 表示，不是從清單裡消失。
///
/// 這個區別是必要的：`PackValidator` 靠 `size == nil` 判「PNG 無法解碼」，
/// 若這一層直接略過該檔案，錯誤會退化成「格數不符」——訊息就指錯地方了。
@Test func undecodablePNGKeepsItsSlotWithNilSize() throws {
    // 複製一份到暫存目錄再破壞：fixtures 是共用 resources，改它會污染別的測試
    let source = try fixtureURL("bad-missing-teaser")
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fm-broken-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: source, to: temp)
    defer { try? FileManager.default.removeItem(at: temp) }

    try Data("not a png".utf8).write(to: temp.appendingPathComponent("run/000.png"))

    let loaded = try #require(SpritePackRepository.load(at: temp))
    let run = try #require(loaded.listing.directories["run"])
    #expect(run.count == 2, "壞掉的那張仍要佔一個位置")
    #expect(run.first { $0.name == "000.png" }?.size == nil)
    // 同目錄其他格仍讀得到，證明失敗是逐檔的而不是整個目錄放棄
    #expect(run.first { $0.name == "001.png" }?.size != nil)
}

/// pack.json 壞掉時回 nil，而不是丟出例外或回一個半殘的 manifest。
@Test func undecodableManifestReturnsNil() throws {
    let source = try fixtureURL("bad-frame-count")
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fm-badjson-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: source, to: temp)
    defer { try? FileManager.default.removeItem(at: temp) }

    try Data("{ not json".utf8).write(to: temp.appendingPathComponent("pack.json"))
    #expect(SpritePackRepository.load(at: temp) == nil)
}
