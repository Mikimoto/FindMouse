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
    #expect(tree.installableEntries(under: "cat").map(\.relativePath)
            == ["cat/pack.json", "cat/run/000.png"])
}

/// 前綴比對要以路徑分隔為界，`cat` 不能匹配到 `catalog/`。
@Test func siblingWithTheSamePrefixIsNotUnderIt() {
    let tree = ExtractedTree(entries: [entry("cat/pack.json"),
                                       entry("catalog/pack.json")])
    #expect(tree.installableEntries(under: "cat").map(\.relativePath) == ["cat/pack.json"])
}

/// cruft 不會被裝進去。`__MACOSX` 這個**目錄本身**要一起濾掉：只濾它底下的話，
/// 目的地會多一個空目錄，而那會讓 `PackValidator` 報 undeclaredDirectory。
@Test func cruftIsNotInstalledIncludingTheMacOSXDirectoryItself() {
    let tree = ExtractedTree(entries: [entry("__MACOSX", .directory, bytes: 0),
                                       entry("__MACOSX/._pack.json"),
                                       entry(".DS_Store"),
                                       entry("pack.json"),
                                       entry("run", .directory, bytes: 0),
                                       entry("run/000.png")])
    #expect(tree.installableEntries(under: "").map(\.relativePath)
            == ["pack.json", "run", "run/000.png"])
}

/// **根是空字串時，夾帶的檔案擋不掉。** ditto 把 `../escaped.txt` 攤平到解壓根
/// 之後，它與作者真的放在 pack 根的檔案長得一模一樣。這條釘住那個已知邊界，
/// 免得註解與程式碼各說各話——守住的是「不會跑到 Packs 外面」而不是「裡面乾淨」。
@Test func aFlattenedStrayIsIndistinguishableWhenTheManifestSitsAtTheRoot() {
    let tree = ExtractedTree(entries: [entry("escaped.txt"), entry("pack.json")])
    #expect(tree.installableEntries(under: "").map(\.relativePath)
            == ["escaped.txt", "pack.json"])
}
