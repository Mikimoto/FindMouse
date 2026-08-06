import FindMouseDomain

/// 命令被拒絕的理由。Core 不能 import Wire（架構邊界測試釘著），
/// 所以錯誤在這裡定義，由 Task 6 的 router 對應到 `WireErrorCode`。
public enum ControlError: Error, Sendable, Equatable {
    /// pack 缺 teaser 動作。M1 的 `CatSessionUseCase.setTeaser` 對這件事是靜默 no-op，
    /// 「回報」是這一層的責任。
    case teaserUnavailable
}

/// 快捷鍵、選單列、CLI 的共同入口（spec 第 7.2 節）。
///
/// 存在的理由只有一個：**三條路徑共用同一個佇列**，所以它們不可能行為分歧。
/// M2 時佇列是 `AppDelegate` 的私有欄位，CLI 一旦加進來就會需要第二條路徑；
/// 抽到 Core 之後，「誰按的」在 `tick` 眼中完全沒有差別。
///
/// 它**不持有** `CatSessionUseCase`：命令是被 `tick` 消費的，這一層只負責
/// 累積與前置檢查。這也讓佇列可以在 tick 之外的任何時機被填入
/// （M3 的 socket server 在別的執行緒收到請求，marshal 回主執行緒才 enqueue）。
public final class ControlUseCase {

    private let catalog: AnimationCatalogPort
    private var queue: [Command] = []

    public init(catalog: AnimationCatalogPort) {
        self.catalog = catalog
    }

    /// 佇列是否為空。`AppDelegate` 用它決定「貓退場後可不可以停掉 display link」——
    /// 還有命令沒消費完就停，那些命令要等到下一次按鍵才會生效。
    public var isEmpty: Bool { queue.isEmpty }

    /// 投遞一個命令。被拒絕時**不會**進佇列。
    ///
    /// 用 throws 而不是回傳 optional 錯誤，是為了讓呼叫端不可能默默忽略拒絕：
    /// 快捷鍵路徑要 log、CLI 路徑要把它變成 exit code，兩邊都必須寫出 catch。
    public func enqueue(_ command: Command) throws(ControlError) {
        if let reason = rejection(for: command) { throw reason }
        queue.append(command)
    }

    /// 取走目前累積的命令並清空。同一個命令不會被消費兩次。
    public func drain() -> [Command] {
        defer { queue.removeAll(keepingCapacity: true) }
        return queue
    }

    /// 前置檢查。回 nil 表示可以進佇列。
    ///
    /// `toggleTeaser` 在無 teaser 的 pack 上只可能是「想打開」：
    /// `CatSessionUseCase.setTeaser` 從不讓 `teaserEnabled` 在這種 pack 上變成 true，
    /// 所以不需要知道當前狀態就能判定。
    ///
    /// `setTeaser(false)` 相反——它要的後置條件（teaser 是關的）在這種 pack 上
    /// 本來就成立，讓 `findmouse teaser off` 對任何 pack 都成功比較好寫腳本。
    private func rejection(for command: Command) -> ControlError? {
        switch command {
        case .setTeaser(true), .toggleTeaser:
            return catalog.capabilities.teaserAvailable ? nil : .teaserUnavailable
        case .summon, .dismiss, .toggle, .setTeaser(false):
            return nil
        }
    }
}
