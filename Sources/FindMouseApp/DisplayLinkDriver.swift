import AppKit
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
@MainActor
final class DisplayLinkDriver {

    private var link: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private let view: NSView
    private let onFrame: (TimeInterval) -> Void

    init(view: NSView, onFrame: @escaping (TimeInterval) -> Void) {
        self.view = view
        self.onFrame = onFrame
    }

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil else { return }
        // 重新啟動時清掉舊時間戳：停了幾分鐘再開，第一帧的 dt 會是那整段時間。
        previousTimestamp = nil
        let created = view.displayLink(target: self, selector: #selector(step(_:)))
        created.add(to: .main, forMode: .common)
        link = created
    }

    func stop() {
        link?.invalidate()
        link = nil
        previousTimestamp = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        // 第一帧沒有前一個時間戳，用 0 推進。狀態機對 dt = 0 是安全的——
        // M1 的 negativeDeltaIsTreatedAsZero 與 nonFiniteDeltaIsTreatedAsZero 釘住了。
        let dt = previousTimestamp.map { link.timestamp - $0 } ?? 0
        previousTimestamp = link.timestamp
        onFrame(dt)
    }
}
