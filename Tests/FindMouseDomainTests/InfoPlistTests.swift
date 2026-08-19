// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

/// `Scripts/Info.plist` 的內部一致性。
///
/// **為什麼有這個檔**：`.fmpack` 的雙擊入口完全靠那份 plist，而它沒有任何編譯期
/// 檢查——`make-app.sh` 只是把它 `cp` 進 `.app`。寫錯了不會有錯誤訊息，症狀是
/// 「雙擊沒反應」或「被別的 app 接走」，而那兩種都要裝好、註冊、實際雙擊一次
/// 才看得出來。
///
/// **為什麼住在 `FindMouseDomainTests`**：`FindMouseApp` 沒有測試 target，而這個
/// target 已經在做同一類的專案衛生掃描（`ArchitectureBoundaryTests` 讀 `Sources/`）。
/// 分成獨立檔案而不是塞進那一個：兩者掃的東西沒有關係。
private func infoPlist() throws -> [String: Any] {
    // `#filePath` → Tests/FindMouseDomainTests/ → Tests/ → repo 根
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = root.appendingPathComponent("Scripts/Info.plist")
    let raw = try Data(contentsOf: url)
    guard let dict = try PropertyListSerialization.propertyList(
        from: raw, format: nil) as? [String: Any] else {
        throw CocoaError(.propertyListReadCorrupt)
    }
    return dict
}

/// `CFBundleDocumentTypes` 認領的每一個型別，都必須在 `UTExportedTypeDeclarations`
/// （或 `UTImportedTypeDeclarations`）裡宣告過。
///
/// 2026-08-13 實測六個變體，這是最貴的一格：`LSItemContentTypes` 指到一個**沒宣告
/// 過**的識別字時，系統**連預設 handler 都沒有**——不是退回別的 app，是查不到任何
/// 東西。而「宣告了」與「漏掉宣告」在 plist 上看起來一模一樣。
@Test func everyClaimedDocumentTypeIsDeclared() throws {
    let root = try infoPlist()
    let declared = Set(
        (root["UTExportedTypeDeclarations"] as? [[String: Any]] ?? [])
            .compactMap { $0["UTTypeIdentifier"] as? String }
        + (root["UTImportedTypeDeclarations"] as? [[String: Any]] ?? [])
            .compactMap { $0["UTTypeIdentifier"] as? String })
    let claimed = Set((root["CFBundleDocumentTypes"] as? [[String: Any]] ?? [])
        .flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })

    // 沒有這一行，整條測試在「兩個鍵都不見了」時會空洞地通過——而那正是
    // 雙擊入口整個消失的樣子。
    #expect(!claimed.isEmpty, "沒有認領任何型別，這條測試會空洞地通過")
    #expect(claimed.isSubset(of: declared),
            "這些型別被認領卻沒宣告，系統會連 handler 都沒有：\(claimed.subtracting(declared))")
}

/// 副檔名與型別的對應只有一份。少了 `UTTypeTagSpecification`，`.fmpack` 會落回
/// `dyn.…`（實測），於是 Finder 顯示不出型別描述，任何想按型別過濾的地方也拿不到
/// 穩定的識別字。
@Test func theFmpackExtensionIsMappedToTheExportedType() throws {
    let exported = try infoPlist()["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
    let fmpack = try #require(exported.first {
        (($0["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"]
            as? [String])?.contains("fmpack") == true
    }, "沒有任何 exported type 宣告 fmpack 這個副檔名")
    #expect(fmpack["UTTypeIdentifier"] as? String == "tw.com.deepthought.findmouse.fmpack")
}

/// `Scripts/FindMouse.entitlements` 的兩個鍵，各自守著一件會靜默失效的事。
///
/// 這個檔案與 `Info.plist` 同一種危險：`make-app.sh` 與 `release.sh` 只是把它交給
/// `codesign`，沒有任何編譯期檢查，而拿掉一個鍵的後果**都不是錯誤訊息**。
///
/// - `app-sandbox`：拿掉的話 App 綁的 socket 不在容器裡，CLI 永遠回
///   `APP_NOT_RUNNING` 而 App 一切正常。`make-app.sh` 簽完當場斷言一次，這裡
///   是第二道（那一道擋不住「有人把這個鍵從檔案裡刪掉」——它讀的是簽出來的結果）。
/// - `files.user-selected.read-only`：**NSOpenPanel 是第三個機制**，powerbox 不吃
///   雙擊與拖放各自發的那張 extension。少了它面板根本不出現，`runModal()` 當場回
///   `.cancel`、`url` 是 nil——與使用者按取消**一個字都不差**（2026-08-17 實測，
///   log 裡 `openAndSavePanelService` 起來 4ms 後就被 `xpc_connection_cancel()`）。
///   搬移舊 pack 那條路（`AppDelegate.runLegacyPackMigration`）就是靠它。
///
/// 用**精確相等**而不是「至少含這兩個」：多一個 entitlement 是安全面的擴權，
/// 應該逼人回來這裡寫下理由，理由與 `swiftUIStaysInTheSettingsWindow` 同一條。
@Test func theSandboxEntitlementsAreExactlyTheOnesWeCanJustify() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let raw = try Data(contentsOf: root.appendingPathComponent("Scripts/FindMouse.entitlements"))
    let plist = try #require(
        try PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any])

    // **比 key 的集合，不是「值為 true 的那些」。** 原本寫成
    // `plist.filter { ($0.value as? Bool) == true }`，於是值不是布林的 entitlement
    // 完全隱形——加一條 `com.apple.security.temporary-exception.files.absolute-path
    // .read-write`（值是陣列）進去，這條測試照樣全綠（2026-08-19 突變實測）。
    // 而 temporary-exception 那一族正是最該被擋下的：它在沙盒上開一個洞，
    // 卻不長得像一個開關，所以「只看開關」的寫法對它天生瞎。
    #expect(Set(plist.keys) == ["com.apple.security.app-sandbox",
                               "com.apple.security.files.user-selected.read-only"],
            "entitlement 清單變了。每一個都要說得出哪一個實測失敗需要它：\(plist.keys.sorted())")

    // 值也要真的是 `true`。只比 key 的話，把 app-sandbox 改成 `<false/>` 會全綠，
    // 而那等於整個沙盒沒了——檔案看起來還好端端地宣告著它。
    for (key, value) in plist {
        #expect((value as? Bool) == true, "\(key) 的值不是 true：\(value)")
    }
}
