import Foundation
import Testing
@testable import FindMouseAdapters
// `CatAction.core` / `.teaser` / `.restPool` 是 internal（M1 沒把它們設成 public），
// 跨 target 取用必須走 @testable。
@testable import FindMouseDomain

/// M1 的 `PackValidator` 有 13 個測試，全部餵手寫的記憶體 listing。
/// 這個檔案是它第一次面對真實檔案系統：真的目錄、真的 PNG、真的 pack.json。
private func report(for url: URL) throws -> PackValidationReport {
    let loaded = try #require(SpritePackRepository.load(at: url))
    return PackValidator.validate(manifest: loaded.manifest,
                                  directoryName: loaded.directoryName,
                                  listing: loaded.listing)
}

private func builtInPackURL() throws -> URL {
    let packs = try #require(SpritePackRepository.builtInPacksDirectory())
    return packs.appendingPathComponent("test-blocks")
}

private func fixtureURL(_ id: String) throws -> URL {
    let base = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return base.appendingPathComponent(id)
}

/// spec 第 6.6 節：test-blocks 涵蓋全部 14 個動作，所以能力應該全開、
/// 而且**一個 warning 都不該有**——它是後面每個 M2 task 的基準素材，
/// 基準本身有雜訊的話，真正的問題會被淹掉。
@Test func testBlocksIsValidWithFullCapabilities() throws {
    let report = try report(for: builtInPackURL())

    #expect(report.errors.isEmpty, "內建 pack 有 error：\(report.errors)")
    #expect(report.warnings.isEmpty, "內建 pack 有 warning：\(report.warnings)")
    #expect(report.isValid)
    let caps = try #require(report.capabilities, "有效的 pack 必須帶著能力")
    #expect(caps.available == Set(CatAction.allCases))
    #expect(caps.teaserAvailable)
    // 休息池只有三個（stretch／yawn／scratch）。它**不等於** spec 第 6.3 節的
    // flourish 級——後者含 brake 與 lieDown，但那兩個是轉換動作而不是
    // 待機時隨機插播的動作，所以不在池子裡。
    #expect(Set(caps.restPool) == CatAction.restPool)
    #expect(caps.restPool.count == 3)
}

/// 缺 core 動作 → 整套無效（spec 第 6.3 節的必要級）。
/// 斷言具體是哪一項 error，不只是「有 error」——後者在任何一種壞法下都成立。
@Test func missingCoreFixtureIsRejectedForTheRightReason() throws {
    let report = try report(for: fixtureURL("bad-missing-core"))

    #expect(report.isValid == false)
    #expect(report.errors.contains(.missingCoreActions([.sit])),
            "預期缺 sit 的 error，實際：\(report.errors)")
    // 無效的 pack 沒有能力可言。這比「available 不含 sit」強：
    // 它讓呼叫端不可能拿被拒絕的 pack 的能力去組休息池或開逗貓棒。
    #expect(report.capabilities == nil)
}

/// 宣告 8 格實際 2 檔 → error，不靜默播較少格。
@Test func frameCountFixtureIsRejectedForTheRightReason() throws {
    let report = try report(for: fixtureURL("bad-frame-count"))

    #expect(report.isValid == false)
    #expect(report.errors.contains(.frameCountMismatch(action: "run", declared: 8, found: 2)),
            "預期 run 的格數不符，實際：\(report.errors)")
}

/// 缺單一 teaser 動作 → pack 仍可用，但逗貓棒整個標記不可用。
///
/// spec 第 12 節明文要求「`teaserAvailable == false`」這條斷言必須做 mutation
/// 驗證——它是「斷言某事不會發生」型的，夾具若從未讓 teaser 有機會可用，
/// 它就是恆真句。這裡的夾具只缺一個 pounce，其餘四個 teaser 動作都在，
/// 所以「全有全無」那條規則真的被執行到了。
@Test func missingTeaserFixtureStaysValidButDisablesTeaserEntirely() throws {
    let report = try report(for: fixtureURL("bad-missing-teaser"))

    #expect(report.errors.isEmpty, "缺 teaser 不該是 error：\(report.errors)")
    #expect(report.isValid)
    let caps = try #require(report.capabilities)
    #expect(caps.teaserAvailable == false)
    #expect(report.warnings.contains(.missingTeaserActions([.pounce])),
            "預期缺 pounce 的 warning，實際：\(report.warnings)")
    // 其餘四個 teaser 動作確實存在——這是「全有全無」規則有被執行到的前提。
    // 少了這一段，夾具可能其實五個 teaser 動作全缺，而 teaserAvailable == false
    // 就變成恆真句、證明不了那條規則。
    for action in CatAction.teaser where action != .pounce {
        #expect(caps.available.contains(action))
    }
}
