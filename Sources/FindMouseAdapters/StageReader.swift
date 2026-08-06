import AppKit
import CoreGraphics
import Foundation
import FindMouseDomain

/// 一片螢幕的幾何與縮放。
///
/// 兩個欄位綁在一起，是為了讓「哪一片」與「它的 scale」只查一次。
/// 分開傳的話，`status --json` 的 `screenIndex` 與 `scale` 會各自算，
/// 而在多螢幕不同 scale（Retina ＋ 外接 1080p）時，兩者指到不同螢幕
/// 不會有任何訊號——那正是這種欄位最容易錯的形狀。
public struct ScreenInfo: Sendable, Equatable {
    public let frame: CGRect
    public let scale: CGFloat

    public init(frame: CGRect, scale: CGFloat) {
        self.frame = frame
        self.scale = scale
    }
}

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
        let index = cursorScreenIndex(screens: screens, cursor: cursor)
        return Stage(union: union, cursorScreen: index.map { screens[$0] } ?? union)
    }

    /// 鼠標所在螢幕在 `screens` 中的索引。空清單回 nil。
    ///
    /// `status --json` 的 `display.screenIndex` 與貓的入場點都問這個問題，
    /// 答案必須是同一個。分開實作的話，鼠標落在螢幕空隙時兩邊會分歧：
    /// 貓從最近那片的邊緣跑出來，而 status 說牠不在任何螢幕上。
    public static func cursorScreenIndex(screens: [CGRect], cursor: CGPoint) -> Int? {
        if let containing = screens.firstIndex(where: { $0.contains(cursor) }) {
            return containing
        }
        // 鼠標落在螢幕之間的空隙（螢幕錯位排列時會有）。挑最近的一片。
        // 回 nil 會讓 edgePoint 把貓生在座標原點，看起來像 bug 而不是降級。
        return screens.indices.min {
            distance(from: cursor, to: screens[$0]) < distance(from: cursor, to: screens[$1])
        }
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
