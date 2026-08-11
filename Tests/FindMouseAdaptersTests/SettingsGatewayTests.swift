import Foundation
import Testing
@testable import FindMouseAdapters
import FindMouseDomain

/// 測試用 suite 的名字。**用編號而不是 UUID，這是刻意的。**
///
/// `UserDefaults(suiteName:)` 會在 `~/Library/Preferences/` 落一個 plist。
/// 原本每個 suite 一個新 UUID，於是每跑一次測試就多留幾個檔案——實測累積到
/// 5528 個（router 2604 ＋ tests 2924、共 21MB）才被發現，而且完全沒有訊號。
///
/// 「用完刪掉」試過，不可靠：`removePersistentDomain` 清得掉內容，但 cfprefsd
/// 會非同步地把一個空 plist flush 回磁碟，連 unlink 都可能發生在 flush 之前
/// ——實測同一份程式碼連跑三輪，殘留分別是 0、11、0。那是 race，修不乾淨。
///
/// 改成編號之後名字跨輪重複使用，磁碟上的檔案數就有上限（＝同時存在的 suite
/// 數，約 46 個空檔），不再隨時間成長。建立時清一次內容，就不會被上一輪污染。
/// **每個 prefix 各一個計數器**，不能共用一個。
///
/// 共用試過：兩個 prefix 交錯取號，而交錯順序取決於測試的平行排程，
/// 每一輪都不一樣——於是名字集合每輪都不同，檔案照樣無限成長
/// （實測連跑三輪：12 → 21 → 29）。分開之後每個 prefix 拿到的都是
/// 1…N，集合跨輪固定。
private let suiteCounters = SuiteCounters()

final class SuiteCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func next(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = (counts[key] ?? 0) + 1
        counts[key] = n
        return n
    }
}

/// 借一個乾淨的測試 suite。內容在這裡清掉——不倚賴上一輪有沒有清成功。
func borrowSuiteName(_ prefix: String) -> String {
    let name = "\(prefix).\(suiteCounters.next(prefix))"
    UserDefaults.standard.removePersistentDomain(forName: name)
    return name
}

/// suite 用完清掉內容。檔案本身留著（見上：刪它是 race），但它是空的。
func removeSuite(_ name: String) {
    UserDefaults.standard.removePersistentDomain(forName: name)
}

/// 每個測試用自己的 suite，避免污染真實 UserDefaults，也避免測試互相影響。
///
/// **用完一定要清掉。** `UserDefaults(suiteName:)` 會在
/// `~/Library/Preferences/` 落一個 plist，而 UUID 的名字每跑一次就換一個新的
/// ——實測累積到 2924 個才被發現（router 那邊另有 2604）。那個洩漏沒有任何
/// 訊號：測試照樣綠、磁碟慢慢長大。
///
/// 寫成 closure 而不是回傳一個「deinit 時清掉」的包裝物件：`UserDefaults`
/// 本身會被 `SettingsGateway` 持有並在包裝物件之後才用到，ARC 可能在測試還沒
/// 跑完就把包裝物件釋放掉——那時 domain 被移除、後面的寫入又把它建回來，
/// 洩漏照舊而且更難查。`defer` 的時機是確定的。
private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
    let suite = borrowSuiteName("com.findmouse.tests")
    let defaults = UserDefaults(suiteName: suite)!
    defer { removeSuite(suite) }
    body(defaults)
}

@Test func unsetKeysFallBackToSpecDefaults() {
    withIsolatedDefaults { defaults in
        let config = SettingsGateway(defaults: defaults).config
        #expect(config == BehaviorConfig(),
                "空白 UserDefaults 必須給出與 BehaviorConfig() 完全相同的值")
    }
}

@Test func storedValuesRoundTripThroughUserDefaults() {
    withIsolatedDefaults { defaults in
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
}

/// **這是這個檔案最重要的測試。**
///
/// `UserDefaults.double(forKey:)` 對不存在的鍵回 **0**，所以用它讀就沒辦法區分
/// 「沒設定過」與「明確設成 0」。而 `wakeThresholdOverride` 的兩者語意完全相反：
/// nil＝沿用衍生預設（3 × rehuntThreshold），0＝任何一點滑鼠移動都叫醒睡著的貓。
/// 見 M1 完成報告第 5 項。
@Test func zeroIsDistinguishableFromUnsetForOptionalOverrides() {
    withIsolatedDefaults { defaults in
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
}

/// 把 override 從有值改回 nil，鍵要真的被移除，不是留著舊值。
@Test func clearingAnOverrideRemovesTheKey() {
    withIsolatedDefaults { defaults in
            var withOverride = BehaviorConfig()
        withOverride.wakeThresholdOverride = 999
        SettingsGateway(defaults: defaults).save(withOverride)
        #expect(SettingsGateway(defaults: defaults).config.wakeThresholdOverride == 999)

        SettingsGateway(defaults: defaults).save(BehaviorConfig())   // override 為 nil
        #expect(SettingsGateway(defaults: defaults).config.wakeThresholdOverride == nil,
                "改回 nil 之後仍讀到舊值，代表鍵沒有被移除")
    }
}

/// 壞掉的 trigger 字串要退回預設，不是 crash 也不是留空。
/// UserDefaults 是使用者可以用 `defaults write` 手改的，任何值都可能出現。
@Test func unknownTriggerStringFallsBackToTheDefault() {
    withIsolatedDefaults { defaults in
            defaults.set("nonsense", forKey: "spotlight.trigger")
        #expect(SettingsGateway(defaults: defaults).config.spotlightTrigger
                == BehaviorConfig().spotlightTrigger)
    }
}

/// M1 完成報告第 6 項：值域拒絕屬 M3 的 SettingsUseCase。
/// 這一層只做編解碼，**刻意不驗值域**——寫下這個測試是為了讓那個分工在程式碼裡
/// 有據，而不是讓下一個人以為忘了做。這裡若順手加 clamp，M3 會拿到「已經被
/// 偷偷修正過」的值而無法回報 CONFIG_VALUE_OUT_OF_RANGE。
@Test func gatewayDoesNotValidateRanges() {
    withIsolatedDefaults { defaults in
            var absurd = BehaviorConfig()
        absurd.restDuration = 999_999
        absurd.catScale = -3
        SettingsGateway(defaults: defaults).save(absurd)

        let reread = SettingsGateway(defaults: defaults).config
        #expect(reread.restDuration == 999_999)
        #expect(reread.catScale == -3)
    }
}
