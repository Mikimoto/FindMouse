// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// pack 的大小上限。**住在 Wire 是因為兩端都要它。**
///
/// App 用它拒絕過大的 pack（`PackInstaller.install`），CLI 用它決定「值不值得先
/// 把來源複製進容器」（`SourceStaging.exceedsByteLimit`）。兩份數字會漂，一份不會
/// ——而漂掉的症狀不是錯誤訊息，是 CLI 花好幾分鐘複製一份 App 接下來一定會拒絕
/// 的東西。同一個理由讓 `ControlSocket` 也住在這裡：兩端要得到同一個答案。
public enum PackLimits {

    /// 解壓後的大小上限。
    ///
    /// CLI 那一側量的是**來源**（zip 是壓縮後的、目錄是原尺寸），兩者都不會大於
    /// 解壓後的大小，所以 CLI 這一關永遠比 App 寬：它只擋得掉「明顯不是一套圖組」
    /// 的東西，真正的判定仍然在 App，而且不會拒絕任何 App 會接受的來源。
    public static let byteLimit = 200 * 1024 * 1024
}
