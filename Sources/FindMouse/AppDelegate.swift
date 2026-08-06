import AppKit
import FindMouseAdapters
import FindMouseCore
import FindMouseDomain
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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
