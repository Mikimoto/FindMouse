import AppKit
import FindMouseAdapters
import FindMouseCore
import FindMouseDomain
import FindMouseWire
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "com.findmouse.app", category: "session")

    private let settings = SettingsGateway()
    private let cursor = CursorGateway()

    private var session: CatSessionUseCase?
    private var control: ControlUseCase?
    private var presenter: OverlayPresenter?
    private var overlays: OverlayEnsemble?
    private var driver: DisplayLinkDriver?
    private var hotkeys: CarbonHotkeyDriver?
    private var menuBar: MenuBarController?
    private var socket: UnixSocketServer?
    private var router: RequestRouter?

    /// 最後一帧的狀態。`status --json` 讀的就是這一份——spec 第 7.3 節的
    /// 「畫面與 status 讀同一份」在實作上就是這個欄位只有一個。
    private var lastState: CatFrameState?
    private var packID = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 第二個實例：spec 第 8.1 節。判定是**真的連上去**，不是看檔案在不在——
        // 啟動時會先 unlink，所以殘留的 socket 檔一直都在。
        if WireClient.isListening(at: UnixSocketServer.defaultPath) {
            presentFatal("FindMouse 已經在執行中。")
            return
        }

        guard let sprites = loadBuiltInPack() else {
            presentFatal("內建 pack 載入失敗，詳見 log")
            return
        }

        let cfg = settings.config
        session = CatSessionUseCase(config: settings, catalog: sprites,
                                    randomizer: SystemRandomizer())
        // 快捷鍵、選單列、（M3 的）CLI 都只透過它投遞命令，所以三條路徑共用一個佇列
        control = ControlUseCase(catalog: sprites)
        presenter = OverlayPresenter(
            logicalHeight: sprites.logicalHeight, catScale: cfg.catScale,
            anchor: sprites.anchor, spriteFacing: sprites.spriteFacing,
            mirrorForOpposite: sprites.mirrorForOpposite,
            spriteAspect: sprites.spriteAspect, feather: cfg.spotlightFeather)

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
        hotkeys.install()
        self.hotkeys = hotkeys

        let menuBar = MenuBarController { [weak self] in self?.enqueue(.toggle) }
        menuBar.showHotkeyFailure(hotkeys.failed.map { "\($0)" })
        self.menuBar = menuBar

        startSocket(sprites: sprites, menuBar: menuBar)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        log.notice("""
            up: screens=\(ensemble.screenCount, privacy: .public) \
            pack=test-blocks hotkeyFailures=\(hotkeys.failed.count, privacy: .public)
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

    private func startSocket(sprites: SpriteRepository, menuBar: MenuBarController) {
        guard let control else { return }

        router = RequestRouter(
            control: control,
            settings: SettingsUseCase(store: settings, catalog: sprites),
            status: { [weak self] in
                MainActor.assumeIsolated { self?.snapshot(sprites: sprites) ?? placeholderStatus }
            })

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
                    self?.router?.handle(request) ?? appClosingResponse
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
    private func snapshot(sprites: SpriteRepository) -> StatusPayload {
        StatusJSONPresenter.payload(
            state: lastState ?? hiddenState(cursor: cursor.location),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "0.0.0",
            packID: packID,
            packLogicalHeight: sprites.logicalHeight,
            screens: NSScreen.screens.map {
                ScreenInfo(frame: $0.frame, scale: $0.backingScaleFactor)
            })
    }

    // MARK: - 每帧

    private func enqueue(_ command: Command) {
        guard let control else { return }
        do {
            try control.enqueue(command)
        } catch {
            // 被拒絕的命令不該把 display link 叫醒——沒有東西要推進。
            // M2 時這裡是靜默的（狀態機自己 no-op），現在至少留得下痕跡。
            log.notice("命令被拒絕：\(String(describing: command), privacy: .public) → \(String(describing: error), privacy: .public)")
            return
        }
        // 貓不可見時 display link 是停的，命令進來要把它叫醒，
        // 否則按了快捷鍵不會有任何事發生。
        if driver?.isRunning == false { driver?.start() }
    }

    private func frame(dt: TimeInterval) {
        guard let session, let control, let presenter, let overlays else { return }

        let point = cursor.location
        let stage = StageReader.current(cursor: point)

        let state = session.tick(dt: dt, cursor: point, stage: stage, commands: control.drain())
        lastState = state
        overlays.apply(state, presenter: presenter)

        if !state.isVisible, control.isEmpty, driver?.isRunning == true {
            // spec 第 7.4 節：貓不可見時停止 display link
            driver?.stop()
            log.debug("display link 停止（貓已退場）")
        }
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

    private func loadBuiltInPack() -> SpriteRepository? {
        guard let packs = SpritePackRepository.builtInPacksDirectory() else {
            log.error("找不到內建 Packs 目錄（resource bundle 沒被複製進 .app？）")
            return nil
        }
        let dir = packs.appendingPathComponent("test-blocks")
        guard let loaded = SpritePackRepository.load(at: dir) else {
            log.error("test-blocks 的 pack.json 讀不到：\(dir.path, privacy: .public)")
            return nil
        }
        let report = PackValidator.validate(manifest: loaded.manifest,
                                            directoryName: loaded.directoryName,
                                            listing: loaded.listing)
        guard let capabilities = report.capabilities else {
            log.error("test-blocks 驗證失敗：\(String(describing: report.errors), privacy: .public)")
            return nil
        }
        packID = loaded.manifest.id
        return SpriteRepository(loaded: loaded, capabilities: capabilities)
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

private let placeholderStatus = StatusJSONPresenter.payload(
    state: hiddenState(cursor: .zero), appVersion: "0.0.0",
    packID: "", packLogicalHeight: 0, screens: [])

/// `self` 已經沒了——App 正在關閉，而這條連線還在等回應。
/// 回一個合法的錯誤信封而不是關掉連線：後者在 CLI 那端會變成
/// 「連上了但沒有回應」，訊息會把人指向網路問題。
private let appClosingResponse: Data =
    (try? JSONEncoder().encode(WireResponse<AckPayload>(error: WireError(
        code: .appNotRunning, message: "FindMouse 正在關閉"))))
    ?? Data(#"{"protocol":1,"ok":false,"error":{"code":"APP_NOT_RUNNING","message":"closing"}}"#.utf8)
