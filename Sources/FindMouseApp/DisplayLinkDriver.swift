import AppKit
import Foundation
import OSLog
import QuartzCore

/// 每帧驅動一次 `tick`。
///
/// dt 由**相鄰兩帧的 timestamp 相減**得出，不用 `targetTimestamp - timestamp`——
/// 後者是「預期的幀長」而不是「實際過了多久」，掉帧時會低報，貓就會愈掉帧走愈慢。
///
/// M1 的 `tick` 會把 dt clamp 在 0.1 秒並把非有限值當 0，但那是防線不是規格：
/// 這裡仍然要給出正確的值。
///
/// spec 第 7.4 節：貓不可見時停止 display link。
///
/// ## 為什麼有計時器退路
///
/// `CADisplayLink` 在本機（macOS 27 beta ＋ Xcode 27 beta 工具鏈）**完全不觸發**。
/// 這不是本專案的 bug：一支二十行、不含任何專案程式碼的探針，
/// `isPaused == false`、加進 `RunLoop.main` 的 `.common` 模式、視窗已 order front，
/// 三秒內收到 0 次 callback。`NSView.displayLink` 與 `NSScreen.displayLink` 兩種
/// 建立方式都試過，borderless overlay 視窗與普通的 titled key window 也都試過。
///
/// 症狀是最惡劣的那一種：`start()` 成功、`isRunning` 為真、log 一切正常，
/// 只是狀態機永遠不前進——「貓被叫了但不出現」，而每一層的單元測試都是綠的。
///
/// 所以照樣先用 `CADisplayLink`（它是對的 API，正常環境下會與 vsync 對齊），
/// 但啟動後觀察半秒；一帧都沒來就換計時器並記一筆 log。換過一次之後，
/// 整個 process 直接走計時器，不再每次都等那半秒。
@MainActor
final class DisplayLinkDriver {

    private static let log = Logger(subsystem: "tw.com.deepthought.findmouse", category: "clock")

    /// 本 process 是否已確認 `CADisplayLink` 不會動。
    private static var displayLinkIsDead = false

    private var link: CADisplayLink?
    private var timer: Timer?
    private var previousTimestamp: CFTimeInterval?
    private var ticks = 0
    private let view: NSView
    private let onFrame: (TimeInterval) -> Void

    init(view: NSView, onFrame: @escaping (TimeInterval) -> Void) {
        self.view = view
        self.onFrame = onFrame
    }

    var isRunning: Bool { link != nil || timer != nil }

    func start() {
        guard !isRunning else { return }
        // 重新啟動時清掉舊時間戳：停了幾分鐘再開，第一帧的 dt 會是那整段時間。
        previousTimestamp = nil
        ticks = 0

        if Self.displayLinkIsDead {
            startTimer()
            return
        }

        let created = view.displayLink(target: self, selector: #selector(step(_:)))
        created.add(to: .main, forMode: .common)
        link = created

        // 觀察窗要遠大於一帧，才不會把「剛好卡在兩帧之間」誤判成壞掉。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.link != nil, self.ticks == 0 else { return }
                Self.displayLinkIsDead = true
                Self.log.notice("CADisplayLink 半秒內一帧都沒來，改用計時器")
                self.link?.invalidate()
                self.link = nil
                self.startTimer()
            }
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        previousTimestamp = nil
    }

    private func startTimer() {
        // 跟著螢幕的更新率走，拿不到就用 60。
        let fps = view.window?.screen?.maximumFramesPerSecond ?? 60
        let created = Timer(timeInterval: 1.0 / Double(max(fps, 30)), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(at: CACurrentMediaTime()) }
        }
        // `.common` 模式：選單開著或使用者在拖曳時仍要繼續跑，
        // 否則貓會在那段期間凍住。
        RunLoop.main.add(created, forMode: .common)
        timer = created
    }

    /// `CACurrentMediaTime()` 與 `CADisplayLink.timestamp` 是同一個時間基準
    /// （mach absolute time），所以兩條路徑混用不會讓 dt 跳掉。
    private func tick(at now: CFTimeInterval) {
        ticks += 1
        // 第一帧沒有前一個時間戳，用 0 推進。狀態機對 dt = 0 是安全的——
        // M1 的 negativeDeltaIsTreatedAsZero 與 nonFiniteDeltaIsTreatedAsZero 釘住了。
        let dt = previousTimestamp.map { now - $0 } ?? 0
        previousTimestamp = now
        onFrame(dt)
    }

    @objc private func step(_ link: CADisplayLink) {
        tick(at: link.timestamp)
    }
}
