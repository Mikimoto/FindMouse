import FindMouseAdapters
import FindMouseCore
import FindMouseDomain

/// 所有從「當前 pack」衍生出來的東西，綁成一包。換 pack 就是換掉整個 `PackBinding`。
///
/// 為什麼要有這個型別：五個協作者各自把 pack 的某一面**藏成 `private let`**——
/// `CatSessionUseCase` 與 `ControlUseCase` 藏 catalog、`SettingsUseCase` 藏 catalog、
/// `OverlayPresenter` 藏 logicalHeight 與 spriteAspect——所以換 pack 一律是重建，
/// 沒有一個是「改個欄位」。分開存五個欄位的話，漏換一個不是編譯錯誤而是
/// **視覺 bug**：新圖配舊格數、或是新貓走舊體高的路。綁成一包之後，
/// 「換掉了幾個」變成「有沒有換掉這個賦值」。
///
/// `OverlayEnsemble` 刻意不在裡面：它持有 `NSWindow`，重建會閃一下，
/// 所以它走 `replace(sprites:)` 換圖。
@MainActor
struct PackBinding {

    /// manifest 的 id（不是使用者請求的字串）。兩者相等由 `PackValidator` 保證——
    /// id 與目錄名不符是 error，那種 pack 根本組不出 binding。
    let id: String
    let sprites: SpriteRepository
    let session: CatSessionUseCase
    let control: ControlUseCase
    let presenter: OverlayPresenter
    let settings: SettingsUseCase

    /// - Parameter config: 讀好的設定快照。`catScale` 與 `spotlightFeather` 來自
    ///   **設定而不是 pack**，但 presenter 要它們，所以換 pack 時一起重讀——
    ///   沿用啟動時那份的話，換 pack 會把使用者中途改過的 `cat.scale` 打回去。
    init(sprites: SpriteRepository, id: String, store: SettingsGateway,
         config: BehaviorConfig, randomizer: Randomizer) {
        self.id = id
        self.sprites = sprites
        session = CatSessionUseCase(config: store, catalog: sprites, randomizer: randomizer)
        // 快捷鍵、選單列、CLI 都只透過它投遞命令，所以三條路徑共用一個佇列
        control = ControlUseCase(catalog: sprites)
        presenter = OverlayPresenter(
            logicalHeight: sprites.logicalHeight, catScale: config.catScale,
            anchor: sprites.anchor, spriteFacing: sprites.spriteFacing,
            mirrorForOpposite: sprites.mirrorForOpposite,
            spriteAspect: sprites.spriteAspect, feather: config.spotlightFeather)
        settings = SettingsUseCase(store: store, catalog: sprites)
    }
}

/// 把非 Sendable 的值搬出 `MainActor.assumeIsolated`。
///
/// `assumeIsolated` 的回傳型別必須是 Sendable，而 `ControlUseCase` 與
/// `SettingsUseCase` 都不是（兩者都持有無鎖的可變狀態）。用這個盒子而不是
/// 把 `PackBinding` 整個改成非隔離的：後者會連 `SpriteRepository.spriteAspect`
/// 那個 lazy var 的保護一起拿掉，而它在 M2 就是一個真的 data race。
///
/// 取出來的值不會跨執行緒：`RequestRouter.handle` 本身就跑在
/// `DispatchQueue.main.sync` 裡的 `MainActor.assumeIsolated` 區塊內。
struct MainActorEscape<T>: @unchecked Sendable {
    let value: T
}
