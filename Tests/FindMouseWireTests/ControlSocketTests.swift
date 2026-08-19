// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing
@testable import FindMouseWire

/// `Scripts/Info.plist` 的 `CFBundleIdentifier`。
///
/// 與 `InfoPlistTests` 那支同一招（`#filePath` 往上三層到 repo 根），但那支在
/// `FindMouseDomainTests`，而這個 target 依賴的是 Wire——跨 target 用不到，
/// 所以這裡自己讀一次。抄的是六行，換到的是「這條測試放在它守的東西旁邊」。
private func infoPlistBundleID() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let raw = try Data(contentsOf: root.appendingPathComponent("Scripts/Info.plist"))
    let dict = try PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any]
    return try #require(dict?["CFBundleIdentifier"] as? String)
}

/// **這條是這個檔案存在的理由。**
///
/// 沙盒之後 socket 住在 App 的容器裡，而容器路徑以 bundle id 命名。CLI 不沙盒、
/// 也讀不到 App 的 Info.plist，所以它只能拿一份編譯期常數去算。兩者漂開的症狀是
/// CLI 回 `APP_NOT_RUNNING`——與「App 真的沒開」一個字都不差，而 App 那端一切正常。
@Test func bundleIDMatchesTheInfoPlist() throws {
    #expect(ControlSocket.bundleID == (try infoPlistBundleID()))
}

/// socket 要住在**容器根**，不是容器裡的 Application Support。
///
/// 後者實測 119 bytes，而 `sun_path` 只有 104——長度不是風格問題，是 bind 得起來
/// 與否。這條釘住路徑形狀，免得哪天有人「順手」改回 `applicationSupportDirectory`
/// （那在沙盒下會自動變成那條 119 bytes 的路徑，而且只有真的跑起來才看得出來）。
@Test func theSocketLivesAtTheContainerRoot() {
    let path = ControlSocket.containerData
    #expect(path.hasSuffix("/Library/Containers/\(ControlSocket.bundleID)/Data"))
    #expect(!path.contains("Application Support"))
}

/// 預設路徑要短到綁得起來。
///
/// 用實際的 `sun_path` 容量比，不是寫死 104——那個常數在別的平台可能不同，
/// 而 `WireClient.connect` 與 `UnixSocketServer.start` 的守衛讀的也是這個值。
@Test func theDefaultPathFitsInSunPath() {
    var addr = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    #expect(ControlSocket.path.utf8.count < capacity,
            "預設路徑 \(ControlSocket.path.utf8.count) bytes，上限 \(capacity)：\(ControlSocket.path)")
}

/// 路徑要從家目錄長出來。
///
/// **這條守不住「`getpwuid` 被換成 `NSHomeDirectory()`」，而那正是原始碼那段註解
/// 在講的事——所以先把話說清楚，免得有人以為它守得住。** 兩者只在沙盒下不同，
/// 而測試 process 不沙盒：實測連 `HOME=/tmp/fake` 都改不動 `NSHomeDirectory()`
/// （它讀的是 passwd，不是環境變數），所以在這裡**沒有任何輸入**能讓兩者分岔。
///
/// 它守得住的是別的東西：路徑改成從 `NSTemporaryDirectory()`、從相對路徑、
/// 或從某個寫死的地方長出來，這條都會紅。那個 swap 的真正防線是 App 端的
/// `isInOwnContainer`——它在**真的沙盒裡**跑，那時兩者才分得開。
@Test func theContainerPathStartsAtTheHomeDirectory() throws {
    let pw = try #require(getpwuid(getuid()))
    let dir = try #require(pw.pointee.pw_dir)
    let real = String(cString: dir)
    #expect(ControlSocket.containerData.hasPrefix(real + "/"))
}

/// 覆寫要贏過推導出來的路徑——e2e 與開發時都靠它。
@Test func theEnvironmentOverrideWins() throws {
    let key = "FINDMOUSE_SOCKET"
    let saved = ProcessInfo.processInfo.environment[key]
    defer {
        if let saved { setenv(key, saved, 1) } else { unsetenv(key) }
    }
    // **值不用 `/tmp`。** 這條只驗字串優先序、不會真的 bind，但沙盒下在 `/tmp`
    // bind 回 EPERM（CLAUDE.md 記過），拿它當範例會讓讀的人以為那是可行的覆寫
    // 目的地。用容器內的形狀，與 `e2e.sh` 實際的用法一致。
    let override = ControlSocket.containerData + "/fm-override-check.sock"
    setenv(key, override, 1)
    #expect(ControlSocket.path == override)
}

/// 舊位置**不是**從容器算的，而且不受 `FINDMOUSE_SOCKET` 影響。
///
/// 它是一個歷史事實（沙盒之前 `applicationSupportDirectory` 解到的地方），
/// 拿現在的 API 去算會在沙盒下解到容器裡——那正是新位置，於是判別永遠成立，
/// 每一次「App 沒在跑」都會被說成「你的 App 是舊版」。
@Test func theLegacyPathIsTheRealHomeNotTheContainer() throws {
    let pw = try #require(getpwuid(getuid()))
    let dir = try #require(pw.pointee.pw_dir)
    let real = try #require(String(validatingUTF8: dir))
    #expect(ControlSocket.legacyPath
            == real + "/Library/Application Support/FindMouse/control.sock")
    #expect(ControlSocket.legacyPath != ControlSocket.path)
    #expect(!ControlSocket.legacyPath.hasPrefix(ControlSocket.containerData),
            "舊位置若落在容器裡，這個判別就永遠成立")
}
