// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ServiceManagement
import FindMouseDomain

/// 「開機時啟動」對系統的那一面。
///
/// 抽成協定是為了讓 `RequestRouter` 的測試能餵假狀態——真的去註冊登入項目
/// 是不可逆的副作用，測試不該做那種事。
public protocol LoginItemGateway: AnyObject {
    /// 當下狀態。每次都重問，不快取：使用者可能剛在系統設定裡改過。
    var state: LoginItem.State { get }
    func register() throws
    func unregister() throws
    /// 帶使用者去「系統設定 → 一般 → 登入項目」。
    func openSystemSettings()
}

public final class SystemLoginItem: LoginItemGateway {

    private let bundleURL: URL
    private let roots: [URL]

    /// - Parameter bundleURL: 預設是本 app 的 bundle，**已解過 symlink**。
    ///   解析會碰磁碟，所以留在這一層；`LoginItem.isEligibleLocation` 只做純比對。
    /// - Parameter roots: 視為穩定的位置。`~/Applications` 與 `/Applications`
    ///   一樣穩定——使用者把 app 收在自己的家目錄不代表它會消失。
    public init(bundleURL: URL = Bundle.main.bundleURL.resolvingSymlinksInPath(),
                roots: [URL] = [
                    URL(fileURLWithPath: "/Applications"),
                    FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Applications"),
                ]) {
        self.bundleURL = bundleURL
        // roots 也要解 symlink，否則與已解過的 bundleURL 比不起來。
        // 家目錄在外接磁碟、由 symlink 指過去時，真的裝在 ~/Applications 的 app
        // 會永遠判成 ineligible，勾變成灰的還配一句「請拖進應用程式資料夾」——
        // 而它已經在那裡了。`standardizedFileURL` 不解 symlink，只做路徑正規化。
        self.roots = roots.map { $0.resolvingSymlinksInPath() }
    }

    public var state: LoginItem.State {
        // 不合格優先於系統狀態：位置不穩定時，系統怎麼說都不重要，
        // 因為我們不會在那裡註冊（見 spec 一、為什麼不在 Applications 底下就不讓開）。
        guard LoginItem.isEligibleLocation(bundleURL, under: roots) else {
            return .ineligible
        }
        switch SMAppService.mainApp.status {
        case .notRegistered:    return .notRegistered
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .notFound
        // 未來的 macOS 加了新狀態時當成 notFound。
        //
        // 注意這**不是**「往看起來壞掉的方向猜」：實測之後 notFound 的行為
        // 等同 notRegistered，可以點、on 會去 register、CLI 印「關」。所以這個
        // fallback 的實際代價是「顯示成還沒開，使用者按一下就會嘗試註冊，
        // 成功就成功、失敗有說明」。若那個新狀態其實代表「已註冊」，畫面會
        // 少報一個開著的項目——要避免那個就得為它開一個帶說明的獨立狀態，
        // 而在真的出現之前沒有東西可以驗，所以先不預先造。
        @unknown default:       return .notFound
        }
    }

    // register() 之後不需要等待或重試：2026-08-11 用探針實測，同一個 process 裡
    // 緊接著重讀 status 就已經是 enabled（raw=1）。呼叫端照樣要重讀一次，
    // 因為結果可能是 requiresApproval——那是「呼叫成功但不是你要的結果」。
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
