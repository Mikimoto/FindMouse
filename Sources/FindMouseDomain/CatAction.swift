/// 一個 sprite pack 可能提供的動作。rawValue 同時是 pack 內的目錄名。
public enum CatAction: String, Sendable, CaseIterable {
    case run, brake, sit, sitIdle, stretch, yawn, scratch, lieDown, sleep
    case stalk, windup, pounce, tumble, retreat
}

public extension CatAction {
    /// 缺任一 → 整套 pack 無效
    static let core: Set<CatAction> = [.run, .sit, .sitIdle, .sleep]
    /// 缺了降級，不影響運作
    static let flourish: Set<CatAction> = [.brake, .stretch, .yawn, .scratch, .lieDown]
    /// 缺任一 → 逗貓棒模式不可用
    static let teaser: Set<CatAction> = [.stalk, .windup, .pounce, .tumble, .retreat]
    /// 休息時隨機插入的動作（brake 與 lieDown 是轉場，不在池內）
    static let restPool: Set<CatAction> = [.stretch, .yawn, .scratch]
}
