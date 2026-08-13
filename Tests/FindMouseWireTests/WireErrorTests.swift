// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Testing
@testable import FindMouseWire

/// 五個新碼的 rawValue 與 exit code。腳本靠 rawValue 分辨處方，
/// 所以它們是對外契約的一部分——改字串等於改 API。
@Test func packInstallErrorsHaveTheirCodesAndExitOne() {
    #expect(WireErrorCode.packAlreadyInstalled.rawValue == "PACK_ALREADY_INSTALLED")
    #expect(WireErrorCode.packBuiltIn.rawValue == "PACK_BUILT_IN")
    #expect(WireErrorCode.packIDReserved.rawValue == "PACK_ID_RESERVED")
    #expect(WireErrorCode.packSourceInvalid.rawValue == "PACK_SOURCE_INVALID")
    #expect(WireErrorCode.packTooLarge.rawValue == "PACK_TOO_LARGE")
    for code in [WireErrorCode.packAlreadyInstalled, .packBuiltIn, .packIDReserved,
                 .packSourceInvalid, .packTooLarge] {
        #expect(code.exitCode == 1, "命令失敗是 1；2 保留給用法錯誤、3 給程式沒開")
    }
}

/// `PACK_BUILT_IN` 與 `PACK_ID_RESERVED` 刻意分開：前者是「這套拿不掉」，
/// 後者是「這個 id 被佔了、裝了不會生效」，處方完全不同（改 id）。
/// 共用一個碼會讓腳本無法分辨，也會讓錯誤訊息只能講其中一種處方。
@Test func removingBuiltInAndInstallingOntoItAreDifferentCodes() {
    #expect(WireErrorCode.packBuiltIn != WireErrorCode.packIDReserved)
}

/// `CaseIterable` 讓「有沒有漏掉 exitCode 的分類」變成可窮舉的斷言。
/// 新增碼卻忘記想 exit code 時，這條會紅在一個具體的名字上。
@Test func everyCodeHasANonZeroExitCode() {
    for code in WireErrorCode.allCases {
        #expect(code.exitCode != 0, "\(code.rawValue) 的 exit code 是 0，那代表成功")
    }
}
