// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FindMouseDomain

/// Info.plist 的三個建置鍵 → 顯示字串。
///
/// **吃 dictionary 而不是 `Bundle`**：測試裡的 `Bundle.main` 是測試 runner 自己的
/// bundle，直接讀它等於這一層的降級行為測不到。預設參數保留正式路徑的方便。
///
/// 設定視窗與 `status --json` 的 `appVersion` 都走這裡，所以兩邊必然是同一串——
/// 使用者回報問題時貼上的東西與腳本讀到的一致。
public enum BuildInfo {

    public static func stamp(from info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        // `as?` 對型別不符一律回 nil，所以「鍵不存在」與「型別不對」在這裡自動
        // 走同一條路——那正是要的：兩者都表示建置腳本沒把事做對。
        let version = info?["FMSourceVersion"] as? String
        let commit = info?["FMSourceCommit"] as? String

        // 預設 true 是安全方向：寧可把發布版標成 (dev)（難看），也不要把含未提交
        // 改動的開發建置標成發布版（會讓人拿它當發布產物判斷問題）。
        let isDevelopment = info?["FMIsDevelopmentBuild"] as? Bool ?? true

        return BuildStamp.display(version: version,
                                  commit: commit,
                                  isDevelopment: isDevelopment)
    }
}
