import CoreGraphics
import Foundation
import Testing
@testable import FindMouseCore
import FindMouseDomain

/// spec 第 10 節：螢幕組態變更後，貓若落在不存在的區域要移到最近的有效螢幕。

private let bigStage = Stage(union: CGRect(x: 0, y: 0, width: 3000, height: 1000),
                             cursorScreen: CGRect(x: 2000, y: 0, width: 1000, height: 1000))
/// 拔掉右邊那片之後只剩左邊
private let smallStage = Stage(union: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                               cursorScreen: CGRect(x: 0, y: 0, width: 1000, height: 1000))

private func summonedCat(on stage: Stage, cursor: CGPoint) -> CatSessionUseCase {
    let session = CatSessionUseCase(config: StubConfig(), catalog: StubCatalog(),
                                    randomizer: SeededRandomizer(seed: 7))
    _ = session.tick(dt: 0, cursor: cursor, stage: stage, commands: [.summon])
    for _ in 0..<600 {
        _ = session.tick(dt: 1.0 / 60, cursor: cursor, stage: stage, commands: [])
    }
    return session
}

/// 拔掉貓所在的那片螢幕之後，牠要出現在剩下的螢幕裡。
///
/// 不搬的話牠仍在追鼠標，會從畫面外慢慢走回來——使用者看到的是
/// 「按了快捷鍵好幾秒都沒有貓」，像卡住而不像降級。
@Test func catStrandedOffStageIsBroughtBack() {
    let cursorOnRight = CGPoint(x: 2500, y: 500)
    let session = summonedCat(on: bigStage, cursor: cursorOnRight)

    let before = session.tick(dt: 0, cursor: cursorOnRight, stage: bigStage, commands: [])
    #expect(before.body.position.x > 1000, "前提：貓現在在右邊那片上（實際 \(before.body.position)）")
    #expect(before.isVisible)

    // 右邊那片被拔掉，鼠標也跟著回到左邊
    let after = session.tick(dt: 1.0 / 60, cursor: CGPoint(x: 500, y: 500),
                             stage: smallStage, commands: [])
    #expect(smallStage.cursorScreen.contains(after.body.position),
            "貓還在畫面外：\(after.body.position)")
}

/// 沒有離開舞台的貓不可以被動到。
///
/// 少了這條，「每帧都把位置夾進 cursorScreen」也會讓上一條通過——
/// 而那會讓多螢幕的貓永遠跨不出鼠標所在的那一片。
@Test func catInsideTheStageIsNeverMoved() {
    let cursor = CGPoint(x: 2500, y: 500)
    let session = summonedCat(on: bigStage, cursor: cursor)

    let before = session.tick(dt: 0, cursor: cursor, stage: bigStage, commands: [])
    // 貓在右邊那片，但 union 涵蓋左邊——夾進 cursorScreen 的話座標不會變，
    // 所以要換一個「在 union 內、卻不在 cursorScreen 內」的位置來測
    let leftStage = Stage(union: bigStage.union,
                          cursorScreen: CGRect(x: 0, y: 0, width: 1000, height: 1000))
    let after = session.tick(dt: 0, cursor: CGPoint(x: 500, y: 500),
                             stage: leftStage, commands: [])
    #expect(after.body.position == before.body.position,
            "貓在 union 內卻被搬走了：\(before.body.position) → \(after.body.position)")
}

/// 不在場的貓不需要搬——搬了會讓下一次入場點被覆寫。
@Test func hiddenCatIsNotRelocated() {
    let session = CatSessionUseCase(config: StubConfig(), catalog: StubCatalog(),
                                    randomizer: SeededRandomizer(seed: 7))
    let state = session.tick(dt: 0, cursor: CGPoint(x: 500, y: 500),
                             stage: smallStage, commands: [])
    #expect(state.phase == .hidden)
    #expect(state.body.position == .zero, "hidden 的貓位置應該還是初始值")
}

/// 所有螢幕都不見了（全部睡著）時不要把貓丟到原點。
///
/// `cursorScreen` 是 `.zero` 時夾進去就是 (0, 0)——那是一個看起來像 bug 的位置，
/// 而且螢幕回來時貓會從角落瞬移回去。
@Test func noScreensLeavesThePositionAlone() {
    let cursor = CGPoint(x: 2500, y: 500)
    let session = summonedCat(on: bigStage, cursor: cursor)
    let before = session.tick(dt: 0, cursor: cursor, stage: bigStage, commands: [])

    let empty = Stage(union: .zero, cursorScreen: .zero)
    let after = session.tick(dt: 0, cursor: cursor, stage: empty, commands: [])
    #expect(after.body.position == before.body.position,
            "螢幕全沒了就不要動它：\(after.body.position)")
}

/// 搬回來要落在**鼠標所在那片**，不是 union 邊緣隨便一個點。
///
/// 這兩者只有在「union 的邊緣離 cursorScreen 很遠」時才分得出來，
/// 所以夾具讓鼠標留在左邊那片，而貓被留在右邊那片的外面。
/// 夾進 union 會把貓放在右邊那片裡——技術上在畫面上，但在使用者
/// 沒有在看的那片螢幕上，症狀仍然是「叫了貓卻沒看到」。
@Test func relocatedCatLandsOnTheCursorScreenNotMerelyInsideTheUnion() {
    // 貓待在最右邊那片
    let rightFocused = Stage(union: CGRect(x: 0, y: 0, width: 4000, height: 1000),
                             cursorScreen: CGRect(x: 3000, y: 0, width: 1000, height: 1000))
    let cursorRight = CGPoint(x: 3500, y: 500)
    let session = summonedCat(on: rightFocused, cursor: cursorRight)
    let before = session.tick(dt: 0, cursor: cursorRight, stage: rightFocused, commands: [])
    #expect(before.body.position.x > 3000, "前提：貓在最右邊（實際 \(before.body.position)）")

    // 最右邊那片被拔掉，鼠標到最左邊。**union 的右緣（3000）離鼠標那片很遠**，
    // 兩種夾法因此給出完全不同的答案：夾進 union 會把貓丟到 x≈3000，
    // 那裡技術上「在畫面上」，但在使用者根本沒有在看的那片螢幕。
    let leftFocused = Stage(union: CGRect(x: -1000, y: 0, width: 4000, height: 1000),
                            cursorScreen: CGRect(x: -1000, y: 0, width: 1000, height: 1000))
    let after = session.tick(dt: 1.0 / 60, cursor: CGPoint(x: -500, y: 500),
                             stage: leftFocused, commands: [])
    #expect(leftFocused.cursorScreen.contains(after.body.position),
            "落在 \(after.body.position)，不在鼠標那片 \(leftFocused.cursorScreen)")
}

/// 不在場的貓不搬。
///
/// 退場之後貓停在畫面外（那是它走出去的地方）。這時螢幕組態變動，
/// 若也把它夾回畫面內，下一次 summon 的入場點就會從一個「已經在畫面裡」的
/// 位置算起——貓會直接出現在中間，而不是從邊緣跑進來。
@Test func hiddenCatKeepsItsOffscreenPosition() {
    let cursor = CGPoint(x: 500, y: 500)
    let stage = Stage(union: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                      cursorScreen: CGRect(x: 0, y: 0, width: 1000, height: 1000))
    let session = CatSessionUseCase(config: StubConfig(), catalog: StubCatalog(),
                                    randomizer: SeededRandomizer(seed: 3))
    _ = session.tick(dt: 0, cursor: cursor, stage: stage, commands: [.summon])
    var state = session.tick(dt: 0, cursor: cursor, stage: stage, commands: [])
    for _ in 0..<3600 where state.phase != .hidden {
        state = session.tick(dt: 1.0 / 60, cursor: cursor, stage: stage, commands: [])
    }
    #expect(state.phase == .hidden, "前提：貓已經退場")
    let parked = state.body.position

    // 縮到一片很小的螢幕，讓停放點確實落在新舞台之外——
    // 否則守衛根本不會被走到，這條測試就什麼都沒驗
    let moved = Stage(union: CGRect(x: 0, y: 0, width: 200, height: 200),
                      cursorScreen: CGRect(x: 0, y: 0, width: 200, height: 200))
    #expect(!moved.union.contains(parked), "前提：停放點在新舞台外（實際 \(parked)）")
    let after = session.tick(dt: 1.0 / 60, cursor: cursor, stage: moved, commands: [])
    #expect(after.body.position == parked,
            "hidden 的貓被搬走了：\(parked) → \(after.body.position)")
}
