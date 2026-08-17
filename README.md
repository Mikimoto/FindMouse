# FindMouse

找不到滑鼠游標時，按一下快捷鍵，一隻貓從螢幕邊緣跑過來坐在游標旁邊。

macOS 選單列常駐程式。貓抵達之後會待一陣子、伸懶腰、打呵欠，最後蜷起來睡著；
游標移遠了牠會重新追過來。另有一個逗貓棒模式（⌥⌘T），貓會潛行、蓄力、撲向游標。

- 預設快捷鍵：**⌥⌘F** 召喚／收回、**⌥⌘T** 逗貓棒（皆可改）
- 需求：macOS 14 以上。自己建置才需要 Xcode／Swift 6

## 安裝

```sh
brew tap mikimoto/findmouse
brew install --cask findmouse
```

或到 [Releases](https://github.com/Mikimoto/FindMouse/releases) 抓 `.dmg`，掛載後
拖進「應用程式」。兩條路拿到的是同一個 `.app`：簽好章、notarize 過，Gatekeeper
不會擋，也不必右鍵開啟。

> **v0.5.0（含）以前發出去的 `.app` 裡沒有票**（notarization ticket）——票只釘在
> `.dmg` 上，而兩條安裝路徑拿到的都是從 dmg 取出來的 `.app`。它照樣過 Gatekeeper
> （實測 `spctl` 回 `accepted / Notarized Developer ID`），因為系統上網查得到紀錄；
> 但 Apple 自己的 `syspolicy_check` 對它回 `Notary Ticket Missing / Severity: Fatal`，
> 而離線首次啟動會不會被擋，本專案沒有能重現的機器可以測。
>
> `Scripts/release.sh` 已改成 `.app` 與 `.dmg` 各送審一次、兩邊都釘票，**下一版起
> 兩條路拿到的 `.app` 都自帶票**。已經裝好的 v0.5.0 想現在就補：
> `xcrun stapler staple /Applications/FindMouse.app`（票在 Apple 那裡，不必重新下載）。

更新是 `brew upgrade --cask findmouse`。

命令列工具是**分開的**，要用腳本控制才需要。它從原始碼建（`swift build` 本身約 6 秒，
透過 brew 連下載與檢查實測十幾秒），所以你的機器上要有 Xcode：

```sh
brew install findmouse-cli
```

移除用 `brew uninstall --cask findmouse`。**加 `--zap` 會連設定與你自己裝的 pack
一起刪掉**（`~/Library/Containers/tw.com.deepthought.findmouse/`，v0.5.0 以前
是 `~/Library/Application Support/FindMouse/`），要清乾淨才加。
而**開機啟動的註冊連 `--zap` 都清不掉**——那筆紀錄在系統手上，`brew` 碰不到。
先在設定視窗把那個勾關掉，或到「系統設定 → 一般 → 登入項目」移除。

## 建置與執行

```sh
swift build                      # 全部
Scripts/make-app.sh              # 組成可雙擊的 build/FindMouse.app（debug）
Scripts/make-app.sh release      # release 版
open build/FindMouse.app
```

CLI 是獨立的執行檔，透過 unix socket 與跑著的 App 溝通：

```sh
swift build --product findmouse
.build/debug/findmouse status
.build/debug/findmouse --help
```

```
summon | dismiss | toggle        叫貓咪 / 讓牠回家 / 切換
teaser on | off | toggle         逗貓棒模式
status                           目前狀態
config get [key] | set <k> <v> | reset <k>|--all
pack list | use <id> | validate <path>
pack install <path> [--force]     裝一套別人做的圖組（.fmpack、.zip 或目錄）
pack remove <id>                  移除一套自己裝的
login-item [on|off]              開機時是否啟動（不帶動詞就是查詢）
```

所有命令都吃 `--json`。exit code：`0` 成功、`1` 命令失敗、`2` 用法錯誤、`3` App 沒在跑。

`config` 的每一項在設定視窗裡也改得到，走的是同一份驗證：常用的 8 項在主視窗，
其餘 15 項在「進階設定…」開的獨立視窗——滑桿可以邊拖邊看貓，而那個視窗與主視窗
能同時開著。CLI 適合的是把一組值一次改完，或寫進腳本。

`toggle` **不是幂等的**——自動化請用方向明確的 `summon` / `dismiss`。

## 測試

```sh
mise tasks                       # 列出全部
mise run check                   # 單元測試 ＋ 素材管線（快的那兩層）
mise run e2e                     # 端對端：真的啟動 .app、真的跑 CLI
mise run mutate -- <批次.json>    # 突變測試
```

沒有 [mise](https://mise.jdx.dev) 也不影響——`mise.toml` 裡就是原始指令，直接抄來跑即可。
指令只寫在那一個檔案裡，這份 README 不重複列，免得兩邊漂掉。

`e2e.sh` 用自己的 `FINDMOUSE_SOCKET`，不會干擾你正在跑的那一份。它有第三種結果
「無法判定」——某些斷言需要獨占游標，你在同一台機器上動滑鼠時它會如實說「沒證明」
而不是誤報通過。

## 自己發一份

需要 Developer ID 憑證與一組存好的 notarytool profile（一次性）：

```sh
xcrun notarytool store-credentials findmouse-release
```

`store-credentials` 是互動式的，要在真的終端機裡跑。它問的密碼是
**app-specific password**（appleid.apple.com 產生的那種），不是 Apple ID 的登入密碼
——填錯會回 `HTTP status code: 401`。也可以改用 App Store Connect API key
（`--key`／`--key-id`／`--issuer`），對 `release.sh` 來說沒差別，它只認得 profile 名稱。

發布是五步，**順序有相依**：

```sh
# 1. 建置 → 簽 → notarize .app → 釘票 → 打 dmg → notarize dmg → 釘票 → 驗收 → 打本機 tag
#    要等 Apple 兩次（票按 cdhash 發，.app 與 dmg 各要一張）
mise run release -- <版本> --profile findmouse-release

# 2. 推 tag。release.sh 刻意不自動推：本地打錯是 git tag -d 一行，
#    遠端要 push 刪除 ref，而中間可能已經有人抓下去了
git push origin v<版本>

# 3. 發 Release（cask 的下載連結指向這個 asset）
gh release create v<版本> build/FindMouse-<版本>-<sha>.dmg --verify-tag --notes-file <某個檔>

# 4. 更新 tap。cask 的 version／sha256 由 release.sh 印出；
#    formula 的 tarball sha256 要等 step 2 之後才算得出來，release.sh 也把命令印給你
#    → https://github.com/Mikimoto/homebrew-findmouse

# 5. 快進 main。tag 打在 dev 上，而 main 是預設分支——首頁該與發出去的東西一致
git push origin dev:main
```

第 1 步會自己驗自己的產出，包含**加上隔離屬性再驗一次**——那是唯一測得到
「使用者從網路下載會不會被擋」的方式。任一條紅，整個發布視為失敗。它打的 tag 指向
**被建置的那個 commit** 而不是當下的 HEAD（notarize 要等 Apple，那段窗口裡 HEAD 會動）。

**v0.5.1 的 step 4 還要改一樣東西**：cask 的 `zap trash:` 目前列的是
`~/Library/Application Support/FindMouse`，而沙盒化之後使用者的圖組與設定都住在
`~/Library/Containers/tw.com.deepthought.findmouse`。兩個都要列——舊位置對
「從 v0.5.0 以前升上來、但沒按過設定裡那個『搬過來…』」的人仍然有東西。
沒改的話 `--zap` 會清掉一個空目錄然後說完成，而使用者的 pack 與設定原封不動留著。

只驗一個既有的 dmg：`Scripts/release.sh --verify-only <某個.dmg>`

驗收會掛載 dmg、對**裡面那個 `.app`** 也跑一遍（包含 `stapler validate` 與 Apple 的
`syspolicy_check distribution`）——因為使用者實際執行的是它，不是 dmg。拿 v0.5.0 的
dmg 當正控制實測過：只有那兩條 `.app` 相關的紅，其餘全綠。

### `main` 什麼時候可以動

`main` 是預設分支，也就是陌生人的第一站，所以它只有兩個前進的時機：

1. **發布**（上面第 5 步）。
2. **對已發布事實的文件修正**——例如發現 README 對已出貨的版本說了假話。

**不要因為 dev 前進就快進 main。** 那會讓首頁描述還沒有任何 Release 具備的功能
（例如 `pack install` 在 C2 合併後、v0.4.0 發布前那段時間）。發過哪些版看
`gh release list`，不是看 `main` 的 log。

## Sprite pack

貓的外觀是一套 **sprite pack**：一個目錄加一份 `pack.json`，宣告 14 組動作
（core 4 ／ flourish 5 ／ teaser 5）與 `anchor`（腳底中心在畫布上的相對座標）。

```sh
findmouse pack list
findmouse pack use <id>
findmouse pack validate <路徑>    # 與 install 吃一樣的東西
findmouse pack install <路徑>     # .fmpack、.zip 或一個目錄
findmouse pack remove <id>
```

- 內建：`mycat`（出廠預設，就是那隻貓）、`test-blocks` 與 `test-blocks-tall`（開發用的色塊）
- 使用者的：`~/Library/Containers/tw.com.deepthought.findmouse/Data/Library/Application Support/FindMouse/Packs/<id>/`
- 缺 flourish 只會降級，缺任一 teaser 則逗貓棒不可用，缺 core 則整套無效

那一長串是 App 的沙盒容器。**不必自己打**——設定視窗的「顯示資料夾」會直接開到
那裡。FindMouse 從 v0.5.1 起在沙盒裡跑，而沙盒把「應用程式支援」重導進容器。

### 從 v0.5.0 以前升級上來，圖組不見了

沒有不見，只是它們還在舊位置（`~/Library/Application Support/FindMouse/Packs/`），
而沙盒版沒有權限讀那裡。**設定不受影響**——那是 macOS 自己搬的，圖組沒有人替你搬。

打開設定，圖組清單下面會有一行「舊版放的圖組還在原本的位置」加一個「搬過來…」。
按下去選那個資料夾（面板已經幫你指好了），按「授權並搬移」——那個選取動作就是
授權，FindMouse 要有它才讀得到。新家已經有同 id 的一律跳過不覆蓋。

舊資料夾**不會被刪**，確認搬好之後可以自己清掉。

### 裝別人做的一套

三個入口，做的是同一件事：

- **拖進設定視窗**——打開設定，把 `.fmpack` 或 pack 資料夾拖到圖組區的虛線框裡
- **雙擊 `.fmpack`**——FindMouse 會接手，設定視窗會打開並顯示結果
- **命令列**——`findmouse pack install <路徑>`，吃 `.fmpack`（就是 zip）、`.zip`、
  或已經解開的目錄

id 取自 `pack.json` 而不是檔名，所以下載時被瀏覽器改過名也沒關係。三件會被擋下：

- **同 id 已經裝過** → 要加 `--force` 才覆蓋
- **id 與內建的撞名** → 一律拒絕，`--force` 也不例外。理由不是權限而是**裝了不會
  生效**：同 id 時內建那套優先，你裝進去的永遠不會被載入。改一個 id 就好
- **正在使用中的那套要移除** → 先換成別的再移除。不自動幫你切走：
  換 pack 是非同步的，切換還沒發生就把目錄刪掉會讓貓靜默變回內建那套

移除：設定視窗裡每套自己裝的圖組旁邊有「移除」，或 `findmouse pack remove <id>`。
設定視窗還有一個「顯示資料夾」，直接開到上面那個 Packs 目錄。

### 做一套自己的圖組拿去給人

`python3 tools/pack-fmpack.py <pack 目錄>` 打包成 `.fmpack`。它會**先跑一次
`findmouse pack validate`**（所以 FindMouse 要在執行中），過了才打包——不合格的
pack 打出來也沒有人裝得起來。沒有跳過驗證的旗標；真的只想壓縮就用 `ditto -c -k`。

`tools/` 是把 AI 生圖的橫排多格圖變成一套 pack 的後處理管線
（切格 → chroma key 去背 → 統一畫布 → 對齊腳底線 → 產 manifest），
詳見 [`tools/README.md`](tools/README.md)。生圖那一側的操作在
`docs/superpowers/plans/2026-08-08-m6-asset-generation-guide.md`（不進版控）。

## 架構

依賴方向只能往內。這條規則由 `Tests/FindMouseDomainTests/ArchitectureBoundaryTests.swift`
的 import 允許清單強制執行，不是靠自律。

```
FindMouseDomain     純函式與型別（只准 Foundation / CoreGraphics）
FindMouseCore       狀態機與 use case（＋ Domain）
FindMouseAdapters   AppKit / CALayer / 檔案系統
FindMouseWire       CLI 與 App 的 JSON 契約（不准碰 Domain）
FindMouseCLICore    參數解析與輸出格式（只准 Wire）
FindMouseApp        NSApplication、overlay、快捷鍵
```

設計文件（`docs/superpowers/`）**不進版控**，只存在於作者本機。

## 授權

Apache License 2.0，見 [`LICENSE`](LICENSE)。

Copyright 2026 Mikimoto
