# FindMouse — 給 Claude 的工作守則

專案介紹在 `README.md`，設計權威在 `docs/superpowers/specs/2026-08-05-findmouse-design.md`。

> **`docs/superpowers/` 不在版控裡**（2026-08-11 連同歷史一起清除，見 `.gitignore`）。
> 本檔以下所有指向它的路徑都是**作者本機的檔案**——在乾淨的 clone 裡不存在，
> 備份由作者自行安排。讀不到那些檔案時不要當成專案壞掉，改問使用者要。
本檔只記**從程式碼看不出來、而且踩過會浪費時間**的東西。

## 先讀哪一份

| 情境 | 讀 |
|---|---|
| 任何行為問題（狀態機、時序、契約） | spec，它是權威；程式碼與 spec 衝突時先確認哪一邊該改 |
| 動 `tools/` 或素材管線 | `tools/README.md` |
| 要生新的貓素材 | `docs/superpowers/plans/2026-08-08-m6-asset-generation-guide.md` |
| 想知道某個里程碑做了什麼、驗到哪 | `docs/superpowers/plans/*-completion.md` |

## 驗證

指令的**唯一真實來源是 `mise.toml`**——`mise tasks` 列得出來，這裡不重複抄，
免得兩邊漂掉。常用的是 `mise run check`（unit ＋ 素材管線）與 `mise run e2e`。

`mise.toml` **刻意沒有 `[tools]` 區段**：Swift 來自 Xcode（本機只能用 27.0 的 beta，
最後一個正式版 26.6 在 macOS 27 上跑不動），而 Python 必須維持系統那一份——`tools/`
的 Pillow 與 SciPy 裝在它上面，讓 mise 換一個 python 進來會讓素材管線立刻找不到套件。
要知道當下是哪一個 beta 就跑 `xcodebuild -version`，別在文件裡存第二份。

- **`FindMouseApp` 沒有測試 target**。那一層的東西只有 `e2e.sh` 驗得到。
- **`e2e.sh` 有三種結果**，第三種是「無法判定」。某些斷言需要獨占游標，使用者
  在動滑鼠時它會如實說「沒證明」。把「無法判定」讀成通過就是自欺。
- **跑 e2e 的那個終端機必須有「完全取用磁碟」。** 沒有的話 macOS 擋掉所有對
  `~/Library/Containers/tw.com.deepthought.findmouse/` 的存取（**連 `ls` 都
  `Operation not permitted`**），而 pack 的家就在裡面：`make_pack` 一路 EPERM，
  收尾報一堆失敗，沒有一條與程式碼有關（2026-08-19 實測 49 過 36 敗）。
  兩個判別訊號：訊息裡有 `Operation not permitted`，以及 `defaults read
  tw.com.deepthought.findmouse pack.id` 回 `Domain ... not found`（`defaults`
  走的是 cfprefsd，同樣被擋）。**這不是「無法判定」那一態**——它會如實印 ✗。
  授權在「系統設定 → 隱私權與安全性 → 完全取用磁碟」，加的是終端機 App 本身
  （本機是 Ghostty），改完要重開終端機。
- **`Scripts/test-release.sh` 對陳舊的 `build/FindMouse.app` 只有第 9 段會自己重建。**
  一次中途失敗的 `make-app.sh`（例如停在簽章前的某個守衛）會留下一個沒簽章、少檔案
  的半成品，而其餘幾段只在**目錄不存在**時才建——於是它們會報一堆與你的 diff 完全
  無關的紅。判別訊號：訊息裡出現「對一份真的沙盒 .app 說不」這種自相矛盾的話。
  遇到就先 `Scripts/make-app.sh` 重建再重跑。
  （第 9 段的條件看的是**那個檔案**在不在而不是目錄，缺了就先重建一次——那是
  2026-08-20 的 review 指出來的，其餘幾段還沒跟上。）
- **`mise run e2e` 的輸出不要接 `| tail`。** 它的 exit code 會變成 `tail` 的，
  於是 `[e2e] ERROR task failed` 與 exit 0 同時出現。要壓縮就先落檔再讀。
- **突變的判讀是三態**：紅（含 crash）／綠／編不過。`grep -c FAIL` 回 0 有兩種
  成因——全綠，與根本沒跑。每一批 `mutate.py` 會自動附 no-op 對照組，它若不是
  全綠，整批結果不可採信。
- 架構的 import 允許清單由 `Tests/FindMouseDomainTests/ArchitectureBoundaryTests.swift`
  強制。它擋不住刻意規避（一行兩個 import、跨行），那不是它的目的。
  **`swiftUIStaysInTheSettingsWindow` 是精確相等**（不是 contains）：新增一個 import
  SwiftUI 的檔案就編得過但測試紅，要回去那條清單登記檔名。放寬成 contains 之後
  SwiftUI 擴散就不再有任何訊號，那條測試也就不守任何東西了。

## 會咬人的地方

- **`Scripts/make-app.sh` 一次只建一個 product。** `swift build --product A --product B`
  不是「兩個都建」，後面那個把前面的蓋掉——`.app` 裡會裝著上一次剛好還留在
  `.build` 裡的舊執行檔，而且沒有任何錯誤訊息。判斷「我的修改有沒有進到跑起來的
  那個東西」唯一可信的是**比對產物的雜湊**，不是 mtime、也不是看建置有沒有印錯誤。
- **出貨的是 universal binary（arm64 ＋ x86_64），旗標在 `make-app.sh` 的 `ARCHS`。**
  SwiftPM 預設只建當前架構，而開發機是 Apple Silicon——所以 arm64-only 出貨在
  本機**完全沒有訊號**：`.app` 照組、e2e 照綠、`codesign` 照過、ASC 照收、審查照過。
  只有 Intel 使用者會發現，而那時東西已經在 App Store 上了（2026-09-01 實際發生：
  使用者在 macOS 26.6.2 的 Intel Mac 上看到「與此裝置不相容」、連下載鍵都沒有）。
  **那個訊息完全不提 CPU**，第一直覺會去查系統版本需求，而 ASC 上那個 build 的
  `lsMinimumSystemVersion` 是 14.0——查得到、也對，於是死路一條。判別法是
  `lipo -archs <.app>/Contents/MacOS/FindMouse`。
  `make-app.sh` 在簽章前有一道 lipo 守衛擋這件事（拿掉 `--arch x86_64` 實測會紅）。
  兩件連帶的：**`--show-bin-path` 也要帶同一組旗標**（不帶的話回的是
  `.build/arm64-apple-macosx/<config>`，帶了是 `.build/out/Products/<Config>`，
  兩個目錄同時存在且都有產物——`e2e.sh` 取 CLI 路徑那行就是為此同步的）；
  而 CLI 走 Homebrew formula 從原始碼建，不受影響。
- **同時只能有一個 FindMouse 實例。** 身分是 unix socket，第二個實例會自己退出。
  測試前要斷言零個實例，不能「殺完就當作乾淨」；`pgrep -f <路徑片段>` 比
  `pgrep -x <名字>` 可靠（bundle 內執行檔名與 SwiftPM 產物名不同）。
  **但「零個實例」不是唯一的路**——身分既然是 socket，給不同的 socket 就是不同的
  身分，可以與使用者自己那份（`/Applications`，常常正在跑）共存，`e2e.sh` 的
  `launch_app` 就是這樣做的。要驗開發建置時**不要去殺使用者的實例**。

  **那條路徑不能放 `/tmp`。** 沙盒下在 `/tmp` bind 回 `errno 1`（EPERM，2026-08-17
  實測；不沙盒時成功，所以是沙盒擋的）。要放進 App 自己的容器：

      open -n --env "FINDMOUSE_SOCKET=$HOME/Library/Containers/tw.com.deepthought.findmouse/Data/dev-$$.sock" <某個.app>

  **同一個容器內靠檔名隔離仍然成立，靠目錄隔離不成立**——App 只寫得進自己的容器，
  而所有實例共用同一個容器（容器以 bundle id 為鍵），所以只能靠檔名分開。
  收工要照 e2e 那兩支的分工：`launch_app`（`e2e.sh`）用 before/after 的 `pgrep`
  差集記下**自己啟動的 pid**，`kill_started` 只殺那些、並等到它們真的不在了
  才繼續（不寫行號是因為它們漂過一次而沒人發現，函式名 grep 得到）。那個差集有個
  已知邊界：它會收養 `open` 之後 2 秒內出現的**任何**實例，所以「只殺自己的」
  在那個窗口內有別人啟動時不成立。
  **不要用 `pkill -f <路徑片段>`**——路徑片段是相對的，它會匹配**任何** worktree 的
  `build/FindMouse.app`，連另一個 session 的實例一起殺，正是這條要避免的事。
- **出貨的 pack 只有 `mycat` 一套，而且是精確相等釘住的。** 開發用的色塊
  2026-08-19 從 `Sources/FindMouseAdapters/Resources/Packs/` 搬到
  `Tests/FindMouseAdaptersTests/Fixtures/`——0.2.0 就是連色塊一起出貨的，使用者
  在圖組選單裡看得到，其中一套還顯示「缺少逗貓棒動作」。
  `release.sh` 的守衛從「預設那套在不在」改成**目錄集合恰好等於
  `PackDefaults.factory`**，所以多放一套進去會擋住發版，不是靜默出貨。
  色塊搬走之後就沒有自然出現的反例了，`test-release.sh` 第 8 段因此是**永久的**
  負向對照組：它對「組好的 `.app` 的拋棄式複本」種一個帶 `pack.json` 的誘餌
  （用 `/usr/bin/ditto` 複製，不是 `cp -R`），並**先正面確認誘餌真的種進去**
  才看守衛的反應。不要改成種進 `Sources/`——誘餌是 untracked，乾淨工作樹檢查會
  先擋下來，紅的就變成「工作樹不乾淨」而不是精確相等那一條。
  e2e 要色塊時自己用 `make_pack` 現做（`e2e-` 前綴，收工只刪自己造的）。
- **圖示是建置產物，repo 裡沒有 `.icns`。** `Scripts/icon.svg` 是唯一來源，
  `Scripts/make-icon.swift` 渲染 10 個尺寸再 `iconutil` 打包，由 `make-app.sh`
  在**簽章之前**呼叫——排在後面的話 `codesign --verify` 會報 `resource added`，
  而那個訊息一個字都不會提到圖示。檔名讀的是**已複製進 `.app` 的那份 plist**
  的 `CFBundleIconFile`，不是 `Scripts/Info.plist`：出貨的是複本，而這支腳本與
  `release.sh` 都會對複本下 PlistBuddy。
  實測值得記的一件：**`NSImage` 在這個 macOS 上把 SVG 當向量畫**——直接畫 1024
  的邊緣過渡是 0px，從 128 放大上去是 6px。所以不必準備多份點陣來源。
- **每一種建置都是沙盒的**（v0.5.1 起）。`make-app.sh` 收尾會 ad-hoc 簽章並帶上
  `Scripts/FindMouse.entitlements`——不簽的話 e2e 從頭到尾都沒在測沙盒，而那正是
  它該測的東西。App 自己也會查（`ControlSocket.isInOwnContainer`），不在容器裡就在
  選單列掛一筆降級提示。

  **那個提示講的不是 socket。** CLI 照樣連得上——兩端都用 `ControlSocket.path`，
  它從 `getpwuid` 算起、不被沙盒重導，而 `UnixSocketServer.start()` 還會自己把那個
  目錄建出來。壞掉的是**資料的家**：非沙盒建置的 `NSHomeDirectory()` 是真家目錄，
  於是 pack 與設定讀寫的是沙盒之前的位置。也就是說那份建置看起來一切正常，
  卻在讀寫舊世界——拿它驗沙盒行為會得到一個什麼都沒驗到的綠。

  **entitlement 清單由測試釘成精確相等**（`theSandboxEntitlementsAreExactlyTheOnesWeCanJustify`）。
  加一個就紅，那是刻意的：每一個都要說得出「哪一個實測失敗需要它」。目前兩個，
  第二個的來歷值得記——**`NSOpenPanel` 需要 `files.user-selected.read-only`，
  而少了它面板不是報錯，是根本不出現**：`runModal()` 當場回 `.cancel`、`url` 是 nil，
  與使用者按取消一個字都不差（2026-08-17 實測，log 裡 `openAndSavePanelService`
  起來 4ms 後就 `xpc_connection_cancel()`）。雙擊與拖放不需要它——那兩條各自有
  LaunchServices／拖放發的 sandbox extension，**powerbox 是第三個機制、不吃那兩張票**。
  把前者的結論套到後者身上，就是這個 bug 的成因。
- **pack 的家在容器裡**：`~/Library/Containers/tw.com.deepthought.findmouse/Data/Library/Application Support/FindMouse/Packs`。
  程式碼不必自己組——`applicationSupportDirectory` 在沙盒下就指向那裡。要**舊家**
  才得自己算（`PackCatalogRepository.legacyUserPacksDirectory`，走
  `ControlSocket.realHome`：`getpwuid` 不被沙盒重導）。

  **設定會自動搬，pack 不會。** `cfprefsd` 認得容器並替你搬（2026-08-17 實測：
  舊 plist 直接消失，是搬不是複製），而 `Application Support` 底下就只是檔案。
  所以同一次沙盒化，設定安然無恙、圖組整批消失——這個不對稱猜不到。
  搬移只能靠使用者在 `NSOpenPanel` 授權（`AppDelegate.runLegacyPackMigration`），
  搬完在 `Packs/.legacy-migration-done` 落一個記號，否則那一列提示每次啟動都回來
  （授權只活在那一個 process 裡，下次開 App 偵測器又為真）。
- **CLI 的 `pack install`／`validate` 會先把來源複製進容器**（`SourceStaging`）。
  App 讀不到 CLI 遞過來的裸路徑——雙擊與拖放有 extension，socket 上的一個字串沒有。
  所以 App 看到的路徑與你在命令列打的不是同一個。容器的 `tmp/fm-cli-<pid>/` 在
  **那個 CLI 還在等回應時本來就存在**（收到回應才刪），所以看到一個不代表出過事；
  `kill(pid, 0)` 回 ESRCH 的那些才是被 SIGKILL 留下的，下一次 CLI 啟動會掃掉。
- **`/Applications/FindMouse.app` 現在由 Homebrew cask 管**（2026-08-14 起）。
  兩個後果：驗 cask 時不要裝進 `/Applications`（用
  `brew fetch --cask <tap>/findmouse`——它下載並驗 sha256 但**不安裝**，2026-08-17
  實測快取檔的雜湊與本機建的 dmg、cask 宣告的值三者相同，這已經是「tap 送出去的
  東西對不對」的完整答案）。

  **不要用 `brew install --cask --appdir="$(mktemp -d)"` 當沙盒。** 那條路只在
  cask **沒裝過**時是安全的；已經裝了的話 brew 把它當**升級**，會先
  `==> Removing App '/Applications/FindMouse.app'`（brew 的原句，路徑帶單引號）
  再把新版放進 `--appdir`，接著你為了收拾而跑的 `brew uninstall --cask <tap>/findmouse`
  就把那份也清掉——使用者最後一個 app 都沒有，而且
  正在跑的那個 process 從此指著一個被刪掉的 bundle（`findmouse pack list --json`
  的 `data.packs` 變成空陣列，因為它連自己的三個內建 pack 都讀不到了——那是
  「這個實例已經廢了」最快的判別法）。2026-08-17 實際造成過一次，
  復原是 `brew install --cask <tap>/findmouse` 重裝，然後請使用者重開 App。
  真的要驗「裝進去長什麼樣」就直接 `brew upgrade --cask <tap>/findmouse`——它結束在
  一個好的狀態，而不是一個要你自己收拾的狀態。

  以及**永遠不要跑 `brew uninstall --cask --zap`**
  ——`zap` 的路徑是絕對路徑，會刪掉使用者真正的圖組與設定，而 `brew uninstall`
  **沒有 `--dry-run`** 可以先看（實測回 `Error: invalid option`）。
  要移除就用不帶 `--zap` 的版本。
  （那份 `zap` 清單在 v0.5.1 那一輪補齊了**三條**——容器、舊的
  `Application Support/FindMouse`、舊的 plist。**三條都要列，理由不對稱**：搬移是
  複製、刻意不刪原檔（README〈從 v0.5.0 以前升級上來，圖組不見了〉就是這樣寫給使用者的），所以
  只列新家會留下舊的、只列舊的會刪掉搬移功能存在要救的那一批又漏掉新家。理由寫在
  cask 那個區塊上面，改它之前先讀。）
- **`findmouse pack validate` 走 socket，App 必須在跑。** CLI 是薄用戶端，
  App 沒跑會回 `APP_NOT_RUNNING`（exit 3），那不是 pack 有問題。
- **`ditto -x -k` 會把 zip 裡的 `../x` 攤平到目標根目錄，不是拒絕它**
  （2026-08-12 實測：`../escaped.txt` 與 `../../escaped2.txt` 都落在目標目錄底下、
  exit 0）。所以匯入 pack 的安全性**不靠它**——靠「解到空暫存目錄之後只搬 pack 根
  底下的東西」（`ExtractedTree.installableEntries(under:)`）。那個守衛的測試是
  `onlyThePackRootIsInstalledNotTheStrayFiles`，**不是**釘 ditto 行為的那條：
  後者在「整個暫存目錄搬過去」這個突變下仍然通過（檔案確實沒逃出暫存目錄）。
  **但 pack 根是空字串時（`pack.json` 直接在 zip 根，也就是 Finder「壓縮所選項目
  的內容」的佈局）擋不掉夾帶的檔案**：那時「根底下」就是全部，而攤平後的
  `../escaped.txt` 與作者真的放在 pack 根的檔案無法區分，於是它會被裝進
  `Packs/<id>/`。守住的是「不會跑到 `Packs` 外面」，不是「裡面很乾淨」——邊界
  釘在 `aFlattenedStrayLandsInsideThePackWhenTheManifestSitsAtTheZipRoot`。
  macOS cruft（`__MACOSX/`、`.DS_Store`、`._*`）是另一回事，逐筆複製時濾掉了。
  順帶：`ditto` 也不驗證 zip 自報的未壓縮大小（改成 1 照樣解出真正的 1000 bytes），
  所以大小上限只能解壓後複查。
- **`.fmpack` 的型別宣告要兩個鍵，缺一不可。** `UTExportedTypeDeclarations` 只是
  宣告「世上有這個型別」，認領要靠 `CFBundleDocumentTypes` 的 `LSItemContentTypes`。
  2026-08-13 實測六個變體：只寫前者的話 `.fmpack` 會落到別的 app 手上；而
  `LSItemContentTypes` 指到一個**沒宣告過**的識別字時，系統**連預設 handler 都
  沒有**——不是退回別的 app，是查不到任何東西，比什麼都不寫更糟，且兩者在 plist
  上看起來一模一樣。`InfoPlistTests.everyClaimedDocumentTypeIsDeclared` 釘住它。
- **冷啟動時 `application(_:open:)` 比 `applicationDidFinishLaunching` 先到**
  （2026-08-13 實測差 0.3ms）。那個時間點 `pack`、`settingsForm`、`settingsWindow`
  全是 nil，當場處理必然什麼都不會發生**而且沒有任何訊號**。`AppDelegate` 因此把
  URL 收進 `pendingOpenURLs`，啟動走完才排空。App 已在跑時不會起第二個 process，
  事件直接送給既有實例——與單一實例守衛不衝突。
- **匯入與移除的判斷只有一份**：`PackLibraryUseCase`（Adapters）。`RequestRouter`
  與設定視窗都只是把它的 outcome 翻成自己的話。它**不回文字處方**——
  `needsConfirmation` 的下一步 CLI 是「加 `--force`」、GUI 是彈確認框，揉進訊息裡
  就沒有人能重用它。要加第四個入口就接這支，不要再抄一次那四步。
- **`findmouse pack validate` 對不合格的 pack 是 exit 1，而 body 是 `ok:true` /
  `valid:false`**（2026-08-13 實測）。兩件事同時成立，所以判「這套合不合格」要問
  `data.valid` 而**不是**看 exit code——先看 exit code 的話會落到「未知錯誤」那條
  退路，把整包原始 JSON 當訊息吐出去（`pack-fmpack.py` 實際踩過）。
- **`mutate.py` 只跑 `swift test`。** python 與 shell 那些工具的突變要手動做：
  先 commit，改，跑該工具自己的測試，`git checkout` 還原。
- **裝一套與內建同 id 的 pack 會「成功但永遠看不到」。** `PackCatalogRepository.scan`
  用 seen set 去重且內建目錄排在前面，所以 `pack.install` 對內建 id 一律回
  `PACK_ID_RESERVED`（與「移除內建」的 `PACK_BUILT_IN` 分開，處方不同），
  連 `--force` 都不給過。
- **目錄名與 `pack.json` 的 id 可以不一致，而清單是依 id 列的。**
  `PackCatalogRepository.scan` 列 manifest 的 id、去重也依它，而哪一個目錄贏得
  那一列由**目錄順序**（內建優先）與**同一個目錄內的名稱字典序**決定。
  所以「清單上這一列住在哪個目錄」不是看得出來的——要問
  `sourceDirectoryName(forID:in:)`，它刻意用同一個順序回答。移除走它，
  問不到才退回「目錄名 == id」（`pack.json` 讀不出來的垃圾目錄說不出自己是誰，
  而那正是使用者要清的）。**不要再寫「拿 id 當目錄名」的第二份**。
  2026-08-14 修掉之前 `remove` 就是那樣做的，四種後果都實測過：刪掉使用者
  **沒看到**的那一個而畫面說「已移除」／回「刪不掉」而該目錄從 GUI 與 CLI 都
  永遠拿不掉／不符的那個變成看不見的孤兒／id 撞內建時回 `PACK_BUILT_IN`。
  順帶：`PackInstaller.remove` 驗的是**單一路徑組件**而不是 `isValidID`，
  因為 `<id>.incoming` 含 `.`，照 `[a-z0-9-]+` 驗會讓那種殘留目錄永遠拿不掉。

  **`pack use` 沒有跟著改**（`directory(for:)` 仍拿 id 當目錄名）：那條路不刪
  東西，而名稱不符的 pack 本來就不合格、不可選。

  造得出名稱不符目錄的兩條路：手動放置（設定視窗那個「在 Finder 裡打開」按鈕的
  用途正是手動放置），以及半途失敗留下的 `<id>.incoming`——`PackInstaller.install`
  有三個清除點（下一次安裝同一個 id 的開頭、複製失敗、rename 失敗），**但 process
  被殺一個都不會跑**，也沒有開機掃除。

  第三條已經堵掉了，而**堵法值得記**：`install` 的目錄名來自呼叫端給的 id，那個 id
  是**上一次**讀取決定的，而複製迴圈是**又一次**讀取——來源在這幾次之間可被抽換
  （2026-08-14 用目錄型來源實測構造成功，3000 個檔案加一個 watcher，裝出目錄名
  `cat`／manifest id `mycat`，連 `PACK_ID_RESERVED` 都繞過去）。所以驗來源沒有用，
  驗完到複製完之間還有一段；現在驗的是**已經複製到 `.incoming` 的那一份**，
  中間沒有縫。保證的是「裝進去那個目錄的名字 == 它自己 manifest 的 id」，
  **不是**「內容來自同一次快照」——後者這個形狀的檔案複製給不了。
- **`URL.hasDirectoryPath` 只看路徑字串有沒有結尾斜線，不問檔案系統。**
  `URL(fileURLWithPath:)` 建出來的目錄 URL 通常沒有斜線，於是目錄會被當成 zip
  丟給 `ditto`（訊息是「Is a directory」）。要問就用 `isDirectoryKey`。
- **`toggle` 不是幂等的。** 腳本裡一律用 `summon` / `dismiss`。
- SwiftUI **只給設定視窗**。Overlay 維持純 AppKit ＋ CALayer——那裡有 spec 第 7.4 節
  的每帧預算，設定視窗一秒鐘畫不到一次。
- **`Scripts/Info.plist` 的版本值是佔位符。** `CFBundleShortVersionString` 寫死
  `0.1.0`、`CFBundleVersion` 寫死 `1`，只有 `release.sh` 會在**複製到 .app 裡的那份**
  寫真值。要判斷「手上這份 .app 是哪一版」看 `FMSourceVersion` /
  `FMSourceCommit` / `FMIsDevelopmentBuild` 三個鍵，或直接跑
  `findmouse status --json` 讀 `appVersion`——它與設定視窗右下角是同一串
  （同一支 `BuildInfo.stamp()`）。形狀是：發布版 `<版本> (<sha>)`、開發建置
  `<git describe 輸出> (dev)`、拿不到版本時 `開發版`。
- **`git describe --always` 不是萬用退路。** 它只涵蓋「有 repo、有 commit、
  沒有 tag」（退到裸 sha）。**完全沒有 `.git` 或零 commit 都是 exit 128**，
  腳本裡必須接非零（`make-app.sh` 的 `|| DESCRIBE=""`）。另外兩件實測：
  不加 `--long` 時，坐在 tag 上的 commit 回的是 `v0.3.1`、**不帶 sha**；
  而 `--long` 的 `-N-` 是**可達 commit 數**不是線性距離（tag 打在 `HEAD~3`
  實測回 `-61-`，因為 merge commit 帶進整條 feature 分支）。`-dirty` 只反映
  tracked 檔案的修改，untracked 不算。

  **而 `v0.2.0` 與 `v0.3.0` 不在任何分支上**（2026-08-11 那次連同歷史清掉
  `docs/superpowers/` 的重寫留下的孤兒），所以 `git describe` 從現行歷史看不到它們，
  `git branch --contains` 也回空的。要盤點「發過哪些版」只能用 `git tag -l`
  加 `gh release list`，不要從分支歷史推。
- **不要拿 `notarytool submit --wait` 的 exit code 當審查結果。** 它對「命令自己
  失敗」是有紀律的（實測：profile 不存在回 69、檔案不存在回 64、合約過期回 403 並
  非零），但「送出成功、而 Apple 判 `Invalid`」會不會也回非零，**本專案還沒實測過**。
  `release.sh` 因此改看它印出來的 `status: Accepted`——那個訊號兩種情況下都對，
  不必賭一個沒驗過的前提。
- **驗收命令不接管線。** `codesign ... | tail` 的 exit code 來自 `tail`，接了就
  每一條都通過。`release.sh` 的 `check()` 把輸出寫檔再讀，就是為了這個。
- **票是按 cdhash 發的，所以 `.app` 與 `.dmg` 要各自送審一次。** v0.5.0 以前只送
  dmg，於是**使用者實際執行的那個 `.app` 沒有票**——`syspolicy_check distribution`
  對它回 `Notary Ticket Missing / Severity: Fatal`（2026-08-17 實測；那是 Apple
  自己的發布就緒工具，macOS 14 起內建）。已在 `release.sh` 修掉：先把 `.app` 壓成
  zip 送審、釘票，再用釘好的那份打 dmg 送第二次。

  三件從文件看不出來、而且改變了成本估算的事：

  1. **notarize dmg 時 Apple 連裡面的 `.app` 一起發票。** 所以已經發出去的版本
     事後補得起來——直接對那份 `.app` 跑 `stapler staple` 就會成功，不必重發。
     但這救不了流程：票要等送審完才存在，而 `.app` 一被釘票，用它重打的 dmg 就是
     新的 cdhash、還是得再送一次。順序只能是「先釘 app，再打 dmg」。
  2. **釘票不動 cdhash**（實測前後逐字相同）——票寫進 `Contents/CodeResources`，
     不在簽章封印範圍內，`codesign --verify --deep --strict` 照樣過。
  3. **`spctl` 會吃 Gatekeeper 的評估快取，`syspolicy_check` 不會。** 所以在一台
     早就信任過這個 app 的機器上，「斷網再 `spctl` 一次」量不出東西，而
     `syspolicy_check` 直接給答案。兩者的 exit code 都分得開
     （`stapler validate` 0／65、`syspolicy_check` 0／70），可以直接當驗收判準。

  `release.sh` 的驗收因此多了兩條（`stapler validate app`、`syspolicy_check`），
  兩輪都跑。拿 v0.5.0 的 dmg 當正控制實測：**只有那兩條紅**、其餘全綠。
- **App Store 是第二條通路，不是 `release.sh` 的一個模式。** `Scripts/appstore.sh`。
  六項全不同：app 簽章身分（Apple Distribution 而非 Developer ID）、必須內嵌
  `Contents/embedded.provisionprofile`、另一份 entitlements（多兩個身分鍵）、
  容器是 `.pkg` 而非 `.dmg`、**不 notarize**（App Store 走審查）、驗收是
  `altool --validate-app`。共用的是 `make-app.sh`——兩條通路出貨的必須是同一個 App。

  `Scripts/appstore.sh --check` 只印前置條件、什麼都不做。2026-08-20 的狀態是
  **前置條件都到齊了**（兩張憑證、Mac App Store 的 Distribution 描述檔），而且整條線
  實走過一次：`appstore.sh 0.5.2` 出的 `.pkg` 送 `altool --validate-app` 回
  `VERIFY SUCCEEDED with no errors`。順帶回答了兩個掛很久的前提——**build number 的
  前導零過得了格式檢查**（`2026.0820.0552`；ASC 上顯示的值是另一回事，見下一段），
  而 `PrivacyInfo.xcprivacy` 帶著它通過驗證
  （只證明不會被拒，不證明必要）。

  **上傳與 processing 也走完了**（同日、重建自 `da9a653`，build `2026.0820.1137`）：
  `--upload-app` 回 `UPLOAD SUCCEEDED with no errors`，ASC 上那個 build 是 `VALID`。
  而 **ASC 顯示的字串與送上去的不一定相同**——`.pkg` 裡是 `2026.0820.1137`，ASC 回報
  的是 `2026.820.1137`，中間那段的前導零沒了。所以別拿它做字串比對，搜不到不等於沒
  上傳成功，以 ASC 自己顯示的值為準。

  **ASC 怎麼排序沒有實測，所以不替它下結論。** 這個欄位是「最多三段以句點分隔的非負
  整數」，逐段當整數比的話 `0820` 與 `820` 同值、排序不受影響；但字串比較下 `1001` 會
  排在 `905` 前面（10 月比 9 月舊），而 ASC 走哪一種沒人量過——寫「應該不受影響」等於
  拿同一句話裡說沒實測的前提去支撐結論。要驗只能等下一次跨月上傳。

  **送審已經送出去了**（2026-08-26 16:41 UTC；2026-08-29 查仍是 `IN_REVIEW`）。
  查狀態用 `asc review status --app 6803354801`——它把版本、最近一次 submission
  與「下一步該做什麼」一起回，比翻網頁快。

  **版本記錄的字串與 build 裡的 `CFBundleShortVersionString` 不必相同。**
  ASC 的版本記錄是 `1.0`，而送審那個 build 的 pre-release version 實查是 `0.5.2`
  （`asc builds pre-release-version view --build-id <id>`），Apple 照樣收下並進入審查。
  所以「App Store 顯示 1.0」與「repo 是 0.5.x」不是漂移，是兩個不同的東西：對外的
  行銷版本，與這包程式碼的版本。判斷「審的到底是哪一包程式碼」只能問 build 的
  pre-release version，不能看版本記錄。

  **而 v0.5.3 沒有進 App Store。** 它 08-26 15:06 UTC 發到 GitHub，送審在 1.5 小時
  之後，送的卻仍是 08-20 上傳的那個 build——`asc builds count --app 6803354801`
  到今天回 `total: 1`。所以兩條通路是分岔的：Homebrew 拿得到 0.5.3，App Store
  審的是 0.5.2。這不會有任何訊號提醒你，發版時要自己對。

  **已上架的那個 build 是 arm64-only。** 版本 1.0 在 2026-08-26 送審、09-01 已是
  `READY_FOR_DISTRIBUTION`，而它承載的 build `2026.820.1137` 建於 `make-app.sh`
  加上 `--arch` 之前——Intel Mac 在 App Store 看到的是「與此裝置不相容」。
  修法在〈會咬人的地方〉的 universal binary 那條；**光修腳本救不了已上架的那一版**，
  要重建、重新 `--upload-app`、再送一次審查。查它是不是還沒換掉：
  `asc builds list --app 6803354801` 的 `version` 欄若仍是 `2026.820.1137` 就是。

  **那份描述檔在 `.gitignore` 裡，所以它會跟著 worktree 一起消失。**
  `Scripts/embedded.provisionprofile` 是 untracked，而 `git worktree remove` 不留情
  ——`git-flow:finish` 的收尾那一步就刪掉過一次。救援來源是 Xcode 自己的快取：
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`，挑名字是
  `tw.com.deepthought.findmouse AppStore` 的那一份（`security cms -D -i <檔> -o <暫存>`
  再 `PlistBuddy -c 'Print :Name' <暫存>`——**`-o` 是必要的**，PlistBuddy 讀不了
  `/dev/stdin`）。實測那份與 repo 裡的逐位元組相同。所以要放就放在**主 checkout**，
  用的時候複製進 worktree，不要在 worktree 裡生一份。

  **內嵌描述檔要排在 codesign 之前**，理由與圖示同一個（簽章封印整個 `Contents`），
  而錯誤訊息同樣一個字都不提描述檔。

  三個工具陷阱，每一個都會讓守衛變成恆真句：

  1. **盤點簽章身分不要用 `security find-identity -v -p codesigning`。** 那個 `-p`
     會**濾掉 Installer 憑證**（它不是 codesigning 身分）而且不報錯，於是「本機沒有
     Installer 憑證」這個結論看起來很確定。要看全部就不加 `-p`。
  2. **`plutil -lint` 不等於 XML 有效。** XML 註解不允許 ASCII 的兩個連字號，而
     `plutil -lint` 對含有它的檔案回 OK；抓得到的是 `xmllint --noout` 與 codesign
     的 AMFI 解析器，後者是在簽章那一步才炸、訊息是
     `AMFIUnserializeXML: syntax error near line N`。這個 repo 的 plist 註解都很長
     又常提到命令列旗標，所以踩得到——`InfoPlistTests` 有一條在掃它。
  3. **`plutil -extract` 把 `.` 當 keypath 分隔符**，所以它讀不到任何 entitlement 鍵：
     `plutil -extract com.apple.security.app-sandbox` 對一份**確實含有那個鍵**的
     plist 回「No value at that key path」並 exit 1（實測）。讀這種鍵一律用
     `PlistBuddy -c 'Print :<key>'`。危險的不是假性失敗（那很吵），而是拿它寫
     「某個鍵**不在**」的斷言——那會變成恆真句，`get-task-allow` 真的在也照樣通過。
- **Homebrew tap 在另一個 repo**（`Mikimoto/homebrew-findmouse`），發版收尾要手動同步，
  完整順序寫在 README 的〈自己發一份〉。動它之前先知道兩件事：
  `depends_on macos:` 的字串比較格式（`">= :sonoma"`）在 **cask 只是 deprecation 警告、
  在 formula 是硬失敗**（`unknown or unsupported macOS version`），兩邊都要寫裸符號
  `:sonoma`（語意相同，`brew info` 都回 `Required: macOS >= 14`）；而 **`brew test`
  斷言失敗時仍回 exit 0**，判讀只能看輸出裡有沒有 `Error:` 行。

- **開機啟動只在 `/Applications` 或 `~/Applications` 底下可用。** 開發時跑的是
  `build/FindMouse.app`，那個勾**永遠是灰的**——那是刻意的，不是壞掉。同樣的閘門
  也讓 e2e 不可能誤註冊。另外兩件實測過、從 SDK 文件看不出來的事：
  `SMAppService.mainApp` **以 bundle id 為鍵**（從 `build/` 那份 `unregister()`
  會把裝在 `/Applications` 那份一起關掉），而 `notFound` **是全新安裝的狀態**
  不是壞掉（BTM 裡還沒有記錄，`register()` 從那裡呼叫是成功的）。量法與數據在
  `docs/superpowers/specs/2026-08-10-login-item-design.md` 的〈未驗證的前提〉。

## 素材與 pack

- `packs/mycat` 由 `python3 tools/build-mycat.py` 從 `raw/` **一鍵重建**。那支腳本
  同時是這套 pack 的**來源清單**（哪張條子的哪一格對應哪一幀、對照格在第幾格）。
  手動組會組錯——已經發生過。
- `raw/` 裡有三個檔是**衍生**的定錨圖（`sit-final` / `sleep-final` / `windup-final`），
  來源記在 `build-mycat.py` 的註解裡。`ref.png` / `ref-clean.png` 是參考表，
  每次生成都要附，**無法從任何檔案復原**。
- `raw/`、`work/`、`packs/` 都在 gitignore 裡——素材不進版控。

## 寫程式的慣例

- 註解寫**為什麼**，不寫做了什麼。這個 repo 的既有註解密度偏高且都在解釋取捨與
  踩過的坑，跟著那個風格寫。
- 使用者面向的字串一律繁體中文，錯誤訊息要講「接下來能做什麼」。
- 新增的守衛要能**證明它會紅**：斷言「某事沒有發生」的測試，寫完必須用突變驗一次。
- 「走不到的程式碼＝未測試的程式碼」。搬動防呆分支之後要實際餵一次會踩到它的輸入。
