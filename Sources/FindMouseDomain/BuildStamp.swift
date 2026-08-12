// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

/// 建置身分的呈現。**這是這個功能唯一有判斷的地方**——`FindMouseApp` 沒有測試
/// target，所以設定視窗那一列裡不能有任何條件；Adapters 只負責把 plist 的值取出來。
///
/// 三個原料由建置腳本寫進 Info.plist：`make-app.sh` 寫 `git describe` 的輸出並標
/// development，`release.sh` 寫使用者給的版本號與 sha 並標非 development。
/// `Scripts/Info.plist` 裡的 `CFBundleShortVersionString` 是佔位符（寫死 `0.1.0`），
/// 刻意不參與這條路。
public enum BuildStamp {

    /// - Parameters:
    ///   - version: 發布版是乾淨的版本號（`0.4.0`）；開發建置是
    ///     `git describe --tags --long --always --dirty` 的輸出（**已經含 sha**）。
    ///   - commit: 只有發布版會寫。開發建置不寫——describe 已經含 sha，而 describe
    ///     失敗時 `git rev-parse` 的失敗條件相同（都要 repo ＋ commit），補不上。
    ///   - isDevelopment: 缺鍵或型別不對時，呼叫端一律給 `true`（見 `BuildInfo`）。
    public static func display(version: String?,
                               commit: String?,
                               isDevelopment: Bool) -> String {
        let version = present(version)
        let commit = present(commit)

        // 有版本字串時它就是基底。開發建置補 `(dev)` 而不是 sha：基底本身就是
        // describe 輸出、已經含 sha，再括號一次會讓同一個 sha 出現兩次。
        if let version {
            if isDevelopment { return "\(version) (dev)" }
            return commit.map { "\(version) (\($0))" } ?? version
        }

        // 沒有版本字串。發布版與開發版刻意用不同的字：一份自稱發布版卻不知道
        // 自己版本的產物是壞的，講「開發版」會讓那件事看起來正常。
        let base = isDevelopment ? "開發版" : "版本不明"
        return commit.map { "\(base) (\($0))" } ?? base
    }

    /// 空字串與缺鍵是同一件事。腳本寫入失敗可能是任一種形態
    /// （`PlistBuddy` 寫入失敗、或 `git describe` 回空字串），
    /// 讓它們走不同分支等於同一個故障有兩種畫面。
    private static func present(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
