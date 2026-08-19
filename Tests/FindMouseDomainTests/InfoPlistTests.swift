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

/// 圖示的宣告面。
///
/// **這一條只驗宣告，不驗建置**——單元測試跑不到 `make-app.sh`。把兩個半邊釘在
/// 一起的是那支腳本自己：它讀剛複製進 `.app` 的那份 plist 宣告的名字，再確認
/// `Contents/Resources/` 底下真的有那個檔案。
///
/// 漏掉這個鍵的症狀是**圖示靜默不出現**，而 plist 本身完全合法：Finder、Dock、
/// Spotlight 都退回通用圖示，沒有任何錯誤訊息。v0.5.1 以前就是這個狀態。
@Test func theIconFileIsDeclared() throws {
    let plist = try infoPlist()
    let name = try #require(plist["CFBundleIconFile"] as? String,
                            "沒有 CFBundleIconFile，.app 會用通用圖示而且不會有任何訊息")
    #expect(!name.isEmpty)
    // 不寫 `.icns` 副檔名：CFBundleIconFile 的慣例是給不帶副檔名的基底名，
    // 而 make-app.sh 會自己接上 `.icns`。帶了副檔名不會壞，但兩邊的組法就
    // 各有一份假設了。
    #expect(!name.hasSuffix(".icns"), "只寫基底名，副檔名由 make-app.sh 接")
}

/// App Store 的主類別。
///
/// **為什麼在 Homebrew 版也要有**：出貨的是同一份 `Scripts/Info.plist`，兩條通路
/// 共用。分開維護兩份 plist 才是真正會漂掉的做法。
///
/// 只驗形狀不釘死值：換類別是產品決定，不該要改測試。要防的是**打錯字與整個漏掉**
/// ——Xcode 27 的 `DVTCorePlistStructDefs` 把這個鍵標成 `use="required"`，而它的
/// 合法值是一份 45 個字串的封閉清單（`public.app-category.utilities` 在裡面，
/// 2026-08-20 從那份定義檔查的）。不在清單上的字串會被 App Store Connect 退件，
/// 而在本機**沒有任何東西會發現**：plist 合法、簽章有效、App 照常啟動。
@Test func theAppStoreCategoryIsDeclared() throws {
    let category = try #require(try infoPlist()["LSApplicationCategoryType"] as? String,
                                "沒有 LSApplicationCategoryType，App Store 上架必填")
    #expect(category.hasPrefix("public.app-category."),
            "類別必須是 public.app-category.* 那份封閉清單裡的值，實際是「\(category)」")
    #expect(category != "public.app-category.", "前綴後面是空的")
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func privacyManifest() throws -> [String: Any] {
    let raw = try Data(contentsOf: repoRoot().appendingPathComponent("Scripts/PrivacyInfo.xcprivacy"))
    guard let dict = try PropertyListSerialization.propertyList(
        from: raw, format: nil) as? [String: Any] else {
        throw CocoaError(.propertyListReadCorrupt)
    }
    return dict
}

/// 隱私宣告清單宣告的東西，恰好是我們真的用到的那些。
///
/// 用**精確相等**的理由與 entitlements 那條一樣：多宣告一類不會壞掉，但它會變成
/// 一個沒有人知道能不能拿掉的宣告。少宣告一類則是上傳被退，而本機驗不出來。
///
/// 三個「無」的鍵也一起釘：把 `NSPrivacyTracking` 從 `false` 改成 `true` 不會讓
/// 任何東西報錯，只會讓 App Store 的隱私標籤說我們在追蹤使用者。
@Test func thePrivacyManifestDeclaresExactlyTheApisWeUse() throws {
    let m = try privacyManifest()

    #expect((m["NSPrivacyTracking"] as? Bool) == false, "FindMouse 不追蹤")
    #expect((m["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
    #expect((m["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.isEmpty == true)

    let types = try #require(m["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
    let declared = Set(types.compactMap { $0["NSPrivacyAccessedAPIType"] as? String })
    #expect(declared == ["NSPrivacyAccessedAPICategoryUserDefaults"],
            "宣告的 API 類別變了，每一類都要說得出哪一行程式碼用到它：\(declared.sorted())")

    let userDefaults = try #require(types.first {
        $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults"
    })
    // CA92.1 = Access info from same app。另外三個 User Defaults 代碼都不是我們：
    // 1C8F.1 是 App Group、AC6B.1 是受管理設定、C56D.1 是第三方 SDK。四個長得很像，
    // 寫錯的後果是上傳被退而本機全綠，所以這裡把值釘死。
    #expect((userDefaults["NSPrivacyAccessedAPITypeReasons"] as? [String]) == ["CA92.1"])
}

/// 反方向：程式碼開始用到某一類 required-reason API，而清單沒跟上。
///
/// 上面那條守的是「清單多宣告」，這條守的是「程式碼多用」——**兩個方向的失效
/// 完全不同**，而後者才是會被退件的那個。掃的是 `Sources/`，與
/// `ArchitectureBoundaryTests` 同一種專案衛生掃描。
///
/// 這是**文字比對**，所以它擋不住刻意規避（動態呼叫、字串拼接），那不是它的目的；
/// 目的是讓「順手加一行讀檔案修改時間」在 CI 就紅，而不是在上傳時才知道。
/// 已宣告的 UserDefaults 不在掃描範圍——它本來就該出現。
@Test func noUndeclaredRequiredReasonApiSneaksIntoSources() throws {
    // 每一類的標記取自 Apple 的 required reason API 清單裡實際會出現在 Swift 原始碼
    // 的那些呼叫。命中不代表一定要宣告（可能在註解裡），但它值得一次人工判讀。
    let markers: [String: [String]] = [
        "NSPrivacyAccessedAPICategoryFileTimestamp":
            [".creationDateKey", ".contentModificationDateKey", ".attributeModificationDateKey",
             "attributesOfItem(", "getattrlist(", "fstat(", "lstat("],
        "NSPrivacyAccessedAPICategorySystemBootTime":
            ["systemUptime", "mach_absolute_time(", "kern.boottime"],
        "NSPrivacyAccessedAPICategoryDiskSpace":
            [".volumeAvailableCapacityKey", ".volumeAvailableCapacityForImportantUsageKey",
             "systemFreeSize", "statfs("],
        "NSPrivacyAccessedAPICategoryActiveKeyboards":
            ["activeInputModes"],
    ]

    let sources = repoRoot().appendingPathComponent("Sources")
    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" } ?? []
    // 沒有這一行，整條測試在「路徑算錯、一個檔案都沒讀到」時會空洞地通過。
    #expect(files.count > 20, "只掃到 \(files.count) 個 .swift，路徑可能算錯了")

    let declared = Set((try privacyManifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [])
        .compactMap { $0["NSPrivacyAccessedAPIType"] as? String })

    for (category, needles) in markers where !declared.contains(category) {
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in needles where text.contains(needle) {
                Issue.record("""
                    \(file.lastPathComponent) 出現「\(needle)」，那屬於 \(category)，\
                    而 Scripts/PrivacyInfo.xcprivacy 沒有宣告它。\
                    確認是真的用到就去補宣告（代碼查 Xcode 的 DVTCorePlistStructDefs），\
                    只是碰巧出現在註解裡就改掉那個字。
                    """)
            }
        }
    }
}
