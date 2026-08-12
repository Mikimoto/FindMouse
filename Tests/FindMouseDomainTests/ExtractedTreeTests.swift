// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import FindMouseDomain

private func entry(_ path: String, _ kind: ExtractedTree.Entry.Kind = .file,
                   bytes: Int = 10) -> ExtractedTree.Entry {
    .init(relativePath: path, kind: kind, bytes: bytes)
}

// MARK: - 認 pack 根

@Test func manifestAtTheRootMeansTheRootIsThePack() throws {
    let tree = ExtractedTree(entries: [entry("pack.json"), entry("run/000.png")])
    #expect(try tree.packRoot() == "")
}

@Test func manifestOneLevelDownMeansThatDirectoryIsThePack() throws {
    let tree = ExtractedTree(entries: [entry("orange-cat/pack.json"),
                                       entry("orange-cat/run/000.png")])
    #expect(try tree.packRoot() == "orange-cat")
}

/// zip 裡有兩套 pack。訊息要講出「找到幾個」——「格式不對」讓人無從下手。
@Test func twoManifestsIsAnErrorThatNamesTheCount() {
    let tree = ExtractedTree(entries: [entry("a/pack.json"), entry("b/pack.json")])
    #expect(throws: ExtractedTree.Failure.multiplePacks(["a", "b"])) { try tree.packRoot() }
}

@Test func noManifestIsItsOwnError() {
    let tree = ExtractedTree(entries: [entry("run/000.png")])
    #expect(throws: ExtractedTree.Failure.noManifest) { try tree.packRoot() }
}

/// 巢狀的第二個 manifest 也算兩個。深度不是判準——「恰好一個」才是。
@Test func aNestedSecondManifestStillCountsAsTwo() {
    let tree = ExtractedTree(entries: [entry("cat/pack.json"),
                                       entry("cat/inner/pack.json")])
    #expect(throws: ExtractedTree.Failure.multiplePacks(["cat", "cat/inner"])) {
        try tree.packRoot()
    }
}

/// macOS 打包 zip 常夾這兩樣。它們不該讓「恰好一個」的判定失敗。
@Test func macOSCruftIsIgnoredWhenLookingForThePack() throws {
    let tree = ExtractedTree(entries: [entry("__MACOSX/._pack.json"),
                                       entry(".DS_Store"),
                                       entry("cat/pack.json"),
                                       entry("cat/.DS_Store")])
    #expect(try tree.packRoot() == "cat")
}

// MARK: - 非 regular file

@Test func aSymlinkAnywhereIsRejectedAndNamed() {
    let tree = ExtractedTree(entries: [entry("cat/pack.json"),
                                       entry("cat/evil", .other)])
    #expect(throws: ExtractedTree.Failure.notARegularFile("cat/evil")) {
        try tree.rejectIrregularEntries()
    }
}

@Test func directoriesAreFineOfCourse() throws {
    let tree = ExtractedTree(entries: [entry("cat", .directory, bytes: 0),
                                       entry("cat/pack.json")])
    try tree.rejectIrregularEntries()
}

// MARK: - 大小

@Test func totalBytesCountsFilesOnly() {
    let tree = ExtractedTree(entries: [entry("cat", .directory, bytes: 0),
                                       entry("cat/pack.json", bytes: 100),
                                       entry("cat/run/000.png", bytes: 900)])
    #expect(tree.totalBytes == 1000)
}

// MARK: - 只挑 pack 根底下的東西（安全論述的唯一守衛）

/// `ditto` 會把 zip 裡的 `../escaped.txt` **攤平到解壓根目錄**（2026-08-12 實測，
/// 沒有逃出去但也沒被拒絕）。所以搬移時只能取 pack 根底下的路徑。
@Test func entriesOutsideThePackRootAreNotPartOfIt() {
    let tree = ExtractedTree(entries: [entry("escaped.txt"),
                                       entry("cat/pack.json"),
                                       entry("cat/run/000.png")])
    #expect(tree.entries(under: "cat").map(\.relativePath)
            == ["cat/pack.json", "cat/run/000.png"])
}

/// 前綴比對要以路徑分隔為界，`cat` 不能匹配到 `catalog/`。
@Test func siblingWithTheSamePrefixIsNotUnderIt() {
    let tree = ExtractedTree(entries: [entry("cat/pack.json"),
                                       entry("catalog/pack.json")])
    #expect(tree.entries(under: "cat").map(\.relativePath) == ["cat/pack.json"])
}
