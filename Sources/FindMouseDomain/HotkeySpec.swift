// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一個全域快捷鍵：一到四個修飾鍵 ＋ 一個主鍵。spec 第 9 節把它存成
/// `"⌥⌘F"` 這種人看得懂的字串，這個型別是那個字串與實際註冊之間的唯一翻譯。
///
/// **為什麼住在 Domain。** `SettingsUseCase`（Core）要拿它驗 `hotkey.*` 的值域，
/// 而 Core 只能 import Domain（`ArchitectureBoundaryTests` 的允許清單）。
/// 這裡是唯一能讓 Core、Adapters、App 三邊都構得到的位置。
///
/// **為什麼值域驗證非在 `SettingsUseCase` 不可。** 加上熱更新之後，
/// `findmouse config set hotkey.summon F` 若寫得進去，重新註冊時就解不出 spec，
/// 使用者的快捷鍵會靜默消失——而他打的那個值還好端端存在設定裡，重啟也救不回來。
/// 值域只有一份（spec 第 9 節），所以它在這裡，不在 UI。
public struct HotkeySpec: Sendable, Equatable {

    /// 修飾鍵。**刻意不用 Carbon 的 `cmdKey`／`optionKey` 位元**——那是 Carbon
    /// 的佈局，Domain 不該知道。轉成那組位元是 `CarbonHotkeyDriver` 的事
    /// （App 是唯一允許 import Carbon 的那一層）。
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// 直接餵給 `RegisterEventHotKey` 的虛擬鍵碼。
    public let keyCode: UInt32
    public let modifiers: Modifiers
    /// 正規化後的主鍵（大寫）。`displayString` 與錯誤訊息都用它。
    public let key: Character

    /// 出廠的兩個快捷鍵（spec 第 9 節）。存成字串是因為註冊表存的就是字串；
    /// 兩個使用端——`SettingsUseCase` 的註冊表預設、App 在設定值解不開時的回落
    /// ——共用這一份，不各自寫死字面值。
    public static let defaultSummonText = "⌥⌘F"
    public static let defaultTeaserText = "⌥⌘T"

    /// 解析 `"⌥⌘F"`。解不開就回 nil——**不猜、不部分接受**。
    ///
    /// 接受的形狀：開頭是一到四個**互不重複**的修飾鍵符號，後面接**剛好一個**
    /// A–Z 或 0–9。修飾鍵彼此的順序不管，輸出一律正規化成 macOS 慣例的
    /// `⌃⌥⇧⌘`；小寫主鍵也接受並轉大寫。
    ///
    /// **正規化而不是拒絕非慣例順序**，是因為這個字串要使用者自己打，而 `⌘⌥F`
    /// 沒有第二種解讀。但正規化的結果必須被寫回設定（見 `SettingsUseCase`），
    /// 否則設定視窗顯示的與 `config get` 回的會是同一個鍵的兩種寫法。
    ///
    /// **重複的修飾鍵一律拒絕**（`⌥⌥F`）：沒有人是故意打的，靜默吸收會把一個
    /// 打錯的字串變成一個合法、但不是他要的快捷鍵。
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var mods = Modifiers()
        var index = trimmed.startIndex
        while index < trimmed.endIndex, let modifier = Self.modifier(for: trimmed[index]) {
            guard !mods.contains(modifier) else { return nil }
            mods.insert(modifier)
            index = trimmed.index(after: index)
        }
        // 沒有修飾鍵的話按那個字母就會被整個吃掉——打字時碰到就沒有字了。
        guard !mods.isEmpty else { return nil }

        // 剩下的必須剛好一個字元：`⌥⌘FF` 與 `⌥⌘`（只有修飾鍵）都在這裡被擋掉。
        // 用位置比對而不是「掃出所有修飾鍵」，所以 `F⌥⌘` 也不合法——修飾鍵
        // 寫在主鍵後面的字串沒有人看得懂，接受它只是多一種寫法要正規化。
        let rest = trimmed[index...]
        guard rest.count == 1, let raw = rest.first,
              let key = Self.canonicalKey(raw), let code = Self.keyCodes[key] else { return nil }

        self.modifiers = mods
        self.key = key
        self.keyCode = code
    }

    /// 正規化後的字串。順序固定 `⌃⌥⇧⌘`（macOS 慣例），往返才會穩定。
    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        text.append(key)
        return text
    }

    private static func modifier(for character: Character) -> Modifiers? {
        switch character {
        case "⌃": return .control
        case "⌥": return .option
        case "⇧": return .shift
        case "⌘": return .command
        default: return nil
        }
    }

    /// 小寫轉大寫，其餘一律不是合法主鍵。
    ///
    /// 用 ASCII 位移而不是 `uppercased()`：後者是 Unicode 全域大小寫映射，
    /// `"ı"`（無點 i）會被映成 `"I"`，於是一個不在鍵盤上的字元變成合法主鍵。
    private static func canonicalKey(_ character: Character) -> Character? {
        if ("A"..."Z").contains(character) || ("0"..."9").contains(character) { return character }
        guard ("a"..."z").contains(character), let ascii = character.asciiValue else { return nil }
        return Character(UnicodeScalar(ascii - 32))
    }

    /// 字元 → 虛擬鍵碼。數值是 `Carbon.HIToolbox` 的 `kVK_ANSI_*`，
    /// 2026-08-07 於本機以 `import Carbon.HIToolbox` 逐一印出核對過。
    ///
    /// 為什麼硬編而不是 import Carbon：見型別本身的說明——Domain 的允許清單
    /// 只有 Foundation 與 CoreGraphics。這不是妥協：ANSI 虛擬鍵碼是凍結的常數，
    /// 從 Apple Extended Keyboard 以來沒有變過。
    ///
    /// **它編的是實體按鍵的位置，不是打出來的字**：非 ANSI 佈局上同一個位置
    /// 印的字可能不同，於是設定裡寫 `⌥⌘F` 而實際要按的是別的鍵。這與 M2 寫死
    /// `kVK_ANSI_F` 時的行為完全一樣，Task 8 沒有改變它，也沒有解決它。
    private static let keyCodes: [Character: UInt32] = [
        "A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5, "H": 4, "I": 34,
        "J": 38, "K": 40, "L": 37, "M": 46, "N": 45, "O": 31, "P": 35, "Q": 12,
        "R": 15, "S": 1, "T": 17, "U": 32, "V": 9, "W": 13, "X": 7, "Y": 16, "Z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
        "8": 28, "9": 25,
    ]
}
