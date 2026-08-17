// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import FindMouseCore
import FindMouseDomain
import Foundation
import Testing

/// 記憶體版設定儲存。與 `SettingsUseCaseTests` 裡那個同形，
/// 但刻意各留一份：兩邊要驗的東西不同，共用會讓其中一邊改壞另一邊。
private final class StubStore: SettingsStorePort, @unchecked Sendable {
    private var stored = BehaviorConfig()
    private var strings: [String: String] = [:]

    var config: BehaviorConfig { stored }
    func save(_ config: BehaviorConfig) { stored = config }
    func string(forKey key: String) -> String? { strings[key] }

    func setString(_ value: String?, forKey key: String) {
        if let value { strings[key] = value } else { strings.removeValue(forKey: key) }
    }
}

/// 設定視窗的四個外部依賴，全部可觀測。
@MainActor
private final class FormHarness {
    /// `settings` 底下那個儲存。測試要能分辨「沒寫過這個 key」與「寫成預設值」
    /// ——`get` 對沒設定過的外層字串 key 回的是註冊表的預設值，看不出差別。
    let backing = StubStore()
    /// 「當前的」設定。換 pack 就是換掉這個欄位——設定視窗必須跟著換。
    lazy var settings = SettingsUseCase(store: backing, catalog: StubCatalog())
    var packs: [PackSummary] = []
    var currentPackID = "test-blocks"

    private(set) var swapRequests: [String] = []
    private(set) var changeNotifications = 0

    // 分發 C-2 的三個注入點。記下**每一次呼叫的參數**而不只是次數：force 那一路
    // 與非 force 那一路走的是同一個 closure，只記次數的話「確認之後忘了帶 force」
    // 不會有任何訊號。
    var installResult: PackActionResult = .failed(message: "測試沒設定 installResult")
    var removeResult: PackActionResult = .failed(message: "測試沒設定 removeResult")
    private(set) var installedSources: [String] = []
    private(set) var forcedSources: [String] = []
    private(set) var removedIDs: [String] = []
    private(set) var revealCount = 0
    /// `reload()` 被呼叫幾次——它一定會呼叫 `packs`，所以掛在那裡數。
    private(set) var reloadCount = 0

    lazy var store = SettingsFormStore(
        settings: { [unowned self] in self.settings },
        packs: { [unowned self] in self.reloadCount += 1; return self.packs },
        currentPackID: { [unowned self] in self.currentPackID },
        usePack: { [unowned self] id in self.swapRequests.append(id) },
        onChanged: { [unowned self] in self.changeNotifications += 1 },
        installPack: { [unowned self] url, force in
            if force { self.forcedSources.append(url.path) }
            else { self.installedSources.append(url.path) }
            return self.installResult
        },
        removePack: { [unowned self] id in
            self.removedIDs.append(id)
            return self.removeResult
        },
        revealPacksDirectory: { [unowned self] in self.revealCount += 1 })
}

private func summary(_ id: String, builtIn: Bool = true, errors: [String] = []) -> PackSummary {
    PackSummary(id: id, isBuiltIn: builtIn, logicalHeight: 96,
                errors: errors, warnings: [], teaserAvailable: true)
}

// MARK: - 哪些 key 出現在哪裡

/// spec 第 9 節那張表 UI 欄打 ✓ 的 8 項的**獨立抄本**。
/// 不從 `SettingsForm.windowKeys` 推導：那樣抄錯的時候測試會跟著錯。
private let specWindowKeys = [
    "pack.id", "cat.scale", "rest.duration", "sleep.duration",
    "spotlight.enabled", "spotlight.trigger", "hotkey.summon", "hotkey.teaser",
]

@Test func theWindowShowsExactlyTheEightKeysTheSpecMarks() {
    #expect(SettingsForm.windowKeys == specWindowKeys)
}

/// 手抄的清單抄到不存在的 key 時，那個欄位在畫面上會是空的而不是紅的。
@Test func everyWindowKeyIsActuallyDeclared() {
    let declared = Set(SettingsUseCase.declaredKeys)
    let ghosts = SettingsForm.windowKeys.filter { !declared.contains($0) }
    #expect(ghosts.isEmpty, "設定視窗要顯示註冊表裡沒有的 key：\(ghosts)")
}

/// 「進階設定…」是**推導**出來的，所以註冊表加一項就會自動出現在那裡。
/// 這條同時釘住 spec 第 9 節的 23 = 8 + 15。
@Test func advancedIsTheRestOfTheRegistryWithNothingLostInBetween() {
    let declared = SettingsUseCase.declaredKeys
    #expect(declared.count == 23, "spec 第 9 節共 23 項，實際 \(declared.count)")
    #expect(SettingsForm.windowKeys.count == 8)
    #expect(SettingsForm.advancedKeys.count == 15)
    #expect(Set(SettingsForm.windowKeys).isDisjoint(with: Set(SettingsForm.advancedKeys)))
    #expect(Set(SettingsForm.windowKeys).union(SettingsForm.advancedKeys) == Set(declared))
}

/// 兩件事：一項都不能掉（`advancedEntries` 裡的 `try?` 是靜默的），
/// 而且總數是 spec 第 9 節的 15——後者不從 `advancedKeys` 推導，
/// 不然清單算錯的時候這條會跟著錯。
@Test func advancedEntriesCoverEveryCLIOnlyKey() {
    let entries = SettingsForm.advancedEntries(
        SettingsUseCase(store: StubStore(), catalog: StubCatalog()))
    #expect(entries.count == 15)
    #expect(entries.map(\.key) == SettingsForm.advancedKeys)
}

/// 命令要帶**當前值**：貼進終端機就是原地不動，改一個數字才是新設定。
/// 印佔位符的話，調手感的人得先自己去 `config get` 一次。
@Test func advancedCommandsCarryTheValueThatIsInEffectNow() throws {
    let settings = SettingsUseCase(store: StubStore(), catalog: StubCatalog())
    try settings.set("cat.speed", to: "1234")
    let entry = try #require(SettingsForm.advancedEntries(settings)
        .first { $0.key == "cat.speed" })
    #expect(entry.command == "findmouse config set cat.speed 1234")
    #expect(entry.range == "200–3000")
}

/// 值域說明沿用 `SettingsUseCase` 的數字格式，不另寫一份——
/// 各印各的話同一個範圍在 CLI 是 `40–1000`、在設定視窗是 `40.0–1000.0`。
@Test func rangeTextReadsTheSameWayTheCLIPrintsValues() {
    #expect(SettingsForm.text(for: .number(40...1000)) == "40–1000")
    // `2.0` 印成 `2`，與 `config get cat.scale` 對 1.0 印 `1` 是同一條規則。
    // 為了讓範圍好看而在這裡加一位小數，就是第二份數字格式。
    #expect(SettingsForm.text(for: .number(0.5...2.0)) == "0.5–2")
    #expect(SettingsForm.text(for: .boolean) == "true | false")
    #expect(SettingsForm.text(for: .choice(["a", "b"])) == "a | b")
    #expect(SettingsForm.text(for: .packID) == "a-z、0-9、-")
}

// MARK: - pack 下拉選單

/// 不合格的 pack 照列（spec 第 10 節：設定裡一列紅字告訴他哪裡壞了），
/// 濾掉的話使用者看到的是「我放進去的 pack 不見了」。
@Test func unusablePacksStayInTheListCarryingTheirErrors() {
    let rows = PackChoice.choices(
        packs: [summary("test-blocks"),
                summary("broken", builtIn: false, errors: ["缺少必要動作：run"])],
        current: "test-blocks")
    #expect(rows.map(\.id) == ["test-blocks", "broken"])
    #expect(rows[1].isUsable == false)
    #expect(rows[1].problems == ["缺少必要動作：run"])
    #expect(rows[0].isCurrent && !rows[1].isCurrent)
}

/// 跑著的那套從磁碟上消失了（使用者刪了目錄，App 還握著已載入的圖）。
/// 沒有這一列的話下拉選單的選取值對不到任何一列，SwiftUI 顯示空白，
/// 而使用者看到的是「我的 pack 欄位不見了」。
@Test func theRunningPackGetsARowEvenAfterItsFilesAreGone() {
    let rows = PackChoice.choices(packs: [summary("test-blocks")], current: "my-cat")
    #expect(rows.map(\.id) == ["test-blocks", "my-cat"])
    let ghost = rows[1]
    #expect(ghost.isCurrent)
    #expect(ghost.isUsable == false, "已經不在磁碟上的 pack 不該可以再被選一次")
    #expect(ghost.problems.isEmpty == false)
}

/// 還沒有任何 pack（啟動失敗）時不要憑空生一列出來。
@Test func noRunningPackMeansNoSyntheticRow() {
    #expect(PackChoice.choices(packs: [summary("test-blocks")], current: "").count == 1)
}

// MARK: - 選單列那一列的字

/// 選單裡灰掉的項目沒有任何「把游標停在我上面」的暗示，而 tooltip 要停約 1.5 秒
/// 才浮出來。原因只掛 tooltip 的話，「這套為什麼不能選」實際上沒有人看得到——
/// 那正是這個專案一直在獵殺的靜默失敗。
@Test func theMenuTitleSaysWhyAPackCannotBeChosen() {
    let rows = PackChoice.choices(
        packs: [summary("broken", builtIn: false,
                        errors: ["缺少必要動作：run", "宣告 8 格但只有 3 個檔"])],
        current: "test-blocks")
    let broken = rows[0]
    #expect(broken.menuTitle.contains("缺少必要動作：run"))
    #expect(broken.menuTitle.contains("宣告 8 格但只有 3 個檔"))
    // tooltip 是標題被選單寬度截掉時的補充，一行一個原因
    #expect(broken.menuTooltip == "缺少必要動作：run\n宣告 8 格但只有 3 個檔")
}

/// 可用的那些不該憑空多出破折號、也不該掛一個空的 tooltip
/// （空字串的 tooltip 會浮出一個空白小框，比沒有還糟）。
@Test func aUsablePackJustSaysItsNameAndWhetherItIsBuiltIn() {
    let rows = PackChoice.choices(packs: [summary("test-blocks"),
                                          summary("my-cat", builtIn: false)],
                                  current: "test-blocks")
    #expect(rows[0].menuTitle == "test-blocks（內建）")
    #expect(rows[1].menuTitle == "my-cat")
    #expect(rows[0].menuTooltip == nil)
    #expect(rows[1].menuTooltip == nil)
}

/// 使用者把跑著的那套目錄整個刪掉：選單上那一項要說得出發生了什麼事，
/// 不然他看到的是一個灰掉、沒有標記、和可用的長得一模一樣的項目。
@Test func theRowOfADeletedPackExplainsItselfInTheMenu() {
    let ghost = PackChoice.choices(packs: [summary("test-blocks")], current: "my-cat")[1]
    #expect(ghost.menuTitle == "my-cat — 這套 pack 已經不在磁碟上")
    #expect(ghost.menuTooltip == "這套 pack 已經不在磁碟上")
}

/// `isUsable == false` 卻沒附原因的那一列。今天從 `choices` 走不到
/// （`problems` 來自 `PackSummary.errors`，而 `isUsable` 就是「errors 是空的」），
/// 但 `PackChoice` 的 init 是 public。沒有這個墊底字的話，那一列在畫面上
/// 與可用的完全無法分辨——而灰掉這件事本身在截圖裡並不明顯。
@Test func anUnusablePackWithoutAReasonStillAdmitsItIsUnusable() {
    let mute = PackChoice(id: "silent", isBuiltIn: false, isUsable: false,
                          isCurrent: false, problems: [])
    #expect(mute.menuTitle == "silent — 不可用")
    // 空字串的 tooltip 會浮出一個空白小框，比沒有 tooltip 更難理解
    #expect(mute.menuTooltip == nil)
}

// MARK: - 寫入路徑

/// **裁決 2**：換 pack 會把整個 `PackBinding`（連同 `SettingsUseCase`）換掉。
/// 設定視窗若捕獲一份，換完之後它寫的是孤兒物件——UI 顯示成功，`config get` 讀不到。
@Test @MainActor func writesFollowThePackSwapInsteadOfLandingInTheOldUseCase() throws {
    let harness = FormHarness()
    let before = harness.settings
    harness.store.reload()

    // 換 pack：新的 binding 帶著自己的 SettingsUseCase 與自己的 store
    let after = SettingsUseCase(store: StubStore(), catalog: StubCatalog())
    harness.settings = after

    harness.store.submit("cat.speed", "1500")

    #expect(try after.get("cat.speed") == "1500")
    #expect(try before.get("cat.speed") == "900", "寫進了換掉之前那個孤兒物件")
}

/// spec 第 9 節：超出範圍一律拒絕，**不 clamp**。
/// UI 若自己先夾一次再送，使用者拉到底會靜默變成 2.0 而不是被拒絕。
@Test @MainActor func outOfRangeIsRejectedRatherThanClamped() throws {
    let harness = FormHarness()
    harness.store.reload()

    #expect(harness.store.submit("cat.scale", number: 5) == false)
    #expect(try harness.settings.get("cat.scale") == "1", "被 clamp 成 2 或寫進 5 都是錯的")
    #expect(harness.store.snapshot.errors["cat.scale"] == "5 超出範圍 0.5–2")
    #expect(harness.changeNotifications == 0, "沒改成任何東西就不該通知")
}

/// 非法快捷鍵不能寫進去（Task 8：寫得進去的話重新註冊時解不出 spec，
/// 使用者的快捷鍵當場靜默消失，而那個值還存在設定裡，重啟也救不回來）。
@Test @MainActor func anIllegalHotkeyIsRefusedAndTheTypedTextIsKept() throws {
    let harness = FormHarness()
    harness.store.reload()

    #expect(harness.store.submit("hotkey.summon", "F") == false)
    #expect(try harness.settings.get("hotkey.summon") == "⌥⌘F")
    #expect(harness.store.snapshot.errors["hotkey.summon"] != nil)
    #expect(harness.store.snapshot.text("hotkey.summon") == "F",
            "紅框旁邊要留他打的那個字串，顯示舊值的話看不出哪裡錯")
}

/// 存進去的是正規化後的字串。回讀的話畫面顯示的與 `config get` 回的
/// 會是同一個鍵的兩種寫法。
@Test @MainActor func anAcceptedHotkeyComesBackNormalised() {
    let harness = FormHarness()
    harness.store.reload()

    #expect(harness.store.submit("hotkey.summon", "⌘⌥f"))
    #expect(harness.store.snapshot.text("hotkey.summon") == "⌥⌘F")
    #expect(harness.changeNotifications == 1)
}

/// 打字中不寫、也不驗：`⌥⌘F` 打到第一個字元時必然非法，
/// 一邊打一邊紅框只是在說「你還沒打完」。
@Test @MainActor func typingDoesNotWriteAndDoesNotComplain() throws {
    let harness = FormHarness()
    harness.store.reload()

    harness.store.draft("hotkey.summon", "⌥")
    #expect(harness.store.snapshot.text("hotkey.summon") == "⌥")
    #expect(harness.store.snapshot.errors["hotkey.summon"] == nil)
    #expect(try harness.settings.get("hotkey.summon") == "⌥⌘F")
    #expect(harness.changeNotifications == 0)
}

/// 使用者一開始改，紅字就該消失——那是「我知道你在修了」。
///
/// 打的字串必須與現有草稿**不同**，因為「一次編輯」在畫面上本來就不可能字字相同：
/// 多打一個字元、刪掉一個字元、換掉一個字元，長度或內容一定會變。相同的那一種
/// 不是編輯而是 AppKit 的回送（見 `theEchoAfterARejectedCommitKeepsTheComplaint`）。
@Test @MainActor func editingClearsThePreviousComplaint() {
    let harness = FormHarness()
    harness.store.reload()
    harness.store.submit("hotkey.summon", "F")
    #expect(harness.store.snapshot.errors["hotkey.summon"] != nil)

    harness.store.draft("hotkey.summon", "⌥F")
    #expect(harness.store.snapshot.errors["hotkey.summon"] == nil)
}

/// **靜默拒絕**：失焦提交被拒絕之後，AppKit 會把欄位內容原字回送一次到
/// `TextField` binding 的 `set:`，於是 `draft` 緊接在 `commitDraft` 之後又被呼叫，
/// 而 `draft` 無條件清紅字——剛設好的那句話當場被自己抹掉。
///
/// 實測到的順序（在「貓的大小」打 `abc` 再把焦點移到「休息時間」）：
///     commitDraft cat.scale draft="abc" → submit → error=「abc」不合法…
///     binding-set cat.scale value="abc" focused=rest.duration   ← 回送
///     draft       cat.scale incoming="abc" existingDraft="abc"  ← 紅字在這裡消失
/// 回送的字串與草稿**逐字相同**，所以守衛比字串就夠。
/// 按 Enter 走 `onSubmit`、焦點沒變、沒有那次回送，所以只有失焦會靜默——
/// 使用者看到的是「值被擋下來，而畫面上沒有任何理由」。
@Test @MainActor func theEchoAfterARejectedCommitKeepsTheComplaint() throws {
    let harness = FormHarness()
    harness.store.reload()

    harness.store.draft("cat.scale", "abc")
    #expect(harness.store.commitDraft("cat.scale") == false)
    #expect(harness.store.snapshot.errors["cat.scale"] != nil, "前提：紅字先被設起來")

    harness.store.draft("cat.scale", "abc")     // AppKit 的回送

    #expect(harness.store.snapshot.errors["cat.scale"] == "「abc」不合法，要的是 數字",
            "回送把紅字清掉了——值被擋下來而使用者看不到任何理由")
    #expect(harness.store.snapshot.text("cat.scale") == "abc")
    #expect(try harness.settings.get("cat.scale") == "1")
}

/// 回送在 hotkey 欄位一樣會發生——`editableField` 是三種列共用的那一塊，
/// 只守數值欄的話另外兩種列照樣靜默。
@Test @MainActor func theEchoAfterARejectedHotkeyKeepsTheComplaintToo() {
    let harness = FormHarness()
    harness.store.reload()

    harness.store.draft("hotkey.summon", "F")
    #expect(harness.store.commitDraft("hotkey.summon") == false)
    let complaint = harness.store.snapshot.errors["hotkey.summon"]
    #expect(complaint != nil, "前提：紅字先被設起來")

    harness.store.draft("hotkey.summon", "F")   // AppKit 的回送

    #expect(harness.store.snapshot.errors["hotkey.summon"] == complaint)
}

/// 關視窗時會對**全部** 8 個 key 各提交一次（`SettingsWindowController`
/// 的後備路徑）。沒動過任何欄位的話那一輪必須完全不寫——不然每次開關設定
/// 都會重新註冊一次快捷鍵，而那期間快捷鍵是不存在的。
@Test @MainActor func closingAnUntouchedWindowWritesNothing() throws {
    let harness = FormHarness()
    harness.store.reload()
    let before = try SettingsUseCase.declaredKeys.map { try harness.settings.get($0) }

    for key in SettingsForm.windowKeys { harness.store.commitDraft(key) }

    #expect(harness.changeNotifications == 0)
    #expect(try SettingsUseCase.declaredKeys.map { try harness.settings.get($0) } == before)
}

/// 打了字沒按 Enter 就關視窗，那個編輯要生效——「我明明打了，關掉再開卻沒生效」
/// 是完全沒有訊號的資料遺失。
@Test @MainActor func closingTheWindowCommitsWhatWasTyped() throws {
    let harness = FormHarness()
    harness.store.reload()
    harness.store.draft("hotkey.teaser", "⌃⇧G")

    for key in SettingsForm.windowKeys { harness.store.commitDraft(key) }

    #expect(try harness.settings.get("hotkey.teaser") == "⌃⇧G")
}

/// 只是點進去看一眼就失焦，不該觸發一輪快捷鍵重新註冊
/// （那期間快捷鍵是不存在的）。
@Test @MainActor func leavingAnUntouchedFieldWritesNothing() {
    let harness = FormHarness()
    harness.store.reload()

    harness.store.commitDraft("hotkey.summon")
    #expect(harness.changeNotifications == 0)

    harness.store.draft("hotkey.summon", "⌥⌘F")   // 打了但打回原樣
    harness.store.commitDraft("hotkey.summon")
    #expect(harness.changeNotifications == 0, "值沒變還是通知了")
}

// MARK: - 可輸入的數值欄位

/// **本批的關鍵條**：數值欄位點進去看一眼再點出去，不該寫入。
///
/// `commitDraft` 的守衛原本寫成 `if case .text(let stored)? = values[key]`，
/// 只認字串型；`cat.scale` 的值是 `.number`，永遠比不中，於是每次失焦都白寫一次，
/// 每次都是一輪 `onChanged()` → 重新註冊快捷鍵，而那期間快捷鍵是不存在的。
/// 三個數值欄各驗一次，因為它們的 render 格式不同（`1` 是整數、`1.25` 不是）。
@Test @MainActor func leavingAnUntouchedNumberFieldWritesNothing() throws {
    let harness = FormHarness()
    try harness.settings.set("cat.scale", to: "1.25")
    harness.store.reload()

    // 畫面上顯示什麼就打回什麼——使用者點進欄位、什麼都沒改就點出去
    for key in ["cat.scale", "rest.duration", "sleep.duration"] {
        let shown = harness.store.snapshot.text(key)
        harness.store.draft(key, shown)
        harness.store.commitDraft(key)
        #expect(harness.store.snapshot.drafts[key] == nil, "\(key) 的草稿沒被收掉")
    }

    #expect(harness.store.snapshot.text("cat.scale") == "1.25")
    #expect(harness.changeNotifications == 0, "值沒變還是重新註冊了一輪快捷鍵")
}

/// 布林型也走同一個守衛。`spotlight.enabled` 在畫面上是開關沒有文字欄，
/// 但關視窗那條後備路徑（`SettingsWindowController.windowWillClose`）對
/// **全部 8 個 key** 各 `commitDraft` 一次，守衛必須三種型別一體適用。
@Test @MainActor func leavingAnUntouchedFlagWritesNothing() {
    let harness = FormHarness()
    harness.store.reload()

    harness.store.draft("spotlight.enabled", "true")
    harness.store.commitDraft("spotlight.enabled")

    #expect(harness.store.snapshot.drafts["spotlight.enabled"] == nil)
    #expect(harness.changeNotifications == 0)
}

/// 打字中不寫入——數值欄與 hotkey 欄同一條路。
/// 邊打邊寫的話 `1.25` 打到 `1.` 時會先被拒絕一次（`1.` 解不成數字），
/// 而使用者只是還沒打完。
@Test @MainActor func typingIntoANumberFieldWritesNothingUntilItIsCommitted() throws {
    let harness = FormHarness()
    harness.store.reload()

    harness.store.draft("cat.scale", "1.9")
    #expect(try harness.settings.get("cat.scale") == "1", "打字當下就寫進去了")
    #expect(harness.store.snapshot.errors["cat.scale"] == nil)
    #expect(harness.changeNotifications == 0)

    #expect(harness.store.commitDraft("cat.scale"))
    #expect(try harness.settings.get("cat.scale") == "1.9")
    #expect(harness.changeNotifications == 1)
}

/// 打非數字：紅字說「要的是 數字」，值不變，而且**留著他打的那個字串**
/// ——紅框旁邊顯示舊值的話看不出哪裡錯。
@Test @MainActor func typingRubbishIntoANumberFieldIsRefusedAndTheTextIsKept() throws {
    let harness = FormHarness()
    harness.store.reload()

    harness.store.draft("cat.scale", "abc")
    #expect(harness.store.commitDraft("cat.scale") == false)

    #expect(try harness.settings.get("cat.scale") == "1")
    #expect(harness.store.snapshot.errors["cat.scale"] == "「abc」不合法，要的是 數字")
    #expect(harness.store.snapshot.text("cat.scale") == "abc")
    #expect(harness.changeNotifications == 0)
}

/// spec 第 8 節：超出範圍**一律拒絕，不 clamp**。
/// 打 `5` 到 0.5–2.0 的欄位要紅字，不是靜靜變成 2——默默改掉使用者給的值
/// 比明確失敗更難查。（`outOfRangeIsRejectedRatherThanClamped` 驗的是滑軌那條
/// `submit(number:)`，這條驗的是打字那條。）
@Test @MainActor func aNumberTypedOutOfRangeIsRefusedNotClamped() throws {
    let harness = FormHarness()
    harness.store.reload()

    harness.store.draft("cat.scale", "5")
    #expect(harness.store.commitDraft("cat.scale") == false)

    #expect(try harness.settings.get("cat.scale") == "1", "被 clamp 成 2 或寫進 5 都是錯的")
    #expect(harness.store.snapshot.errors["cat.scale"] == "5 超出範圍 0.5–2")
    #expect(harness.changeNotifications == 0)
}

/// 打字沒提交就去拖滑軌：草稿被丟掉，欄位顯示滑軌拖到的那個值。
///
/// 沒有這條的話，`submit` 哪天不再清草稿，畫面會停在使用者半小時前打的字串上，
/// 而 `config get` 早就是別的值了——兩者不一致而且沒有任何訊號。
@Test @MainActor func movingTheSliderDropsAnUncommittedDraft() throws {
    let harness = FormHarness()
    harness.store.reload()
    harness.store.draft("cat.scale", "1.9")

    harness.store.submit("cat.scale", number: 1.5)

    #expect(harness.store.snapshot.drafts["cat.scale"] == nil)
    #expect(harness.store.snapshot.text("cat.scale") == "1.5", "欄位還顯示著被丟掉的草稿")
    #expect(try harness.settings.get("cat.scale") == "1.5")
}

/// 欄位裡有沒提交的草稿時按加號：以**存著的值**為基準，不是草稿。
///
/// 兩種都說得通，這裡選存著的值：草稿可能是 `abc`（`abc + 1` 沒有意義），
/// 而解得開的那些要先 parse，那是 `SettingsUseCase` 的事（spec 第 9 節）。
/// 釘住是因為改成另一種不會有任何訊號。
@Test @MainActor func steppingWithAnUncommittedDraftCountsFromTheStoredValue() throws {
    let harness = FormHarness()
    harness.store.reload()
    #expect(harness.store.snapshot.number("rest.duration") == 10)

    harness.store.draft("rest.duration", "99")     // 打了但沒提交
    harness.store.step("rest.duration", by: 1)

    #expect(try harness.settings.get("rest.duration") == "11", "拿草稿 99 加一了")
    #expect(harness.store.snapshot.drafts["rest.duration"] == nil)
    #expect(harness.store.snapshot.text("rest.duration") == "11")
}

/// 草稿是非法值時按加號一樣能動，而且紅字要跟著消失
/// ——加號成功了卻還掛著上一輪的紅字，使用者不知道到底寫進去沒有。
@Test @MainActor func steppingRecoversFromAFieldLeftInAnErrorState() throws {
    let harness = FormHarness()
    harness.store.reload()
    harness.store.draft("rest.duration", "abc")
    #expect(harness.store.commitDraft("rest.duration") == false)
    #expect(harness.store.snapshot.errors["rest.duration"] != nil)

    harness.store.step("rest.duration", by: 1)

    #expect(try harness.settings.get("rest.duration") == "11")
    #expect(harness.store.snapshot.errors["rest.duration"] == nil)
    #expect(harness.store.snapshot.text("rest.duration") == "11")
}

/// hotkey 的正規化只寫一次：打 `⌘⌥F`（存的是 `⌥⌘F`）→ 草稿與 render 不相等
/// → 寫入一次 → **草稿被清掉**，所以第二次失焦不會再寫。
///
/// 正規化本來就需要那一次寫入才回讀得到，關鍵是它不會變成每次失焦都重來。
@Test @MainActor func normalisingAHotkeyCostsExactlyOneWrite() throws {
    let harness = FormHarness()
    harness.store.reload()

    harness.store.draft("hotkey.summon", "⌘⌥F")
    harness.store.commitDraft("hotkey.summon")
    #expect(harness.changeNotifications == 1)
    #expect(try harness.settings.get("hotkey.summon") == "⌥⌘F")

    // 再失焦一次（`onChange(of: focused)` 與關視窗那條後備路徑各會來一次）
    harness.store.commitDraft("hotkey.summon")
    harness.store.commitDraft("hotkey.summon")
    #expect(harness.changeNotifications == 1, "正規化之後每次失焦都在重寫")
}

/// **這條記錄的是取捨，不是目標。** 守衛比的是字串，所以 `1.250`／`+1.25`
/// 這種「格式不同但等值」的輸入會白寫一次（值仍然正規化成 `1.25`）。
/// 要消掉它得先 parse，而 parse 住在 `SettingsUseCase`（spec 第 9 節）。
/// 哪天真的改成比對解析後的值，這裡的 `1` 會變成 `0`——那是進步，照改。
@Test @MainActor func aDifferentlySpelledButEqualNumberStillCostsOneWrite() throws {
    let harness = FormHarness()
    try harness.settings.set("cat.scale", to: "1.25")
    harness.store.reload()

    harness.store.draft("cat.scale", "1.250")
    harness.store.commitDraft("cat.scale")

    #expect(try harness.settings.get("cat.scale") == "1.25", "值本身不該被這個寫法改掉")
    #expect(harness.store.snapshot.text("cat.scale") == "1.25", "回讀成正規格式")
    #expect(harness.changeNotifications == 1)
}

// MARK: - 設定視窗開著的時候，別人也在改

/// 加減以**當下讀到的值**為基準，不是畫面上那個。
///
/// `findmouse config set rest.duration 20` 之後，畫面若還停在 10，
/// 按一下加號送出的是 11 —— 使用者只是按了個加號，卻把 CLI 的改動蓋掉了。
@Test @MainActor func theStepperCountsFromTheStoredValueNotTheStaleScreen() throws {
    let harness = FormHarness()
    harness.store.reload()
    #expect(harness.store.snapshot.number("rest.duration") == 10)

    // 別人（CLI）改了值，視窗還沒重讀
    try harness.settings.set("rest.duration", to: "20")
    #expect(harness.store.snapshot.number("rest.duration") == 10, "前提：畫面是舊的")

    harness.store.step("rest.duration", by: 1)
    #expect(try harness.settings.get("rest.duration") == "21", "拿畫面上的 10 加一了")
}

/// 反轉同理：畫面停在 true 而實際已被改成 false 時，
/// 按一下開關會送出 false —— 看起來像「按了沒反應」。
@Test @MainActor func theToggleFlipsTheStoredValueNotTheStaleScreen() throws {
    let harness = FormHarness()
    harness.store.reload()
    #expect(harness.store.snapshot.flag("spotlight.enabled"))

    try harness.settings.set("spotlight.enabled", to: "false")
    #expect(harness.store.snapshot.flag("spotlight.enabled"), "前提：畫面是舊的")

    harness.store.toggle("spotlight.enabled")
    #expect(try harness.settings.get("spotlight.enabled") == "true", "把畫面上的 true 反轉成 false 了")
}

@Test @MainActor func reloadPicksUpWhatSomebodyElseChanged() throws {
    let harness = FormHarness()
    harness.store.reload()

    try harness.settings.set("cat.scale", to: "1.75")
    harness.store.reload()
    #expect(harness.store.snapshot.number("cat.scale") == 1.75)
}

/// 重讀的觸發者常常是別人（CLI 改了某個值）。順手清掉紅字與草稿的話，
/// 使用者正在修的那個欄位會在他眼前被重置。
@Test @MainActor func reloadLeavesTheFieldTheUserIsStillFixingAlone() throws {
    let harness = FormHarness()
    harness.store.reload()
    harness.store.submit("hotkey.summon", "F")

    try harness.settings.set("cat.scale", to: "1.5")
    harness.store.reload()

    #expect(harness.store.snapshot.number("cat.scale") == 1.5)
    #expect(harness.store.snapshot.errors["hotkey.summon"] != nil)
    #expect(harness.store.snapshot.text("hotkey.summon") == "F")
}

/// snapshot 保留型別，UI 不必從 `"true"` 解回 `Bool`——那等於把 `render`
/// 的規則抄第二份到畫不出測試的地方。
@Test @MainActor func theSnapshotKeepsTypesInsteadOfMakingTheUIReparseStrings() throws {
    let harness = FormHarness()
    try harness.settings.set("spotlight.enabled", to: "false")
    try harness.settings.set("cat.scale", to: "1.5")
    harness.store.reload()

    #expect(harness.store.snapshot.flag("spotlight.enabled") == false)
    #expect(harness.store.snapshot.number("cat.scale") == 1.5)
    #expect(harness.store.snapshot.text("spotlight.trigger") == "onSummonOnly")
    // 數字型的 key 也要能拿到字串（Stepper 的標籤），格式與 CLI 一致
    #expect(harness.store.snapshot.text("rest.duration") == "10")
}

@Test @MainActor func theSnapshotCarriesTheFifteenAdvancedCommands() {
    let harness = FormHarness()
    harness.store.reload()
    #expect(harness.store.snapshot.advanced.map(\.key) == SettingsForm.advancedKeys)
}

// MARK: - 換 pack

/// **裁決 3**：只寫 `pack.id` 不會換 pack —— 它的持久化是換 pack 的副作用，
/// 反過來寫不會觸發抽換，使用者會看到「選了新 pack、貓還是舊的，重開才變」。
@Test @MainActor func choosingAPackAsksForASwapInsteadOfWritingTheSetting() throws {
    let harness = FormHarness()
    harness.packs = [summary("test-blocks"), summary("test-blocks-tall")]
    harness.store.reload()

    harness.store.choosePack("test-blocks-tall")

    #expect(harness.swapRequests == ["test-blocks-tall"])
    #expect(harness.backing.string(forKey: "pack.id") == nil,
            "設定視窗不該自己寫 pack.id，那是 performSwap 的副作用")
    #expect(harness.changeNotifications == 0)
}

/// 換 pack 可能要等貓退場（spec 第 6.5 節）。這段期間 `currentPackID()` 還是舊的，
/// 不記下請求的話下拉選單會在使用者眼前彈回他剛剛選掉的那一套。
@Test @MainActor func thePickerHoldsTheRequestedPackUntilTheSwapConcludes() {
    let harness = FormHarness()
    harness.packs = [summary("test-blocks"), summary("test-blocks-tall")]
    harness.store.reload()

    harness.store.choosePack("test-blocks-tall")
    #expect(harness.store.snapshot.selectedPackID == "test-blocks-tall")

    harness.currentPackID = "test-blocks-tall"
    harness.store.packSwapConcluded()
    #expect(harness.store.snapshot.selectedPackID == "test-blocks-tall")
    #expect(harness.store.snapshot.pendingPackID == nil)
}

/// 換失敗時（pack 載不起來）下拉選單要彈回實際跑著的那一套：
/// 那正是「這套換不過去」的訊號，詳細原因在選單列的降級提示裡。
@Test @MainActor func aFailedSwapPutsThePickerBackOnTheRunningPack() {
    let harness = FormHarness()
    harness.packs = [summary("test-blocks"), summary("test-blocks-tall")]
    harness.store.reload()

    harness.store.choosePack("test-blocks-tall")
    harness.store.packSwapConcluded()          // currentPackID 沒變 = 換失敗
    #expect(harness.store.snapshot.selectedPackID == "test-blocks")
}

/// 選到自己不必大費周章，也不該在選單列冒出一次沒必要的降級提示。
@Test @MainActor func choosingTheRunningPackIsANoOp() {
    let harness = FormHarness()
    harness.packs = [summary("test-blocks")]
    harness.store.reload()

    harness.store.choosePack("test-blocks")
    #expect(harness.swapRequests.isEmpty)
}

// MARK: - pack 匯入與移除（分發 C-2）

/// 移除按鈕只出現在**拿得掉**的那幾列：內建拿不掉，正在用的那套也拿不掉
/// （`PackLibraryUseCase.remove` 會拒絕）。按鈕照顯示的話，使用者按下去只會拿到
/// 一句本來可以用「不顯示按鈕」避免的錯誤。
@Test func onlyRemovablePacksOfferARemoveButton() {
    let rows = PackChoice.choices(packs: [
        summary("mycat"),
        summary("current-one", builtIn: false),
        summary("spare", builtIn: false),
        summary("broken", builtIn: false, errors: ["缺少必要動作：sit"]),
    ], current: "current-one")

    func row(_ id: String) -> PackChoice { rows.first { $0.id == id }! }
    #expect(!row("mycat").isRemovable, "內建拿不掉")
    #expect(!row("current-one").isRemovable, "正在用的拿不掉")
    #expect(row("spare").isRemovable)
    #expect(row("broken").isRemovable, "壞掉的更該讓人拿掉——它就是使用者要清的東西")
}

/// 匯入成功之後要**重讀清單**，否則新裝的那套要等下一次 reload 才看得到，
/// 而使用者的感受是「拖進去沒反應」。
@Test @MainActor func aSuccessfulImportRefreshesTheListAndSaysSo() {
    let harness = FormHarness()
    harness.installResult = .succeeded(id: "brand-new")
    harness.store.importPack(from: URL(fileURLWithPath: "/tmp/brand-new.fmpack"))

    #expect(harness.installedSources == ["/tmp/brand-new.fmpack"])
    #expect(harness.reloadCount == 1, "裝完要重讀，否則清單看不到新的那套")
    #expect(harness.store.snapshot.packNotice?.contains("brand-new") == true,
            "要講出裝了哪一套：\(String(describing: harness.store.snapshot.packNotice))")
    #expect(harness.store.snapshot.packConfirmation == nil)
}

/// 同 id 已存在時**不自己決定**：把問句交給呼叫端去問，不重試也不覆蓋。
@Test @MainActor func aCollisionSurfacesAConfirmationInsteadOfOverwriting() {
    let harness = FormHarness()
    harness.installResult = .needsConfirmation(id: "cat", prompt: "「cat」已安裝 1.0，要更新成 2.0 嗎？")
    harness.store.importPack(from: URL(fileURLWithPath: "/tmp/cat.fmpack"))

    let pending = harness.store.snapshot.packConfirmation
    #expect(pending?.prompt.contains("2.0") == true)
    #expect(pending?.source.path == "/tmp/cat.fmpack", "確認之後要用同一個來源重試")
    #expect(harness.reloadCount == 0, "什麼都還沒發生，不必重讀")
}

/// 使用者按下「取代」：用同一個來源、force 重試一次，然後把問句收掉。
@Test @MainActor func confirmingRetriesTheSameSourceWithForce() {
    let harness = FormHarness()
    harness.installResult = .needsConfirmation(id: "cat", prompt: "問句")
    harness.store.importPack(from: URL(fileURLWithPath: "/tmp/cat.fmpack"))

    harness.installResult = .succeeded(id: "cat")
    harness.store.confirmPendingImport()

    #expect(harness.forcedSources == ["/tmp/cat.fmpack"])
    #expect(harness.store.snapshot.packConfirmation == nil, "問完就收掉")
    #expect(harness.reloadCount == 1)
}

/// 取消就是什麼都不做——**特別是不能留著那個問句**，否則下一次拖放會看到舊的。
@Test @MainActor func cancellingLeavesNothingBehind() {
    let harness = FormHarness()
    harness.installResult = .needsConfirmation(id: "cat", prompt: "問句")
    harness.store.importPack(from: URL(fileURLWithPath: "/tmp/cat.fmpack"))
    harness.store.cancelPendingImport()

    #expect(harness.store.snapshot.packConfirmation == nil)
    #expect(harness.forcedSources.isEmpty)
    #expect(harness.installedSources.count == 1, "取消不重試")
}

@Test @MainActor func aFailedImportShowsTheReasonAndDoesNotReload() {
    let harness = FormHarness()
    harness.installResult = .failed(message: "這個來源裡沒有 pack.json，不是一套 sprite pack。")
    harness.store.importPack(from: URL(fileURLWithPath: "/tmp/junk.zip"))

    #expect(harness.store.snapshot.packNotice?.contains("pack.json") == true)
    #expect(harness.reloadCount == 0)
}

/// 一次拖進多個檔案：只收第一個，並且明說。逐一匯入會連續彈好幾個確認框，
/// 而「裝了哪些、哪些失敗」在一行提示裡講不清楚。
@Test @MainActor func droppingSeveralFilesTakesTheFirstAndSaysSo() {
    let harness = FormHarness()
    harness.installResult = .succeeded(id: "a")
    harness.store.importPacks(from: [URL(fileURLWithPath: "/tmp/a.fmpack"),
                                     URL(fileURLWithPath: "/tmp/b.fmpack")])

    #expect(harness.installedSources == ["/tmp/a.fmpack"])
    #expect(harness.store.snapshot.packNotice?.contains("一次只能") == true,
            "多檔要明說只收了一個：\(String(describing: harness.store.snapshot.packNotice))")
}

@Test @MainActor func droppingNothingIsNotAnError() {
    let harness = FormHarness()
    harness.store.importPacks(from: [])
    #expect(harness.installedSources.isEmpty)
    #expect(harness.store.snapshot.packNotice == nil)
}

@Test @MainActor func removingAPackReloadsAndReportsIt() {
    let harness = FormHarness()
    harness.removeResult = .succeeded(id: "spare")
    harness.store.removePack("spare")

    #expect(harness.removedIDs == ["spare"])
    #expect(harness.reloadCount == 1)
    #expect(harness.store.snapshot.packNotice?.contains("spare") == true)
}

@Test @MainActor func aFailedRemovalShowsTheReason() {
    let harness = FormHarness()
    harness.removeResult = .failed(message: "「spare」正在使用中。請先換成別的圖組，再移除它。")
    harness.store.removePack("spare")

    #expect(harness.store.snapshot.packNotice?.contains("正在使用中") == true)
    #expect(harness.reloadCount == 0)
}

/// 提示是**一次性的**：下一個動作開始時就清掉，否則使用者會看到上一次的結果
/// 掛在那裡，分不出「這是剛剛那次的」還是「這次也失敗了」。
///
/// 第二個動作刻意落在 `needsConfirmation`——那條路**不寫** `packNotice`，
/// 所以只有「動作開始時清掉」那一行能讓它變 nil。用一個會成功的動作當第二步
/// 的話，`apply` 會順手覆蓋掉舊訊息，這條測試在守衛被拿掉時照樣綠。
@Test @MainActor func aNewActionClearsThePreviousNotice() {
    let harness = FormHarness()
    harness.removeResult = .failed(message: "壞了")
    harness.store.removePack("spare")
    #expect(harness.store.snapshot.packNotice?.contains("壞了") == true)

    harness.installResult = .needsConfirmation(id: "a", prompt: "問句")
    harness.store.importPack(from: URL(fileURLWithPath: "/tmp/a.fmpack"))
    #expect(harness.store.snapshot.packNotice == nil,
            "上一次的結果還掛著：\(String(describing: harness.store.snapshot.packNotice))")
    #expect(harness.store.snapshot.packConfirmation != nil)
}

/// **選下去的那一刻按鈕就要消失**，不必等換 pack 真的完成（spec 第 6.5 節，
/// 貓在場時要先退場）。這一層守的是可用性；「真的擋下移除」在
/// `PackLibraryUseCaseTests.theSwapTargetCannotBeRemoved` 與
/// `RequestRouterTests.removeRefusesThePackThatIsBeingSwappedTo`。
@Test @MainActor func choosingAPackHidesItsRemoveButton() {
    let harness = FormHarness()
    harness.packs = [summary("mycat"), summary("spare", builtIn: false)]
    harness.currentPackID = "mycat"
    harness.store.reload()
    #expect(harness.store.snapshot.packs.first { $0.id == "spare" }?.isRemovable == true,
            "還沒選它之前是拿得掉的")

    harness.store.choosePack("spare")
    #expect(harness.store.snapshot.packs.first { $0.id == "spare" }?.isRemovable == false,
            "選下去之後那一列的按鈕就要消失")
}

/// **CLI 發起的換 pack 也要能標記。** `findmouse pack use` 走
/// `RequestRouter` → `AppDelegate.requestPackSwap`，完全不經過 `choosePack`；
/// 只標在 `choosePack` 裡的話，CLI 造出的空窗裡按鈕不會消失——而那個空窗
/// 與視窗發起的一模一樣長。
@Test @MainActor func aSwapRequestedElsewhereAlsoHidesTheRemoveButton() {
    let harness = FormHarness()
    harness.packs = [summary("mycat"), summary("spare", builtIn: false)]
    harness.currentPackID = "mycat"
    harness.store.reload()
    #expect(harness.store.snapshot.packs.first { $0.id == "spare" }?.isRemovable == true)

    // 注意：沒有經過 choosePack
    harness.store.noteSwapRequested("spare")
    #expect(harness.store.snapshot.packs.first { $0.id == "spare" }?.isRemovable == false)
    #expect(harness.swapRequests.isEmpty, "標記不該順便發出換 pack 的請求")
}

/// `reload()` 會重掃磁碟重建整份 rows，所以它必須把 pending 帶進去——
/// 不帶的話，換 pack 空窗裡任何一次 reload（選單列打開子選單就會觸發一次）
/// 都會把剛藏起來的按鈕變回來。
@Test @MainActor func reloadKeepsThePendingLabel() {
    let harness = FormHarness()
    harness.packs = [summary("mycat"), summary("spare", builtIn: false)]
    harness.currentPackID = "mycat"
    harness.store.reload()
    harness.store.choosePack("spare")
    harness.store.reload()
    #expect(harness.store.snapshot.packs.first { $0.id == "spare" }?.isRemovable == false,
            "reload 之後按鈕又冒出來了")
}

/// 「顯示資料夾」只是轉發，但**要真的轉發**——沒有這條的話，接線漏掉時
/// 按鈕按下去沒反應，而那與「Finder 開了但你沒看到」外觀相同。
@Test @MainActor func revealForwardsToTheInjectedAction() {
    let harness = FormHarness()
    harness.store.revealPacks()
    #expect(harness.revealCount == 1)
}

// MARK: - 進階設定那一列要顯示什麼

/// 完整性：`advancedKeys` 是推導的，所以有人加了新設定又沒填展示資料時，
/// 這條會紅——不是靜默少畫一列。
///
/// **它不是獨立的覆蓋。** 同一個缺漏會讓 `sliderSpecExistsExactlyForNumberKinds`
/// 的 `try #require` 一起紅。留著是為了**訊息**：這條說得出缺的是哪幾個 key，
/// 那條只會說某個 required value 是 nil。
@Test func everyAdvancedKeyHasPresentation() {
    let useCase = SettingsUseCase(store: StubStore(),
                                  catalog: StubCatalog(logicalHeight: 100))
    let missing = SettingsForm.advancedKeys.filter { useCase.presentation(of: $0) == nil }
    #expect(missing.isEmpty, "這些進階 key 沒有展示資料：\(missing)")

    // 反方向：主視窗那 8 項的標題寫在 View 裡，registry 再放一份就是兩份
    // 會漂掉的字串。多填的那一份不會有任何訊號，所以在這裡擋。
    let extra = SettingsForm.windowKeys.filter { useCase.presentation(of: $0) != nil }
    #expect(extra.isEmpty, "這些主視窗 key 不該有展示資料：\(extra)")
}

/// 數字 key 一定要有滑桿規格，choice 一定不能有——畫錯列型就是這裡分岔。
@Test func sliderSpecExistsExactlyForNumberKinds() throws {
    let useCase = SettingsUseCase(store: StubStore(),
                                  catalog: StubCatalog(logicalHeight: 100))
    for key in SettingsForm.advancedKeys {
        let presentation = try #require(useCase.presentation(of: key))
        if case .number = try useCase.kind(of: key) {
            #expect(presentation.slider != nil, "\(key) 是數字卻沒有滑桿規格")
        } else {
            #expect(presentation.slider == nil, "\(key) 不是數字卻有滑桿規格")
        }
    }
}

/// 量化位數是從 `step` 推導出來的，這條釘住現行五個 step 值的對應。
///
/// 推導取代了「另外傳一個 digits」——那兩個旋鈕可以互相矛盾，而矛盾**沒有任何
/// 測試看得見**（`step: 0.05` 配 0 位會把 0.95 量化成 1.0，超出宣告值域，
/// 症狀只在軌道盡頭出現）。代價是推導本身成了單點，所以它要有自己的測試。
@Test func sliderDigitsFollowFromTheStep() {
    let expected: [Double: Int] = [10: 0, 5: 0, 50: 0, 0.5: 1, 0.05: 2]
    for (step, digits) in expected {
        #expect(AdvancedPresentation.SliderSpec(step: step).fractionDigits == digits,
                "step \(step) 應該量化到 \(digits) 位")
    }

    // 上面那張表是**手抄的**，所以它會在有人往註冊表加新 step 時靜默過時。
    // 拿註冊表實際用到的 step 回頭對一次，逼那個人把表補齊。
    //
    // 這同時是 `decimals(of:)` 唯一的已知破口（指數形式沒有小數點，`5e-05`
    // 會被算成 0 位）的守衛：那種寫法一出現在註冊表就會紅在這裡，
    // 所以推導本身不必為一個還沒發生的情況長出一條走不到的分支。
    let useCase = SettingsUseCase(store: StubStore(),
                                  catalog: StubCatalog(logicalHeight: 100))
    let inUse = Set(SettingsForm.advancedKeys.compactMap {
        useCase.presentation(of: $0)?.slider?.step
    })
    let unpinned = inUse.subtracting(expected.keys).sorted()
    #expect(unpinned.isEmpty, "註冊表用了沒被釘住的 step：\(unpinned)")
}

/// 滑桿吐得出來的每一格，`set` 都必須收得下。
///
/// 兩個獨立的決定湊在一起才有這個危險：值要量化（`Slider` 帶了 `step` 仍給
/// `1.2999999999`），而 `set` **拒絕超出值域的值、不 clamp**（spec 第 9 節）。
/// 量化把值推出值域的話，使用者只是拉一下滑桿就吃一行紅字，而那一格他永遠
/// 拉不到——UI 吐出自己的驗證器不收的值。
///
/// **這條與 `sliderDigitsFollowFromTheStep` 不重疊。** 那條只問「digits 是不是
/// 從 step 推出來的」，它對值域一無所知；推導正確而**值域端點比 step 細**時
/// 它照樣綠。實測：`spotlight.dimOpacity` 的 step 從 0.05 改成 0.1、並照那條
/// 的要求把 `0.1: 1` 補進它那張表（digits 仍是正確的 1），0.95 這個上界量化成
/// 1.0，全 suite 只有這條紅。
///
/// 走 `store.submit(key, number:)` 而不是直接 `settings.set`：那才是滑桿實際
/// 走的線（`SettingsWindow` → `model.submit(_:number:)` → 這裡 → `render` →
/// `set`），中間的 `render` 也在受測範圍內。自己拼字串等於把 `render` 抄一份。
///
/// **量化公式在這裡是抄的**（進階視窗還沒寫）。所以它釘的是「註冊表的 step
/// 與值域互相相容」，不是「視窗真的照這個公式量化」——後者要等那個視窗存在。
@Test @MainActor func everySliderStopIsAValueTheValidatorAccepts() throws {
    let harness = FormHarness()
    for key in SettingsForm.advancedKeys {
        guard let slider = harness.settings.presentation(of: key)?.slider,
              case .number(let range) = try harness.settings.kind(of: key) else { continue }

        // 上界要**明確補一格**，靠 `lowerBound + n * step` 走不到它：step 除不盡
        // 值域時最後一格落在上界之前，而上界正是最容易出事的那一格。實測把
        // `spotlight.margin` 的上界改成 200.5，只有補了這一格才紅。
        //
        // 反過來也不能讓它衝過頭。滑桿收在 `in:` 宣告的兩端裡，吐不出「上界再
        // 加一格」的值；拿那種值來驗，會對「step 除不盡值域」這種**無害**的情況
        // 誤報（實測 `teaser.pounceSpeed` 改 step 40 時就是這樣，那不是缺陷）。
        var stops: [Double] = []
        var raw = range.lowerBound
        while raw < range.upperBound {
            stops.append(raw)
            raw += slider.step
        }
        stops.append(range.upperBound)

        let factor = pow(10.0, Double(slider.fractionDigits))
        for (index, stop) in stops.enumerated() {
            let quantised = (stop * factor).rounded() / factor
            // 先算出結果再進 `#expect`：訊息要讀 `errors[key]`，那是這次
            // submit 才寫進去的。
            let accepted = harness.store.submit(key, number: quantised)
            #expect(accepted, """
                \(key) 第 \(index) 格：\(stop) 量化成 \(quantised)，落在 \(range) 外\
                （\(harness.store.snapshot.errors[key] ?? "沒有錯誤訊息")）。\
                step \(slider.step) 只量化到 \(slider.fractionDigits) 位，\
                而值域端點比它細。
                """)
        }

        // 沒有中間格的話，上面那圈只驗了頭尾兩個端點——對這個 key 而言它是空的，
        // 而畫面上那條軌道也只有頭尾可停。
        #expect(slider.step < range.upperBound - range.lowerBound,
                "\(key) 的 step \(slider.step) 不比整個 \(range) 窄，軌道沒有中間格")
    }
}

// MARK: - 進階視窗的分組

/// 分組是**重新排過的同一批 key**，所以「不重不漏」是它唯一的完整性條件：
/// 漏一個就是那一列在畫面上不存在，重複一個就是同一個設定出現在兩組
/// ——後者拖動其中一份，另一份不會跟著動。
///
/// 第二句**不是獨立的覆蓋**：`declaredKeys` 不可能有重複（真有的話
/// `SettingsUseCase.init` 的 `Dictionary(uniqueKeysWithValues:)` 會先 trap），
/// 所以第一句成立時第二句必然成立。留著是為了**訊息**——實測讓 `window.level`
/// 落進每一組，兩句一起紅，而第一句吐的是兩串長陣列要人自己比對。
@Test func advancedSectionsCoverExactlyTheAdvancedKeys() {
    let useCase = SettingsUseCase(store: StubStore(),
                                  catalog: StubCatalog(logicalHeight: 100))
    let listed = SettingsForm.advancedSections(useCase).flatMap { $0.rows.map(\.key) }
    #expect(listed.sorted() == SettingsForm.advancedKeys.sorted(), "不重不漏")
    #expect(listed.count == Set(listed).count, "同一個 key 出現在兩組")
}

/// 兩件不同的事，所以分成兩個斷言。
///
/// 前一句是 `advancedGroups` 自己的合約：畫面順序就是 `CaseIterable` 的順序
/// （`AdvancedGroup` 的註解），而這個函式必須照那個順序回。把 `allCases` 反過來
/// 跑實測只有這一句會紅——分組全部還在、每一組也都還有 key，錯的只有順序。
///
/// 後一句問的是**註冊表**：有沒有哪個分組沒人用。它不是前一句的副作用——
/// 沒有它的話，一個沒人用的分組會紅在「順序」那一句上，而讀到那句話的人
/// 會跑去查 `advancedGroups` 的排序，真正該改的地方在註冊表。
///
/// 沒人用的分組**判為錯誤**而不是放行：到得了它的只有兩種手動編輯——加了 case
/// 還沒配 key，或把某組最後一個 key 升上 `windowKeys` 卻留著空 case——兩種都是
/// 沒做完的改動，而畫面上的後果是一個底下什麼都沒有的標題。
@Test func advancedSectionsAreOrderedAndNonEmpty() {
    let useCase = SettingsUseCase(store: StubStore(),
                                  catalog: StubCatalog(logicalHeight: 100))
    let groups = SettingsForm.advancedSections(useCase)
    #expect(groups.map(\.group) == AdvancedGroup.allCases, "順序要與 CaseIterable 一致")

    let orphans = groups.filter { $0.rows.isEmpty }.map(\.group)
    #expect(orphans.isEmpty, "這些分組沒有任何 key 用它：\(orphans)")
}

/// 同一組內的順序來自**註冊表的宣告順序**，不是 key 的字典序。
///
/// 斷言用標題而不是 key，因為要看的就是它讀起來對不對：字典序會排成
/// 命中半徑 → 撲擊速度 → 撲擊觸發速度 → 後退距離 → 潛行距離 → 潛行逾時，
/// 也就是效果排在觸發它的原因前面，而使用者是照著這個順序一格一格試的。
@Test func rowsWithinAGroupFollowTheRegistryNotTheAlphabet() throws {
    let useCase = SettingsUseCase(store: StubStore(),
                                  catalog: StubCatalog(logicalHeight: 100))
    let teaser = try #require(
        SettingsForm.advancedSections(useCase).first { $0.group == .teaser })
    #expect(teaser.rows.map(\.presentation.title)
            == ["潛行距離", "潛行逾時", "撲擊觸發速度", "撲擊速度", "命中半徑", "後退距離"],
            "逗貓棒那組要照 潛行 → 撲擊 → 命中 → 後退 的因果順序")
}

/// 每一列的欄位都是**各自算的**。寫成常數的話畫面上整欄會一致地錯，
/// 而一致的錯看起來像對的（整排都不顯示還原鍵、或整排都顯示）。
///
/// 走 `reload()` 而不是直接呼叫 `advancedSections`：View 讀的是快照，
/// 漏接那一行的話函式再正確畫面也是空的——兩個 `#require` 就是那條線的守衛，
/// 快照沒填的話它們先掛。
@Test @MainActor func theSnapshotCarriesEveryAdvancedRowWithItsOwnState() throws {
    let harness = FormHarness()
    try harness.settings.set("spotlight.margin", to: "48")   // 預設是 24
    harness.store.reload()

    let rows = harness.store.snapshot.advancedSections.flatMap(\.rows)

    let edited = try #require(rows.first { $0.key == "spotlight.margin" })
    #expect(edited.isAtDefault == false, "剛改過的那一列不該說自己是預設")
    #expect(edited.presentation.title == "邊界留白")
    #expect(edited.kind == .number(0...200))

    let untouched = try #require(rows.first { $0.key == "spotlight.feather" })
    #expect(untouched.isAtDefault, "沒動過的那一列跟著鄰居一起變成「改過」了")
}

// MARK: - 進階視窗的「全部還原」

/// 範圍語意：按鈕在進階視窗裡，就只能動進階那 15 項。連帶還原主視窗的 pack、
/// 快捷鍵與聚光燈設定會很意外，而 `resetAll()` 正是那樣。
@Test func resetAdvancedLeavesTheMainWindowKeysUntouched() throws {
    let useCase = SettingsUseCase(store: StubStore(),
                                  catalog: StubCatalog(logicalHeight: 100))
    try useCase.set("cat.speed", to: "1500")          // 進階
    try useCase.set("cat.scale", to: "1.5")           // 主視窗
    try useCase.set("hotkey.summon", to: "⌃⇧K")       // 主視窗

    SettingsForm.resetAdvanced(useCase)

    #expect(try useCase.isAtDefault("cat.speed"), "進階項應被還原")
    #expect(try !useCase.isAtDefault("cat.scale"), "主視窗的 cat.scale 不該被動")
    #expect(try useCase.get("hotkey.summon") == "⌃⇧K", "主視窗的快捷鍵不該被動")
}

/// 先把**每一個**進階 key 都弄髒，再還原。
///
/// 原本只弄髒三個 key 就迴圈斷言全部——沒被弄髒的那些本來就在預設值上，
/// 那些斷言無論 `resetAdvanced` 有沒有碰它們都會過。實測：把實作的迴圈改成
/// `where key != "spotlight.feather"`，整包全綠；同形的 `!= "cat.speed"`
/// 會紅（所以突變本身有效，那個綠是真的洞）。名字說全部，證明的是三個。
///
/// 探針**推導**而不是手抄字面值：這裡只有兩種 kind（數字與 choice），
/// 一條規則比一張表小。與 Task 2 的 `everyKeyCanTellThatItHasBeenChanged`
/// 相反是對的——那條跨五種 kind（含 hotkey 與 packID），規則會比表大。
///
/// 兩道防呆，因為「探針剛好等於預設」正是這條測試要修的那種靜默失效：
/// 挑完探針先確認它與現值不同，寫完再整批確認**沒有一項**還在預設上。
/// 後者才是完整的守衛——有些 key 的預設是衍生的（`wake.threshold` 跟著
/// `rehunt.threshold` 動，見 `SettingsUseCase.isAtDefault` 的註解），
/// 所以「寫入當下不同」不蘊含「全部寫完之後仍然不同」。
@Test func resetAdvancedClearsEveryAdvancedKey() throws {
    let useCase = SettingsUseCase(store: StubStore(),
                                  catalog: StubCatalog(logicalHeight: 100))

    for key in SettingsForm.advancedKeys {
        let probe: String
        switch try useCase.kind(of: key) {
        case .number(let range):
            guard case .number(let now) = try useCase.value(key) else {
                Issue.record("\(key) 宣告成數字，讀回來的卻不是"); return
            }
            // 挑另一端：預設坐在下界時就用上界，其餘一律用下界。
            let pick = now == range.lowerBound ? range.upperBound : range.lowerBound
            try #require(pick != now, "\(key) 的探針等於預設，這一列會變成恆真句")
            probe = String(pick)
        case .choice(let allowed):
            guard case .text(let now) = try useCase.value(key) else {
                Issue.record("\(key) 宣告成 choice，讀回來的卻不是"); return
            }
            probe = try #require(allowed.first { $0 != now },
                                 "\(key) 只有一個合法值，弄不髒它")
        case .boolean, .hotkey, .packID:
            // 停下而不是偷偷跳過：規則沒涵蓋的 kind 要先決定怎麼弄髒它，
            // 略過它等於把這條測試退回它原本那個恆真的樣子。
            Issue.record("\(key) 的 kind 不在這條規則的涵蓋範圍內"); return
        }
        try useCase.set(key, to: probe)
    }

    for key in SettingsForm.advancedKeys {
        #expect(try !useCase.isAtDefault(key), "\(key) 沒被弄髒，它下面那個斷言是恆真的")
    }

    SettingsForm.resetAdvanced(useCase)

    for key in SettingsForm.advancedKeys {
        #expect(try useCase.isAtDefault(key), "\(key) 沒被還原")
    }
}

/// 還原鍵按下去要收拾三樣東西：值、草稿、紅字。
///
/// 後兩樣不是順手——`reload()` **刻意不清**它們（它的註解說明了為什麼：重讀的
/// 觸發者常常是 CLI），所以沒有人清的話，欄位會繼續顯示使用者按 ↺ 之前打的字，
/// 而紅字會指著一個已經被還原掉的值。
///
/// `snapshot.values` 那一句就是 `reload()` 的守衛：值只有重讀才會進快照，
/// 漏掉那一行的話畫面停在 1500，而磁碟上已經是預設值。
@Test @MainActor func revertingAKeyAlsoDropsTheDraftAndTheComplaint() throws {
    let harness = FormHarness()
    try harness.settings.set("cat.speed", to: "1500")
    harness.store.reload()
    // 造出「打了字、被拒絕」的那個狀態：草稿與紅字同時在。
    #expect(harness.store.submit("cat.speed", "99999") == false)
    #expect(harness.store.snapshot.drafts["cat.speed"] == "99999")
    #expect(harness.store.snapshot.errors["cat.speed"] != nil)
    #expect(harness.changeNotifications == 0, "被拒絕的寫入不該通知")

    // 另一個 key 也弄成同樣的狀態。還原一列**只能動那一列**——
    // 把兩行 removeValue 寫成 removeAll 是很自然的手滑，而在補這幾行之前
    // 那個突變不會讓任何測試轉紅（批次那條路有守衛，單鍵這條沒有）。
    #expect(harness.store.submit("cat.scale", "9") == false)
    #expect(harness.store.snapshot.drafts["cat.scale"] == "9")
    #expect(harness.store.snapshot.errors["cat.scale"] != nil)

    harness.store.reset("cat.speed")

    #expect(try harness.settings.isAtDefault("cat.speed"), "值沒有被還原")
    #expect(harness.store.snapshot.drafts["cat.speed"] == nil, "欄位還顯示他按 ↺ 之前打的字")
    #expect(harness.store.snapshot.errors["cat.speed"] == nil, "紅字指著一個已經不存在的值")
    #expect(harness.store.snapshot.drafts["cat.scale"] == "9", "還原一列不該清掉別列的草稿")
    #expect(harness.store.snapshot.errors["cat.scale"] != nil, "還原一列不該清掉別列的紅字")
    #expect(harness.store.snapshot.values["cat.speed"] == .number(900), "沒有重讀，畫面停在舊值")
    #expect(harness.changeNotifications == 1, "還原是一種變更，要通知一次")
}

/// 範圍語意在 store 這一層的樣子：值、草稿、紅字**三樣都**只能動進階那些。
///
/// 主視窗那一半特別容易被未來的編輯弄壞——把清除迴圈換成
/// `snapshot.drafts.removeAll()` 看起來更乾淨，而它會靜默清掉使用者正在
/// 主視窗修的那個欄位。所以這裡對 `cat.scale` 的三個斷言是正向的：它們要求
/// 那些東西**還在**。
@Test @MainActor func revertingTheAdvancedPaneLeavesTheMainWindowAlone() throws {
    let harness = FormHarness()
    try harness.settings.set("cat.speed", to: "1500")   // 進階
    try harness.settings.set("cat.scale", to: "1.5")    // 主視窗
    harness.store.reload()
    #expect(harness.store.submit("cat.speed", "99999") == false)
    #expect(harness.store.submit("cat.scale", "9") == false)

    harness.store.resetAdvanced()

    #expect(try harness.settings.isAtDefault("cat.speed"), "進階項的值沒有被還原")
    #expect(harness.store.snapshot.drafts["cat.speed"] == nil, "進階項的草稿沒被清掉")
    #expect(harness.store.snapshot.errors["cat.speed"] == nil, "進階項的紅字沒被清掉")
    #expect(harness.store.snapshot.values["cat.speed"] == .number(900), "沒有重讀，畫面停在舊值")

    #expect(try !harness.settings.isAtDefault("cat.scale"), "主視窗的值被連帶還原了")
    #expect(harness.store.snapshot.drafts["cat.scale"] == "9", "主視窗的草稿被連帶清掉了")
    #expect(harness.store.snapshot.errors["cat.scale"] != nil, "主視窗的紅字被連帶清掉了")

    #expect(harness.changeNotifications == 1, "整批只通知一次")
}
