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
        self.roots = roots
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
        // 未來的 macOS 加了新狀態時，當成 notFound 而不是硬當成 enabled——
        // 猜錯的方向要選「看起來壞掉」而不是「看起來正常」。
        //
        // 實測（2026-08-11）notFound 的行為等同 notRegistered（可以點、on 會
        // 去 register），所以這個 fallback 的代價是「使用者按一次 register，
        // 成功就成功、失敗有說明」——比假裝已經開著安全。
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
