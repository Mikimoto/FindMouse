import Testing
import FindMouseDomain

/// `isUsable` 是 UI 與 CLI 共用的「這套能不能選」判定。
/// 分開放在型別上而不是各自寫 `errors.isEmpty`，是因為 spec 第 6.4 節說
/// **警告不影響可用性**——缺 teaser 只是逗貓棒不可用，pack 本身合格。
@Test func onlyErrorsMakeAPackUnusable() {
    let clean = PackSummary(id: "a", isBuiltIn: true, logicalHeight: 96,
                            errors: [], warnings: [], teaserAvailable: true)
    let warned = PackSummary(id: "b", isBuiltIn: false, logicalHeight: 240,
                             errors: [], warnings: ["缺少逗貓棒動作"], teaserAvailable: false)
    let broken = PackSummary(id: "c", isBuiltIn: false, logicalHeight: 96,
                             errors: ["缺少必要動作：sit"], warnings: [], teaserAvailable: true)

    #expect(clean.isUsable)
    #expect(warned.isUsable, "警告不影響可用性——缺 teaser 的 pack 仍然是合格的 pack")
    #expect(broken.isUsable == false)
}

/// 上面三個樣本每個都只有 errors 或 warnings 其中一邊有值，於是「兩邊都有值」
/// 這個組合沒有被釘住：`errors.isEmpty || !warnings.isEmpty` 這種把兩個清單
/// 混在一起的寫法照樣全綠，卻會讓一套**有 error 又有 warning** 的壞 pack 變成可選。
///
/// 順帶釘住兩組**同型別**欄位的搬運方向。init 是手寫的逐行賦值，而
/// `isBuiltIn` / `teaserAvailable` 同為 Bool、`errors` / `warnings` 同為 [String]，
/// 組內對調編得過，型別檢查在這裡幫不上忙。對調的後果是使用者可見的：
/// warning 存進 errors，設定視窗就把一套合格的 pack 畫成紅字不可選，
/// spec 第 6.4 節分成兩級的意義整個消失。
///
/// `id` 與 `logicalHeight` 刻意不驗——它們在這個型別裡型別唯一，搬錯編譯就紅了，
/// 再寫斷言只是重述實作。
@Test func bothListsPopulatedStaysUnusableAndNeitherPairGetsSwapped() {
    let summary = PackSummary(id: "d", isBuiltIn: false, logicalHeight: 96,
                              errors: ["缺少必要動作：run"],
                              warnings: ["缺少點綴動作：yawn"],
                              teaserAvailable: true)

    #expect(summary.isUsable == false)
    #expect(summary.errors == ["缺少必要動作：run"])
    #expect(summary.warnings == ["缺少點綴動作：yawn"])
    #expect(summary.isBuiltIn == false)
    #expect(summary.teaserAvailable == true)
}
