import AppKit
import CoreGraphics
import Foundation
import FindMouseDomain

/// `NSScreen` → `Stage`。
///
/// 幾何計算做成吃 `[CGRect]` 的靜態函式，多螢幕的判定才測得到——
/// `NSScreen.screens` 在測試裡是本機的實際螢幕，斷言不了。
public enum StageReader {

    public static func current(cursor: CGPoint) -> Stage {
        stage(screens: NSScreen.screens.map(\.frame), cursor: cursor)
    }

    static func stage(screens: [CGRect], cursor: CGPoint) -> Stage {
        guard let first = screens.first else {
            return Stage(union: .zero, cursorScreen: .zero)
        }
        let union = screens.dropFirst().reduce(first) { $0.union($1) }

        if let containing = screens.first(where: { $0.contains(cursor) }) {
            return Stage(union: union, cursorScreen: containing)
        }

        // 鼠標落在螢幕之間的空隙（螢幕錯位排列時會有）。挑最近的一片。
        // 回 .zero 會讓 edgePoint 把貓生在座標原點，看起來像 bug 而不是降級。
        let nearest = screens.min {
            distance(from: cursor, to: $0) < distance(from: cursor, to: $1)
        }
        return Stage(union: union, cursorScreen: nearest ?? union)
    }

    /// 點到矩形的距離（點在矩形內時為 0）。
    ///
    /// 用**邊緣**距離而不是中心距離：一片很大的螢幕，其中心可能離鼠標很遠，
    /// 但鼠標其實就貼在它的邊上。用中心距離會挑到另一片小而遠的螢幕，
    /// 貓就從一個與鼠標無關的邊緣跑出來。
    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
