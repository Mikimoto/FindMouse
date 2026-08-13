// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

/// pack 的 `version` 欄位。**它不驗格式**——spec 第 6.2 節只規範 `id` 是
/// `[a-z0-9-]+`，作者可能填 `2.0`、`2026.08`、`v3`、`1.0-beta`，硬要求 semver
/// 等於新增一條會拒絕合法 pack 的規則。
///
/// 所以分工是：解析得出來就能比方向，解析不出來就只並列事實。
public struct PackVersion: Sendable, Equatable, Comparable {

    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    /// 一到三段十進位數字。**解析不出回 nil，不丟例外**：那是正常情況。
    ///
    /// 只認 ASCII 數字。`Int("１")` 對全角數字會成功，而那不是這裡的語意——
    /// 一個填了全角數字的 pack 應該落到「不並列方向」那條路，不是被當成版本 1。
    ///
    /// **`2026.08` 會被照字面解析成 `2026.8`**，不特別偵測「這看起來像日期」：
    /// 字面上它與 `2.0` 無法區分，而判斷作者的意圖只能靠猜。這樣做是安全的——
    /// 方向只在**兩邊都**解析得出時才講，而兩個日期互比出來的方向恰好也是對的。
    public static func parse(_ raw: String?) -> PackVersion? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var nums: [Int] = []
        for p in parts {
            // **空段落靠 `Int("")` 回 nil 擋，不用另外檢查 isEmpty。** 兩個
            // isEmpty 守衛（一個在函式開頭、一個在這裡）本來都在，突變證明它們
            // 都是死條件：`""` 會 split 成 `[""]`（count 1，過得了範圍檢查），
            // 然後在這裡被 `Int("")` 擋下。留著它們只是多兩個沒人守的分支。
            //
            // 注意 `allSatisfy` 對空字串回 **true**（vacuous truth），所以擋住
            // 空段落的是 `Int(p)` 而不是它——這也是為什麼順序不能顛倒。
            guard p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else {
                return nil
            }
            nums.append(n)
        }
        return PackVersion(major: nums[0],
                           minor: nums.count > 1 ? nums[1] : 0,
                           patch: nums.count > 2 ? nums[2] : 0)
    }

    public static func < (a: PackVersion, b: PackVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    /// 覆蓋前的確認訊息。spec 第三節那張四列表就是它的規格。
    ///
    /// **方向只在兩邊都解析得出時才講。** 「這是較舊的版本」若說錯，使用者會據此
    /// 做出相反的決定；解析不出時並列原始字串不是能力不足，是拒絕做沒有根據的宣稱。
    public static func replacementPrompt(packName: String,
                                         installed: String?,
                                         incoming: String?) -> String {
        let name = "「\(packName)」"
        if let old = parse(installed), let new = parse(incoming),
           let i = installed, let n = incoming {
            if new > old { return "\(name)已安裝 \(i)，要更新成 \(n) 嗎？" }
            if new < old { return "\(name)已安裝 \(i)，要換成較舊的 \(n) 嗎？" }
            return "\(name)已安裝的也是 \(i)，要重新安裝嗎？"
        }
        switch (installed, incoming) {
        case let (i?, n?):  return "\(name)已安裝的版本是 \(i)，要換成 \(n) 嗎？"
        case let (nil, n?): return "\(name)已安裝（沒有標版本），要換成 \(n) 嗎？"
        case let (i?, nil): return "\(name)已安裝 \(i)，要換成一份沒有標版本的嗎？"
        case (nil, nil):    return "\(name)已安裝，要取代嗎？"
        }
    }
}
