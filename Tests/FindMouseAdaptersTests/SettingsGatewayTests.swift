import Foundation
import Testing
@testable import FindMouseAdapters
import FindMouseDomain

/// 每個測試用自己的 suite，避免污染真實 UserDefaults，也避免測試互相影響。
private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "com.findmouse.tests.\(UUID().uuidString)")!
}

@Test func unsetKeysFallBackToSpecDefaults() {
    let config = SettingsGateway(defaults: isolatedDefaults()).config
    #expect(config == BehaviorConfig(),
            "空白 UserDefaults 必須給出與 BehaviorConfig() 完全相同的值")
}

@Test func storedValuesRoundTripThroughUserDefaults() {
    let defaults = isolatedDefaults()
    var changed = BehaviorConfig()
    changed.restDuration = 42
    changed.catSpeed = 1234
    changed.spotlightEnabled = false
    changed.spotlightTrigger = .everyHunt
    changed.teaserHitRadius = 7
    SettingsGateway(defaults: defaults).save(changed)

    // 另建一個實例，證明值真的落在 defaults 而不是留在記憶體
    let reread = SettingsGateway(defaults: defaults).config
    #expect(reread == changed, "存進去再讀出來必須完全相同")
}

/// **這是這個檔案最重要的測試。**
///
/// `UserDefaults.double(forKey:)` 對不存在的鍵回 **0**，所以用它讀就沒辦法區分
/// 「沒設定過」與「明確設成 0」。而 `wakeThresholdOverride` 的兩者語意完全相反：
/// nil＝沿用衍生預設（3 × rehuntThreshold），0＝任何一點滑鼠移動都叫醒睡著的貓。
/// 見 M1 完成報告第 5 項。
@Test func zeroIsDistinguishableFromUnsetForOptionalOverrides() {
    let defaults = isolatedDefaults()
    let gateway = SettingsGateway(defaults: defaults)

    // 沒設定過 → nil → wakeThreshold 走衍生預設
    #expect(gateway.config.wakeThresholdOverride == nil)
    #expect(gateway.config.wakeThreshold == BehaviorConfig().rehuntThreshold * 3)

    // 明確設成 0 → 讀回來必須是 0 而不是 nil
    var zeroed = BehaviorConfig()
    zeroed.wakeThresholdOverride = 0
    zeroed.arriveRadiusOverride = 0
    gateway.save(zeroed)

    let reread = SettingsGateway(defaults: defaults).config
    #expect(reread.wakeThresholdOverride == 0, "0 被讀成 \(String(describing: reread.wakeThresholdOverride))")
    #expect(reread.arriveRadiusOverride == 0)
    #expect(reread.wakeThreshold == 0, "明確的 0 必須壓過衍生預設")
}

/// 把 override 從有值改回 nil，鍵要真的被移除，不是留著舊值。
@Test func clearingAnOverrideRemovesTheKey() {
    let defaults = isolatedDefaults()
    var withOverride = BehaviorConfig()
    withOverride.wakeThresholdOverride = 999
    SettingsGateway(defaults: defaults).save(withOverride)
    #expect(SettingsGateway(defaults: defaults).config.wakeThresholdOverride == 999)

    SettingsGateway(defaults: defaults).save(BehaviorConfig())   // override 為 nil
    #expect(SettingsGateway(defaults: defaults).config.wakeThresholdOverride == nil,
            "改回 nil 之後仍讀到舊值，代表鍵沒有被移除")
}

/// 壞掉的 trigger 字串要退回預設，不是 crash 也不是留空。
/// UserDefaults 是使用者可以用 `defaults write` 手改的，任何值都可能出現。
@Test func unknownTriggerStringFallsBackToTheDefault() {
    let defaults = isolatedDefaults()
    defaults.set("nonsense", forKey: "spotlight.trigger")
    #expect(SettingsGateway(defaults: defaults).config.spotlightTrigger
            == BehaviorConfig().spotlightTrigger)
}

/// M1 完成報告第 6 項：值域拒絕屬 M3 的 SettingsUseCase。
/// 這一層只做編解碼，**刻意不驗值域**——寫下這個測試是為了讓那個分工在程式碼裡
/// 有據，而不是讓下一個人以為忘了做。這裡若順手加 clamp，M3 會拿到「已經被
/// 偷偷修正過」的值而無法回報 CONFIG_VALUE_OUT_OF_RANGE。
@Test func gatewayDoesNotValidateRanges() {
    let defaults = isolatedDefaults()
    var absurd = BehaviorConfig()
    absurd.restDuration = 999_999
    absurd.catScale = -3
    SettingsGateway(defaults: defaults).save(absurd)

    let reread = SettingsGateway(defaults: defaults).config
    #expect(reread.restDuration == 999_999)
    #expect(reread.catScale == -3)
}
