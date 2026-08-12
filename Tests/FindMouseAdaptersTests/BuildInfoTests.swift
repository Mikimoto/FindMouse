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

/// **型別不對時一律當開發建置。**
///
/// 這條**不要刪**。它唯一能反駁的是「把 `as? Bool` 換成寬鬆轉型」這個很自然的
/// 重構——`(x as AnyObject).boolValue` 或 `NSString.boolValue` 會把字串 `"false"`
/// 讀成 `false`，於是一個型別打錯的發布版會被當成真的發布版出貨。其他測試都抓不到
/// 那個改動（對「刪掉這段」型的突變，它與 `missingKeysDegradeToDevelopment` 無法區分，
/// 所以光看突變結果會覺得它多餘）。
///
/// 型別打錯的來源在**腳本**而不是這裡：`Add :K string false` 與 `Add :K bool false`
/// 只差一個字，而 `PlistBuddy Print` 對兩者都印 `false`（實測）。`release.sh` 因此
/// 用 `plutil -p` 斷言型別——那一側是這個不變式的另一半。
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
