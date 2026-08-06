import CoreGraphics
import FindMouseCore
import FindMouseDomain
import Foundation
import Testing

/// 記憶體版的設定儲存。
///
/// 直接存 `BehaviorConfig`（而不是模擬 UserDefaults 的鍵值表）是刻意的：
/// 「鍵被移除」這件事在 `BehaviorConfig` 裡就是那兩個 override 為 nil，
/// 而 `SettingsGateway` 已經有 M2 的測試釘住「nil → 移除鍵」的往返。
private final class StubSettingsStore: SettingsStorePort, @unchecked Sendable {
    private var stored = BehaviorConfig()
    private var strings: [String: String] = [:]

    var config: BehaviorConfig { stored }
    func save(_ config: BehaviorConfig) { stored = config }
    func string(forKey key: String) -> String? { strings[key] }

    func setString(_ value: String?, forKey key: String) {
        if let value { strings[key] = value } else { strings.removeValue(forKey: key) }
    }
}

/// spec 第 9 節那張表的**獨立抄本**。
///
/// 為什麼不從 `SettingsUseCase.registry` 推導：那樣測試會跟著實作一起錯。
/// 把範圍改成 40...10000 之後，「界內／界外」若都由註冊表算出來就永遠通過。
private let specRanges: [(key: String, min: Double, max: Double)] = [
    ("cat.scale", 0.5, 2.0),
    ("rest.duration", 1, 120),
    ("sleep.duration", 1, 60),
    ("rehunt.threshold", 40, 1000),
    ("wake.threshold", 0, 3000),
    ("cat.speed", 200, 3000),
    ("cat.turnRate", 90, 1800),
    ("arrive.radius", 20, 400),
    ("spotlight.dimOpacity", 0, 0.95),
    ("spotlight.margin", 0, 200),
    ("spotlight.feather", 0.2, 0.95),
    ("teaser.stalkRange", 80, 800),
    ("teaser.stalkTimeout", 0.5, 20),
    ("teaser.pounceTriggerSpeed", 50, 3000),
    ("teaser.pounceSpeed", 500, 6000),
    ("teaser.hitRadius", 10, 300),
    ("teaser.retreatDistance", 30, 800),
]

/// 同樣是 spec 第 9 節的抄本：23 個 key，一個都不能漏。
private let specKeys: [String] = specRanges.map(\.key) + [
    "pack.id", "hotkey.summon", "hotkey.teaser",
    "spotlight.enabled", "spotlight.trigger", "window.level",
]

private func makeUseCase(logicalHeight: CGFloat = 100) -> SettingsUseCase {
    SettingsUseCase(store: StubSettingsStore(),
                    catalog: StubCatalog(logicalHeight: logicalHeight))
}

private func settingsError(_ body: () throws -> Void) -> SettingsError? {
    do { try body(); return nil } catch let error as SettingsError { return error }
    catch { return nil }
}

/// spec 第 9 節的每一條範圍都要有「剛好在界內」與「剛好在界外」。
/// 只測中間值的話，把 40...1000 寫成 40...100 也不會紅。
@Test func rangesRejectJustOutsideAndAcceptJustInside() throws {
    let delta = 0.001
    for row in specRanges {
        let inside = makeUseCase()
        #expect(throws: Never.self, "\(row.key) 的下界 \(row.min) 必須被接受") {
            try inside.set(row.key, to: String(row.min))
        }
        #expect(throws: Never.self, "\(row.key) 的上界 \(row.max) 必須被接受") {
            try inside.set(row.key, to: String(row.max))
        }

        let low = settingsError { try makeUseCase().set(row.key, to: String(row.min - delta)) }
        #expect(low == .outOfRange(key: row.key, value: row.min - delta,
                                   range: row.min...row.max),
                "\(row.key) 低於下界必須拒絕，實際：\(String(describing: low))")

        let high = settingsError { try makeUseCase().set(row.key, to: String(row.max + delta)) }
        #expect(high == .outOfRange(key: row.key, value: row.max + delta,
                                    range: row.min...row.max),
                "\(row.key) 高於上界必須拒絕，實際：\(String(describing: high))")
    }
}

/// 拒絕就是拒絕，不是 clamp——回錯誤而且值沒有被改動。
@Test func outOfRangeValueIsRejectedAndNothingIsWritten() throws {
    let settings = makeUseCase()
    try settings.set("rest.duration", to: "42")

    let error = settingsError { try settings.set("rest.duration", to: "999999") }
    #expect(error == .outOfRange(key: "rest.duration", value: 999_999, range: 1...120))
    #expect(try settings.get("rest.duration") == "42",
            "被拒絕的 set 不得留下任何痕跡；clamp 成 120 也算改動")
}

@Test func unknownKeyReportsConfigKeyUnknown() {
    let settings = makeUseCase()
    #expect(settingsError { _ = try settings.get("cat.velocity") } == .unknownKey("cat.velocity"))
    #expect(settingsError { try settings.set("cat.velocity", to: "1") } == .unknownKey("cat.velocity"))
    #expect(settingsError { try settings.reset("cat.velocity") } == .unknownKey("cat.velocity"))
}

/// 型別不對 → `invalidValue`，不是 `outOfRange`。
/// 「我打錯字」與「我超出範圍」對腳本的意義不同。
@Test func nonNumericValueReportsInvalidArgument() {
    let settings = makeUseCase()
    #expect(settingsError { try settings.set("rest.duration", to: "abc") }
            == .invalidValue(key: "rest.duration", value: "abc", expected: "數字"))
    #expect(settingsError { try settings.set("spotlight.enabled", to: "maybe") }
            == .invalidValue(key: "spotlight.enabled", value: "maybe", expected: "true 或 false"))
    // "nan" 解得出 Double 卻不是有效設定值，同樣算格式錯
    #expect(settingsError { try settings.set("cat.speed", to: "nan") }
            == .invalidValue(key: "cat.speed", value: "nan", expected: "數字"))
}

/// spec 第 8.3 節：`config reset` 是必要功能而非裝飾。
/// `wake.threshold` 的預設是 3× `rehunt.threshold`，設過就固定，
/// reset 之後必須重新跟著連動——所以 reset 是移除鍵，不是寫入當下算出來的數字。
@Test func resetRestoresTheDerivedDefaultNotAFixedNumber() throws {
    let settings = makeUseCase()

    try settings.set("rehunt.threshold", to: "200")
    #expect(try settings.get("wake.threshold") == "600", "未設定時應為 3× rehunt.threshold")

    try settings.set("wake.threshold", to: "500")
    try settings.set("rehunt.threshold", to: "300")
    #expect(try settings.get("wake.threshold") == "500", "明確設過就固定，不再連動")

    try settings.reset("wake.threshold")
    #expect(try settings.get("wake.threshold") == "900", "reset 後應立刻回到 3× 當下的 rehunt")

    try settings.set("rehunt.threshold", to: "400")
    #expect(try settings.get("wake.threshold") == "1200", "reset 後必須恢復連動而不是停在 900")
}

/// `arrive.radius` 的衍生預設是 0.8× 實際體高，同樣要能 reset 回連動。
@Test func resetRestoresTheArriveRadiusDerivedFromPackHeight() throws {
    let settings = makeUseCase(logicalHeight: 100)
    #expect(try settings.get("arrive.radius") == "80", "0.8 × 100 × cat.scale 1.0")

    try settings.set("arrive.radius", to: "120")
    try settings.set("cat.scale", to: "2")
    #expect(try settings.get("arrive.radius") == "120", "設過就固定")

    try settings.reset("arrive.radius")
    #expect(try settings.get("arrive.radius") == "160", "0.8 × 100 × cat.scale 2.0")
}

/// M1 完成報告第 5 項：`wake.threshold` 設 0 的語意與直覺相反
/// （0 ＝ 任何移動都叫醒，不是停用喚醒）。那是文件問題，不是驗證問題——0 必須被接受。
@Test func zeroIsAValidWakeThreshold() throws {
    let settings = makeUseCase()
    try settings.set("wake.threshold", to: "0")
    #expect(try settings.get("wake.threshold") == "0")
}

/// 23 個 key 都要回得出值，一個都不能漏——
/// 漏掉的那個在 CLI 上是「這個設定不存在」，而不是任何錯誤訊息。
@Test func getReturnsEveryDeclaredKey() throws {
    #expect(specKeys.count == 23, "spec 第 9 節共 23 項")
    #expect(SettingsUseCase.declaredKeys == specKeys.sorted(),
            "註冊表必須與 spec 第 9 節的清單逐字相同")

    let settings = makeUseCase()
    for key in specKeys {
        let value = try settings.get(key)
        #expect(!value.isEmpty, "\(key) 必須回得出值")
    }
    #expect(settings.getAll().map(\.key) == specKeys.sorted())
}

/// 選項型的 key 只吃列舉裡的值，打錯字算格式錯不算超範圍。
@Test func choiceKeysAcceptOnlyDeclaredOptions() throws {
    let settings = makeUseCase()
    try settings.set("spotlight.trigger", to: "everyHunt")
    #expect(try settings.get("spotlight.trigger") == "everyHunt")
    #expect(settingsError { try settings.set("spotlight.trigger", to: "always") }
            == .invalidValue(key: "spotlight.trigger", value: "always",
                             expected: "onSummonOnly | everyHunt"))

    try settings.set("window.level", to: "screenSaver")
    #expect(try settings.get("window.level") == "screenSaver")
    #expect(settingsError { try settings.set("window.level", to: "normal") }
            == .invalidValue(key: "window.level", value: "normal",
                             expected: "overlay | screenSaver | floating"))
}

/// 4 個不進 Domain 的字串 key 一樣要能存、能讀、能 reset 回預設。
@Test func externalStringKeysRoundTripAndReset() throws {
    let settings = makeUseCase()
    let before = try settings.get("pack.id")

    try settings.set("pack.id", to: "fluffy-orange")
    try settings.set("hotkey.summon", to: "⌃⌘F")
    #expect(try settings.get("pack.id") == "fluffy-orange")
    #expect(try settings.get("hotkey.summon") == "⌃⌘F")
    // hotkey.* 仍然只要求非空
    #expect(settingsError { try settings.set("hotkey.summon", to: "  ") }
            == .invalidValue(key: "hotkey.summon", value: "  ", expected: "非空字串"))

    try settings.reset("pack.id")
    #expect(try settings.get("pack.id") == before, "reset 後回到內建 pack")
}

/// `pack.id` 的字元集要與 `PackValidator.isValidID` 同一條規則。
///
/// **這是安全性守衛，不是格式潔癖。** M4 的 `pack use <id>` 會拿它當路徑組件，
/// 不驗的話 `config set pack.id ../../../etc` 今天就會寫進 UserDefaults，
/// 而它變成路徑穿越的那一天離設定被寫下的那一天很遠，沒有人會把兩件事聯想在一起。
///
/// 拒絕清單裡的每一項都是**具體的攻擊或具體的比對陷阱**，不是隨機的壞字串：
/// 路徑穿越、絕對路徑、路徑分隔、NUL 截斷、Unicode 正規化（NFC 對 NFD 在 Swift
/// 的字串相等下會比成相等，但在檔案系統上是兩個名字）。
@Test func packIDRejectsAnythingThatCouldBecomeAPath() throws {
    let settings = makeUseCase()

    for bad in ["../../../etc", "/absolute", "a/b", "a\\b", "with space",
                "UPPER", "under_score", "dot.dot", "", "  ",
                "café", "٣", "pack\u{0}id"] {
        #expect(settingsError { try settings.set("pack.id", to: bad) }
                == .invalidValue(key: "pack.id", value: bad, expected: "只能是 a-z、0-9、-"),
                "「\(bad)」應該被拒絕")
    }

    // 合法的照樣通過，而且沒有被改寫
    for good in ["test-blocks", "fluffy-orange", "cat2", "a", "0"] {
        try settings.set("pack.id", to: good)
        #expect(try settings.get("pack.id") == good)
    }
}

/// `config reset --all` 要把兩類 key 一起清掉。
@Test func resetAllClearsBothDomainAndExternalKeys() throws {
    let settings = makeUseCase()
    let pristine = settings.getAll()

    try settings.set("cat.speed", to: "1500")
    try settings.set("wake.threshold", to: "10")
    try settings.set("window.level", to: "floating")
    #expect(settings.getAll() != pristine)

    settings.resetAll()
    #expect(settings.getAll() == pristine, "reset --all 之後必須與全新狀態逐項相同")
}

/// bool 接受多種拼法，但 `get` 一律回正規形式。
///
/// spec 第 9 節只寫「bool」，接受 `1`／`yes`／`on` 是刻意放寬的——
/// CLI 的使用者（含 AI）不該因為打 `1` 而失敗。但**放寬輸入不等於放寬輸出**：
/// `get` 若把使用者原本打的字原樣回傳，同一個設定就會有八種表示法，
/// 腳本拿它做比對就會時對時錯。這條測試把「刻意的放寬」與「正規化的輸出」
/// 兩件事一起釘住，否則兩者在程式碼裡分不出是設計還是意外。
@Test func booleanAcceptsSeveralSpellingsButAlwaysReadsBackCanonical() throws {
    for spelling in ["true", "TRUE", "1", "yes", "On"] {
        let settings = makeUseCase()
        try settings.set("spotlight.enabled", to: spelling)
        #expect(try settings.get("spotlight.enabled") == "true",
                "\(spelling) 應該正規化成 true")
    }
    for spelling in ["false", "FALSE", "0", "no", "Off"] {
        let settings = makeUseCase()
        try settings.set("spotlight.enabled", to: spelling)
        #expect(try settings.get("spotlight.enabled") == "false",
                "\(spelling) 應該正規化成 false")
    }
    #expect(settingsError { try makeUseCase().set("spotlight.enabled", to: "maybe") }
            != nil, "看不懂的字仍要拒絕，放寬不是照單全收")
}

/// 整數印成 `160` 而不是 `160.0`，而且印出來的東西餵回 `set` 要解得回來。
///
/// 後半是重點：輸出格式若與輸入格式不相容，
/// 「讀出全部設定 → 改一項 → 寫回去」這個最常見的腳本模式會在其餘每一項上失敗。
@Test func numbersRenderTidilyAndSurviveARoundTrip() throws {
    let settings = makeUseCase()
    try settings.set("rehunt.threshold", to: "160")
    #expect(try settings.get("rehunt.threshold") == "160", "不該印成 160.0")
    try settings.set("spotlight.dimOpacity", to: "0.75")
    #expect(try settings.get("spotlight.dimOpacity") == "0.75")

    // 把每一個 key 讀出來再原樣寫回去，全部都要成功
    for entry in settings.getAll() {
        #expect(throws: Never.self, "\(entry.key) 的輸出 \(entry.value) 餵不回 set") {
            try settings.set(entry.key, to: entry.value)
        }
    }
}

/// 衍生預設也必須落在自己宣告的範圍內。
///
/// `arrive.radius` 未設定時是 0.8 × 體高 × 縮放。`PackValidator` 允許體高 24–400、
/// `cat.scale` 允許 0.5–2.0，所以衍生值的跨度是 9.6–640，而 key 的範圍是 20–400。
/// 不夾的話，極端組合下 `config get` 會回一個 `config set` 拒收的值——
/// 「讀出來的值餵回去一定被接受」那個保證就破了，而破的時候不會有任何訊號。
///
/// （`wake.threshold` 沒有這個問題：3 × rehunt 的跨度是 120–3000，而它的範圍是
/// 0–3000，剛好包得住。那是算術上的巧合，不是設計，所以這裡一併釘住。）
@Test func derivedDefaultsStayInsideTheirOwnRange() throws {
    for (height, scale) in [(24.0, "0.5"), (24.0, "2"), (400.0, "0.5"),
                            (400.0, "2"), (96.0, "1")] {
        let settings = makeUseCase(logicalHeight: CGFloat(height))
        try settings.set("cat.scale", to: scale)

        for key in ["arrive.radius", "wake.threshold"] {
            let value = try settings.get(key)
            // 讀出來的值一定要餵得回去——這就是那個保證本身
            try settings.set(key, to: value)
            #expect(try settings.get(key) == value,
                    "體高 \(height) × 縮放 \(scale) 的 \(key) 衍生預設 \(value) 不被 set 接受")
        }
    }
}
