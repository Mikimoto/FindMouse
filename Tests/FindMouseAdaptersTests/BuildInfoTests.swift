// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import FindMouseAdapters

@Test func readsAllThreeKeysFromAReleaseBuild() {
    let info: [String: Any] = ["FMSourceVersion": "0.4.0",
                               "FMSourceCommit": "a3c3feb",
                               "FMIsDevelopmentBuild": false]
    #expect(BuildInfo.stamp(from: info) == "0.4.0 (a3c3feb)")
}

@Test func readsADevelopmentBuild() {
    let info: [String: Any] = ["FMSourceVersion": "v0.3.1-5-ga3c3feb",
                               "FMIsDevelopmentBuild": true]
    #expect(BuildInfo.stamp(from: info) == "v0.3.1-5-ga3c3feb (dev)")
}

/// plist 完全沒有那三個鍵——`make-app.sh` 漏寫時的形態。
@Test func missingKeysDegradeToDevelopment() {
    #expect(BuildInfo.stamp(from: [:]) == "開發版")
}

/// `nil` dictionary：`Bundle.main.infoDictionary` 的型別是 optional。
@Test func nilDictionaryDegradesToDevelopment() {
    #expect(BuildInfo.stamp(from: nil) == "開發版")
}

/// **型別不對時一律當開發建置。** 2026-08-12 實測 `PlistBuddy Add ... bool true`
/// 進到 Swift 確實是 `Bool`，所以這條在正常流程走不到——它釘的是一個不變式：
/// `Add :K string true` 與 `Add :K bool true` 只差一個字，寫錯時降級方向必須是
/// 安全的那邊。把開發建置誤標成發布版，會讓人拿一份含未提交改動的 .app 當發布
/// 產物來判斷問題；反過來把發布版誤標成 (dev) 只是難看。
@Test func wrongTypeOnTheDevelopmentFlagIsTreatedAsDevelopment() {
    let info: [String: Any] = ["FMSourceVersion": "0.4.0",
                               "FMSourceCommit": "a3c3feb",
                               "FMIsDevelopmentBuild": "false"]
    #expect(BuildInfo.stamp(from: info) == "0.4.0 (dev)")
}

/// 版本鍵的型別不對 → 當缺鍵，而不是把數字硬轉成字串。
@Test func wrongTypeOnTheVersionKeyIsTreatedAsMissing() {
    let info: [String: Any] = ["FMSourceVersion": 4,
                               "FMIsDevelopmentBuild": true]
    #expect(BuildInfo.stamp(from: info) == "開發版")
}
