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
