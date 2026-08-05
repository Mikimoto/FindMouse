/// 對狀態機的命令。summon / dismiss 是幂等的；toggle 不是。
public enum Command: Sendable, Equatable {
    case summon
    case dismiss
    case toggle
    case setTeaser(Bool)
    case toggleTeaser
}
