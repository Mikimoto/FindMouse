import Foundation
import Testing
@testable import FindMouseWire

/// spec 第 8.4 節的範例 payload，逐值照抄。
/// 測試用它編碼後拆成字典逐鍵比對——round-trip 對「兩邊一起改名」是盲的。
private let specExample = StatusPayload(
    appVersion: "1.0.0",
    visible: true,
    phase: "resting",
    phaseElapsed: 3.42,
    teaser: .init(enabled: false, available: true),
    cat: .init(position: .init(x: 1284.0, y: 663.5),
               facing: "left", action: "sitIdle", frame: 3, frameCount: 6),
    cursor: .init(x: 1310.0, y: 640.0),
    distance: 34.2,
    spotlight: .init(active: false, radius: 0, opacity: 0),
    timers: .init(rest: 3.42, sleep: 0),
    pack: .init(id: "fluffy-orange", logicalHeight: 96),
    display: .init(screenIndex: 0, scale: 2))

/// spec 第 8.4 節那段 JSON 的 `data` 部分，一字不改。
private let specExampleJSON = #"""
{
  "appVersion":"1.0.0",
  "visible":true,
  "phase":"resting",
  "phaseElapsed":3.42,
  "teaser":{"enabled":false,"available":true},
  "cat":{"position":{"x":1284.0,"y":663.5},"facing":"left",
         "action":"sitIdle","frame":3,"frameCount":6},
  "cursor":{"x":1310.0,"y":640.0},
  "distance":34.2,
  "spotlight":{"active":false,"radius":0,"opacity":0},
  "timers":{"rest":3.42,"sleep":0},
  "pack":{"id":"fluffy-orange","logicalHeight":96},
  "display":{"screenIndex":0,"scale":2}
}
"""#

private func encodedObject(_ payload: StatusPayload) throws -> [String: Any] {
    let data = try JSONEncoder().encode(payload)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// 頂層鍵的**集合**必須與 spec 完全相同。逐鍵斷言抓得到改名與刪除，
/// 抓不到「多送一個欄位」——多出來的欄位一樣是契約變更。
@Test func statusTopLevelKeysMatchTheSpecExactly() throws {
    let object = try encodedObject(specExample)
    #expect(Set(object.keys) == [
        "appVersion", "visible", "phase", "phaseElapsed", "teaser", "cat",
        "cursor", "distance", "spotlight", "timers", "pack", "display",
    ])
}

@Test func statusScalarsEncodeWithTheSpecKeys() throws {
    let object = try encodedObject(specExample)
    #expect(object["appVersion"] as? String == "1.0.0")
    #expect(object["visible"] as? Bool == true)
    #expect(object["phase"] as? String == "resting")
    #expect(object["phaseElapsed"] as? Double == 3.42)
    #expect(object["distance"] as? Double == 34.2)
}

@Test func teaserEncodesEnabledAndAvailableSeparately() throws {
    let teaser = try #require(try encodedObject(specExample)["teaser"] as? [String: Any])
    #expect(Set(teaser.keys) == ["enabled", "available"])
    #expect(teaser["enabled"] as? Bool == false)
    #expect(teaser["available"] as? Bool == true)
}

@Test func catEncodesPositionFacingActionAndFrameCount() throws {
    let cat = try #require(try encodedObject(specExample)["cat"] as? [String: Any])
    #expect(Set(cat.keys) == ["position", "facing", "action", "frame", "frameCount"])
    let position = try #require(cat["position"] as? [String: Any])
    #expect(Set(position.keys) == ["x", "y"])
    #expect(position["x"] as? Double == 1284.0)
    #expect(position["y"] as? Double == 663.5)
    #expect(cat["facing"] as? String == "left")
    #expect(cat["action"] as? String == "sitIdle")
    #expect(cat["frame"] as? Int == 3)
    #expect(cat["frameCount"] as? Int == 6)
}

@Test func cursorEncodesAsAPointWithXAndY() throws {
    let cursor = try #require(try encodedObject(specExample)["cursor"] as? [String: Any])
    #expect(Set(cursor.keys) == ["x", "y"])
    #expect(cursor["x"] as? Double == 1310.0)
    #expect(cursor["y"] as? Double == 640.0)
}

@Test func spotlightEncodesActiveRadiusAndOpacity() throws {
    let spotlight = try #require(try encodedObject(specExample)["spotlight"] as? [String: Any])
    #expect(Set(spotlight.keys) == ["active", "radius", "opacity"])
    #expect(spotlight["active"] as? Bool == false)
    #expect(spotlight["radius"] as? Double == 0)
    #expect(spotlight["opacity"] as? Double == 0)
}

@Test func timersEncodeRestAndSleep() throws {
    let timers = try #require(try encodedObject(specExample)["timers"] as? [String: Any])
    #expect(Set(timers.keys) == ["rest", "sleep"])
    #expect(timers["rest"] as? Double == 3.42)
    #expect(timers["sleep"] as? Double == 0)
}

@Test func packEncodesIdAndLogicalHeight() throws {
    let pack = try #require(try encodedObject(specExample)["pack"] as? [String: Any])
    #expect(Set(pack.keys) == ["id", "logicalHeight"])
    #expect(pack["id"] as? String == "fluffy-orange")
    #expect(pack["logicalHeight"] as? Double == 96)
}

@Test func displayEncodesScreenIndexAndScale() throws {
    let display = try #require(try encodedObject(specExample)["display"] as? [String: Any])
    #expect(Set(display.keys) == ["screenIndex", "scale"])
    #expect(display["screenIndex"] as? Int == 0)
    #expect(display["scale"] as? Double == 2)
}

/// 另一個方向：spec 那段 JSON 原文必須解得開，且每個值落在對的屬性上。
/// 只有編碼測試時，把兩個同型別的鍵對調（cursor 與 cat.position）仍會通過。
@Test func specExampleJSONDecodesIntoTheSameValue() throws {
    let decoded = try JSONDecoder().decode(
        StatusPayload.self, from: Data(specExampleJSON.utf8))
    #expect(decoded == specExample)
}
