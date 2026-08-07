/// 換 pack 的**時序**（spec 第 6.5 節）：貓在場就先淡出，退場之後才換，換完叫回來。
///
/// 為什麼是一個型別而不是 `AppDelegate` 裡的幾行 if：那幾行跨越多個 frame，
/// 而 App 層沒有任何測試碰得到。M3 有一個同形狀的 bug（CLI 投遞命令沒有喚醒
/// display link）躲過了 225 個單元測試，就是因為它只存在於 AppDelegate。
///
/// 它**不負責換得成不成功**。`.swap` 的語意只有「現在動手不會出現錯格」——
/// 載入失敗、退回內建都要碰檔案系統，那是 Adapters 的事。若把重試搬進來，
/// 一個永遠載不起來的 id 會讓它每帧都回 `.swap`，而這一層分不出那是失敗
/// 還是呼叫端根本沒理會。同理，換失敗之後要不要把貓叫回來也由呼叫端決定：
/// 它才知道失敗與否。
public final class PackSwapUseCase {

    public enum Action: Equatable, Sendable {
        case idle
        /// 先讓貓回家。
        ///
        /// 與 `.wait` 分成兩個 case 是必要的：合併之後淡出的每一帧都會再下一次
        /// dismiss，而那要靠 `CatSessionUseCase.goHome` 的幂等守衛才不會讓貓
        /// 一路走出畫面。把正確性押在另一個型別的守衛上，那個守衛哪天被
        /// 「簡化」掉時沒有人會聯想到這裡。
        case dismissFirst
        /// 還在淡出，這一帧什麼都別做
        case wait
        /// 現在可以換了。`resummon` 表示換完要不要把貓叫回來
        case swap(id: String, resummon: Bool)
    }

    /// 等著被換上的 pack，以及「換完要不要把貓叫回來」。
    ///
    /// 兩件事綁在同一個 optional，而不是 `pendingID` 加一個獨立的 `wasVisible` 旗標：
    /// 兩個欄位就必須在同一個地方一起清掉，而漏清旗標的症狀落在**下一次**切換
    /// （貓不在場卻憑空跑出一隻），離漏掉的那一行很遠。綁成一包之後，
    /// 「換完了」與「忘掉貓在場過」是同一個賦值。
    private var pending: (id: String, resummon: Bool)?

    public init() {}

    /// 收到切換請求。回傳這一刻該做什麼。
    public func request(_ id: String, isVisible: Bool) -> Action {
        // 「要不要叫回來」問的是**這一輪切換有沒有把貓趕走**，不是此刻在不在場。
        // 上一次 request 已經送牠回家時，牠不在場正是我們造成的——這時不叫回來，
        // 使用者看到的是「換個 pack，貓就再也沒回來」，而畫面上沒有任何提示。
        pending = (id, isVisible || pending?.resummon == true)
        guard !isVisible else { return .dismissFirst }
        // 已經不在場就不必等。走 step 而不是自己拼一個 `.swap`：
        // 「什麼時候能換、要不要叫回來」只寫一次，兩條路就不可能分歧。
        return step(isVisible: false)
    }

    /// 每帧呼叫一次。
    ///
    /// 不可以假設它每帧都真的被呼叫到：貓不可見時 App 會停掉 display link
    /// （spec 第 7.4 節），停著的時候沒有人來收尾。所以待處理的請求要能在
    /// 下一次 `request` 手上被正確地接手，而不是靠這裡一定會跑到。
    public func step(isVisible: Bool) -> Action {
        guard let pending else { return .idle }
        // 還在淡出。這時換圖就是 spec 第 6.5 節要避免的錯格：新 pack 的身體
        // 配上舊 pack 的那一格。
        guard !isVisible else { return .wait }
        self.pending = nil
        return .swap(id: pending.id, resummon: pending.resummon)
    }
}
