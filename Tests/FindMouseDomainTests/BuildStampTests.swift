// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import FindMouseDomain

private func stamp(_ version: String?, _ commit: String?, dev: Bool) -> String {
    BuildStamp.display(version: version, commit: commit, isDevelopment: dev)
}

// MARK: - 發布版

@Test func releaseWithCommitShowsVersionAndCommit() {
    #expect(stamp("0.4.0", "a3c3feb", dev: false) == "0.4.0 (a3c3feb)")
}

@Test func releaseWithoutCommitShowsVersionAlone() {
    #expect(stamp("0.4.0", nil, dev: false) == "0.4.0")
}

// MARK: - 開發建置

/// describe 的輸出**已經含 sha**，所以不再括號一次——這條是防重複的唯一守衛，
/// 而且必須用完整字串相等比對：`contains(sha)` 對「sha 出現兩次」照樣通過。
@Test func developmentBuildUsesDescribeOutputWithoutRepeatingTheSHA() {
    #expect(stamp("v0.3.1-5-ga3c3feb-dirty", "a3c3feb", dev: true)
            == "v0.3.1-5-ga3c3feb-dirty (dev)")
}

@Test func developmentBuildWithoutVersionFallsBackToChinese() {
    #expect(stamp(nil, "a3c3feb", dev: true) == "開發版 (a3c3feb)")
}

@Test func developmentBuildWithNothingKnown() {
    #expect(stamp(nil, nil, dev: true) == "開發版")
}

// MARK: - 不該發生但必須有定義的組合

/// 自稱發布版卻不知道自己版本的產物是壞的，用與「開發版」不同的字，
/// 免得那件事看起來正常。
@Test func releaseWithoutVersionSaysUnknownNotDevelopment() {
    #expect(stamp(nil, nil, dev: false) == "版本不明")
    #expect(stamp(nil, "a3c3feb", dev: false) == "版本不明 (a3c3feb)")
}

// MARK: - 空字串邊界

/// 腳本寫入失敗的形態可能是「鍵不存在」也可能是「空字串」，兩者結果必須相同——
/// 否則同一個故障會有兩種畫面。
@Test func emptyStringsBehaveLikeMissingKeys() {
    #expect(stamp("", "", dev: true) == "開發版")
    #expect(stamp("", "a3c3feb", dev: true) == "開發版 (a3c3feb)")
    #expect(stamp("0.4.0", "", dev: false) == "0.4.0")
}
