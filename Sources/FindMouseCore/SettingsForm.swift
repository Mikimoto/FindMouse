// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

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
    ///
    /// 順序是註冊表的**宣告順序**，所以這裡讀 `registry` 而不是 `declaredKeys`。
    /// 後者的字典序會把逗貓棒那組排成「命中半徑 → 撲擊速度 → 撲擊觸發速度 →
    /// 後退距離 → 潛行距離 → 潛行逾時」——效果排在觸發它的原因前面，而作者在
    /// 註冊表裡寫下的是因果順序（潛行 → 撲擊 → 命中 → 後退）。
    /// `rowsWithinAGroupFollowTheRegistryNotTheAlphabet` 釘住它。
    ///
    /// **`declaredKeys` 不動**：它的字典序是 `config get` 列表的樣子，是另一回事。
    public static var advancedKeys: [String] {
        SettingsUseCase.registry.map(\.key).filter { !windowKeys.contains($0) }
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

    /// 進階視窗的一列。
    ///
    /// 進階視窗（`AdvancedSettingsRootView`）畫的就是這個。
    ///
    /// 舊的那份 `advancedEntries`（每列一行可複製的命令）還在，但**已經沒有 View
    /// 讀它**了——它與 `Snapshot.advanced` 一起收掉是下一個任務的事，不是忘了。
    ///
    /// 沒有 `range`：值域說明由 `text(for: kind)` 當場算，而 `kind` 就在同一個
    /// 結構裡。存一份衍生欄位只是多一個會與來源分岔的地方。
    public struct AdvancedRow: Sendable, Equatable {
        public let key: String
        public let presentation: AdvancedPresentation
        public let kind: SettingKind
        /// false 時那一列才顯示還原鍵
        public let isAtDefault: Bool
    }

    public struct AdvancedSection: Sendable, Equatable {
        public let group: AdvancedGroup
        public let rows: [AdvancedRow]
    }

    /// 依 `AdvancedGroup.allCases` 的順序分組——那個順序就是畫面順序。
    /// 組內順序見 `advancedKeys`（註冊表的宣告順序，`filter` 原樣保留它）。
    ///
    /// **沒有任何 key 用的分組不濾掉**，即使那會讓畫面多一個底下空無一物的標題。
    /// 曾經寫成濾掉，實測拿掉那一行整批測試全綠：分組來自靜態註冊表，呼叫端換掉
    /// store 或 catalog 都影響不到它，所以沒有人造得出空組，那一行是走不到、也
    /// 無法被證明有效的程式碼。守衛改放在 `advancedSectionsAreOrderedAndNonEmpty`
    /// ——它在註冊表長出沒人用的分組時會紅，而且說得出是哪一個。與
    /// `SliderSpec.decimals(of:)` 對指數形式的處置同一個判斷。
    ///
    /// **列先一次建好再分組**，不是每組各掃一遍 `advancedKeys`：後者會把
    /// `advancedKeys` 求值五次，而它每次都重建整份 `registry`（連同每個 spec 的
    /// closure，見 `presentation(of:)` 的註解）。省下來的是那四次重建與四輪
    /// 字典查詢；`isAtDefault` 兩種寫法都只跑每個 key 一次，因為舊版的分組條件
    /// 排在那兩個查詢**之前**就短路了。
    ///
    /// 三個 `guard` 是另一回事：key 來自註冊表，三個查詢都不會落空
    /// （`presentation` 的完整性另有 `everyAdvancedKeyHasPresentation` 守）。
    /// 真的落空時那一列會安靜消失，而 `advancedSectionsCoverExactlyTheAdvancedKeys`
    /// 會抓到——與 `advancedEntries` 同一個處理方式。
    public static func advancedSections(_ settings: SettingsUseCase) -> [AdvancedSection] {
        let rows = advancedKeys.compactMap { key -> AdvancedRow? in
            guard let presentation = settings.presentation(of: key),
                  let kind = try? settings.kind(of: key),
                  let isDefault = try? settings.isAtDefault(key) else { return nil }
            return AdvancedRow(key: key, presentation: presentation, kind: kind,
                               isAtDefault: isDefault)
        }
        return AdvancedGroup.allCases.map { group in
            AdvancedSection(group: group, rows: rows.filter { $0.presentation.group == group })
        }
    }

    /// 還原**只有**進階那 15 項。
    ///
    /// 刻意不呼叫 `SettingsUseCase.resetAll()`：那會連主視窗的 pack、快捷鍵與
    /// 聚光燈一起還原，而按鈕在進階視窗裡。CLI 的 `config reset --all` 語意不變。
    ///
    /// `try?`：key 全部來自 `advancedKeys`（推導自註冊表），而 `reset` 只在
    /// `spec(key)` 查不到時拋（`SettingsUseCase.reset`），所以拋不出來；
    /// 真的拋了也不該讓剩下的項目半途停下。
    public static func resetAdvanced(_ settings: SettingsUseCase) {
        for key in advancedKeys { try? settings.reset(key) }
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

/// 匯入／移除做完之後的結果。
///
/// **與 `PackLibraryUseCase` 的兩個 outcome 型別刻意不同。** 那兩個住 Adapters，
/// 而 Core 的 import 允許清單只有 `Foundation`／`CoreGraphics`／`FindMouseDomain`
/// （`ArchitectureBoundaryTests` 強制）；而且 Core 也不需要 wire 的錯誤碼——
/// 設定視窗只顯示訊息。翻譯由 App 那一層做。
public enum PackActionResult: Sendable, Equatable {
    case succeeded(id: String)
    /// 同 id 已存在。`prompt` 是給人看的問句，呼叫端要問過才重試。
    case needsConfirmation(id: String, prompt: String)
    case failed(message: String)
}

/// 等使用者回答的那個確認。**帶著來源**：按下「取代」時要用同一個來源重試，
/// 而使用者按鈕的當下已經沒有別的地方記得它是哪個檔案了。
public struct PendingPackImport: Sendable, Equatable {
    public let source: URL
    public let id: String
    public let prompt: String

    public init(source: URL, id: String, prompt: String) {
        self.source = source
        self.id = id
        self.prompt = prompt
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

    /// 已經請求換過去、但還沒真的換成功的那一套。
    ///
    /// **它只決定按鈕顯不顯示。** 真正擋下移除的是 `PackLibraryUseCase.remove` 的
    /// `swapTarget` 守衛——那一層問的是狀態機（`PackSwapUseCase.pendingID`），
    /// 不是這份快照。這裡存在的理由是使用者不該看到一個按下去只會拿到錯誤的按鈕。
    ///
    /// 值由 `noteSwapRequested(_:)` 設定，而**兩條入口都要記得呼叫它**：GUI 走
    /// `choosePack`（它自己標一次，這樣不接上 App 也測得到），CLI 走
    /// `AppDelegate.requestPackSwap`——後者是兩條路的匯流點。漏掉它的話，
    /// CLI 造出的空窗裡按鈕不會消失（按下去仍會被 use case 擋，但那是壞的可用性）。
    public let isPendingSwap: Bool

    /// 這一列該不該有移除按鈕。
    ///
    /// 內建拿不掉、正在用的拿不掉、已經請求換過去的也拿不掉。按鈕照顯示的話，
    /// 使用者按下去只會拿到一句本來可以用「不顯示按鈕」避免的錯誤。不合格的
    /// 那些**要**能拿掉——它們正是使用者要清的。
    ///
    /// 它由投影過的那三個欄位算出來，而「這個 id 到底能不能刪、刪掉的是哪一個
    /// 目錄」由 `PackLibraryUseCase.remove` 決定。
    ///
    /// 兩邊在哪些輸入上不一致、不一致的後果是什麼，這裡**刻意不列**——列過三個
    /// 版本，每一版都被一個新的反例推翻。最近一次是：目錄名與 manifest id 不符
    /// 時兩層其實**一致**（都認 manifest 的 id），只是一起指向錯的目錄，於是
    /// 「多給一個按鈕最多就是一句錯誤訊息」也跟著是假的。要知道某個情況會怎樣，
    /// 去讀 `remove`，或者跑一次。
    ///
    /// 用計算屬性而不是 init 參數：它完全由既有三個欄位決定，多一個參數
    /// 只是多一處可以填錯的地方。
    public var isRemovable: Bool { !isBuiltIn && !isCurrent && !isPendingSwap }

    public init(id: String, isBuiltIn: Bool, isUsable: Bool,
                isCurrent: Bool, problems: [String], isPendingSwap: Bool = false) {
        self.id = id
        self.isBuiltIn = isBuiltIn
        self.isUsable = isUsable
        self.isCurrent = isCurrent
        self.problems = problems
        self.isPendingSwap = isPendingSwap
    }

    /// - Parameter current: **實際跑著的** pack id，不是 `config get pack.id`。
    ///   兩者會不一致：啟動時想要的那套載不起來會退回內建（`AppDelegate`），
    ///   而設定裡那個壞掉的 id **不會被改寫**。拿設定當選取值的話，
    ///   下拉選單會顯示一套紅字、不可選、而且根本沒在跑的 pack。
    /// - Parameter pending: 已經請求換過去、但還沒換成功的那一套（`nil` 代表沒有）。
    ///   只影響 `isRemovable`——見它的註解。
    public static func choices(packs: [PackSummary], current: String,
                               pending: String? = nil) -> [PackChoice] {
        var rows = packs.map {
            PackChoice(id: $0.id, isBuiltIn: $0.isBuiltIn, isUsable: $0.isUsable,
                       isCurrent: $0.id == current, problems: $0.errors,
                       isPendingSwap: $0.id == pending)
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
        /// 上一次匯入／移除的結果，一句話。**一次性**：下一個動作開始時就清掉，
        /// 否則使用者會看到上一次的結果掛在那裡，分不出「這是剛剛那次的」
        /// 還是「這次也一樣」。
        public var packNotice: String?
        /// 非 nil 時設定視窗要彈確認框。
        public var packConfirmation: PendingPackImport?
        public var advanced: [SettingsForm.AdvancedEntry] = []
        public var advancedSections: [SettingsForm.AdvancedSection] = []

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
    /// 匯入一個來源。第二個參數是 force。
    ///
    /// **注入而不是自己呼叫 `PackLibraryUseCase`**：那個住 Adapters，而 Core
    /// 的 import 允許清單只有 Domain。與 `usePack` 是同一個模式。
    private let installPack: @MainActor (URL, Bool) -> PackActionResult
    /// 與 `removePack(_:)` 這個方法同名會遮蔽，所以欄位另取名。
    private let removePackAction: @MainActor (String) -> PackActionResult
    private let revealPacksDirectory: @MainActor () -> Void

    public private(set) var snapshot = Snapshot()

    /// - Parameter onChanged: 設定**真的改了**之後通知一次。與 `RequestRouter`
    ///   的同名參數走同一條路（App 收到後重裝快捷鍵並重建 presenter），
    ///   所以 CLI 改與視窗改的後續處理只有一份。失敗的寫入不呼叫它。
    public init(settings: @escaping @MainActor () -> SettingsUseCase?,
                packs: @escaping @MainActor () -> [PackSummary],
                currentPackID: @escaping @MainActor () -> String,
                usePack: @escaping @MainActor (String) -> Void,
                onChanged: @escaping @MainActor () -> Void,
                // 前兩個的預設值是**明確的失敗**而不是 no-op：漏接線時使用者看得到
                // 一句話，而不是按了沒反應。第三個做不到——它回 Void，沒有地方
                // 講話；它漏接線的後果是「按了 Finder 沒開」，而那由
                // `revealForwardsToTheInjectedAction` 釘住。
                // 給預設值本身是為了讓既有呼叫點與既有測試一個字都不用改。
                installPack: @escaping @MainActor (URL, Bool) -> PackActionResult
                    = { _, _ in .failed(message: "這個建置沒有接上匯入") },
                removePack: @escaping @MainActor (String) -> PackActionResult
                    = { _ in .failed(message: "這個建置沒有接上移除") },
                revealPacksDirectory: @escaping @MainActor () -> Void = {}) {
        self.settings = settings
        self.packs = packs
        self.currentPackID = currentPackID
        self.usePack = usePack
        self.onChanged = onChanged
        self.installPack = installPack
        self.removePackAction = removePack
        self.revealPacksDirectory = revealPacksDirectory
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
            snapshot.advancedSections = SettingsForm.advancedSections(settings)
        }
        snapshot.currentPackID = currentPackID()
        snapshot.packs = PackChoice.choices(packs: packs(), current: snapshot.currentPackID,
                                            pending: snapshot.pendingPackID)
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

    /// 還原一個 key。
    ///
    /// 草稿與紅字一併清掉——`reload()` **刻意不清**它們（見它的註解：重讀的觸發者
    /// 常常是別人，清掉會在使用者眼前重置他正在修的欄位）。但這一次的觸發者就是
    /// 使用者自己按的還原鍵，留著草稿的話欄位仍顯示他剛打的字、紅字仍指著一個
    /// 已經被還原掉的值，畫面與狀態分岔。
    ///
    /// **還原是一種變更，所以照樣通知 `onChanged`。** CLI 那條路已經先遇到這題
    /// 並留了字：`RequestRouter.configReset` 對 `reset` 與 `set` 各接一次，
    /// 註解寫「只接一條的話『改壞了想 reset 回來』會失效——而那正是使用者最需要它
    /// 當場生效的時刻」。兩條路走的是同一個 `AppDelegate.settingsDidChange()`，
    /// 這裡不接的話，同一個還原從 CLI 下去會生效、從 ↺ 按下去不會。
    ///
    /// 那一輪不會白白重裝快捷鍵：`AppDelegate` 用 `installedSummon`／
    /// `installedTeaser` 記住現在註冊著的那一組，spec 沒變就不動它。
    public func reset(_ key: String) {
        guard let settings = settings() else { return }
        // 這裡不能照抄 `resetAdvanced` 那個裸 `try?`：那支的 key 全部來自
        // `advancedKeys`，這支收的是任意字串。未知 key 讓 `reset` 拋錯之後，
        // 值沒有被還原，卻照樣清掉草稿、重讀、通知——三個副作用建立在一件
        // 沒發生的事情上。拋了就什麼都不做。
        guard (try? settings.reset(key)) != nil else { return }
        snapshot.drafts.removeValue(forKey: key)
        snapshot.errors.removeValue(forKey: key)
        reload()
        onChanged()
    }

    /// 還原進階那 15 項。範圍與按鈕所在的視窗一致，不碰主視窗那 8 項——
    /// 理由見 `SettingsForm.resetAdvanced`，通知的理由見 `reset(_:)`。
    ///
    /// `onChanged()` 整批只發一次，與 `RequestRouter` 對 `config reset --all`
    /// 的處置相同——它要的是「設定變了，重新套用一次」，不是逐項各來一輪。
    public func resetAdvanced() {
        guard let settings = settings() else { return }
        SettingsForm.resetAdvanced(settings)
        for key in SettingsForm.advancedKeys {
            snapshot.drafts.removeValue(forKey: key)
            snapshot.errors.removeValue(forKey: key)
        }
        reload()
        onChanged()
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
        noteSwapRequested(id)
        usePack(id)
    }

    /// 有人請求換 pack 了——**不一定是這個視窗**。
    ///
    /// CLI 的 `pack use` 走 `RequestRouter` → `AppDelegate.requestPackSwap`，
    /// 完全不經過這裡。少了這支的話，**CLI 發起的空窗裡按鈕不會消失**——而那個
    /// 空窗與 GUI 發起的一模一樣長。所以標記的入口要在兩條路的匯流點被呼叫一次。
    ///
    /// 幂等：GUI 那條會經過這裡兩次（`choosePack` 一次、`requestPackSwap` 一次）。
    public func noteSwapRequested(_ id: String) {
        snapshot.pendingPackID = id
        // 重標 rows：`isPendingSwap` 變了，那一列的移除按鈕要當場消失。
        //
        // 就地映射而不是重跑 `choices(packs:...)`：那要一份 `[PackSummary]`，而這裡
        // 只有已經投影過的 rows。重掃磁碟拿一份新的也不對——這一刻該變的只有
        // 「哪一列在等待」。
        snapshot.packs = snapshot.packs.map {
            PackChoice(id: $0.id, isBuiltIn: $0.isBuiltIn, isUsable: $0.isUsable,
                       isCurrent: $0.isCurrent, problems: $0.problems,
                       isPendingSwap: $0.id == id)
        }
    }

    /// 換 pack 這件事結束了——**成功與失敗都算**。
    ///
    /// 失敗時 `currentPackID()` 還是舊的，下拉選單跟著彈回去：那正是
    /// 「這套換不過去」的訊號（詳細原因在選單列的降級提示裡）。
    public func packSwapConcluded() {
        snapshot.pendingPackID = nil
        reload()
    }

    // MARK: - 匯入與移除（分發 C-2）

    /// 拖進來的東西。
    public func importPacks(from urls: [URL]) {
        guard let first = urls.first else { return }
        importPack(from: first)
        guard urls.count > 1 else { return }
        // 逐一匯入會連續彈好幾個確認框，而「裝了哪些、哪些失敗」在一行提示裡
        // 講不清楚。所以只收第一個，而且**明說**——安靜地丟掉另外幾個的話，
        // 使用者會以為它們都裝好了。
        let outcome = snapshot.packNotice.map { "（\($0)）" } ?? ""
        snapshot.packNotice = "一次只能裝一套，只收了 \(first.lastPathComponent)。" + outcome
    }

    public func importPack(from url: URL) {
        snapshot.packNotice = nil
        snapshot.packConfirmation = nil
        apply(installPack(url, false), source: url)
    }

    /// 使用者按了「取代」。用**同一個來源**重試，帶 force。
    public func confirmPendingImport() {
        guard let pending = snapshot.packConfirmation else { return }
        snapshot.packConfirmation = nil
        apply(installPack(pending.source, true), source: pending.source)
    }

    /// 取消。**問句一定要收掉**，不然下一次拖放會看到上一次的。
    public func cancelPendingImport() {
        snapshot.packConfirmation = nil
    }

    public func removePack(_ id: String) {
        snapshot.packNotice = nil
        snapshot.packConfirmation = nil
        // 這裡**不再**自己擋「正在切換過去」的那一套。曾經擋過，理由是
        // 「use case 看到的 currentPackID 還是舊的」——那句話在 `remove` 收下
        // `swapTarget` 之後就不成立了，而留著的話同一句話會有兩份、各自用一份
        // 可能不同步的狀態（這裡是快照，那裡是狀態機）判斷。
        switch removePackAction(id) {
        case let .succeeded(id):
            reload()
            snapshot.packNotice = "已移除「\(id)」。"
        case let .failed(message):
            snapshot.packNotice = message
        case .needsConfirmation:
            // 型別上到得了、語意上到不了：移除沒有「要不要覆蓋」這回事。
            // 不留一句捏造的訊息——什麼都不顯示比顯示一句假話好。
            break
        }
    }

    /// 在 Finder 裡打開使用者的 pack 目錄。
    public func revealPacks() { revealPacksDirectory() }

    private func apply(_ result: PackActionResult, source: URL) {
        switch result {
        case let .succeeded(id):
            // 裝完要重讀，否則新的那套要等下一次 reload 才看得到，
            // 而使用者的感受是「拖進去沒反應」。
            reload()
            snapshot.packNotice = "已裝好「\(id)」。"
        case let .needsConfirmation(id, prompt):
            snapshot.packConfirmation = PendingPackImport(source: source, id: id, prompt: prompt)
        case let .failed(message):
            snapshot.packNotice = message
        }
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
