import Testing
@testable import FindMouseCore

/// 貓在畫面上時要先淡出再換，換完再叫回來（spec 第 6.5 節）。
///
/// 不先淡出的話，動作播到一半換圖會出現錯格——貓的身體是新 pack 的、
/// 格數是舊 pack 的那一格。
@Test func swappingWhileVisibleDismissesFirstThenResummons() {
    let swap = PackSwapUseCase()
    #expect(swap.request("tall", isVisible: true) == .dismissFirst)

    // 還在淡出中：什麼都不做
    #expect(swap.step(isVisible: true) == .wait)
    // 淡出完成 → 換，並且記得要叫回來
    #expect(swap.step(isVisible: false) == .swap(id: "tall", resummon: true))
    // 換完就沒事了
    #expect(swap.step(isVisible: false) == .idle)
}

/// 貓本來就不在場時直接換，不要多叫一次。
///
/// 少了 resummon: false，使用者在設定視窗換 pack 會憑空跑出一隻貓。
@Test func swappingWhileHiddenSwapsImmediatelyWithoutSummoning() {
    let swap = PackSwapUseCase()
    #expect(swap.request("tall", isVisible: false) == .swap(id: "tall", resummon: false))
    #expect(swap.step(isVisible: false) == .idle)
}

/// 淡出途中又換一次 → 用最後那一個 id，而且只換一次。
@Test func aSecondRequestDuringFadeOutReplacesTheFirst() {
    let swap = PackSwapUseCase()
    #expect(swap.request("tall", isVisible: true) == .dismissFirst)
    #expect(swap.request("wide", isVisible: true) == .dismissFirst)
    #expect(swap.step(isVisible: false) == .swap(id: "wide", resummon: true))
    #expect(swap.step(isVisible: false) == .idle)
}

/// 沒有待處理的請求時，step 不可以做任何事。
///
/// 少了這條，「每帧都回 swap」也會讓上面三條通過——而那會讓 App 每帧重建
/// 七個協作者，畫面直接停住。
@Test func stepDoesNothingWithoutAPendingRequest() {
    let swap = PackSwapUseCase()
    for visible in [true, false, true] {
        #expect(swap.step(isVisible: visible) == .idle)
    }
}

/// 淡出途中貓已經離場，使用者又換一次 → 還是要把貓叫回來。
///
/// 判準是「這一輪切換有沒有把貓趕走」，不是「此刻在不在場」——貓現在不在場
/// 正是上一次 request 造成的。只看此刻的實作在這裡會回 `resummon: false`，
/// 於是使用者換個 pack 貓就永久消失，而畫面上沒有任何提示。
///
/// 這個型別不可以假設「兩次 request 之間一定有人叫過 step」：`step` 只在
/// display link 跑著時才有人叫，而 App 在貓不可見且佇列清空時就把它停掉
/// （`AppDelegate.frame`，spec 第 7.4 節）。所以「貓已不在場」與「還有待換的 pack」
/// 對這一層來說是可以同時成立的輸入，答錯的代價由使用者付。
@Test func aRequestAfterTheCatHasLeftMidSwapStillResummons() {
    let swap = PackSwapUseCase()
    #expect(swap.request("tall", isVisible: true) == .dismissFirst)
    #expect(swap.request("wide", isVisible: false) == .swap(id: "wide", resummon: true))
    #expect(swap.step(isVisible: false) == .idle)
}

/// 一輪「先淡出再換」結束之後，不可以還記得剛才貓在場過。
///
/// 這條防的是把「換完要叫回來」存成獨立旗標、而清除時漏掉它的實作：
/// 上面四條計畫原有的測試每條都用全新的實例，所以旗標殘留一條都抓不到。
/// 症狀是第二次換 pack（此時貓不在場）憑空跑出一隻貓——與
/// `swappingWhileHiddenSwapsImmediatelyWithoutSummoning` 同一個災難，
/// 只是發生在第二次。
@Test func aCompletedSwapLeavesNoMemoryOfTheCatHavingBeenVisible() {
    let swap = PackSwapUseCase()
    _ = swap.request("tall", isVisible: true)
    #expect(swap.step(isVisible: false) == .swap(id: "tall", resummon: true))

    #expect(swap.request("wide", isVisible: false) == .swap(id: "wide", resummon: false))
}
