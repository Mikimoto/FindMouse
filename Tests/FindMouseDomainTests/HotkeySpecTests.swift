import Testing
import FindMouseDomain

/// 整張虛擬鍵碼表的**獨立抄本**。
///
/// 為什麼要抄一份而不是從實作讀：表裡全是魔數，而抄錯一個不會有任何訊號——
/// 註冊照樣成功，只是綁到別的實體按鍵上。往返測試看不到（它只比字串），
/// 單射性也看不到（把 J 與 K 的值對調之後 36 個值仍然互異）。
///
/// 數值來源：2026-08-07 在本機跑 `import Carbon.HIToolbox` 逐一印出 `kVK_ANSI_*`。
private let carbonKeyCodes: [(key: Character, code: UInt32)] = [
    ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5),
    ("H", 4), ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45),
    ("O", 31), ("P", 35), ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32),
    ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6),
    ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22),
    ("7", 26), ("8", 28), ("9", 25),
]

/// spec 第 9 節把 hotkey 存成 `"⌥⌘F"` 這種人看得懂的字串。
/// 解析要能往返，否則設定視窗顯示的與實際註冊的會不一樣。
@Test func hotkeyStringsRoundTrip() throws {
    for text in ["⌥⌘F", "⌥⌘T", "⌃⇧A", "⌘1", "⌃⌥⇧⌘Z"] {
        let spec = try #require(HotkeySpec(text), "\(text) 解析失敗")
        #expect(spec.displayString == text)
    }
}

/// 每個符號要對到**它自己**那個修飾鍵。
///
/// 往返測試對這件事完全盲目：若解析把 `⌥` 讀成 control、而 `displayString`
/// 又把 control 印回 `⌥`，往返照樣通過，但送進 `RegisterEventHotKey` 的是
/// 錯的位元——使用者按 ⌥⌘F 沒反應，按 ⌃⌘F 才有。
@Test func eachSymbolMapsToItsOwnModifier() throws {
    let expected: [(String, HotkeySpec.Modifiers)] = [
        ("⌃A", .control), ("⌥A", .option), ("⇧A", .shift), ("⌘A", .command),
        ("⌥⌘A", [.option, .command]), ("⌃⇧A", [.control, .shift]),
        ("⌃⌥⇧⌘A", [.control, .option, .shift, .command]),
    ]
    for (text, modifiers) in expected {
        #expect(try #require(HotkeySpec(text)).modifiers == modifiers, "\(text) 的修飾鍵不對")
    }
}

/// 修飾鍵之間的順序不管，輸出一律正規化成 macOS 慣例的 `⌃⌥⇧⌘`。
///
/// 這是刻意的設計選擇（另一條路是拒絕非慣例順序）：使用者要自己打這個字串，
/// 而 `⌘⌥F` 沒有第二種解讀。釘住它是因為兩種設計都合理——沒有這條的話，
/// 下一個人改成「拒絕」不會有任何訊號。
@Test func modifierOrderIsNormalisedRatherThanRejected() throws {
    #expect(try #require(HotkeySpec("⌘⌥F")).displayString == "⌥⌘F")
    #expect(try #require(HotkeySpec("⇧⌃A")).displayString == "⌃⇧A")
    #expect(HotkeySpec("⌘⌥F") == HotkeySpec("⌥⌘F"))
    #expect(HotkeySpec("⌥⌘F") != HotkeySpec("⌃⌘F"), "不同修飾鍵不能相等")
    #expect(HotkeySpec("⌥⌘F") != HotkeySpec("⌥⌘G"), "不同主鍵不能相等")
}

/// 小寫主鍵接受並轉大寫——`config set hotkey.summon ⌥⌘f` 不該是個陷阱。
///
/// 轉換走 ASCII 位移而不是 `uppercased()`：後者是 Unicode 全域映射，
/// `"ı"`（無點 i）會變成 `"I"`，於是一個不在鍵盤上的字元變成合法主鍵。
@Test func lowercaseKeysAreNormalisedButUnicodeLookalikesAreNot() throws {
    let spec = try #require(HotkeySpec("⌥⌘f"))
    #expect(spec.displayString == "⌥⌘F")
    #expect(spec.keyCode == 3)
    #expect(HotkeySpec("⌥⌘ı") == nil, "無點 i 不是鍵盤上的鍵")
    #expect(HotkeySpec("⌥⌘Ｆ") == nil, "全形 F 不是鍵盤上的鍵")
}

/// 沒有修飾鍵的快捷鍵要拒絕——註冊成功但會把單一字母整個吃掉。
@Test func aHotkeyWithoutModifiersIsRejected() {
    #expect(HotkeySpec("F") == nil)
    #expect(HotkeySpec("") == nil)
    #expect(HotkeySpec("  ") == nil)
}

/// 不認得的字元要拒絕，不要靜默當成別的鍵。
@Test func unknownKeysAreRejected() {
    for bad in ["⌥⌘😀", "⌥⌘FF", "⌥⌘-", "⌥⌘.", "⌥⌘ F", "⌥⌘F1"] {
        #expect(HotkeySpec(bad) == nil, "「\(bad)」應該被拒絕")
    }
}

/// 只有修飾鍵、沒有主鍵：`RegisterEventHotKey` 收到的 keyCode 會是 0
/// （＝A 鍵），使用者設的是「⌥⌘」而實際綁到 ⌥⌘A。
@Test func modifiersWithoutAKeyAreRejected() {
    for bad in ["⌥⌘", "⌃", "⌃⌥⇧⌘"] {
        #expect(HotkeySpec(bad) == nil, "「\(bad)」應該被拒絕")
    }
}

/// 重複的修飾鍵是打錯字，不是一種寫法。靜默吸收會把它變成一個合法、
/// 但不是使用者要的快捷鍵。
@Test func repeatedModifiersAreRejected() {
    for bad in ["⌥⌥F", "⌥⌘⌘F", "⌃⌃⌃A"] {
        #expect(HotkeySpec(bad) == nil, "「\(bad)」應該被拒絕")
    }
}

/// 修飾鍵一定在主鍵前面。掃全字串分類的寫法會把 `F⌥⌘` 也收下並印成 `⌥⌘F`，
/// 那是多一種沒有人看得懂的寫法要正規化。
@Test func modifiersMustComeBeforeTheKey() {
    #expect(HotkeySpec("F⌥⌘") == nil)
    #expect(HotkeySpec("⌥F⌘") == nil)
}

/// 預設值要解析得出來——否則 App 一啟動就沒有快捷鍵。
/// 順便釘住它們已經是正規形式：不是的話註冊表的預設與 `get` 回的值會不一樣。
@Test func theShippedDefaultsParse() throws {
    #expect(HotkeySpec.defaultSummonText == "⌥⌘F")
    #expect(HotkeySpec.defaultTeaserText == "⌥⌘T")
    let summon = try #require(HotkeySpec(HotkeySpec.defaultSummonText))
    let teaser = try #require(HotkeySpec(HotkeySpec.defaultTeaserText))
    #expect(summon.keyCode == 3)    // kVK_ANSI_F
    #expect(teaser.keyCode == 17)   // kVK_ANSI_T
    #expect(summon.modifiers == [.option, .command])
    #expect(teaser.modifiers == [.option, .command])
    #expect(summon.displayString == HotkeySpec.defaultSummonText)
    #expect(teaser.displayString == HotkeySpec.defaultTeaserText)
}

/// 36 個鍵每一個都要對到 Carbon 的那個鍵碼，而且互不重複。
@Test func everyKeyMapsToItsCarbonVirtualKeyCode() throws {
    #expect(carbonKeyCodes.count == 36, "A–Z 加 0–9")
    #expect(Set(carbonKeyCodes.map(\.code)).count == 36, "兩個鍵共用一個鍵碼＝抄錯了")

    for (key, code) in carbonKeyCodes {
        let spec = try #require(HotkeySpec("⌥\(key)"), "⌥\(key) 解析失敗")
        #expect(spec.keyCode == code, "\(key) 的鍵碼應該是 \(code)，實際 \(spec.keyCode)")
        #expect(spec.key == key)
    }
}
