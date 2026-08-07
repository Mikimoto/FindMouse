import Foundation

/// `pack list` 的回應。
///
/// **不合格的 pack 也在清單裡**，只是 `usable` 為 false 並附上 `errors`。
/// 濾掉的話使用者會看到「我放進去的 pack 不見了」，而他需要知道的是缺什麼
/// （spec 第 10 節）。要挑「能切過去的」就自己看 `usable`。
///
/// 沒有人看的 `name` 欄位是刻意的：兩套內建測試 pack 的 manifest 名稱都是
/// 「測試方塊」，顯示它會出現兩個一模一樣的選項；`id` 既唯一又讀得懂，
/// 而且它就是 `pack use` 的鍵。
public struct PackListPayload: Codable, Sendable, Equatable {

    public struct Entry: Codable, Sendable, Equatable {
        public let id: String
        public let builtIn: Bool
        /// 用 `Double` 而不是 `CGFloat`：Wire 是 CLI 與 App 的共同契約，
        /// 只能碰 Foundation（見 `ArchitectureBoundaryTests` 的允許清單）。
        public let logicalHeight: Double
        /// 能不能被 `pack use` 選中。只有 error 讓它為 false，warning 不會。
        public let usable: Bool
        /// 現在正在用的那一套。UI 要靠它決定勾哪一列。
        public let current: Bool
        public let teaserAvailable: Bool
        public let errors: [String]
        public let warnings: [String]

        public init(id: String, builtIn: Bool, logicalHeight: Double, usable: Bool,
                    current: Bool, teaserAvailable: Bool,
                    errors: [String], warnings: [String]) {
            self.id = id
            self.builtIn = builtIn
            self.logicalHeight = logicalHeight
            self.usable = usable
            self.current = current
            self.teaserAvailable = teaserAvailable
            self.errors = errors
            self.warnings = warnings
        }
    }

    /// 順序是掃描的優先序（內建在前），不是字典序——設定視窗照這個順序列。
    public let packs: [Entry]

    public init(packs: [Entry]) { self.packs = packs }
}
