import CoreGraphics
import Foundation
import FindMouseDomain

/// 設定視窗要顯示什麼、值怎麼進出——**不含任何 SwiftUI**。
///
/// 為什麼住在 Core：`FindMouseApp` 沒有測試 target，寫進 SwiftUI `body` 的判斷
/// 一行都測不到。把「有哪些欄位」「寫入走哪條路」「pack 清單長什麼樣」推到這裡
/// 之後，View 剩下的只有版面配置，而版面配置本來就只能用眼睛驗。
public enum SettingsForm {

    /// spec 第 9 節那張表 UI 欄打 ✓ 的 8 項，順序即畫面順序。
    ///
    /// 這是本檔唯一手抄 spec 的清單。推導不出來的原因是「哪一項配哪一種控制項」
    /// 不在型別裡：`pack.id` 與 `hotkey.summon` 的 `SettingKind` 都是字串型，
    /// 前者是下拉選單、後者是文字欄。所以這裡抄，並由測試釘住每個 key 都存在。
    public static let windowKeys = [
        "pack.id",
        "cat.scale",
        "rest.duration",
        "sleep.duration",
        "spotlight.enabled",
        "spotlight.trigger",
        "hotkey.summon",
        "hotkey.teaser",
    ]

    /// 「進階設定…」要列的其餘項目。**推導而不是手抄**：
    /// 手抄的清單在有人往註冊表加設定時會靜默過時，而少列一項不會有任何訊號。
    public static var advancedKeys: [String] {
        SettingsUseCase.declaredKeys.filter { !windowKeys.contains($0) }
    }

    /// 「進階設定…」的一列：可以直接貼進終端機的命令，加上值域說明。
    public struct AdvancedEntry: Sendable, Equatable {
        public let key: String
        /// 帶**當前值**的整行命令——貼上去執行等於原地不動，改一個數字就是新設定。
        /// 附當前值而不是佔位符，是因為調手感的人要先知道現在是多少。
        public let command: String
        public let range: String
    }

    public static func advancedEntries(_ settings: SettingsUseCase) -> [AdvancedEntry] {
        advancedKeys.compactMap { key in
            // 兩個 try? 都不會是 nil：key 來自 declaredKeys。真的變成 nil 時
            // 少列一項，而 `advancedEntriesCoverEveryCLIOnlyKey` 會抓到。
            guard let value = try? settings.get(key),
                  let kind = try? settings.kind(of: key) else { return nil }
            return AdvancedEntry(key: key,
                                 command: "findmouse config set \(key) \(value)",
                                 range: text(for: kind))
        }
    }

    /// 值域的一句話說明。數字沿用 `SettingsUseCase` 的數字格式（整數印整數），
    /// 不另寫一份——不然同一個範圍在 CLI 與 UI 會印成兩個樣子。
    public static func text(for kind: SettingKind) -> String {
        switch kind {
        case .number(let range):
            return "\(SettingsUseCase.render(.number(range.lowerBound)))–"
                + "\(SettingsUseCase.render(.number(range.upperBound)))"
        case .boolean:
            return "true | false"
        case .choice(let allowed):
            return allowed.joined(separator: " | ")
        case .hotkey:
            return "修飾鍵（⌃⌥⇧⌘）＋ 一個 A–Z 或 0–9"
        case .packID:
            return "a-z、0-9、-"
        }
    }
}

/// pack 下拉選單的一列。
public struct PackChoice: Sendable, Equatable {
    public let id: String
    public let isBuiltIn: Bool
    /// `false` 的那些要顯示紅字且不可選（spec 第 10 節）
    public let isUsable: Bool
    public let isCurrent: Bool
    /// 已經翻成人話的錯誤（來自 `PackSummary.errors`）
    public let problems: [String]

    public init(id: String, isBuiltIn: Bool, isUsable: Bool,
                isCurrent: Bool, problems: [String]) {
        self.id = id
        self.isBuiltIn = isBuiltIn
        self.isUsable = isUsable
        self.isCurrent = isCurrent
        self.problems = problems
    }

    /// - Parameter current: **實際跑著的** pack id，不是 `config get pack.id`。
    ///   兩者會不一致：啟動時想要的那套載不起來會退回內建（`AppDelegate`），
    ///   而設定裡那個壞掉的 id **不會被改寫**。拿設定當選取值的話，
    ///   下拉選單會顯示一套紅字、不可選、而且根本沒在跑的 pack。
    public static func choices(packs: [PackSummary], current: String) -> [PackChoice] {
        var rows = packs.map {
            PackChoice(id: $0.id, isBuiltIn: $0.isBuiltIn, isUsable: $0.isUsable,
                       isCurrent: $0.id == current, problems: $0.errors)
        }
        // 跑著的那套不在掃描結果裡（使用者把目錄整個刪掉、App 還握著已載入的圖）
        // 也要有一列：選取值對不到任何一列時下拉選單顯示空白，
        // 而使用者看到的是「我的 pack 欄位不見了」。
        if !current.isEmpty, !packs.contains(where: { $0.id == current }) {
            rows.append(PackChoice(id: current, isBuiltIn: false, isUsable: false,
                                   isCurrent: true, problems: ["這套 pack 已經不在磁碟上"]))
        }
        return rows
    }

    /// 選單列那一列的字。
    ///
    /// **不可用的原因寫進標題，不是只掛 tooltip。** 灰掉的選單項沒有任何
    /// 「把游標停在我上面」的暗示，而 tooltip 要停約 1.5 秒才浮出來——
    /// 只靠它的話，「這套為什麼不能選」實際上沒有人看得到。
    /// （設定視窗另有一份較短的標籤：它的下拉選單底下有一塊紅字區可以放原因，
    /// 選單沒有那種地方。兩份刻意不同，不是漏改。）
    public var menuTitle: String {
        var text = id
        if isBuiltIn { text += "（內建）" }
        if !isUsable { text += " — \(reasonText)" }
        return text
    }

    /// 標題被選單寬度截掉時的完整版；沒有原因可講就不要掛。
    ///
    /// 實測（macOS 27）：`autoenablesItems = false` 的選單裡，tooltip 在
    /// `isEnabled = false` 的項目上**照樣會顯示**，所以這一份不是白寫的——
    /// 它是標題的補充，不是替代品。
    ///
    /// 條件是「有沒有原因」而不是 `isUsable`：兩者今天等價，但拿 `isUsable` 判
    /// 會讓沒附原因的不可用列掛上一個**空字串** tooltip，而那會浮出一個
    /// 空白小框——比沒有 tooltip 更難理解。
    public var menuTooltip: String? {
        problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    /// `isUsable == false` 卻沒有附原因時的墊底字。
    ///
    /// 今天走不到（`problems` 來自 `PackSummary.errors`，而 `isUsable`
    /// 就是「errors 是空的」）。留著是因為 `PackChoice` 的 init 是 public：
    /// 哪天有人從別條路建出一個沒帶原因的不可用列，使用者看到的會是一個
    /// 灰掉、沒有標記、和可用的長得一模一樣的項目——那是這個專案一直在獵殺的
    /// 那種靜默失敗。
    private var reasonText: String {
        problems.isEmpty ? "不可用" : problems.joined(separator: "、")
    }
}

/// 設定視窗的狀態與寫入路徑。
///
/// **不持有 `SettingsUseCase`，只持有取得它的方法。** 換 pack 會把整個
/// `PackBinding`（連同它的 `SettingsUseCase`）換掉，捕獲一份的話設定視窗之後
/// 寫的是孤兒物件——UI 看起來成功，`config get` 讀不到。這與 `RequestRouter`
/// 對 `control`／`settings` 用 closure 而不是值是同一個理由。
///
/// **值域一律交給 `SettingsUseCase`**（spec 第 9 節：驗證只有一份）。這裡只做
/// 兩件事：把它丟出的錯誤攤成一句話，以及記住使用者打了什麼還沒被接受。
@MainActor
public final class SettingsFormStore {

    /// View 畫的東西。整包換掉而不是一堆 `@Published`，
    /// 這樣「重讀」永遠是一個賦值，不會漏掉其中一個欄位。
    public struct Snapshot: Sendable, Equatable {
        /// 全部宣告過的 key 的當前值，**保留型別**
        public var values: [String: SettingValue] = [:]
        /// 打了但還沒被接受的字串（打字中、或剛被拒絕的那個）
        public var drafts: [String: String] = [:]
        /// key → 紅字
        public var errors: [String: String] = [:]
        public var packs: [PackChoice] = []
        /// 實際跑著的 pack
        public var currentPackID = ""
        /// 已經請求、但還沒真的換過去的那一套（換 pack 要等貓退場，spec 第 6.5 節）
        public var pendingPackID: String?
        public var advanced: [SettingsForm.AdvancedEntry] = []

        public init() {}

        /// 下拉選單該顯示哪一套。
        public var selectedPackID: String { pendingPackID ?? currentPackID }

        /// 文字欄要顯示的字：草稿優先。被拒絕之後仍顯示使用者打的那個字串，
        /// 不然紅框旁邊會是舊值，看不出哪裡錯。
        public func text(_ key: String) -> String {
            if let draft = drafts[key] { return draft }
            if case .text(let s)? = values[key] { return s }
            if let value = values[key] { return SettingsUseCase.render(value) }
            return ""
        }

        public func number(_ key: String) -> Double? {
            if case .number(let d)? = values[key] { return d }
            return nil
        }

        public func flag(_ key: String) -> Bool {
            if case .flag(let b)? = values[key] { return b }
            return false
        }
    }

    private let settings: @MainActor () -> SettingsUseCase?
    private let packs: @MainActor () -> [PackSummary]
    private let currentPackID: @MainActor () -> String
    private let usePack: @MainActor (String) -> Void
    private let onChanged: @MainActor () -> Void

    public private(set) var snapshot = Snapshot()

    /// - Parameter onChanged: 設定**真的改了**之後通知一次。與 `RequestRouter`
    ///   的同名參數走同一條路（App 收到後重裝快捷鍵並重建 presenter），
    ///   所以 CLI 改與視窗改的後續處理只有一份。失敗的寫入不呼叫它。
    public init(settings: @escaping @MainActor () -> SettingsUseCase?,
                packs: @escaping @MainActor () -> [PackSummary],
                currentPackID: @escaping @MainActor () -> String,
                usePack: @escaping @MainActor (String) -> Void,
                onChanged: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.packs = packs
        self.currentPackID = currentPackID
        self.usePack = usePack
        self.onChanged = onChanged
    }

    /// 控制項的範圍取自這裡（slider 的 `in:`、兩選一的選項），
    /// 這樣 UI 不必也不該再寫一份 `0.5...2.0`（spec 第 9 節：值域只有一份）。
    public func kind(of key: String) -> SettingKind? {
        try? settings()?.kind(of: key)
    }

    /// 從**當下的** `SettingsUseCase` 重讀全部值。
    ///
    /// 草稿與紅字刻意不清：重讀的觸發者常常是別人（CLI 改了某個值），
    /// 清掉的話使用者正在修的那個欄位會在他眼前被重置。
    public func reload() {
        if let settings = settings() {
            var values: [String: SettingValue] = [:]
            for key in SettingsUseCase.declaredKeys {
                if let value = try? settings.value(key) { values[key] = value }
            }
            snapshot.values = values
            snapshot.advanced = SettingsForm.advancedEntries(settings)
        }
        snapshot.currentPackID = currentPackID()
        snapshot.packs = PackChoice.choices(packs: packs(), current: snapshot.currentPackID)
    }

    /// 打字中：只記草稿，**不寫入也不驗**。
    ///
    /// 為什麼不邊打邊驗：`⌥⌘F` 打到第一個字元時必然非法，一邊打一邊紅框
    /// 只是在告訴使用者「你還沒打完」。驗證時機是按 Enter、失焦、或關掉視窗
    /// （三條路都走 `commitDraft`；關視窗那條是後備，見 `SettingsWindowController`）。
    /// 紅字在他開始改的當下就清掉——那是「我知道你在修了」。
    ///
    /// **與現有草稿逐字相同的那一次不算「開始改」。** AppKit 在結束編輯時會把
    /// 欄位內容原字回送一次到 binding 的 `set:`，而那一下正好落在失焦提交之後：
    /// `commitDraft` 剛把紅字設好，回送就把它清掉，於是值被擋下來而畫面上
    /// 沒有任何理由（按 Enter 走 `onSubmit`、焦點沒變、沒有回送，所以只有失焦會靜默）。
    /// 用字串相同當判準是因為實測回送帶的就是草稿本身，而使用者打不出這種輸入——
    /// 真的編輯一定會讓長度或內容變掉。
    public func draft(_ key: String, _ text: String) {
        guard snapshot.drafts[key] != text else { return }
        snapshot.drafts[key] = text
        snapshot.errors.removeValue(forKey: key)
    }

    /// 提交草稿。沒有草稿、或草稿與存著的值相同就什麼都不做——
    /// 每次失焦都寫一次的話，只是點進去看一眼也會觸發一輪快捷鍵重新註冊
    /// （那期間快捷鍵是不存在的）。
    ///
    /// **比對用 `render` 而不是拆 `.text`。** 拆 case 的寫法只認得字串型：
    /// 數值欄的 `values[key]` 是 `.number`，永遠比不中，於是點進 `cat.scale`
    /// 看一眼再點出去就會白寫一次。`render` 是三種型別共用的那一份格式，
    /// 而畫面上顯示的也正是它（`Snapshot.text`），所以「畫面沒變」與
    /// 「不寫入」是同一個條件。
    ///
    /// 比的是**字串**不是解析後的值，所以 `1.25` 打成 `1.250`（或 `+1.25`）
    /// 仍會寫一次——值不變、只是多一輪 `onChanged()`。不追這個差是因為
    /// 唯一乾淨的追法是先 parse，而 parse 住在 `SettingsUseCase`（spec 第 9 節：
    /// 值域與格式只有一份），在這裡自己 `Double(draft)` 就是第二份。
    @discardableResult
    public func commitDraft(_ key: String) -> Bool {
        guard let draft = snapshot.drafts[key] else { return true }
        if let stored = snapshot.values[key], SettingsUseCase.render(stored) == draft {
            snapshot.drafts.removeValue(forKey: key)
            return true
        }
        return submit(key, draft)
    }

    /// 寫入一個字串值。值域驗證在 `SettingsUseCase` 裡，這裡只負責把錯誤攤成紅字。
    @discardableResult
    public func submit(_ key: String, _ text: String) -> Bool {
        guard let settings = settings() else { return false }
        do {
            try settings.set(key, to: text)
            snapshot.drafts.removeValue(forKey: key)
            snapshot.errors.removeValue(forKey: key)
            // 回讀：存進去的是**正規化後**的值（`⌘⌥F` → `⌥⌘F`、`yes` → `true`），
            // 不重讀的話畫面顯示的與 `config get` 回的是同一個值的兩種寫法。
            reload()
            onChanged()
            return true
        } catch let error as SettingsError {
            snapshot.drafts[key] = text
            snapshot.errors[key] = Self.message(for: error)
            return false
        } catch {
            snapshot.drafts[key] = text
            snapshot.errors[key] = "\(error)"
            return false
        }
    }

    @discardableResult
    public func submit(_ key: String, number: Double) -> Bool {
        submit(key, SettingsUseCase.render(.number(number)))
    }

    /// Stepper 的加減。基準取**當下讀到的值**而不是 `snapshot`，
    /// **也不是還沒提交的草稿**。
    ///
    /// 設定視窗開著的時候 CLI 也能改值（`findmouse config set rest.duration 20`）。
    /// 拿畫面上那個還沒重讀的舊值加一，送出去的是「舊值 ± 一格」，
    /// 等於把 CLI 的改動默默蓋掉——而使用者只是按了一下加號。
    ///
    /// 數值欄可以打字之後，「按加號時欄位裡有沒提交的草稿」變成真的會發生。
    /// 仍然以存著的值為基準，兩個理由：草稿可能是 `abc`（`abc + 1` 沒有意義，
    /// 以草稿為基準就得再訂一條「解不開時怎麼辦」的例外），而解得開的那些
    /// 要先 parse，那是 `SettingsUseCase` 的事（spec 第 9 節）。
    /// 寫入成功會清掉草稿，所以按完加號欄位顯示的是新值，不會殘留。
    public func step(_ key: String, by delta: Double) {
        guard let settings = settings(),
              case .number(let current)? = try? settings.value(key) else { return }
        submit(key, number: current + delta)
    }

    /// Toggle 的反轉。基準同樣取當下讀到的值，理由同 `step`。
    public func toggle(_ key: String) {
        guard let settings = settings(),
              case .flag(let current)? = try? settings.value(key) else { return }
        submit(key, current ? "false" : "true")
    }

    /// 下拉選單選了一套 pack。
    ///
    /// **不寫 `pack.id`。** 只寫設定不會換 pack——`pack.id` 的持久化是
    /// `AppDelegate.performSwap` 的副作用，反過來寫不會觸發抽換，
    /// 使用者會看到「選了新 pack、貓還是舊的，重開才變」。
    public func choosePack(_ id: String) {
        guard id != snapshot.currentPackID else { return }
        // 換 pack 可能要等貓退場（spec 第 6.5 節），那時 `currentPackID()` 還是舊的。
        // 不記下請求的話，下拉選單會在使用者眼前彈回他剛剛選掉的那一套。
        snapshot.pendingPackID = id
        usePack(id)
    }

    /// 換 pack 這件事結束了——**成功與失敗都算**。
    ///
    /// 失敗時 `currentPackID()` 還是舊的，下拉選單跟著彈回去：那正是
    /// 「這套換不過去」的訊號（詳細原因在選單列的降級提示裡）。
    public func packSwapConcluded() {
        snapshot.pendingPackID = nil
        reload()
    }

    static func message(for error: SettingsError) -> String {
        switch error {
        case .unknownKey(let key):
            return "沒有這個設定：\(key)"
        case .invalidValue(_, let value, let expected):
            return "「\(value)」不合法，要的是 \(expected)"
        case .outOfRange(_, let value, let range):
            return "\(SettingsUseCase.render(.number(value))) 超出範圍 "
                + SettingsForm.text(for: .number(range))
        }
    }
}
