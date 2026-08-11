// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import Testing
@testable import FindMouseAdapters

// MARK: - 漸層

private func alpha(_ image: CGImage, x: Int, y: Int) -> Int? {
    let w = image.width, h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return Int(buf[(y * w + x) * 4 + 3])
}

/// mask 的語意是「alpha 1 的地方顯示暗幕」。方向弄反的話螢幕中央會變黑、
/// 四周正常——很明顯，但不先驗一次就要在整個桌面上除錯。
@Test func rampIsTransparentAtTheCentreAndOpaqueAtTheEdge() throws {
    let ramp = try #require(DimMask.makeRamp(feather: 0.65))
    let side = DimMask.rampSide
    #expect(ramp.width == side && ramp.height == side)

    #expect(alpha(ramp, x: side / 2, y: side / 2) == 0, "中心必須全透明（亮區）")
    // feather 0.65：半徑的 65% 之內仍全透明
    #expect(alpha(ramp, x: side / 2 + Int(Double(side) * 0.3), y: side / 2) == 0)
    // 邊緣中點正好落在漸層半徑上。取不到精確的 255：最後一個像素的中心在
    // 連續座標的 511.5，離圓心 255.5 而半徑是 256，所以差半個像素、算出來約 253。
    // 四角才是真正在半徑之外的點（見下一個測試），那裡必須是 255。
    let edge = try #require(alpha(ramp, x: side - 1, y: side / 2))
    #expect(edge >= 250, "邊緣應該實質不透明（暗區），實際 \(edge)")
}

/// 四角在半徑之外。`.drawsAfterEndLocation` 少了的話它們會是透明的，
/// 暗幕就會漏出四個亮角。
@Test func rampCornersAreOpaque() throws {
    let ramp = try #require(DimMask.makeRamp(feather: 0.65))
    let side = DimMask.rampSide
    for (x, y) in [(0, 0), (side - 1, 0), (0, side - 1), (side - 1, side - 1)] {
        #expect(alpha(ramp, x: x, y: y) == 255, "角落 (\(x), \(y)) 不是全不透明")
    }
}

/// 羽化比例要真的影響漸層的起點，不是只被收下不用。
@Test func featherControlsWhereTheFadeStarts() throws {
    let narrow = try #require(DimMask.makeRamp(feather: 0.1))
    let wide = try #require(DimMask.makeRamp(feather: 0.9))
    let side = DimMask.rampSide
    // 取半徑一半處：feather 0.1 早就開始變暗，feather 0.9 還是全透明
    let probeX = side / 2 + side / 4
    let a = try #require(alpha(narrow, x: probeX, y: side / 2))
    let b = try #require(alpha(wide, x: probeX, y: side / 2))
    #expect(a > b, "feather 0.1 在半徑一半處應該比 feather 0.9 暗（\(a) vs \(b)）")
    #expect(b == 0)
}

// MARK: - 佈局

private let container = CGRect(x: 0, y: 0, width: 1000, height: 800)

/// 洞與四個補滿矩形必須**恰好**鋪滿容器：有縫就會漏出一條沒變暗的亮線，
/// 有重疊則代表某塊區域被算了兩次（alpha 合成後會比別處更暗）。
@Test func holeAndFillersTileTheContainerExactly() {
    let layout = DimMask.layout(container: container,
                                centre: CGPoint(x: 400, y: 300), radius: 150)
    let pieces = [layout.hole] + layout.fillers.filter { !$0.isEmpty }

    // 面積相加等於容器面積 → 既沒縫也沒重疊（配合下面的兩兩不相交）
    let area = pieces.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
    #expect(abs(area - container.width * container.height) < 0.001,
            "面積合計 \(area)，容器是 \(container.width * container.height)")

    for i in pieces.indices {
        for j in pieces.indices where j > i {
            let overlap = pieces[i].intersection(pieces[j])
            #expect(overlap.isEmpty || overlap.isNull,
                    "\(pieces[i]) 與 \(pieces[j]) 重疊了 \(overlap)")
        }
    }
}

/// 洞貼在容器邊緣時，那一側的補滿矩形應該是空的而不是負寬度。
@Test func holeAtTheEdgeProducesEmptyFillersNotNegativeRects() {
    let layout = DimMask.layout(container: container, centre: .zero, radius: 100)
    for filler in layout.fillers {
        #expect(filler.width >= 0 && filler.height >= 0, "負尺寸的矩形：\(filler)")
    }
    let pieces = [layout.hole] + layout.fillers.filter { !$0.isEmpty }
    let area = pieces.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
    #expect(abs(area - container.width * container.height) < 0.001)
}

/// 半徑 0（貓正好站在鼠標上、光圈縮到最小）不能讓整個桌面變亮或變暗。
@Test func zeroRadiusStillCoversTheWholeContainer() {
    let layout = DimMask.layout(container: container,
                                centre: CGPoint(x: 500, y: 400), radius: 0)
    let pieces = [layout.hole] + layout.fillers.filter { !$0.isEmpty }
    let area = pieces.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
    #expect(abs(area - container.width * container.height) < 0.001)
}

/// 光圈完全跑到容器外（多螢幕拔掉一片的瞬間）→ 整個容器都該是暗的。
@Test func holeCompletelyOutsideMakesEverythingDim() {
    let layout = DimMask.layout(container: container,
                                centre: CGPoint(x: 5000, y: 5000), radius: 100)
    #expect(layout.hole == .zero)
    let covered = layout.fillers.filter { !$0.isEmpty }
    #expect(covered == [container])
}
