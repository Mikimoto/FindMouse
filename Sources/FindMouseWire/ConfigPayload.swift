import Foundation

/// `config get` / `set` / `reset` 的回應。
///
/// 值一律是**字串**，即使是數字設定。理由不是偷懶：
/// 23 個 key 的型別是異質的（數字、bool、列舉、快捷鍵字面），
/// 把它們塞進一個 JSON 物件就得用 `Any`，而那會讓 `"1"` 與 `1`
/// 變成兩種要各自處理的情況。`SettingsUseCase` 已經保證輸出是
/// 正規化過的字串（`160` 不是 `160.0`、`true` 不是 `yes`），
/// 而且那個字串餵回 `set` 一定會被接受。
///
/// 用有序的 `entries` 而不是字典：JSON 物件的鍵順序不保證，
/// 而 `config get`（不指定 key）的輸出是給人看的，順序跳動很難讀。
public struct ConfigPayload: Codable, Sendable, Equatable {

    public struct Entry: Codable, Sendable, Equatable {
        public let key: String
        public let value: String
        public init(key: String, value: String) { self.key = key; self.value = value }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }
}
