# FindMouse

找不到滑鼠游標時，按一下快捷鍵，一隻貓從螢幕邊緣跑過來坐在游標旁邊。

macOS 選單列常駐程式。貓抵達之後會待一陣子、伸懶腰、打呵欠，最後蜷起來睡著；
游標移遠了牠會重新追過來。另有一個逗貓棒模式（⌥⌘T），貓會潛行、蓄力、撲向游標。

- 預設快捷鍵：**⌥⌘F** 召喚／收回、**⌥⌘T** 逗貓棒（皆可改）
- 需求：macOS 14 以上、Swift 6

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
```

所有命令都吃 `--json`。exit code：`0` 成功、`1` 命令失敗、`2` 用法錯誤、`3` App 沒在跑。

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

## 安裝已簽章的版本

`build/FindMouse-<版本>-<sha>.dmg` 是簽好章、notarize 過、釘上票的產物：
掛載、拖進「應用程式」、雙擊，Gatekeeper 不會擋，也不必右鍵開啟。

自己做一份（需要 Developer ID 憑證與一組存好的 notarytool profile）：

```sh
xcrun notarytool store-credentials findmouse-release   # 一次性
mise run release -- 0.2.0 --profile findmouse-release
```

它跑完會自己驗自己的產出——包含加上隔離屬性再驗一次，那是唯一測得到
「使用者從網路下載會不會被擋」的方式。任一條紅，整個發布視為失敗。

只驗一個既有的 dmg：`Scripts/release.sh --verify-only <某個.dmg>`

## Sprite pack

貓的外觀是一套 **sprite pack**：一個目錄加一份 `pack.json`，宣告 14 組動作
（core 4 ／ flourish 5 ／ teaser 5）與 `anchor`（腳底中心在畫布上的相對座標）。

```sh
findmouse pack list
findmouse pack use <id>
findmouse pack validate <目錄>
```

- 內建：`mycat`（出廠預設，就是那隻貓）、`test-blocks` 與 `test-blocks-tall`（開發用的色塊）
- 使用者的：`~/Library/Application Support/FindMouse/Packs/<id>/`
- 缺 flourish 只會降級，缺任一 teaser 則逗貓棒不可用，缺 core 則整套無效

`tools/` 是把 AI 生圖的橫排多格圖變成一套 pack 的後處理管線
（切格 → chroma key 去背 → 統一畫布 → 對齊腳底線 → 產 manifest），
詳見 [`tools/README.md`](tools/README.md)。生圖那一側的操作在
[`docs/superpowers/plans/2026-08-08-m6-asset-generation-guide.md`](docs/superpowers/plans/2026-08-08-m6-asset-generation-guide.md)。

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

設計文件：[`docs/superpowers/specs/2026-08-05-findmouse-design.md`](docs/superpowers/specs/2026-08-05-findmouse-design.md)
