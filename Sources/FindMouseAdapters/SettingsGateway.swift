// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import FindMouseCore
import FindMouseDomain

/// `ConfigProviderPort` 的 UserDefaults 實作。
///
/// **只做編解碼，不驗值域。** 值域拒絕（回 `CONFIG_VALUE_OUT_OF_RANGE`）是
/// M3 `SettingsUseCase` 的職責——見 M1 完成報告第 6 項。這裡若順手加了 clamp，
/// M3 就會拿到「已經被偷偷修正過」的值，永遠無法回報那個錯誤。
public final class SettingsGateway: SettingsStorePort, @unchecked Sendable {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var config: BehaviorConfig {
        var c = BehaviorConfig()
        c.catScale = cgFloat(Key.catScale) ?? c.catScale
        c.restDuration = double(Key.restDuration) ?? c.restDuration
        c.sleepDuration = double(Key.sleepDuration) ?? c.sleepDuration

        c.spotlightEnabled = defaults.object(forKey: Key.spotlightEnabled) as? Bool
            ?? c.spotlightEnabled
        // 未知字串退回預設：UserDefaults 是使用者能用 `defaults write` 手改的，
        // 任何值都可能出現，不能假設它一定是我們寫進去的那兩個之一。
        if let raw = defaults.string(forKey: Key.spotlightTrigger),
           let trigger = SpotlightTrigger(rawValue: raw) {
            c.spotlightTrigger = trigger
        }
        c.spotlightDimOpacity = cgFloat(Key.spotlightDimOpacity) ?? c.spotlightDimOpacity
        c.spotlightMargin = cgFloat(Key.spotlightMargin) ?? c.spotlightMargin
        c.spotlightFeather = cgFloat(Key.spotlightFeather) ?? c.spotlightFeather

        c.rehuntThreshold = cgFloat(Key.rehuntThreshold) ?? c.rehuntThreshold
        c.catSpeed = cgFloat(Key.catSpeed) ?? c.catSpeed
        c.catTurnRate = cgFloat(Key.catTurnRate) ?? c.catTurnRate

        c.teaserStalkRange = cgFloat(Key.teaserStalkRange) ?? c.teaserStalkRange
        c.teaserStalkTimeout = double(Key.teaserStalkTimeout) ?? c.teaserStalkTimeout
        c.teaserPounceTriggerSpeed = cgFloat(Key.teaserPounceTriggerSpeed)
            ?? c.teaserPounceTriggerSpeed
        c.teaserPounceSpeed = cgFloat(Key.teaserPounceSpeed) ?? c.teaserPounceSpeed
        c.teaserHitRadius = cgFloat(Key.teaserHitRadius) ?? c.teaserHitRadius
        c.teaserRetreatDistance = cgFloat(Key.teaserRetreatDistance) ?? c.teaserRetreatDistance

        // 這兩個是 optional：nil 與 0 語意不同，所以不能給回落值
        c.wakeThresholdOverride = cgFloat(Key.wakeThreshold)
        c.arriveRadiusOverride = cgFloat(Key.arriveRadius)
        return c
    }

    public func save(_ config: BehaviorConfig) {
        defaults.set(Double(config.catScale), forKey: Key.catScale)
        defaults.set(config.restDuration, forKey: Key.restDuration)
        defaults.set(config.sleepDuration, forKey: Key.sleepDuration)

        defaults.set(config.spotlightEnabled, forKey: Key.spotlightEnabled)
        defaults.set(config.spotlightTrigger.rawValue, forKey: Key.spotlightTrigger)
        defaults.set(Double(config.spotlightDimOpacity), forKey: Key.spotlightDimOpacity)
        defaults.set(Double(config.spotlightMargin), forKey: Key.spotlightMargin)
        defaults.set(Double(config.spotlightFeather), forKey: Key.spotlightFeather)

        defaults.set(Double(config.rehuntThreshold), forKey: Key.rehuntThreshold)
        defaults.set(Double(config.catSpeed), forKey: Key.catSpeed)
        defaults.set(Double(config.catTurnRate), forKey: Key.catTurnRate)

        defaults.set(Double(config.teaserStalkRange), forKey: Key.teaserStalkRange)
        defaults.set(config.teaserStalkTimeout, forKey: Key.teaserStalkTimeout)
        defaults.set(Double(config.teaserPounceTriggerSpeed), forKey: Key.teaserPounceTriggerSpeed)
        defaults.set(Double(config.teaserPounceSpeed), forKey: Key.teaserPounceSpeed)
        defaults.set(Double(config.teaserHitRadius), forKey: Key.teaserHitRadius)
        defaults.set(Double(config.teaserRetreatDistance), forKey: Key.teaserRetreatDistance)

        setOptional(config.wakeThresholdOverride, forKey: Key.wakeThreshold)
        setOptional(config.arriveRadiusOverride, forKey: Key.arriveRadius)
    }

    // MARK: - 不進 Domain 的 4 個字串型 key（pack.id / hotkey.* / window.level）

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    /// nil 一律移除鍵，與 `setOptional` 同一個理由：
    /// 「沒設定過」要讓上層看得出來，才有辦法回落到預設。
    public func setString(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    // MARK: - 鍵名。與 spec 第 9 節的設定項名稱一致，M3 的 CLI `config` 會沿用。

    private enum Key {
        static let catScale = "cat.scale"
        static let restDuration = "rest.duration"
        static let sleepDuration = "sleep.duration"
        static let spotlightEnabled = "spotlight.enabled"
        static let spotlightTrigger = "spotlight.trigger"
        static let spotlightDimOpacity = "spotlight.dimOpacity"
        static let spotlightMargin = "spotlight.margin"
        static let spotlightFeather = "spotlight.feather"
        static let rehuntThreshold = "rehunt.threshold"
        static let catSpeed = "cat.speed"
        static let catTurnRate = "cat.turnRate"
        static let teaserStalkRange = "teaser.stalkRange"
        static let teaserStalkTimeout = "teaser.stalkTimeout"
        static let teaserPounceTriggerSpeed = "teaser.pounceTriggerSpeed"
        static let teaserPounceSpeed = "teaser.pounceSpeed"
        static let teaserHitRadius = "teaser.hitRadius"
        static let teaserRetreatDistance = "teaser.retreatDistance"
        static let wakeThreshold = "wake.threshold"
        static let arriveRadius = "arrive.radius"
    }

    // MARK: - 讀寫小工具

    /// 用 `object(forKey:)` 而不是 `double(forKey:)`。
    ///
    /// 後者對不存在的鍵回 **0**，那會讓「沒設定過」與「明確設成 0」無法區分。
    /// 對 `wakeThresholdOverride` 來說這兩者語意完全相反：nil 是「沿用衍生預設
    /// （3 × rehuntThreshold）」，0 是「任何一點滑鼠移動都叫醒睡著的貓」。
    /// 用錯的話每一個沒設定過的欄位都會靜默變成 0——貓速度 0、休息 0 秒。
    private func double(_ key: String) -> Double? {
        defaults.object(forKey: key) as? Double
    }

    private func cgFloat(_ key: String) -> CGFloat? {
        double(key).map { CGFloat($0) }
    }

    /// nil 要真的把鍵移除，不是寫 0——否則「取消覆寫」會變成「覆寫成 0」。
    private func setOptional(_ value: CGFloat?, forKey key: String) {
        if let value { defaults.set(Double(value), forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}
