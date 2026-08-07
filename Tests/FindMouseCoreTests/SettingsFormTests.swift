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

    lazy var store = SettingsFormStore(
        settings: { [unowned self] in self.settings },
        packs: { [unowned self] in self.packs },
        currentPackID: { [unowned self] in self.currentPackID },
        usePack: { [unowned self] id in self.swapRequests.append(id) },
        onChanged: { [unowned self] in self.changeNotifications += 1 })
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
@Test @MainActor func editingClearsThePreviousComplaint() {
    let harness = FormHarness()
    harness.store.reload()
    harness.store.submit("hotkey.summon", "F")
    #expect(harness.store.snapshot.errors["hotkey.summon"] != nil)

    harness.store.draft("hotkey.summon", "F")
    #expect(harness.store.snapshot.errors["hotkey.summon"] == nil)
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
