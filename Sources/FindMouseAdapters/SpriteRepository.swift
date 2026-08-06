import CoreGraphics
import Foundation
import FindMouseCore
import FindMouseDomain

/// `AnimationCatalogPort` 的真實實作，外加 presenter 需要的取圖介面。
///
/// 為什麼取圖不在 port 上：狀態機只需要「有幾格、幾 fps、循環嗎」才能推進計時，
/// 它不需要圖。把 `image(action:frame:)` 留在具體型別上，Core 就永遠碰不到
/// `CGImage`，分層才是真的而不是宣稱的。
///
/// spec 第 7.4 節的兩個硬性約束都在這裡落地：
/// 一次只有當前與上一個動作的圖在記憶體；`image(action:frame:)` 回傳**快取的
/// 參考**而不是新物件（60fps 下每帧解一張 PNG 會吃掉整個時間預算）。
public final class SpriteRepository: AnimationCatalogPort, @unchecked Sendable {

    public let logicalHeight: CGFloat
    public let capabilities: PackCapabilities

    /// manifest 的 anchor（y 由上往下，見 spec 第 6.2 節）。presenter 要做軸向翻轉。
    public let anchor: CGPoint
    public let mirrorForOpposite: Bool

    private let packDir: URL
    private let clips: [CatAction: AnimationClip]

    /// 動作 → 已解碼的每一格（解不開的那格是 nil）
    private var cache: [CatAction: [CGImage?]] = [:]
    /// 載入順序，用來決定逐出誰
    private var order: [CatAction] = []

    /// 快取中的動作。測試用——沒有它就無法斷言「只保留兩個」這條約束。
    var cachedActions: Set<CatAction> { Set(cache.keys) }

    /// `capabilities` 由呼叫端從 `PackValidator` 取得後傳入，這個型別不自己判定。
    /// 兩邊各算一次的話遲早會分歧，而分歧的那一刻沒有任何訊號。
    public init?(loaded: SpritePackRepository.Loaded, capabilities: PackCapabilities) {
        self.packDir = loaded.directoryURL
        self.logicalHeight = loaded.manifest.logicalHeight
        self.capabilities = capabilities
        self.anchor = CGPoint(x: loaded.manifest.anchor.x, y: loaded.manifest.anchor.y)
        self.mirrorForOpposite = loaded.manifest.mirrorForOpposite

        var clips: [CatAction: AnimationClip] = [:]
        for (name, declared) in loaded.manifest.actions {
            // 未知的動作名在 manifest 裡是 warning（spec 第 6.4 節），這裡略過即可
            guard let action = CatAction(rawValue: name) else { continue }
            clips[action] = AnimationClip(action: action,
                                          frames: declared.frames,
                                          fps: declared.fps,
                                          loops: declared.loop)
        }
        self.clips = clips
    }

    public func clip(for action: CatAction) -> AnimationClip? { clips[action] }

    /// 素材的寬高比（寬 ÷ 高）。presenter 用它從 `logicalHeight` 算出繪製寬度。
    ///
    /// 用 `sit` 第 0 格量：它是 core 級動作，任何合格的 pack 都保證有。
    /// `lazy` 在 `@unchecked Sendable` 上不是執行緒安全的，但這個型別只在
    /// main actor 上使用（driver 與 presenter 都在主執行緒）。
    public lazy var spriteAspect: CGFloat = {
        guard let image = image(action: .sit, frame: 0), image.height > 0 else { return 1 }
        return CGFloat(image.width) / CGFloat(image.height)
    }()

    /// 某動作某格的圖。超出範圍或該動作不存在時回 nil，呼叫端負責不畫。
    public func image(action: CatAction, frame: Int) -> CGImage? {
        guard let clip = clips[action], frame >= 0, frame < clip.frames else { return nil }
        if cache[action] == nil { loadAction(action, frames: clip.frames) }
        return cache[action]?[frame]
    }

    private func loadAction(_ action: CatAction, frames: Int) {
        let dir = packDir.appendingPathComponent(action.rawValue)
        var images: [CGImage?] = []
        images.reserveCapacity(frames)
        for index in 0..<frames {
            images.append(SpriteFileStore.decode(
                dir.appendingPathComponent(String(format: "%03d.png", index))))
        }
        cache[action] = images
        order.append(action)
        while order.count > 2 {
            cache[order.removeFirst()] = nil
        }
    }
}
