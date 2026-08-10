import Foundation
import Testing
@testable import FindMouseWire

/// 對外 JSON 的鍵名是契約。用字面 JSON 比對而不是 round-trip，
/// round-trip 對「欄位改名」是盲的——兩邊一起改就照樣通過。
@Test func requestDecodesFromTheSpecShapedJSON() throws {
    let json = #"{"protocol":1,"command":"summon","args":{}}"#
    let request = try JSONDecoder().decode(WireRequest.self, from: Data(json.utf8))
    #expect(request.protocolVersion == 1)
    #expect(request.command == "summon")
    #expect(request.args.isEmpty)
}

@Test func requestKeepsStringArguments() throws {
    let json = #"{"protocol":1,"command":"config set","args":{"key":"rest.duration","value":"42"}}"#
    let request = try JSONDecoder().decode(WireRequest.self, from: Data(json.utf8))
    #expect(request.args["key"] == "rest.duration")
    #expect(request.args["value"] == "42")
}

/// 沒帶參數的命令（summon／status）允許整個 args 鍵缺席，
/// 否則 CLI 每個無參數命令都得多送一個空物件。
@Test func requestWithoutArgsDecodesAsEmpty() throws {
    let json = #"{"protocol":1,"command":"summon"}"#
    let request = try JSONDecoder().decode(WireRequest.self, from: Data(json.utf8))
    #expect(request.args.isEmpty)
}

/// 編碼出來的鍵必須是 "protocol" 而不是 "protocolVersion"。
@Test func requestEncodesWithTheProtocolKey() throws {
    let data = try JSONEncoder().encode(
        WireRequest(command: "status", args: [:]))
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["protocol"] as? Int == 1)
    #expect(object["command"] as? String == "status")
    #expect(object["protocolVersion"] == nil, "不能洩漏 Swift 端的屬性名")
}

@Test func successResponseCarriesItsPayload() throws {
    let response = WireResponse(data: ["phase": "resting"])
    let data = try JSONEncoder().encode(response)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["protocol"] as? Int == 1)
    #expect(object["ok"] as? Bool == true)
    #expect(object["error"] == nil, "成功時不該有 error 欄位")
    let payload = try #require(object["data"] as? [String: Any])
    #expect(payload["phase"] as? String == "resting")
}

@Test func failureResponseCarriesCodeAndMessage() throws {
    let response = WireResponse<[String: String]>(
        error: WireError(code: .teaserUnavailable, message: "當前 pack 缺 teaser 動作"))
    let data = try JSONEncoder().encode(response)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["ok"] as? Bool == false)
    #expect(object["data"] == nil, "失敗時不該有 data 欄位")
    let error = try #require(object["error"] as? [String: Any])
    #expect(error["code"] as? String == "TEASER_UNAVAILABLE")
    #expect((error["message"] as? String)?.isEmpty == false)
}

/// 錯誤碼的字面值是對外契約，AI 會寫死在腳本裡。
/// 逐一列出而不是迴圈，改名時測試要紅在具體那一行。
@Test func errorCodeRawValuesMatchTheSpec() {
    #expect(WireErrorCode.appNotRunning.rawValue == "APP_NOT_RUNNING")
    #expect(WireErrorCode.appNotResponding.rawValue == "APP_NOT_RESPONDING")
    #expect(WireErrorCode.protocolMismatch.rawValue == "PROTOCOL_MISMATCH")
    #expect(WireErrorCode.unknownCommand.rawValue == "UNKNOWN_COMMAND")
    #expect(WireErrorCode.invalidArgument.rawValue == "INVALID_ARGUMENT")
    #expect(WireErrorCode.packNotFound.rawValue == "PACK_NOT_FOUND")
    #expect(WireErrorCode.packInvalid.rawValue == "PACK_INVALID")
    #expect(WireErrorCode.teaserUnavailable.rawValue == "TEASER_UNAVAILABLE")
    #expect(WireErrorCode.configKeyUnknown.rawValue == "CONFIG_KEY_UNKNOWN")
    #expect(WireErrorCode.configValueOutOfRange.rawValue == "CONFIG_VALUE_OUT_OF_RANGE")
}

/// spec 第 8.5 節：3 與 1 分開，腳本才能區分「命令失敗」與「程式沒開」。
@Test func exitCodesSeparateNotRunningFromFailure() {
    #expect(WireErrorCode.appNotRunning.exitCode == 3)
    // 「在跑但沒回應」不可以是 3：3 的語意是「去把它打開」，而它已經開著
    #expect(WireErrorCode.appNotResponding.exitCode == 1)
    #expect(WireErrorCode.invalidArgument.exitCode == 2)
    #expect(WireErrorCode.unknownCommand.exitCode == 2)
    #expect(WireErrorCode.teaserUnavailable.exitCode == 1)
    #expect(WireErrorCode.configValueOutOfRange.exitCode == 1)
}

@Test func loginItemErrorsExitWithOne() {
    // 這三個是「命令失敗」不是「用法錯誤」，也不是「App 沒開」。
    // 走 default 分支拿到 1 是對的，但那是**推論**——實際斷言一次。
    #expect(WireErrorCode.loginItemIneligible.exitCode == 1)
    #expect(WireErrorCode.loginItemNeedsApproval.exitCode == 1)
    #expect(WireErrorCode.loginItemRegisterFailed.exitCode == 1)
}

@Test func loginItemErrorCodeStringsAreTheContract() {
    // rawValue 會被寫進腳本，改名就是破壞契約——所以字面比對。
    #expect(WireErrorCode.loginItemIneligible.rawValue == "LOGIN_ITEM_INELIGIBLE")
    #expect(WireErrorCode.loginItemNeedsApproval.rawValue == "LOGIN_ITEM_NEEDS_APPROVAL")
    #expect(WireErrorCode.loginItemRegisterFailed.rawValue == "LOGIN_ITEM_REGISTER_FAILED")
}
