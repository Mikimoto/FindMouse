import CoreGraphics
import Foundation
import Testing
@testable import FindMouseAdapters
import FindMouseCore
import FindMouseDomain
import FindMouseWire

/// 只提供 `AnimationCatalogPort` 需要的三件事。真 pack 在這裡用不上：
/// `SpritePackRepository.builtInPacksDirectory()` 走 `Bundle.module`，
/// 而那個 bundle 是**每個 target 各一份**——從測試 target 拿到的是測試自己的。
private final class RouterCatalog: AnimationCatalogPort, @unchecked Sendable {
    let logicalHeight: CGFloat = 96
    let capabilities: PackCapabilities

    init(teaser: Bool = true) {
        let available = teaser
            ? Set(CatAction.allCases)
            : Set(CatAction.allCases).subtracting([.pounce])
        capabilities = PackCapabilities(
            available: available, teaserAvailable: teaser,
            restPool: CatAction.restPool.intersection(available).sorted { $0.rawValue < $1.rawValue })
    }

    func clip(for action: CatAction) -> AnimationClip? {
        AnimationClip(action: action, frames: 2, fps: 10, loops: false)
    }
}

/// 一個給測試用的可變盒子。`Fixture` 是 struct，closure 要往外寫就需要它。
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private struct Fixture {
    let router: RequestRouter
    let control: ControlUseCase
    let settings: SettingsUseCase
    /// `pack.use` 交給 App 的 id。沒交出去就還是 nil。
    let swapped: Box<String?>

    /// 三套 pack，刻意讓每個屬性都與別的屬性**不同調**。
    ///
    /// 若清單裡「內建＝可用＝有 teaser」全部一致，那麼把 `builtIn` 接成
    /// `usable`、`teaserAvailable` 接成 `usable` 這種接錯欄位的錯誤就完全
    /// 看不出來——三個布林在測試裡是同一個布林。所以：內建那套是好的、
    /// 使用者那套也是好的但缺 teaser、壞掉那套是使用者的但 teaser 動作齊全。
    /// errors 與 warnings 同理，兩套 pack 各只有其中一邊非空，對調就會現形。
    static let packs = [
        PackSummary(id: "test-blocks", isBuiltIn: true, logicalHeight: 96,
                    errors: [], warnings: [], teaserAvailable: true),
        PackSummary(id: "test-blocks-tall", isBuiltIn: false, logicalHeight: 240,
                    errors: [], warnings: ["缺少逗貓棒動作（該模式不可用）：pounce"],
                    teaserAvailable: false),
        PackSummary(id: "broken", isBuiltIn: false, logicalHeight: 96,
                    errors: ["缺少必要動作：sit"], warnings: [], teaserAvailable: true),
    ]

    init(teaser: Bool = true) {
        let catalog = RouterCatalog(teaser: teaser)
        let store = SettingsGateway(
            defaults: UserDefaults(suiteName: "com.findmouse.router.\(UUID().uuidString)")!)
        control = ControlUseCase(catalog: catalog)
        settings = SettingsUseCase(store: store, catalog: catalog)
        // 先接成區域變數再交給 closure：struct 的所有屬性都填完之前碰不到 self
        let swapped = Box<String?>(nil)
        self.swapped = swapped
        router = RequestRouter(control: control, settings: settings, status: Fixture.status,
                               packs: { Fixture.packs },
                               usePack: { id in swapped.value = id })
    }

    static func status() -> StatusPayload {
        StatusPayload(
            appVersion: "1.2.3", visible: true, phase: "resting", phaseElapsed: 1,
            teaser: .init(enabled: false, available: true),
            cat: .init(position: .init(x: 1, y: 2), facing: "left",
                       action: "sitIdle", frame: 0, frameCount: 2),
            cursor: .init(x: 3, y: 4), distance: 5,
            spotlight: .init(active: false, radius: 0, opacity: 0),
            timers: .init(rest: 0, sleep: 0),
            pack: .init(id: "test-blocks", logicalHeight: 96),
            display: .init(screenIndex: 0, scale: 2))
    }

    func send(_ command: String, _ args: [String: String] = [:],
              protocolVersion: Int = WireProtocol.version) -> Data {
        router.handle(WireRequest(protocolVersion: protocolVersion,
                                  command: command, args: args))
    }
}

private func decode<T: Codable & Sendable>(_ data: Data, as: T.Type) throws -> WireResponse<T> {
    try JSONDecoder().decode(WireResponse<T>.self, from: data)
}

/// 錯誤回應的 payload 型別無所謂（data 是 null），用 AckPayload 解就行。
private func decodeError(_ data: Data) throws -> WireError {
    let response = try decode(data, as: AckPayload.self)
    #expect(response.ok == false)
    #expect(response.data == nil)
    return try #require(response.error)
}

// MARK: - 信封

/// 協定版號不符 → PROTOCOL_MISMATCH，不猜。
///
/// 用一個**不存在的**命令送：版號檢查若排在命令查表之後，這裡會回
/// UNKNOWN_COMMAND，而那個訊息會叫人去查拼字，真正該做的是升級其中一邊。
@Test func mismatchedProtocolVersionIsRejectedBeforeAnythingElse() throws {
    let f = Fixture()
    let error = try decodeError(f.send("a-command-from-the-future", protocolVersion: 999))
    #expect(error.code == .protocolMismatch)
}

@Test func unknownCommandReportsUnknownCommand() throws {
    let error = try decodeError(Fixture().send("summonn"))
    #expect(error.code == .unknownCommand)
    #expect(error.code.exitCode == 2, "拼錯命令是用法錯誤，不是執行失敗")
}

/// 成功的回應要帶正確的信封：ok 為 true、有 data、沒有 error、協定版號填好。
@Test func successfulResponsesCarryTheFullEnvelope() throws {
    let response = try decode(Fixture().send("status"), as: StatusPayload.self)
    #expect(response.ok == true)
    #expect(response.error == nil)
    #expect(response.protocolVersion == WireProtocol.version)
    #expect(response.data?.appVersion == "1.2.3")
    #expect(response.data?.pack.id == "test-blocks")
}

// MARK: - 動作命令

/// 三個動作命令要真的進佇列。
///
/// 沒有這條的話，`enqueue` 整段拿掉、只回 ok，上面每一條測試都還是綠的——
/// router 會變成一個很有禮貌但什麼都不做的東西。
@Test func movementCommandsReachTheSharedQueue() throws {
    let f = Fixture()
    for (command, expected) in [("summon", Command.summon), ("dismiss", .dismiss),
                                ("toggle", .toggle), ("teaser.on", .setTeaser(true)),
                                ("teaser.off", .setTeaser(false)),
                                ("teaser.toggle", .toggleTeaser)] {
        let response = try decode(f.send(command), as: AckPayload.self)
        #expect(response.data?.queued == command)
        #expect(f.control.drain() == [expected], "\(command) 沒有進佇列")
    }
}

/// pack 缺 teaser 動作時回 TEASER_UNAVAILABLE，而且命令不進佇列。
@Test func teaserOnAnIncapablePackReportsTeaserUnavailable() throws {
    let f = Fixture(teaser: false)
    #expect(try decodeError(f.send("teaser.on")).code == .teaserUnavailable)
    #expect(try decodeError(f.send("teaser.toggle")).code == .teaserUnavailable)
    #expect(f.control.drain() == [])

    // 但「關掉」照樣成功——它要的後置條件本來就成立
    #expect(try decode(f.send("teaser.off"), as: AckPayload.self).ok)
}

// MARK: - config

/// config.set 缺 value 參數 → INVALID_ARGUMENT，不是 crash 也不是寫進空字串。
@Test func missingArgumentReportsInvalidArgument() throws {
    let f = Fixture()
    #expect(try decodeError(f.send("config.set", ["key": "cat.speed"])).code == .invalidArgument)
    #expect(try decodeError(f.send("config.set", ["value": "900"])).code == .invalidArgument)
    #expect(try decodeError(f.send("config.reset")).code == .invalidArgument)
    #expect(try decodeError(f.send("pack.validate")).code == .invalidArgument)

    // 缺參數不能有副作用
    #expect(try settingValue(f, "cat.speed") == "900")
}

/// 三種設定錯誤各自對到不同的碼——它們要修的東西完全不同。
@Test func eachSettingsErrorMapsToItsOwnCode() throws {
    let f = Fixture()
    #expect(try decodeError(f.send("config.get", ["key": "cat.spede"])).code == .configKeyUnknown)
    #expect(try decodeError(f.send("config.set", ["key": "cat.speed", "value": "fast"])).code
            == .invalidArgument)
    #expect(try decodeError(f.send("config.set", ["key": "cat.speed", "value": "99999"])).code
            == .configValueOutOfRange)
}

/// 寫入回讀，回的是正規化過的值而不是使用者打的字。
@Test func configSetEchoesTheNormalisedValue() throws {
    let f = Fixture()
    let response = try decode(f.send("config.set",
                                     ["key": "spotlight.enabled", "value": "yes"]),
                              as: ConfigPayload.self)
    #expect(response.data?.entries == [.init(key: "spotlight.enabled", value: "true")])
    #expect(try settingValue(f, "spotlight.enabled") == "true")
}

/// 不給 key 就回全部 23 項，而且照字典序。
@Test func configGetWithoutAKeyReturnsEveryDeclaredKey() throws {
    let entries = try #require(
        try decode(Fixture().send("config.get"), as: ConfigPayload.self).data?.entries)
    #expect(entries.map(\.key) == SettingsUseCase.declaredKeys)
    #expect(entries.count == 23)
}

/// reset --all 之後每一項都回到預設。
@Test func configResetAllRestoresDefaults() throws {
    let f = Fixture()
    _ = f.send("config.set", ["key": "cat.speed", "value": "1500"])
    _ = f.send("config.set", ["key": "rest.duration", "value": "42"])
    #expect(try settingValue(f, "cat.speed") == "1500")

    let after = try #require(
        try decode(f.send("config.reset", ["all": "true"]), as: ConfigPayload.self).data?.entries)
    #expect(after.first { $0.key == "cat.speed" }?.value == "900")
    #expect(after.first { $0.key == "rest.duration" }?.value == "10")
    #expect(after.count == 23)
}

@Test func configResetOneKeyLeavesTheOthersAlone() throws {
    let f = Fixture()
    _ = f.send("config.set", ["key": "cat.speed", "value": "1500"])
    _ = f.send("config.set", ["key": "rest.duration", "value": "42"])

    _ = f.send("config.reset", ["key": "cat.speed"])
    #expect(try settingValue(f, "cat.speed") == "900")
    #expect(try settingValue(f, "rest.duration") == "42", "reset 一個 key 洗掉了別的")
}

private func settingValue(_ f: Fixture, _ key: String) throws -> String {
    let response = try decode(f.send("config.get", ["key": key]), as: ConfigPayload.self)
    return try #require(response.data?.entries.first?.value)
}

// MARK: - pack validate

/// pack validate 對**無效的** pack 回 ok:true 且 data.valid == false。
///
/// spec 第 8.5 節：「驗證成功地判定這套 pack 不合格」不是命令失敗。
/// 做成 ok:false 的話，CLI 就分不出「這套 pack 有問題」與「驗證本身壞了」。
@Test func validatingABadPackSucceedsWithValidFalse() throws {
    let path = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        .appendingPathComponent("bad-frame-count").path

    let response = try decode(Fixture().send("pack.validate", ["path": path]),
                              as: PackValidatePayload.self)
    #expect(response.ok == true, "驗證這件事成功了，不合格的是 pack")
    #expect(response.error == nil)

    let data = try #require(response.data)
    #expect(data.id == "bad-frame-count")
    #expect(data.valid == false)
    #expect(data.errors.contains("run 宣告 8 格，實際 2 個檔案"),
            "實際拿到：\(data.errors)")
}

/// 合格的 pack 回 valid:true，而 warnings 照樣列出來。
///
/// `bad-missing-teaser` 缺的是 teaser 動作——那是 warning 不是 error，
/// 所以它其實是一套**合格**的 pack，只是逗貓棒模式不可用。
@Test func aValidPackStillReportsItsWarnings() throws {
    let path = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        .appendingPathComponent("bad-missing-teaser").path

    let data = try #require(
        try decode(Fixture().send("pack.validate", ["path": path]),
                   as: PackValidatePayload.self).data)
    #expect(data.valid == true)
    #expect(data.errors.isEmpty)
    #expect(data.warnings.contains { $0.contains("逗貓棒") }, "實際拿到：\(data.warnings)")
}

/// 問題文字是給人看的，不能是 Swift 的 enum 字面。
///
/// `String(describing:)` 會印出 `frameCountMismatch(action: "run", …)`，
/// 那既是天書，也會隨著重構默默改變——而它已經上了 wire。
@Test func packIssuesAreRenderedAsHumanTextNotSwiftLiterals() throws {
    for issue in [PackIssue.frameCountMismatch(action: "run", declared: 8, found: 2),
                  .missingCoreActions([.sit, .run]),
                  .undecodableImage(path: "run/000.png"),
                  .inconsistentSizeAcrossActions] {
        #expect(issue.wireText.contains("(") == false, "洩漏了 enum 字面：\(issue.wireText)")
        #expect(issue.wireText.isEmpty == false)
    }
    // 清單型的問題要列出動作名，而且順序固定（Set 的迭代順序不固定）
    #expect(PackIssue.missingCoreActions([.sit, .run]).wireText.contains("run、sit"))
}

/// pack validate 對不存在的路徑 → PACK_NOT_FOUND。
@Test func validatingAMissingPathReportsPackNotFound() throws {
    let error = try decodeError(Fixture().send("pack.validate",
                                               ["path": "/nonexistent/pack-\(UUID().uuidString)"]))
    #expect(error.code == .packNotFound)
}

// MARK: - pack list / use

/// pack list 要把壞掉的也列出來並標 usable:false，而且標出哪一套是當前的。
@Test func packListShowsEveryPackIncludingTheBrokenOnes() throws {
    let f = Fixture()
    let data = try #require(
        try decode(f.send("pack.list"), as: PackListPayload.self).data)

    // 順序是掃描的優先序（內建在前），不是字典序：設定視窗照這個順序列，
    // 而排過序的話 `broken` 會跑到第一個。
    #expect(data.packs.map(\.id) == ["test-blocks", "test-blocks-tall", "broken"])

    let broken = try #require(data.packs.first { $0.id == "broken" })
    #expect(broken.usable == false)
    #expect(broken.errors.isEmpty == false)

    let good = try #require(data.packs.first { $0.id == "test-blocks" })
    #expect(good.usable)
    #expect(good.current, "當前 pack 要標出來，否則 UI 不知道要勾哪一個")
    #expect(data.packs.filter(\.current).count == 1, "只有一套能是當前的")

    // 列清單是唯讀的。這一行擋的是「順手在 list 裡也叫一次 usePack」——
    // 那會讓一個純查詢的命令把貓換掉。
    #expect(f.swapped.value == nil)
}

/// 每個欄位都要投影自它自己的來源。
///
/// 與上一條分開：上一條只看得出「有沒有列出來、哪一套是當前的」。這一條靠
/// `Fixture.packs` 三套互相不同調的屬性，去抓「欄位接錯來源」——那種錯誤
/// 不會有任何症狀，只會讓設定視窗顯示錯的體高、把使用者 pack 標成內建。
@Test func packListProjectsEveryFieldFromItsOwnSource() throws {
    let f = Fixture()
    let data = try #require(
        try decode(f.send("pack.list"), as: PackListPayload.self).data)

    let builtIn = try #require(data.packs.first { $0.id == "test-blocks" })
    #expect(builtIn.builtIn)
    #expect(builtIn.logicalHeight == 96)
    #expect(builtIn.teaserAvailable)
    #expect(builtIn.warnings.isEmpty)

    // 使用者的、可用的、缺 teaser 的：與內建那套在每個布林上都相反
    let tall = try #require(data.packs.first { $0.id == "test-blocks-tall" })
    #expect(tall.builtIn == false)
    #expect(tall.usable)
    #expect(tall.current == false)
    #expect(tall.logicalHeight == 240, "體高要來自這套 pack，不是當前那套")
    #expect(tall.teaserAvailable == false)
    #expect(tall.errors.isEmpty, "缺 teaser 是警告不是錯誤")
    #expect(tall.warnings.isEmpty == false)

    let broken = try #require(data.packs.first { $0.id == "broken" })
    #expect(broken.errors == ["缺少必要動作：sit"])
    #expect(broken.warnings.isEmpty)
    #expect(broken.teaserAvailable, "不合格不代表它沒有逗貓棒動作")
}

/// pack use 一個不存在的 id → PACK_NOT_FOUND，而且不會去換。
@Test func usingAnUnknownPackReportsNotFoundAndSwapsNothing() throws {
    let f = Fixture()
    #expect(try decodeError(f.send("pack.use", ["id": "nope"])).code == .packNotFound)
    #expect(f.swapped.value == nil)
}

/// pack use 一個**壞掉**的 pack → PACK_INVALID，而且不會去換。
///
/// 與 not-found 分開，是因為要修的東西不同：一個是打錯 id，
/// 另一個是那套 pack 真的缺檔案。
@Test func usingABrokenPackReportsInvalidAndSwapsNothing() throws {
    let f = Fixture()
    let error = try decodeError(f.send("pack.use", ["id": "broken"]))
    #expect(error.code == .packInvalid)
    #expect(error.details == ["缺少必要動作：sit"],
            "要附上 errors 清單，否則使用者不知道缺什麼")
    #expect(f.swapped.value == nil)
}

/// pack use 一個好的 pack → 交給注入的 closure。
///
/// 換到**不是當前**的那一套：拿 `test-blocks`（當前那套）來換的話，
/// 把 id 接成 `status().pack.id` 的實作也會通過。
@Test func usingAGoodPackHandsTheIDToTheApp() throws {
    let f = Fixture()
    let response = try decode(f.send("pack.use", ["id": "test-blocks-tall"]),
                              as: AckPayload.self)
    #expect(response.ok)
    #expect(response.data?.queued == "pack.use", "queued 一律是 wire 上的命令名本身")
    #expect(f.swapped.value == "test-blocks-tall")
}

/// pack use 沒給 id → INVALID_ARGUMENT。
@Test func usingWithoutAnIDReportsInvalidArgument() throws {
    let f = Fixture()
    #expect(try decodeError(f.send("pack.use")).code == .invalidArgument)
    #expect(f.swapped.value == nil)
}
