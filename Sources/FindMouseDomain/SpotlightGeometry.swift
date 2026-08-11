// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation

/// spec 第 5.1 節：r = distance(cat, cursor) + effectiveHeight × 0.6 + margin
///
/// 這條加項是「貓要在光圈內」的實作方式——貓本來就落在亮區邊緣，
/// 加上體型與邊距後完整待在亮區裡，所以渲染端不需要任何 z-order 特例。
/// 同時它讓半徑自帶下限：貓抵達時距離等於 arriveRadius，r 永不為 0。
public enum SpotlightGeometry {
    public static func radius(cursor: CGPoint, cat: CGPoint,
                              effectiveHeight: CGFloat, margin: CGFloat) -> CGFloat {
        let distance = hypot(cursor.x - cat.x, cursor.y - cat.y)
        return distance + effectiveHeight * Timings.spotlightHeightFactor + margin
    }
}
