/// 一套 pack 實際能做什麼。CatSessionUseCase 用它動態組休息池、
/// 動態決定逗貓棒可用性。
public struct PackCapabilities: Sendable, Equatable {
    public var available: Set<CatAction>
    public var teaserAvailable: Bool
    /// 依 rawValue 排序，保證決定性
    public var restPool: [CatAction]

    public init(available: Set<CatAction>, teaserAvailable: Bool, restPool: [CatAction]) {
        self.available = available
        self.teaserAvailable = teaserAvailable
        self.restPool = restPool
    }
}
