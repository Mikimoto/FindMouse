import CoreGraphics
import Foundation
import FindMouseDomain

/// 出廠預設的內建 pack。mycat 是**產品本身**——test-blocks 是開發用的色塊，
/// 讓陌生人裝完看到方塊等於沒有交付這個 App（0.2.0 就是這樣出去的）。
///
/// 它是一個常數而不是兩份字面值，理由是後者踩過：`AppDelegate` 的載入失敗
/// 退路與這裡的 `defaultValue` 各寫一份 "mycat"，靠註解互相提醒對齊。改壞
/// App 那一份的話，`SettingsUseCase` 的測試照樣綠（它讀的是 registry）、
/// release.sh 的守衛照樣綠（它 sed 的是這個檔）、e2e 照樣綠（它在啟動前就把
/// `pack.id` 寫死），而全新安裝的使用者看到的是色塊——沒有任何一層會紅。
public enum PackDefaults {
    public static let factory = "mycat"
}

/// 一個設定項的型別。spec 第 9 節的「範圍」欄位在這裡變成可執行的東西。
public enum SettingKind: Sendable, Equatable {
    case number(ClosedRange<Double>)
    case boolean
    /// 合法值的完整列舉（`spotlight.trigger`、`window.level`）
    case choice([String])
    /// 快捷鍵字串：`HotkeySpec` 解得開的那些（`hotkey.summon`、`hotkey.teaser`）。
    ///
    /// M3 時這兩個 key 是「不驗內容、只要求非空」的，因為改了要重啟才生效，
    /// 錯的值頂多下次啟動時沒有快捷鍵。M4 Task 8 加上熱更新之後那變成地雷：
    /// `config set hotkey.summon F` 會寫入成功、重新註冊時解不出 spec，
    /// 使用者的快捷鍵**當場靜默消失**，而他打的那個值還存在設定裡，重啟也救不回來。
    case hotkey
    /// pack 目錄名：`[a-z0-9-]+`（spec 第 6.4 節）。
    ///
    /// 這裡要驗，是因為 M4 的 `pack use <id>` 會拿它當**路徑組件**——
    /// 不驗的話 `config set pack.id ../../../etc` 現在就會寫進去，
    /// 而它變成路徑穿越的那一天離設定被寫下的那一天很遠，沒有人會聯想。
    /// 規則與 `PackValidator.isValidID` 同一條，只是那邊驗 manifest、這邊驗設定。
    case packID
}

/// 已解析（但還沒驗範圍）的值。
public enum SettingValue: Sendable, Equatable {
    case number(Double)
    case flag(Bool)
    case text(String)
}

/// 設定操作的失敗。
///
/// **這裡刻意不用 `FindMouseWire` 的錯誤碼。** Core 只能依賴 Domain
/// （見 `ArchitectureBoundaryTests` 的允許清單），Wire 是對外契約屬外層。
/// 由 Adapters 的 `RequestRouter` 把這三個 case 轉成
/// `CONFIG_KEY_UNKNOWN` / `INVALID_ARGUMENT` / `CONFIG_VALUE_OUT_OF_RANGE`。
public enum SettingsError: Error, Sendable, Equatable {
    /// 註冊表裡沒有這個 key
    case unknownKey(String)
    /// 格式不對（`rest.duration` 給 `"abc"`）——與 `outOfRange` 是兩件事：
    /// 前者是「我打錯字」，後者是「我超出範圍」，腳本要分得出來
    case invalidValue(key: String, value: String, expected: String)
    /// 格式對、值不對。**一律拒絕，不 clamp**（spec 第 9 節）
    case outOfRange(key: String, value: Double, range: ClosedRange<Double>)
}

/// 一個 key 的完整宣告：型別 ＋ 怎麼讀怎麼寫怎麼還原。
///
/// 三者綁在同一筆資料裡，是為了讓「新增一個設定」只需要動一處。
/// 拆成 `if key == …` 的讀／寫／驗證三段時，沒有任何機制保證三處涵蓋同一組 key。
public struct SettingSpec {
    public let key: String
    public let kind: SettingKind
    let storage: Storage

    /// 存在 `BehaviorConfig`（19 項）還是外層字串（4 項）。
    enum Storage {
        case domain(Domain)
        case external(defaultValue: String)
    }

    struct Domain {
        /// 第二個參數是 pack 的 logicalHeight，`arrive.radius` 的衍生預設要用
        let read: (BehaviorConfig, CGFloat) -> SettingValue
        let write: (SettingValue, inout BehaviorConfig) -> Void
        /// 還原成「未設定」。對兩個 override 而言是寫回 nil，衍生預設才會重新生效
        let clear: (inout BehaviorConfig) -> Void
    }
}

/// `get`／`getAll` 的一筆結果。
public struct SettingEntry: Sendable, Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

private let arriveRadiusBounds = Double(BehaviorConfig.arriveRadiusRange.lowerBound)...Double(BehaviorConfig.arriveRadiusRange.upperBound)

/// spec 第 9 節的 23 個設定項：讀、寫、值域驗證、還原。
///
/// CLI 與設定視窗走同一個實例，所以值域只有一份。
public final class SettingsUseCase {

    private let store: SettingsStorePort
    private let catalog: AnimationCatalogPort
    private let specs: [String: SettingSpec]

    public init(store: SettingsStorePort, catalog: AnimationCatalogPort) {
        self.store = store
        self.catalog = catalog
        self.specs = Dictionary(uniqueKeysWithValues: Self.registry.map { ($0.key, $0) })
    }

    /// 宣告過的全部 key，字典序。
    public static var declaredKeys: [String] { registry.map(\.key).sorted() }

    public func kind(of key: String) throws -> SettingKind {
        try spec(key).kind
    }

    public func get(_ key: String) throws -> String {
        let spec = try self.spec(key)
        return Self.render(currentValue(of: spec))
    }

    /// 當前值，**保留型別**。
    ///
    /// `get` 回字串是為了 CLI 與 wire；設定視窗要的是 `Bool` 與 `Double`，
    /// 讓它自己從 `"true"` 解回去，等於把 `render` 的規則抄第二份到 UI 裡
    /// ——而那份抄本在 `render` 改掉的那天不會有任何訊號。
    public func value(_ key: String) throws -> SettingValue {
        currentValue(of: try spec(key))
    }

    public func getAll() -> [SettingEntry] {
        Self.registry
            .sorted { $0.key < $1.key }
            .map { SettingEntry(key: $0.key, value: Self.render(currentValue(of: $0))) }
    }

    /// 驗證後寫入。**任何一條驗證不過就完全不寫**——拒絕不是 clamp。
    public func set(_ key: String, to raw: String) throws {
        let spec = try self.spec(key)
        let value = try Self.parse(raw, as: spec.kind, key: key)
        switch spec.storage {
        case .domain(let domain):
            var config = store.config
            domain.write(value, &config)
            store.save(config)
        case .external:
            guard case .text(let text) = value else { return }
            store.setString(text, forKey: key)
        }
    }

    /// 還原成未設定。對 `wake.threshold` 與 `arrive.radius` 而言，
    /// 這是把鍵移除讓衍生預設重新生效（spec 第 8.3 節），不是寫入當下算出來的數字。
    public func reset(_ key: String) throws {
        let spec = try self.spec(key)
        switch spec.storage {
        case .domain(let domain):
            var config = store.config
            domain.clear(&config)
            store.save(config)
        case .external:
            store.setString(nil, forKey: key)
        }
    }

    public func resetAll() {
        var config = store.config
        for spec in Self.registry {
            switch spec.storage {
            case .domain(let domain): domain.clear(&config)
            case .external: store.setString(nil, forKey: spec.key)
            }
        }
        store.save(config)
    }

    // MARK: - 內部

    private func spec(_ key: String) throws -> SettingSpec {
        guard let spec = specs[key] else { throw SettingsError.unknownKey(key) }
        return spec
    }

    private func currentValue(of spec: SettingSpec) -> SettingValue {
        switch spec.storage {
        case .domain(let domain):
            return domain.read(store.config, catalog.logicalHeight)
        case .external(let fallback):
            return .text(store.string(forKey: spec.key) ?? fallback)
        }
    }

    /// 不是 private：`SettingsForm` 印值域說明與錯誤訊息時用同一份數字格式。
    /// 各印各的話，同一個範圍在 CLI 會是 `40–1000`、在設定視窗會是 `40.0–1000.0`。
    static func render(_ value: SettingValue) -> String {
        switch value {
        case .number(let d):
            // 整數就印整數：CLI 讀 `160` 比 `160.0` 舒服，而且再餵回 set 也解得回來
            if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
            return String(d)
        case .flag(let b): return b ? "true" : "false"
        case .text(let s): return s
        }
    }

    /// 先判格式（`invalidValue`）再判範圍（`outOfRange`）。順序不能顛倒：
    /// `"abc"` 根本不是數字，談不上超不超出範圍。
    private static func parse(_ raw: String, as kind: SettingKind,
                              key: String) throws -> SettingValue {
        switch kind {
        case .number(let range):
            guard let d = Double(raw), d.isFinite else {
                throw SettingsError.invalidValue(key: key, value: raw, expected: "數字")
            }
            guard range.contains(d) else {
                throw SettingsError.outOfRange(key: key, value: d, range: range)
            }
            return .number(d)

        case .boolean:
            let lowered = raw.lowercased()
            if ["true", "1", "yes", "on"].contains(lowered) { return .flag(true) }
            if ["false", "0", "no", "off"].contains(lowered) { return .flag(false) }
            throw SettingsError.invalidValue(key: key, value: raw, expected: "true 或 false")

        case .choice(let allowed):
            guard allowed.contains(raw) else {
                throw SettingsError.invalidValue(key: key, value: raw,
                                                 expected: allowed.joined(separator: " | "))
            }
            return .text(raw)

        case .hotkey:
            guard let spec = HotkeySpec(raw) else {
                throw SettingsError.invalidValue(
                    key: key, value: raw,
                    expected: "修飾鍵（⌃⌥⇧⌘）加一個 A–Z 或 0–9，例如 \(HotkeySpec.defaultSummonText)")
            }
            // 存**正規化後**的字串而不是使用者打的那個：`⌘⌥F` 與 `⌥⌘F` 是同一個
            // 快捷鍵，兩種寫法都存得進去的話，設定視窗顯示的與 `config get` 回的
            // 會是同一個鍵的兩個樣子。與 `set spotlight.enabled yes` 回 `true`
            // 同一個原則——回讀到的是「存進去的東西」。
            return .text(spec.displayString)

        case .packID:
            // 與 PackValidator.isValidID 同一條規則，理由也同一個：ASCII 的
            // `[a-z0-9-]`，不用 Character.isLowercase／isNumber（那些是 Unicode
            // 全域屬性，會放行 ünïcode、٣、Ⅷ，而 id 要拿去比對磁碟上的目錄名，
            // Swift 的字串相等是正規化等價，NFC 對 NFD 會比成相等）。
            let ok = !raw.isEmpty && raw.allSatisfy {
                ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
            }
            guard ok else {
                throw SettingsError.invalidValue(key: key, value: raw,
                                                 expected: "只能是 a-z、0-9、-")
            }
            return .text(raw)
        }
    }

    // MARK: - 註冊表（spec 第 9 節的 23 列）

    static var registry: [SettingSpec] {
        [
            external("pack.id", .packID, defaultValue: PackDefaults.factory),
            cg("cat.scale", 0.5...2.0, \.catScale),
            seconds("rest.duration", 1...120, \.restDuration),
            seconds("sleep.duration", 1...60, \.sleepDuration),
            flag("spotlight.enabled", \.spotlightEnabled),
            SettingSpec(
                key: "spotlight.trigger",
                kind: .choice(SpotlightTrigger.allCases.map(\.rawValue)),
                storage: .domain(.init(
                    read: { c, _ in .text(c.spotlightTrigger.rawValue) },
                    write: { v, c in
                        if case .text(let s) = v, let t = SpotlightTrigger(rawValue: s) {
                            c.spotlightTrigger = t
                        }
                    },
                    clear: { c in c.spotlightTrigger = BehaviorConfig().spotlightTrigger }))),
            external("hotkey.summon", .hotkey, defaultValue: HotkeySpec.defaultSummonText),
            external("hotkey.teaser", .hotkey, defaultValue: HotkeySpec.defaultTeaserText),
            cg("rehunt.threshold", 40...1000, \.rehuntThreshold),
            SettingSpec(
                key: "wake.threshold",
                // 0 是合法值：它的語意是「任何移動都叫醒」，不是「停用喚醒」
                kind: .number(0...3000),
                storage: .domain(.init(
                    read: { c, _ in .number(Double(c.wakeThreshold)) },
                    write: { v, c in
                        if case .number(let d) = v { c.wakeThresholdOverride = CGFloat(d) }
                    },
                    clear: { c in c.wakeThresholdOverride = nil }))),
            cg("cat.speed", 200...3000, \.catSpeed),
            cg("cat.turnRate", 90...1800, \.catTurnRate),
            SettingSpec(
                key: "arrive.radius",
                // 範圍取自 Domain：衍生預設也夾在同一個範圍內，只能有一份定義
                kind: .number(arriveRadiusBounds),
                storage: .domain(.init(
                    read: { c, h in .number(Double(c.arriveRadius(logicalHeight: h))) },
                    write: { v, c in
                        if case .number(let d) = v { c.arriveRadiusOverride = CGFloat(d) }
                    },
                    clear: { c in c.arriveRadiusOverride = nil }))),
            cg("spotlight.dimOpacity", 0...0.95, \.spotlightDimOpacity),
            cg("spotlight.margin", 0...200, \.spotlightMargin),
            cg("spotlight.feather", 0.2...0.95, \.spotlightFeather),
            cg("teaser.stalkRange", 80...800, \.teaserStalkRange),
            seconds("teaser.stalkTimeout", 0.5...20, \.teaserStalkTimeout),
            cg("teaser.pounceTriggerSpeed", 50...3000, \.teaserPounceTriggerSpeed),
            cg("teaser.pounceSpeed", 500...6000, \.teaserPounceSpeed),
            cg("teaser.hitRadius", 10...300, \.teaserHitRadius),
            cg("teaser.retreatDistance", 30...800, \.teaserRetreatDistance),
            external("window.level", .choice(["overlay", "screenSaver", "floating"]),
                     defaultValue: "overlay"),
        ]
    }

    private static func cg(_ key: String, _ range: ClosedRange<Double>,
                           _ path: WritableKeyPath<BehaviorConfig, CGFloat>) -> SettingSpec {
        SettingSpec(key: key, kind: .number(range), storage: .domain(.init(
            read: { c, _ in .number(Double(c[keyPath: path])) },
            write: { v, c in if case .number(let d) = v { c[keyPath: path] = CGFloat(d) } },
            clear: { c in c[keyPath: path] = BehaviorConfig()[keyPath: path] })))
    }

    private static func seconds(_ key: String, _ range: ClosedRange<Double>,
                                _ path: WritableKeyPath<BehaviorConfig, TimeInterval>) -> SettingSpec {
        SettingSpec(key: key, kind: .number(range), storage: .domain(.init(
            read: { c, _ in .number(c[keyPath: path]) },
            write: { v, c in if case .number(let d) = v { c[keyPath: path] = d } },
            clear: { c in c[keyPath: path] = BehaviorConfig()[keyPath: path] })))
    }

    private static func flag(_ key: String,
                             _ path: WritableKeyPath<BehaviorConfig, Bool>) -> SettingSpec {
        SettingSpec(key: key, kind: .boolean, storage: .domain(.init(
            read: { c, _ in .flag(c[keyPath: path]) },
            write: { v, c in if case .flag(let b) = v { c[keyPath: path] = b } },
            clear: { c in c[keyPath: path] = BehaviorConfig()[keyPath: path] })))
    }

    private static func external(_ key: String, _ kind: SettingKind,
                                 defaultValue: String) -> SettingSpec {
        SettingSpec(key: key, kind: kind, storage: .external(defaultValue: defaultValue))
    }
}
