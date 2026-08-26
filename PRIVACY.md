# FindMouse 隱私政策

最後更新：2026 年 8 月 26 日

## 簡短版

FindMouse 不會把任何東西傳出去——它沒有網路能力。你的設定與圖組只留在你自己的電腦上。

## 我們收集什麼

沒有。FindMouse 不收集、也不傳輸任何個人資料或使用資料。

它確實會在你的電腦上留兩樣東西——你的設定，以及你自己安裝的圖組——但那些從不離開這台
機器，也不會被我們或任何第三方讀到。細節見下面〈存在你電腦上的東西〉。

## 網路連線

FindMouse 沒有網路存取能力。它在 macOS 的 App Sandbox 中執行，而它的
entitlements 沒有包含任何網路權限。這不是一個「我們選擇不傳送」的政策，
而是這個程式在技術上做不到——即使它想傳，作業系統也會拒絕。

App 中不含任何分析、遙測、廣告或崩潰回報的第三方套件。

## 追蹤

沒有。FindMouse 不追蹤你，也不與任何資料仲介或廣告網路共享資料。
它的隱私資訊清單（`PrivacyInfo.xcprivacy`）中，追蹤旗標為 `false`、
追蹤網域清單為空、收集的資料類型清單為空。

## 存在你電腦上的東西

FindMouse 會把你的設定（快捷鍵、聚光燈開關、打瞌睡的時間、目前選用的圖組）
存在 macOS 的標準偏好設定機制中，以及你自己安裝的圖組檔案。兩者都存放在
FindMouse 自己的 App 沙盒容器內，只有你這台電腦上的這個帳號讀得到。
你可以隨時刪除它們。

## 檔案存取權限

FindMouse 只請求一項檔案權限：對「你自己選擇的檔案」的唯讀存取。
它只用在一個地方——當你從 v0.5.0 之前的版本升級上來、需要把先前放在
沙盒之外的圖組搬進新位置時，系統會請你在檔案選擇視窗中授權。
如果你沒有舊版圖組，這個權限永遠不會被用到。

## 兒童

FindMouse 不含任何針對兒童的功能，也不收集任何人的資料，包含兒童。

## 這份政策的變更

若這份政策有變更，會更新每個語言版本最上方的「最後更新」日期。

## 聯絡

有隱私相關的問題，請開一個 issue：
<https://github.com/Mikimoto/FindMouse/issues>

---

# FindMouse Privacy Policy

Last updated: 26 August 2026

## Short version

FindMouse sends nothing anywhere — it has no network access. Your settings and sprite packs
stay on your own Mac.

## What we collect

Nothing. FindMouse does not collect or transmit any personal or usage data.

It does keep two things on your Mac — your settings and any sprite packs you install — but
neither ever leaves the machine, and neither is readable by us or any third party. See
"What lives on your Mac" below.

## Network access

FindMouse has no network access. It runs inside the macOS App Sandbox, and its
entitlements contain no networking permission of any kind. This is not a policy
of choosing not to send data — the app is technically unable to; the operating
system would refuse.

The app contains no analytics, telemetry, advertising, or crash-reporting
third-party library.

## Tracking

None. FindMouse does not track you and shares nothing with data brokers or ad
networks. In its privacy manifest (`PrivacyInfo.xcprivacy`) the tracking flag is
`false`, the tracking-domain list is empty, and the collected-data-type list is
empty.

## What lives on your Mac

FindMouse stores your settings (shortcuts, the spotlight toggle, how long before
the cat dozes, the currently selected sprite pack) in the standard macOS
preferences mechanism, plus any sprite packs you install yourself. Both live
inside FindMouse's own App Sandbox container, readable only by this account on
this Mac. You can delete them at any time.

## File access

FindMouse requests exactly one file permission: read-only access to files you
pick yourself. It is used in one place — when you upgrade from a version before
v0.5.0 and choose to migrate sprite packs from their old, pre-sandbox location,
macOS asks you to grant access through a file picker. If you have no old sprite
packs, this permission is never exercised.

## Children

FindMouse has no features directed at children, and collects no data from
anyone, children included.

## Changes to this policy

If this policy changes, the "Last updated" date at the top of each language version will be
updated.

## Contact

For privacy questions, please open an issue:
<https://github.com/Mikimoto/FindMouse/issues>
