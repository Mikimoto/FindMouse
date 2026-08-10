import AppKit
import FindMouseAdapters
import FindMouseCore
import FindMouseDomain
import FindMouseWire
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "tw.com.deepthought.findmouse", category: "session")

    private let settings = SettingsGateway()
    private let cursor = CursorGateway()

    /// 當前 pack 的全部衍生物。**只有這一個欄位**——換 pack 就是換掉這個賦值，
    /// 所以每個讀取點都必須讀它而不是自己留一份副本。
    private var pack: PackBinding?
    private var overlays: OverlayEnsemble?
    private var driver: DisplayLinkDriver?
    private var hotkeys: CarbonHotkeyDriver?
    private var menuBar: MenuBarController?
    private var socket: UnixSocketServer?
    private var router: RequestRouter?
    private var settingsWindow: SettingsWindowController?
    /// 設定視窗與選單列 pack 子選單**共用同一份**。
    ///
    /// 共用而不是各自建一份：`choosePack` 已經處理了「選到正在跑的那一套就不動」
    /// 與「寫入走抽換而不是寫 `pack.id`」，各寫一份必然漂移，而漂移的那一天
    /// 不會有任何訊號（`FindMouseApp` 沒有測試 target）。
    private var settingsForm: SettingsFormStore?
    private let swapper = PackSwapUseCase()

    /// 最後一帧的狀態。`status --json` 讀的就是這一份——spec 第 7.3 節的
    /// 「畫面與 status 讀同一份」在實作上就是這個欄位只有一個。
    private var lastState: CatFrameState?

    /// 現在真的註冊著的那一組。`onSettingsChanged` 對**任何**設定變更都會來，
    /// 沒有這兩個欄位的話改 `cat.speed` 也會 unregister＋register 一輪：
    /// 期間快捷鍵短暫不存在，而且衝突警告會在選單列裡一次一次疊上去。
    private var installedSummon: HotkeySpec?
    private var installedTeaser: HotkeySpec?

    /// 任何 pack 都載不起來時的最後一條路，也是全新安裝時看到的那一套。
    ///
    /// 讀共用常數而不是自己寫一份 "mycat"：不能讀的是 `SettingsUseCase.registry`
    /// （它要一個 catalog，而 catalog 正是這一步要載出來的東西），常數沒有這個
    /// 問題。各寫一份的版本靠註解提醒對齊，而漂掉的那一天不會有任何訊號——
    /// `FindMouseApp` 沒有測試 target，理由詳見 `PackDefaults`。
    private static let builtInPackID = PackDefaults.factory

    /// 開機啟動的系統面。`SystemLoginItem` 每次被問都重新讀 `SMAppService`，
    /// 所以這裡持有一個實例不會讓狀態變陳舊。
    private let loginItem: LoginItemGateway = SystemLoginItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 第二個實例：spec 第 8.1 節。判定是**真的連上去**，不是看檔案在不在——
        // 啟動時會先 unlink，所以殘留的 socket 檔一直都在。
        if WireClient.isListening(at: UnixSocketServer.defaultPath) {
            presentFatal("FindMouse 已經在執行中。")
            return
        }

        let cfg = settings.config
        // 上次選的那套；載不起來就退回內建（spec 第 10 節）。「載不起來」包含
        // 「使用者把整個目錄刪了」與「他手改設定指向一套不合格的 pack」兩種。
        let wanted = settings.string(forKey: "pack.id") ?? Self.builtInPackID
        guard let binding = makeBinding(id: wanted, config: cfg)
                ?? makeBinding(id: Self.builtInPackID, config: cfg) else {
            presentFatal("內建 pack 載入失敗，詳見 log")
            return
        }
        pack = binding
        let sprites = binding.sprites

        let ensemble = OverlayEnsemble(sprites: sprites, feather: cfg.spotlightFeather,
                                       level: .overlayWindow)
        ensemble.rebuild(screens: NSScreen.screens.map(\.frame))
        overlays = ensemble

        if let view = ensemble.anyView {
            driver = DisplayLinkDriver(view: view) { [weak self] dt in self?.frame(dt: dt) }
        }

        let hotkeys = CarbonHotkeyDriver { [weak self] key in
            switch key {
            case .toggleCat: self?.enqueue(.toggle)
            case .toggleTeaser: self?.enqueue(.toggleTeaser)
            }
        }
        self.hotkeys = hotkeys

        let form = makeSettingsFormStore()
        settingsForm = form
        settingsWindow = SettingsWindowController(store: form)

        let menuBar = MenuBarController(
            onToggleCat: { [weak self] in self?.enqueue(.toggle) },
            onOpenSettings: { [weak self] in self?.settingsWindow?.show() },
            // 每次打開子選單都重掃磁碟（`reload` 會呼叫 `PackCatalogRepository.current()`）：
            // 使用者把 pack 丟進 Packs 目錄之後不該還要重開 App 才看得到。
            packRows: { [weak self] in
                guard let form = self?.settingsForm else { return [] }
                form.reload()
                return form.snapshot.packs
            },
            onChoosePack: { [weak self] in self?.settingsForm?.choosePack($0) })
        self.menuBar = menuBar
        // 排在 menuBar 之後：註冊失敗要攤給使用者看，而那條路要有選單列才走得到
        reinstallHotkeys()

        startSocket(initial: binding, menuBar: menuBar)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // spec 第 10 節：系統睡眠時把貓收回去。
        //
        // dt clamp 只擋住「醒來後一帧跑完整個狀態機」，擋不住「貓在闔上蓋子的
        // 那一刻還站在畫面上」——而且醒來後的第一段動畫沒有人看得到。
        // 用 NSWorkspace 的通知中心，不是 NotificationCenter.default：
        // 工作區層級的通知只發到前者，掛錯地方會靜默收不到。
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil)

        log.notice("""
            up: screens=\(ensemble.screenCount, privacy: .public) \
            pack=\(binding.id, privacy: .public) \
            hotkeyFailures=\(hotkeys.failed.count, privacy: .public)
            """)

        // 先跑一帧產生 hidden 狀態的畫面，之後 display link 只在貓在場時跑
        frame(dt: 0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        driver?.stop()
        hotkeys?.uninstall()
        socket?.stop()
    }

    // MARK: - CLI

    /// - Parameter initial: `self` 已經消失（App 正在關閉）時的回落值。
    ///   走得到的路徑一律讀 `self.pack`——**捕獲 `initial` 當成當前 pack 是
    ///   這個 task 最容易犯的錯**：換 pack 之後 router 會往孤兒佇列投遞
    ///   （回 ok、貓不動），teaser 閘門會問舊 pack 的 capabilities。
    private func startSocket(initial: PackBinding, menuBar: MenuBarController) {
        router = RequestRouter(
            control: { [weak self] in
                MainActor.assumeIsolated {
                    MainActorEscape(value: self?.pack?.control ?? initial.control)
                }.value
            },
            settings: { [weak self] in
                MainActor.assumeIsolated {
                    MainActorEscape(value: self?.pack?.settings ?? initial.settings)
                }.value
            },
            status: { [weak self] in
                MainActor.assumeIsolated { self?.snapshot() ?? placeholderStatus }
            },
            packs: { PackCatalogRepository.current() },
            usePack: { [weak self] id in
                MainActor.assumeIsolated { self?.requestPackSwap(to: id) }
            },
            onSettingsChanged: { [weak self] in
                MainActor.assumeIsolated { self?.settingsDidChange() }
            },
            // 與上面那些不同，這個不包 closure：`SystemLoginItem` 不會隨換 pack
            // 而被換掉，而且它每次被問都重新讀 `SMAppService`，本身就沒有陳舊問題。
            loginItem: loginItem)

        let server = UnixSocketServer(path: UnixSocketServer.defaultPath) { [weak self] request in
            // handler 跑在 accept 執行緒上。**所有**對 session／sprites 的存取都要
            // 切回 main actor——不是為了保險，是因為 SpriteRepository.spriteAspect
            // 是 lazy var，在 @unchecked Sendable 的型別上兩條執行緒同時初始化
            // 就是 data race（M2 完成報告第 5 項）。
            //
            // 用 sync 而不是 async：這條連線在等回應，而從非主執行緒呼叫
            // main.sync 是安全的（主執行緒不會反過來等我們）。
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let self else { return appClosingResponse }
                    let response = self.router?.handle(request) ?? appClosingResponse
                    // router 直接往 ControlUseCase 投遞，所以喚醒要在這裡做
                    self.wakeIfWorkPending()
                    return response
                }
            }
        }

        do {
            try server.start()
            socket = server
            log.notice("control socket 就緒：\(UnixSocketServer.defaultPath, privacy: .public)")
        } catch {
            // spec 第 10 節：綁不起來時 App 照常運作，只是 CLI 不可用。
            log.error("control socket 綁不起來：\(String(describing: error), privacy: .public)")
            menuBar.reportDegradation("CLI 不可用：control socket 綁不起來（\(error)）")
        }
    }

    /// 把最後一帧翻成 `status --json` 的 payload。
    ///
    /// **貓不可見時要換上現在的鼠標位置。** display link 在那時是停的（spec 第 7.4 節），
    /// 所以 `lastState` 連同它的 `cursor` 一起凍在最後一帧——而 `cursor`、`distance`、
    /// `display.screenIndex`、`display.scale` 全都是從鼠標導出的。
    /// hidden 是**預設狀態**，所以「剛啟動的 App 永遠回報啟動當下的鼠標位置」，
    /// 而這個 App 的主題就是鼠標在哪裡。spec 第 8.4 節與成功條件第 5 條都因此不成立。
    ///
    /// 時鐘在跑的時候不換：那時 `lastState` 最多差一帧，而「畫面與 status 讀同一份」
    /// （spec 第 7.3 節）在有真實幀可讀時才是有意義的保證。
    ///
    /// **不收 pack 參數。** 收的話呼叫端就會捕獲建構當下那一份，換 pack 之後
    /// `status --json` 會回報舊的體高——而 `pack.id` 因為讀的是欄位所以是新的，
    /// 兩者對不上，看起來像「換了一半」。
    private func snapshot() -> StatusPayload {
        let frame = lastState ?? hiddenState(cursor: cursor.location)
        let state = driver?.isRunning == true ? frame : frame.withCursor(cursor.location)
        return StatusJSONPresenter.payload(
            state: state,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "0.0.0",
            packID: pack?.id ?? "",
            packLogicalHeight: pack?.sprites.logicalHeight ?? 0,
            screens: NSScreen.screens.map {
                ScreenInfo(frame: $0.frame, scale: $0.backingScaleFactor)
            },
            // 每次都重問，不快取：使用者可能剛在系統設定裡改過，而 status
            // 的整份意義就是「現在的實況」。
            loginItemState: loginItem.state.rawValue)
    }

    // MARK: - 設定

    /// 設定視窗的資料來源。**每一項都是 closure，一個值都不捕獲**——
    /// 換 pack 會把整個 `PackBinding` 換掉，捕獲一份 `SettingsUseCase` 的話
    /// 設定視窗之後寫的是孤兒物件（UI 成功、`config get` 讀不到）。
    /// 與 `RequestRouter` 的 `control`／`settings` 同一個模式。
    private func makeSettingsFormStore() -> SettingsFormStore {
        SettingsFormStore(
            settings: { [weak self] in self?.pack?.settings },
            packs: { PackCatalogRepository.current() },
            // 實際跑著的那套，不是 `config get pack.id`：啟動時想要的 pack
            // 載不起來會退回內建，而設定裡那個壞掉的 id 不會被改寫。
            currentPackID: { [weak self] in self?.pack?.id ?? "" },
            // 換 pack 走與 CLI `pack use` 同一條路（spec 第 6.5 節的先淡出再換）。
            // 只寫 `pack.id` 不會換 pack，使用者會看到「選了新的、貓還是舊的」。
            usePack: { [weak self] id in self?.requestPackSwap(to: id) },
            onChanged: { [weak self] in self?.settingsDidChange() })
    }

    /// 設定真的改了——不管是 CLI 還是設定視窗改的，兩條路都收在這裡。
    private func settingsDidChange() {
        reinstallHotkeys()
        refreshPresenter()
        // 設定視窗開著的時候 CLI 也能改值；不重讀的話畫面停在舊值，
        // 使用者接著動 slider 送出的是「舊值 ± 一格」，把 CLI 的改動蓋掉。
        settingsWindow?.reload()
    }

    /// `cat.scale` 改了要讓畫面跟著變。
    ///
    /// presenter 的 `catScale` 是**建構時**吃進去的，而 `CatSessionUseCase`
    /// 每帧重讀設定（`tick` 裡的 `config.config`）。不重建的話貓的移動幾何
    /// 立刻變、畫出來的大小沒變，兩者對不上。
    ///
    /// 重建後要立刻重畫一次：貓不可見時 display link 是停的（spec 第 7.4 節），
    /// 不補這一帧的話改動要等到下次叫貓才看得到。
    private func refreshPresenter() {
        guard pack != nil else { return }
        pack?.refreshPresenter(config: settings.config)
        if let state = lastState, let overlays, let presenter = pack?.presenter {
            overlays.apply(state, presenter: presenter)
        }
    }

    // MARK: - 快捷鍵

    /// 從設定讀出兩個快捷鍵並註冊。啟動時與**每次設定變更後**都走這裡，
    /// 所以 `hotkey.*` 改了不必重啟（M3 交接下來的那筆帳）。
    ///
    /// 沒變就不動：見 `installedSummon` 的說明。
    private func reinstallHotkeys() {
        guard let hotkeys, let settings = pack?.settings else { return }
        guard let summon = hotkeySpec(settings, "hotkey.summon",
                                      fallback: HotkeySpec.defaultSummonText),
              let teaser = hotkeySpec(settings, "hotkey.teaser",
                                      fallback: HotkeySpec.defaultTeaserText) else {
            // 連出廠值都解不開才會到這裡，而 `theShippedDefaultsParse` 釘住它解得開。
            // 留著是因為 `HotkeySpec` 的 init 是 failable，不是因為預期它會發生。
            log.fault("出廠快捷鍵解不開，維持上一組")
            return
        }
        guard summon != installedSummon || teaser != installedTeaser else { return }

        hotkeys.install(summon: summon, teaser: teaser)
        installedSummon = summon
        installedTeaser = teaser
        menuBar?.showHotkeyFailure(hotkeys.failed.map { "\($0)" })
        log.notice("""
            快捷鍵已註冊：summon=\(summon.displayString, privacy: .public) \
            teaser=\(teaser.displayString, privacy: .public) \
            failures=\(hotkeys.failed.count, privacy: .public)
            """)
    }

    /// 讀一個 `hotkey.*` 的當前值並解析。
    ///
    /// 解不開就退回出廠值。`SettingsUseCase` 已經擋掉解不開的值（spec 第 9 節），
    /// 所以走到這裡代表有人繞過它直接改了 UserDefaults（`defaults write`）——
    /// 那時「快捷鍵整組消失」比「回到出廠值」難查得多。
    private func hotkeySpec(_ settings: SettingsUseCase, _ key: String,
                            fallback: String) -> HotkeySpec? {
        let stored = try? settings.get(key)
        if let stored, let spec = HotkeySpec(stored) { return spec }
        log.error("\(key, privacy: .public) 的值解不開，改用出廠值：\(stored ?? "nil", privacy: .public)")
        return HotkeySpec(fallback)
    }

    // MARK: - 每帧

    private func enqueue(_ command: Command) {
        guard let control = pack?.control else { return }
        do {
            try control.enqueue(command)
        } catch {
            // 被拒絕的命令不該把 display link 叫醒——沒有東西要推進。
            // M2 時這裡是靜默的（狀態機自己 no-op），現在至少留得下痕跡。
            log.notice("命令被拒絕：\(String(describing: command), privacy: .public) → \(String(describing: error), privacy: .public)")
            return
        }
        wakeIfWorkPending()
    }

    /// 佇列裡有東西就確保 display link 在跑。
    ///
    /// 貓不可見時 display link 是停的（spec 第 7.4 節），而停著的時候沒有人會
    /// 消費佇列。**每一條投遞命令的路徑都必須經過這裡**——實測踩過：CLI 經由
    /// router 直接呼叫 `control.enqueue`，繞過了原本寫在快捷鍵路徑裡的喚醒，
    /// 於是 `findmouse summon` 回 ok、命令進了佇列、貓永遠不出現。
    ///
    /// 判斷條件是「佇列非空」而不是「剛剛投遞成功」：後者要每個呼叫端自己記得，
    /// 而前者就是「需要 tick」的定義本身。
    private func wakeIfWorkPending() {
        guard let control = pack?.control, !control.isEmpty else { return }
        if driver?.isRunning == false { driver?.start() }
    }

    private func frame(dt: TimeInterval) {
        guard let current = pack, let overlays else { return }

        let point = cursor.location
        let stage = StageReader.current(cursor: point)

        let state = current.session.tick(dt: dt, cursor: point, stage: stage,
                                         commands: current.control.drain())
        lastState = state
        overlays.apply(state, presenter: current.presenter)

        // 換 pack 排在畫完這一帧之後：這一帧畫的是舊 pack 的那一格，
        // 先換圖就是 spec 第 6.5 節要避免的錯格。
        apply(swapper.step(isVisible: state.isVisible))

        // 佇列要重讀 `pack`，不能用上面的 `current`——上一行可能剛換掉整包，
        // 而換完補的那個 `.summon` 進的是**新**的佇列。拿舊的來問「空了嗎」
        // 會得到「空了」，於是時鐘停下、剛排進去的 summon 沒有人消費，
        // 使用者看到的是「換個 pack，貓就再也沒回來」。
        if !state.isVisible, pack?.control.isEmpty == true, driver?.isRunning == true {
            // spec 第 7.4 節：貓不可見時停止 display link
            driver?.stop()
            log.debug("display link 停止（貓已退場）")
        }
    }

    @objc private func systemWillSleep() {
        log.notice("系統即將睡眠，讓貓回家")
        enqueue(.dismiss)
    }

    @objc private func screensChanged() {
        guard let overlays else { return }
        let screens = NSScreen.screens.map(\.frame)
        overlays.rebuild(screens: screens)
        // view 被換掉了，display link 綁在舊 view 上，要重新建立
        let wasRunning = driver?.isRunning == true
        driver?.stop()
        if let view = overlays.anyView {
            driver = DisplayLinkDriver(view: view) { [weak self] dt in self?.frame(dt: dt) }
            if wasRunning { driver?.start() }
        }
        log.notice("螢幕組態變動：現在有 \(screens.count, privacy: .public) 片")
    }

    // MARK: - pack

    /// CLI／選單列請求換 pack。真正動手要等貓退場（spec 第 6.5 節），
    /// 所以這裡只是把請求交給 `PackSwapUseCase`，時序由它決定。
    private func requestPackSwap(to id: String) {
        apply(swapper.request(id, isVisible: lastState?.isVisible ?? false))
    }

    private func apply(_ action: PackSwapUseCase.Action) {
        switch action {
        case .idle, .wait:
            break
        case .dismissFirst:
            enqueue(.dismiss)
        case .swap(let id, let resummon):
            // 順序不能顛倒：`enqueue` 要進**換完之後**那個佇列。
            performSwap(to: id)
            // 成功與失敗都要通知：失敗時下拉選單要彈回實際跑著的那一套，
            // 而那正是「這套換不過去」的訊號（原因在選單列的降級提示裡）。
            settingsWindow?.packSwapConcluded()
            // 換失敗時**照樣**叫回來。貓是我們上一步趕走的，不叫的話使用者
            // 看到的是「換個 pack，貓就憑空消失」——而失敗的線索只在選單列的
            // 降級提示裡。`PackSwapUseCase` 刻意不管成敗（見它的 doc），
            // 所以這個取捨落在這裡。
            if resummon { enqueue(.summon) }
        }
    }

    /// 真的換掉。失敗就留在原本那套並記一筆降級（spec 第 10 節）。
    ///
    /// 回傳 Void 而不是計畫寫的 Bool：成功與失敗之後要做的事完全一樣
    /// （該叫回來就叫回來），呼叫端拿到 Bool 也只能丟掉。
    private func performSwap(to id: String) {
        let previous = pack?.id ?? ""
        guard let binding = makeBinding(id: id, config: settings.config) else {
            // 失敗這條路不碰佇列：舊的 ControlUseCase 還在，裡面的東西照樣會被消費。
            log.error("""
                換 pack 失敗，留在 \(previous, privacy: .public)：\(id, privacy: .public)
                """)
            menuBar?.reportDegradation("pack \(id) 載入失敗，仍使用 \(previous)")
            return
        }
        // 舊佇列裡還沒被消費的命令要搬過去。走 socket 那條路時（貓不在場，
        // 換 pack 當場就發生）佇列不保證是空的——`findmouse summon` 緊接著
        // `findmouse pack use x` 就落在這個窗口裡，而丟掉的那個 summon
        // 不會有任何訊息。從 `frame` 進來時它必定是空的（那一帧開頭剛排空過）。
        let carried = pack?.control.drain() ?? []

        pack = binding
        overlays?.replace(sprites: binding.sprites)
        // 用 enqueue 而不是直接塞：新 pack 拒絕得了的（缺 teaser 動作）就讓它掉，
        // 而且會留下一行 log——結果與直接對新 pack 下同一個命令一致。
        for command in carried { enqueue(command) }

        // 立刻用新 pack 跑一帧。`lastState` 是 `status --json` 的唯一來源，而
        // teaser 可用性與格數都住在**狀態**裡而不是 pack 欄位裡；不更新的話會有
        // 「pack.id 已經是新的、teaser.available 還是舊的」這個對不上的中間狀態。
        // 而且貓不在場時 display link 是停的（spec 第 7.4 節），那個中間狀態
        // 可能一直留到下一次有人叫貓為止。
        let point = cursor.location
        let state = binding.session.tick(dt: 0, cursor: point,
                                         stage: StageReader.current(cursor: point),
                                         commands: [])
        lastState = state
        overlays?.apply(state, presenter: binding.presenter)

        // 走 SettingsUseCase 而不是 `settings.setString`：pack.id 的值域
        // （`[a-z0-9-]`）只有一份定義（spec 第 9 節），繞過去就多一條沒驗過的
        // 寫入路徑。這裡的 catch 今天走不到——`binding.id` 是通過 `PackValidator`
        // 的 manifest id，兩邊的規則是同一條——留著是為了「哪天有人只放寬其中
        // 一邊」時有訊號，而不是靜默不存檔。
        do {
            try binding.settings.set("pack.id", to: binding.id)
        } catch {
            log.error("""
                pack.id 寫不進設定：\(binding.id, privacy: .public) \
                \(String(describing: error), privacy: .public)
                """)
        }
        log.notice("已換 pack：\(previous, privacy: .public) → \(binding.id, privacy: .public)")
    }

    /// 載入指定 id 的 pack 並接好它的全部衍生物。任何一關過不了就回 nil。
    private func makeBinding(id: String, config: BehaviorConfig) -> PackBinding? {
        guard let directory = PackCatalogRepository.currentDirectory(for: id) else {
            log.error("找不到 pack 目錄：\(id, privacy: .public)")
            return nil
        }
        guard let loaded = loadPack(at: directory) else { return nil }
        return PackBinding(sprites: loaded.sprites, id: loaded.id, store: settings,
                           config: config, randomizer: SystemRandomizer())
    }

    /// 讀 + 驗一套 pack。
    ///
    /// **驗證不能省。** `PackCatalogRepository.directory(for:)` 是拿 id 當目錄名
    /// 組路徑，所以「找得到目錄」不等於「這套 pack 可用」——目錄名與 manifest id
    /// 不符的那種 pack 它照樣找得到，而 `PackValidator` 判它不合格。缺 core 動作
    /// 的那種同理。id 一律取 manifest 的，那是通過驗證的那一個。
    private func loadPack(at directory: URL) -> (sprites: SpriteRepository, id: String)? {
        guard let loaded = SpritePackRepository.load(at: directory) else {
            log.error("pack.json 讀不到：\(directory.path, privacy: .public)")
            return nil
        }
        let report = PackValidator.validate(manifest: loaded.manifest,
                                            directoryName: loaded.directoryName,
                                            listing: loaded.listing)
        guard let capabilities = report.capabilities else {
            log.error("""
                pack 驗證失敗：\(loaded.manifest.id, privacy: .public) \
                \(String(describing: report.errors), privacy: .public)
                """)
            return nil
        }
        guard let sprites = SpriteRepository(loaded: loaded, capabilities: capabilities) else {
            log.error("SpriteRepository 建不起來：\(loaded.manifest.id, privacy: .public)")
            return nil
        }
        return (sprites, loaded.manifest.id)
    }

    private func presentFatal(_ message: String) {
        log.fault("\(message, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "FindMouse 無法啟動"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}

// MARK: - 沒有真實狀態可回時的備援

/// 還沒跑過任何一帧時的狀態。實際上跑不到（`applicationDidFinishLaunching`
/// 結尾就 tick 了一次），但 `lastState` 是 optional，這裡不編一個假的貓出來。
private func hiddenState(cursor: CGPoint) -> CatFrameState {
    CatFrameState(phase: .hidden, phaseElapsed: 0,
                  body: CatBody(position: .zero, heading: 0),
                  action: .sitIdle, frameIndex: 0, frameCount: 0, alpha: 0,
                  spotlight: .inactive, cursor: cursor,
                  teaserEnabled: false, teaserAvailable: false,
                  restTimer: 0, sleepTimer: 0)
}

private extension CatFrameState {
    /// 換掉鼠標位置，其餘照舊。`distanceToCursor` 是計算屬性，所以會跟著更新。
    func withCursor(_ point: CGPoint) -> CatFrameState {
        CatFrameState(phase: phase, phaseElapsed: phaseElapsed, body: body,
                      action: action, frameIndex: frameIndex, frameCount: frameCount,
                      alpha: alpha, spotlight: spotlight, cursor: point,
                      teaserEnabled: teaserEnabled, teaserAvailable: teaserAvailable,
                      restTimer: restTimer, sleepTimer: sleepTimer)
    }
}

// App 正在關閉時回的佔位資料。`loginItem` 這裡給 ineligible 而不是去問系統：
// 這份 payload 的每一個欄位都已經是假的（版本 0.0.0、沒有 pack、沒有螢幕），
// 唯獨一個欄位跑去拿真值，只會讓讀的人以為整份是真的。
private let placeholderStatus = StatusJSONPresenter.payload(
    state: hiddenState(cursor: .zero), appVersion: "0.0.0",
    packID: "", packLogicalHeight: 0, screens: [],
    loginItemState: LoginItem.State.ineligible.rawValue)

/// `self` 已經沒了——App 正在關閉，而這條連線還在等回應。
/// 回一個合法的錯誤信封而不是關掉連線：後者在 CLI 那端會變成
/// 「連上了但沒有回應」，訊息會把人指向網路問題。
private let appClosingResponse: Data =
    (try? JSONEncoder().encode(WireResponse<AckPayload>(error: WireError(
        code: .appNotRunning, message: "FindMouse 正在關閉"))))
    ?? Data(#"{"protocol":1,"ok":false,"error":{"code":"APP_NOT_RUNNING","message":"closing"}}"#.utf8)
