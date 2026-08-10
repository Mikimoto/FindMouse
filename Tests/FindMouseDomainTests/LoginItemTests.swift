import Foundation
import Testing
@testable import FindMouseDomain

// MARK: - 路徑述詞

/// 兩個「應用程式」根目錄。真實環境由 Adapters 供應，這裡寫死好比對。
private let roots = [URL(fileURLWithPath: "/Applications"),
                     URL(fileURLWithPath: "/Users/someone/Applications")]

private func eligible(_ path: String) -> Bool {
    LoginItem.isEligibleLocation(URL(fileURLWithPath: path), under: roots)
}

@Test func appDirectlyInApplicationsIsEligible() {
    #expect(eligible("/Applications/FindMouse.app"))
}

@Test func appNestedUnderApplicationsIsEligible() {
    // 使用者會把 app 收進子資料夾，那不影響路徑穩定性
    #expect(eligible("/Applications/Utilities/FindMouse.app"))
}

@Test func userLevelApplicationsIsEligible() {
    #expect(eligible("/Users/someone/Applications/FindMouse.app"))
}

@Test func buildDirectoryIsNotEligible() {
    #expect(!eligible("/Users/someone/Developer/FindMouse/build/FindMouse.app"))
}

@Test func translocatedPathIsNotEligible() {
    // 使用者直接在 dmg 裡雙擊而沒拖出來時，macOS 跑的是這種隨機化唯讀路徑
    #expect(!eligible(
        "/private/var/folders/ph/x/T/AppTranslocation/1A2B/d/FindMouse.app"))
}

@Test func siblingDirectoryWithApplicationsPrefixIsNotEligible() {
    // 這條防的是 hasPrefix("/Applications")——它會把 /ApplicationsFoo 判成合格。
    // 述詞必須比對路徑元件。
    #expect(!eligible("/ApplicationsFoo/FindMouse.app"))
}

@Test func aRootItselfIsNotAnApp() {
    // 邊界：路徑就是根目錄本身，沒有 app 在裡面
    #expect(!eligible("/Applications"))
}

// MARK: - 決策表

private func decide(_ c: LoginItem.Command,
                    _ s: LoginItem.State) -> LoginItem.Outcome {
    LoginItem.decide(c, from: s)
}

// --- 查詢：任何狀態都是 0、不碰系統 ---

@Test(arguments: LoginItem.State.allCases)
func queryNeverTouchesTheSystem(_ state: LoginItem.State) {
    let out = decide(.query, state)
    #expect(out.effect == .none)
    #expect(out.exitCode == 0)
    #expect(out.failure == nil)
}

// --- on ---

@Test func onWhenIneligibleIsRefusedWithoutTouchingTheSystem() {
    let out = decide(.on, .ineligible)
    #expect(out.exitCode == 1)
    #expect(out.failure == .ineligible)
    // 這一條比 exit code 更重要：被擋下的 on **不可以**去呼叫 register()。
    // 只斷言 exit code 的話，「先註冊了再回報失敗」會照樣通過。
    #expect(out.effect == .none)
}

@Test func onWhenNotRegisteredRegisters() {
    let out = decide(.on, .notRegistered)
    #expect(out.effect == .register)
    #expect(out.exitCode == 0)
    #expect(out.failure == nil)
}

@Test func onWhenAlreadyEnabledIsANoOp() {
    let out = decide(.on, .enabled)
    #expect(out.effect == .none)
    #expect(out.exitCode == 0)
}

@Test func onWhenRequiresApprovalFailsClosed() {
    // register() 已經成功過了，再呼叫一次不會讓它變 enabled——
    // 只有使用者到系統設定按核准才會。所以不再碰系統，直接回報。
    let out = decide(.on, .requiresApproval)
    #expect(out.effect == .none)
    #expect(out.exitCode == 1)
    #expect(out.failure == .needsApproval)
}

@Test func onWhenNotFoundRegistersLikeNotRegistered() {
    // 2026-08-11 實測：notFound 是**全新安裝**的狀態（BTM 裡沒有記錄），
    // 而 register() 從那裡呼叫是成功的。原本的設計讓這一格回 1，
    // 那會擋掉最主要的使用情境——使用者剛裝好、第一次勾。
    let out = decide(.on, .notFound)
    #expect(out.effect == .register)
    #expect(out.exitCode == 0)
    #expect(out.failure == nil)
}

@Test func notFoundBehavesExactlyLikeNotRegistered() {
    // 上面那條的推廣：兩個狀態在**每一個命令**下的結果都必須相同。
    // 分開寫是因為它是這次設計修正的核心主張——只驗 on 那一格的話，
    // 日後有人「順手」把 off × notFound 改成報錯不會有任何訊號。
    for command in [LoginItem.Command.query, .on, .off] {
        #expect(decide(command, .notFound) == decide(command, .notRegistered),
                "\(command) 在 notFound 與 notRegistered 下結果不同")
    }
}

// --- off ---

@Test func offWhenEnabledUnregisters() {
    let out = decide(.off, .enabled)
    #expect(out.effect == .unregister)
    #expect(out.exitCode == 0)
}

@Test func offWhenRequiresApprovalUnregisters() {
    let out = decide(.off, .requiresApproval)
    #expect(out.effect == .unregister)
    #expect(out.exitCode == 0)
}

@Test func offWhenNotRegisteredIsANoOp() {
    let out = decide(.off, .notRegistered)
    #expect(out.effect == .none)
    #expect(out.exitCode == 0)
}

@Test func offWhenNotFoundIsANoOp() {
    // 實測：對一個 notFound 的項目呼叫 unregister() 會丟
    // SMAppServiceErrorDomain Code=1 "Operation not permitted"。
    // 所以這一格不只要回 0，還要證明它**沒有**去呼叫 unregister。
    let out = decide(.off, .notFound)
    #expect(out.effect == .none)
    #expect(out.exitCode == 0)
}

// MARK: - 呈現

@Test func onlyEnabledShowsAsChecked() {
    #expect(LoginItem.presentation(for: .enabled).checked)
    for s in LoginItem.State.allCases where s != .enabled {
        #expect(!LoginItem.presentation(for: s).checked,
                "\(s) 不該顯示為打勾")
    }
}

@Test func requiresApprovalIsNotChecked() {
    // 這一條是上面那條的特例，但單獨留著：它是整個設計最容易被「修好」成
    // 錯誤行為的一格。requiresApproval 的項目**不會**在開機時啟動，
    // 畫成打勾就是說謊。
    let p = LoginItem.presentation(for: .requiresApproval)
    #expect(!p.checked)
    #expect(p.interactive)
    #expect(p.note == .needsApproval)
}

@Test func onlyIneligibleIsNotInteractive() {
    // notFound **可以點**（2026-08-11 實測改的）：它是全新安裝的狀態，
    // 灰掉的話，使用者剛裝好打開設定看到的就是一個不能點的勾加一句
    // 「macOS 找不到這個項目」——把最正常的情境畫成壞掉。
    #expect(!LoginItem.presentation(for: .ineligible).interactive)
    for s in LoginItem.State.allCases where s != .ineligible {
        #expect(LoginItem.presentation(for: s).interactive,
                "\(s) 應該可以點")
    }
}

@Test func healthyStatesShowNoNote() {
    #expect(LoginItem.presentation(for: .enabled).note == nil)
    #expect(LoginItem.presentation(for: .notRegistered).note == nil)
    // notFound 也算健康：它就是還沒開而已
    #expect(LoginItem.presentation(for: .notFound).note == nil)
}

@Test func notFoundLooksExactlyLikeNotRegistered() {
    // 與決策表那條同源：notFound 在 UI 上也不能與 notRegistered 有任何差別，
    // 否則使用者剛裝好會看到一個「怪怪的」勾。
    #expect(LoginItem.presentation(for: .notFound)
            == LoginItem.presentation(for: .notRegistered))
}

@Test func offWhenIneligibleIsRefused() {
    // 以 bundle id 為鍵（2026-08-11 實測），所以從 build/ 呼叫 unregister 會把
    // 使用者裝在 /Applications 那份一起關掉——實測確認過：/Applications 那份
    // 從 enabled 變成 notRegistered。而我們同時把狀態顯示成 ineligible，
    // 等於在一個沒有誠實顯示的狀態上做破壞性操作。
    let out = decide(.off, .ineligible)
    #expect(out.effect == .none)
    #expect(out.exitCode == 1)
    #expect(out.failure == .ineligible)
}
