import CoreGraphics
import Foundation
import Testing
@testable import FindMouseAdapters
import FindMouseDomain

/// 幾何計算與「從 NSScreen 讀」分開，才測得到前者——
/// `NSScreen.screens` 在測試裡是本機的實際螢幕，斷言不了。
@Test func unionIsTheBoundingBoxOfAllScreens() {
    let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let right = CGRect(x: 1920, y: 200, width: 1280, height: 800)
    let stage = StageReader.stage(screens: [left, right], cursor: CGPoint(x: 100, y: 100))
    #expect(stage.union == CGRect(x: 0, y: 0, width: 3200, height: 1080))
}

/// M1 完成報告明文警告：union 與 cursorScreen 不可填成同一個。
/// 入場點用 cursorScreen、退場點用 union，M1 的
/// `catEntersFromTheCursorScreenNotTheUnion` 釘住那個差別。
@Test func cursorScreenIsTheOneContainingTheCursor() {
    let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let right = CGRect(x: 1920, y: 200, width: 1280, height: 800)
    let stage = StageReader.stage(screens: [left, right], cursor: CGPoint(x: 2000, y: 500))
    #expect(stage.cursorScreen == right)
    #expect(stage.cursorScreen != stage.union, "兩個矩形相同時多螢幕入場點會算錯")
}

/// 鼠標可能落在螢幕之間的空隙（螢幕錯位排列時）。
/// 這時要挑最近的一片，不能回 .zero——那會讓 edgePoint 把貓生在座標原點。
@Test func cursorInAGapFallsBackToTheNearestScreen() {
    let left = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let right = CGRect(x: 2000, y: 0, width: 1000, height: 1000)
    let stage = StageReader.stage(screens: [left, right], cursor: CGPoint(x: 1900, y: 500))
    #expect(stage.cursorScreen == right)
}

/// 「最近」要用**到矩形邊緣**的距離，不是到中心的距離。
///
/// 這個佈局兩者的答案不同：鼠標貼在大螢幕右緣外 50 pt，但另有一片很小的螢幕
/// 在遠處。用中心距離會挑到那片小螢幕（因為大螢幕的中心很遠），貓就會從
/// 一個與鼠標無關的螢幕邊緣跑出來。
@Test func nearestIsMeasuredToTheEdgeNotTheCentre() {
    let big = CGRect(x: 0, y: 0, width: 2000, height: 1000)      // 中心 (1000, 500)
    let small = CGRect(x: 2100, y: 0, width: 100, height: 100)   // 中心 (2150, 50)
    let cursor = CGPoint(x: 2050, y: 900)
    // 到邊緣：big 是 50，small 是 hypot(50, 800) ≈ 801.6 → big
    // 到中心：big 是 hypot(1050, 400) ≈ 1123.6，small 是 hypot(100, 850) ≈ 855.9 → small
    let stage = StageReader.stage(screens: [big, small], cursor: cursor)
    #expect(stage.cursorScreen == big,
            "鼠標就貼在 big 的邊緣外 50 pt，卻挑到了 \(stage.cursorScreen)")
}

@Test func noScreensYieldsZeroButDoesNotCrash() {
    let stage = StageReader.stage(screens: [], cursor: .zero)
    #expect(stage.union == .zero)
    #expect(stage.cursorScreen == .zero)
}

/// 單螢幕時 union 與 cursorScreen 相同——這是唯一合法的相同情況。
/// 寫下來是為了讓「兩者不可相同」那條警告不被誤讀成「永遠不同」。
@Test func singleScreenMakesUnionAndCursorScreenIdentical() {
    let only = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let stage = StageReader.stage(screens: [only], cursor: CGPoint(x: 700, y: 400))
    #expect(stage.union == only)
    #expect(stage.cursorScreen == only)
}
