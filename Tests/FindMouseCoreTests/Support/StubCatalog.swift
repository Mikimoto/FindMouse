import CoreGraphics
import FindMouseDomain
import FindMouseCore

/// 模擬 test-blocks pack：每個動作 2 格、10 fps。可以指定要拿掉哪些動作。
final class StubCatalog: AnimationCatalogPort, @unchecked Sendable {
    let logicalHeight: CGFloat
    private(set) var capabilities: PackCapabilities
    private var clips: [CatAction: AnimationClip]

    init(logicalHeight: CGFloat = 100, dropping: Set<CatAction> = [], fps: Double = 10, frames: Int = 2) {
        self.logicalHeight = logicalHeight
        let available = Set(CatAction.allCases).subtracting(dropping)
        self.capabilities = PackCapabilities(
            available: available,
            teaserAvailable: CatAction.teaser.isSubset(of: available),
            restPool: CatAction.restPool.intersection(available).sorted { $0.rawValue < $1.rawValue })
        self.clips = Dictionary(uniqueKeysWithValues: available.map {
            ($0, AnimationClip(action: $0, frames: frames, fps: fps,
                               loops: [.run, .sitIdle, .sleep, .stalk, .windup].contains($0)))
        })
    }

    func clip(for action: CatAction) -> AnimationClip? { clips[action] }
}
