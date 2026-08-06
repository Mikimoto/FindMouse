import CoreGraphics
import Foundation

/// 暗幕 mask 的兩個純運算部分。
///
/// CALayer 的組裝在 app target（`OverlayView`），但漸層與佈局是純運算，
/// 放在這裡才有測試 target 能驗——而這兩者錯了都很難用眼睛診斷：
/// 漸層方向反了會讓螢幕中央變黑，佈局有縫會讓暗幕漏出一條亮線。
public enum DimMask {

    /// 漸層 sprite 的像素邊長。夠大讓縮放不出現肉眼可見的階梯，
    /// 又不必大到浪費記憶體——512 放大到 1000 pt 仍平滑。
    public static let rampSide = 512

    /// 徑向 alpha 漸層：中心到 `feather × 半徑` 全透明，之後升到邊緣全不透明。
    ///
    /// mask 的語意是「alpha 1 的地方顯示暗幕」，所以**中心要 alpha 0**（亮區）、
    /// 外圍 alpha 1（暗）。方向弄反會讓螢幕中央變黑、四周正常。
    ///
    /// 方形的四角在半徑之外，靠 `.drawsAfterEndLocation` 補成全不透明——
    /// 少了它，四角會是透明的，暗幕就會漏出四個亮角。
    public static func makeRamp(feather: CGFloat) -> CGImage? {
        let side = rampSide
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))

        let clear = CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        let solid = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [clear, solid] as CFArray,
                                        locations: [max(0, min(1, feather)), 1])
        else { return nil }

        let centre = CGPoint(x: Double(side) / 2, y: Double(side) / 2)
        ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                               endCenter: centre, endRadius: Double(side) / 2,
                               options: .drawsAfterEndLocation)
        return ctx.makeImage()
    }

    /// 洞與四個補滿矩形的位置。每帧只改幾何，零重繪。
    ///
    /// 為什麼需要補滿矩形：CALayer 的 mask 在其 sublayer 覆蓋不到的地方 alpha 是 0，
    /// 而 alpha 0 代表「不顯示暗幕」。只放漸層 sprite 的話，sprite 以外的整個
    /// 桌面都不會變暗——正好與想要的相反。
    ///
    /// 也不能反過來讓 mask 容器填白再把洞疊上去：sublayer 是 source-over 合成，
    /// 疊在不透明背景上結果永遠是 alpha 1，打不出洞。
    public struct Layout: Sendable, Equatable {
        public let hole: CGRect
        /// 上、下、左、右。左右只補洞的垂直區間，所以四個互不重疊。
        public let fillers: [CGRect]
    }

    public static func layout(container: CGRect, centre: CGPoint, radius: CGFloat) -> Layout {
        let side = max(radius, 0) * 2
        let hole = CGRect(x: centre.x - radius, y: centre.y - radius, width: side, height: side)
            .intersection(container)

        // 洞完全在容器外時 intersection 是 null，此時整個容器都要暗
        guard !hole.isNull, !hole.isEmpty else {
            return Layout(hole: .zero, fillers: [container, .zero, .zero, .zero])
        }

        let w = container.width, h = container.height
        return Layout(hole: hole, fillers: [
            CGRect(x: 0, y: hole.maxY, width: w, height: max(0, h - hole.maxY)),          // 上
            CGRect(x: 0, y: 0, width: w, height: max(0, hole.minY)),                      // 下
            CGRect(x: 0, y: hole.minY, width: max(0, hole.minX), height: hole.height),    // 左
            CGRect(x: hole.maxX, y: hole.minY,
                   width: max(0, w - hole.maxX), height: hole.height),                    // 右
        ])
    }
}
