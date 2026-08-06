import AppKit
import FindMouseAdapters
import FindMouseDomain
import QuartzCore

/// 兩層：暗幕在下、貓在上。
///
/// spec 第 5.1 節說「貓要在光圈內」是半徑公式的結果、**不是 z-order 特例**。
/// 貓仍然畫在暗幕之上，但理由不同：暗幕在光圈內也不是完全透明（羽化區），
/// 讓貓疊在上面才不會被羽化邊緣壓暗。
///
/// spec 第 7.4 節：貓的移動只改 `position`、逐格只換 `contents`，
/// 兩者都是 GPU compositing，不觸發重繪。暗幕的 mask 每帧只改幾何。
@MainActor
final class OverlayView: NSView {

    private let dimLayer = CALayer()
    private let catLayer = CALayer()
    private let maskContainer = CALayer()
    private let holeLayer = CALayer()
    private let fillerLayers = [CALayer(), CALayer(), CALayer(), CALayer()]
    private let sprites: SpriteRepository

    init(sprites: SpriteRepository, feather: CGFloat) {
        self.sprites = sprites
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(dimLayer)
        layer?.addSublayer(catLayer)

        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        dimLayer.mask = maskContainer

        maskContainer.backgroundColor = NSColor.clear.cgColor
        holeLayer.contents = DimMask.makeRamp(feather: feather)
        holeLayer.magnificationFilter = .linear
        maskContainer.addSublayer(holeLayer)
        for filler in fillerLayers {
            filler.backgroundColor = NSColor.white.cgColor
            maskContainer.addSublayer(filler)
        }

        catLayer.magnificationFilter = .linear
        // 關掉隱式動畫。CALayer 預設對 contents／position 變更做 0.25 秒的補間，
        // 那會讓每一格疊在前一格上——看起來是「糊的」而不是「逐格的」，
        // 而且很容易被誤診成素材問題。
        let noAnimation: [String: CAAction] = [
            "contents": NSNull(), "position": NSNull(), "bounds": NSNull(),
            "opacity": NSNull(), "transform": NSNull(), "anchorPoint": NSNull(),
            "hidden": NSNull(),
        ]
        catLayer.actions = noAnimation
        dimLayer.actions = noAnimation
        maskContainer.actions = noAnimation
        holeLayer.actions = noAnimation
        for filler in fillerLayers { filler.actions = noAnimation }
    }

    required init?(coder: NSCoder) { fatalError("不從 nib 建立") }

    /// 每帧呼叫。除了換 `contents` 之外不配置任何物件。
    func apply(_ vm: OverlayViewModel) {
        guard vm.visible else {
            catLayer.isHidden = true
            dimLayer.opacity = 0
            return
        }
        catLayer.isHidden = false
        catLayer.anchorPoint = vm.cat.anchorPoint
        catLayer.bounds = CGRect(origin: .zero, size: vm.cat.size)
        catLayer.position = vm.cat.position
        catLayer.opacity = Float(vm.cat.alpha)
        catLayer.contents = sprites.image(action: vm.cat.action, frame: vm.cat.frameIndex)
        catLayer.transform = vm.cat.mirrored
            ? CATransform3DMakeScale(-1, 1, 1)
            : CATransform3DIdentity

        guard let dim = vm.dim else {
            dimLayer.opacity = 0
            return
        }
        dimLayer.frame = bounds
        dimLayer.opacity = Float(dim.opacity)
        maskContainer.frame = bounds

        let layout = DimMask.layout(container: bounds, centre: dim.center, radius: dim.radius)
        holeLayer.frame = layout.hole
        for (layer, frame) in zip(fillerLayers, layout.fillers) {
            layer.frame = frame
        }
    }
}
