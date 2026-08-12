// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import FindMouseDomain

// MARK: - 解析

@Test func plainSemverParses() {
    #expect(PackVersion.parse("1.2.3") == PackVersion(major: 1, minor: 2, patch: 3))
    #expect(PackVersion.parse("2.0") == PackVersion(major: 2, minor: 0, patch: 0))
    #expect(PackVersion.parse("3") == PackVersion(major: 3, minor: 0, patch: 0))
}

/// 解析不出是**正常情況**不是錯誤：spec 第 6.2 節只規範 id 的格式，
/// 作者填什麼都合法。所以回 nil 而不是丟例外。
@Test func nonSemverIsNilNotAnError() {
    #expect(PackVersion.parse("v3") == nil)
    #expect(PackVersion.parse("1.0-beta") == nil)
    #expect(PackVersion.parse("") == nil)
    #expect(PackVersion.parse(nil) == nil)
    #expect(PackVersion.parse("１.０") == nil, "全角數字：Int() 會成功，但那不是這裡的語意")
    #expect(PackVersion.parse("1..2") == nil)
    #expect(PackVersion.parse("1.2.3.4") == nil, "四段不是 semver")
}

@Test func comparisonIsByComponent() {
    #expect(PackVersion.parse("1.10.0")! > PackVersion.parse("1.9.9")!)
    #expect(PackVersion.parse("2.0")! > PackVersion.parse("1.99.99")!)
    #expect(PackVersion.parse("1.0.0")! == PackVersion.parse("1.0")!)
}

// MARK: - 呈現（spec 第三節那張四列表）

private func message(installed: String?, incoming: String?, name: String = "橘貓") -> String {
    PackVersion.replacementPrompt(packName: name, installed: installed, incoming: incoming)
}

@Test func upgradeSaysUpdate() {
    #expect(message(installed: "1.0", incoming: "2.0")
            == "「橘貓」已安裝 1.0，要更新成 2.0 嗎？")
}

/// 降級要**明說是較舊的**。使用者會據此做相反的決定，所以這條不能只講「要取代嗎」。
@Test func downgradeSaysItIsOlder() {
    #expect(message(installed: "2.0", incoming: "1.0")
            == "「橘貓」已安裝 2.0，要換成較舊的 1.0 嗎？")
}

@Test func sameVersionSaysReinstall() {
    #expect(message(installed: "1.0", incoming: "1.0.0")
            == "「橘貓」已安裝的也是 1.0，要重新安裝嗎？")
}

/// 任一邊解析不出就**不講方向**，只並列事實。講錯方向比不講傷害大。
@Test func unparsableSidesJustListBothValues() {
    #expect(message(installed: "2026.08", incoming: "v3")
            == "「橘貓」已安裝的版本是 2026.08，要換成 v3 嗎？")
}

@Test func missingVersionsFallBackToNoVersionAtAll() {
    #expect(message(installed: nil, incoming: nil) == "「橘貓」已安裝，要取代嗎？")
    #expect(message(installed: nil, incoming: "2.0")
            == "「橘貓」已安裝（沒有標版本），要換成 2.0 嗎？")
    #expect(message(installed: "2.0", incoming: nil)
            == "「橘貓」已安裝 2.0，要換成一份沒有標版本的嗎？")
}
