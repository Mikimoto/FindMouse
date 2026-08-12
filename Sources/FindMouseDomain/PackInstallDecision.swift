// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

/// 匯入一套 pack 時，同 id 該怎麼辦。
public enum PackInstallDecision: Sendable, Equatable {
    case install
    case needsConfirmation
    case replace
    /// 這個 id 被內建佔了。**不是權限問題，是裝了不會生效**（理由見 `decide`）。
    case rejectedIDReserved

    public struct Existing: Sendable, Equatable {
        public var id: String
        public var isBuiltIn: Bool
        public init(id: String, isBuiltIn: Bool) {
            self.id = id; self.isBuiltIn = isBuiltIn
        }
    }

    /// - Parameter existing: 目前掃到的每一套（`PackCatalogRepository.current()` 的結果）。
    public static func decide(incomingID: String,
                              existing: [Existing],
                              force: Bool) -> PackInstallDecision {
        let matches = existing.filter { $0.id == incomingID }

        // 撞到內建一律拒絕，force 也不例外。
        //
        // `PackCatalogRepository.scan` 用一個 seen set 去重，而 currentDirectories()
        // 把內建目錄排在使用者目錄**前面**，所以同 id 時內建勝出、使用者那套被
        // continue 跳過（測試 builtInWinsWhenBothDirectoriesHaveTheSameID 釘住）。
        // 於是裝進去的結果是「成功、檔案真的寫進去了、清單裡永遠看不到它」——
        // 而那個組合沒有任何訊號，使用者只會覺得「我裝的 pack 不見了」。
        //
        // force 的語意是 remove ＋ install，而內建移除不了，硬做只會回到同一個
        // 遮蔽狀態，所以這裡不給它例外。處方是「改一個 id」，不是「再試一次」。
        if matches.contains(where: \.isBuiltIn) { return .rejectedIDReserved }

        guard !matches.isEmpty else { return .install }
        return force ? .replace : .needsConfirmation
    }
}
