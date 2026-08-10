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
