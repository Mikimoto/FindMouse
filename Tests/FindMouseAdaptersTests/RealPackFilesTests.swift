// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FindMouseAdapters
// `CatAction.core` / `.teaser` / `.restPool` 是 internal（M1 沒把它們設成 public），
// 跨 target 取用必須走 @testable。
@testable import FindMouseDomain
import FindMouseCore

/// M1 的 `PackValidator` 有 13 個測試，全部餵手寫的記憶體 listing。
/// 這個檔案是它第一次面對真實檔案系統：真的目錄、真的 PNG、真的 pack.json。
private func report(for url: URL) throws -> PackValidationReport {
    let loaded = try #require(SpritePackRepository.load(at: url))
    return PackValidator.validate(manifest: loaded.manifest,
                                  directoryName: loaded.directoryName,
                                  listing: loaded.listing)
}

private func builtInPackURL(_ id: String) throws -> URL {
    let packs = try #require(SpritePackRepository.builtInPacksDirectory())
    return packs.appendingPathComponent(id)
}

private func fixtureURL(_ id: String) throws -> URL {
    let base = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return base.appendingPathComponent(id)
}

/// spec 第 6.6 節：test-blocks 涵蓋全部 14 個動作，所以能力應該全開、
/// 而且**一個 warning 都不該有**——它是後面每個 M2 task 的基準素材，
/// 基準本身有雜訊的話，真正的問題會被淹掉。
@Test func testBlocksIsValidWithFullCapabilities() throws {
    let report = try report(for: builtInPackURL("test-blocks"))

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

/// M4 的第二套內建 pack。上面那個 `bad-missing-teaser` 證明的是**規則**成立；
/// 這一個證明的是**素材**真的長成那樣——M4 三條驗收條件裡有兩條
/// （「放入第二套 pack 能切換」「缺 teaser 的 pack 讓 ⌥⌘T 無反應」）
/// 直接站在這套 pack 的內容上，而它是產生器跑出來的：參數少給一個
/// 就會安靜地產出一套「看起來正常、卻驗不到東西」的 pack，
/// 而錯誤要拖到手動驗收才會現形。
@Test func tallPackIsValidButHasNoTeaser() throws {
    let url = try builtInPackURL("test-blocks-tall")
    let loaded = try #require(SpritePackRepository.load(at: url))
    let report = PackValidator.validate(manifest: loaded.manifest,
                                        directoryName: loaded.directoryName,
                                        listing: loaded.listing)

    #expect(report.errors.isEmpty, "第二套 pack 必須是合格的：\(report.errors)")
    #expect(report.isValid)

    // 體高與 test-blocks（96）不同，這是「切換真的發生了」的客觀證據：
    // status --json 的 pack.logicalHeight 會跟著變。兩套一樣高的話，
    // 切換成功與切換失敗在畫面上、在 JSON 上都長得一模一樣。
    #expect(loaded.manifest.logicalHeight == 240)

    let caps = try #require(report.capabilities)
    #expect(caps.teaserAvailable == false)
    // 用相等而不是 contains：這套 pack 的用途是「**只**缺 teaser」，
    // 多一個 warning（例如順手漏掉某個 flourish 動作）就不再是乾淨的對照組，
    // 而 contains 對那種退化完全沒有反應。
    #expect(report.warnings == [.missingTeaserActions([.pounce])],
            "預期只有缺 pounce 這一個 warning，實際：\(report.warnings)")
}

/// **出貨的那一套必須是合格的。**
///
/// 這一條在 2026-08-19 之前不存在，而那是一個真的缺口：這個檔案裡每一條真實檔案
/// 系統的驗證，對象都是開發用的色塊；所有 `mycat` 的測試都是記憶體字串 fixture
/// （`summary("mycat")` 那一類）。也就是說**使用者實際拿到的那套 pack 從來沒有被
/// 真的載入過一次**。
///
/// v0.2.0 正是那個形狀：簽好、notarize 過、十條驗收全綠地發出去，而裡面只有色塊。
/// `release.sh` 那條守衛擋的是「pack 目錄在不在」，擋不到「pack 的內容合不合格」。
///
/// 用 `PackDefaults.factory` 而不是寫死 "mycat"：改了出廠預設而忘了改這裡的話，
/// 這條會繼續為舊的那套背書。
@Test func theFactoryPackIsValidWithFullCapabilities() throws {
    let report = try report(for: builtInPackURL(PackDefaults.factory))

    #expect(report.errors.isEmpty, "出貨的 pack 有 error：\(report.errors)")
    #expect(report.warnings.isEmpty, "出貨的 pack 有 warning：\(report.warnings)")
    #expect(report.isValid)
    let caps = try #require(report.capabilities, "有效的 pack 必須帶著能力")
    #expect(caps.available == Set(CatAction.allCases), "出貨的 pack 要涵蓋全部 14 個動作")
    #expect(caps.teaserAvailable, "逗貓棒要可用")
    #expect(Set(caps.restPool) == CatAction.restPool)
}
