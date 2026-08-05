public enum SpotlightTrigger: String, Sendable, Codable, CaseIterable {
    /// 只有從 hidden 被召喚那一次的 hunting 會亮
    case onSummonOnly
    /// 每次進入 hunting 都亮，包含重新狩獵
    case everyHunt
}
