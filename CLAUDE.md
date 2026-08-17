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
- **同時只能有一個 FindMouse 實例。** 身分是 unix socket，第二個實例會自己退出。
  測試前要斷言零個實例，不能「殺完就當作乾淨」；`pgrep -f <路徑片段>` 比
  `pgrep -x <名字>` 可靠（bundle 內執行檔名與 SwiftPM 產物名不同）。
  **但「零個實例」不是唯一的路**——身分既然是 socket，給不同的 socket 就是不同的
  身分：`open -n --env "FINDMOUSE_SOCKET=/tmp/xxx.sock" <某個.app>` 可以與使用者
  自己那份（`/Applications`，常常正在跑）共存，`e2e.sh:131` 的 `launch_app` 就是
  這樣做的。要驗開發建置時**不要去殺使用者的實例**。
  收工要照 e2e 那兩支的分工：`launch_app`（`e2e.sh:131`）用 before/after 的 `pgrep`
  差集記下**自己啟動的 pid**，`kill_started`（`:99`）只殺那些、並等到它們真的不在了
  才繼續。（那個差集有個已知邊界：它會收養 `open` 之後 2 秒內出現的**任何**實例，
  所以「只殺自己的」在那個窗口內有別人啟動時不成立。）
  **不要用 `pkill -f <路徑片段>`**——路徑片段是相對的，它會匹配**任何** worktree 的
  `build/FindMouse.app`，連另一個 session 的實例一起殺，正是這條要避免的事。
- **`/Applications/FindMouse.app` 現在由 Homebrew cask 管**（2026-08-14 起）。
  兩個後果：驗 cask 時不要裝進 `/Applications`（用
  `brew fetch --cask <tap>/findmouse`——它下載並驗 sha256 但**不安裝**，2026-08-17
  實測快取檔的雜湊與本機建的 dmg、cask 宣告的值三者相同，這已經是「tap 送出去的
  東西對不對」的完整答案）。

  **不要用 `brew install --cask --appdir="$(mktemp -d)"` 當沙盒。** 那條路只在
  cask **沒裝過**時是安全的；已經裝了的話 brew 把它當**升級**，會先
  `==> Removing App '/Applications/FindMouse.app'`（brew 的原句，路徑帶單引號）
  再把新版放進 `--appdir`，接著你為了收拾而跑的 `brew uninstall --cask findmouse`
  就把那份也清掉——使用者最後一個 app 都沒有，而且
  正在跑的那個 process 從此指著一個被刪掉的 bundle（`findmouse pack list --json`
  的 `data.packs` 變成空陣列，因為它連自己的三個內建 pack 都讀不到了——那是
  「這個實例已經廢了」最快的判別法）。2026-08-17 實際造成過一次，
  復原是 `brew install --cask <tap>/findmouse` 重裝，然後請使用者重開 App。
  真的要驗「裝進去長什麼樣」就直接 `brew upgrade --cask findmouse`——它結束在
  一個好的狀態，而不是一個要你自己收拾的狀態。

  以及**永遠不要跑 `brew uninstall --cask --zap`**
  ——`zap` 的路徑是絕對路徑，會刪掉使用者真正的 `~/Library/Application Support/FindMouse/`
  （他自己裝的 pack）與 `~/Library/Preferences/tw.com.deepthought.findmouse.plist`
  （全部設定），而 `brew uninstall` **沒有 `--dry-run`** 可以先看（實測回
  `Error: invalid option`）。要移除就用不帶 `--zap` 的版本。
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
- **票只釘在 `.dmg` 上，`.app` 裡沒有票。** 三份都驗過都沒有（2026-08-14）：dmg 裡
  那份、從 dmg 拖進 `/Applications` 那份、brew cask 抽出來那份。`release.sh` 那 12 條
  驗收全部只驗 dmg，所以**它們證明不了使用者實際執行的那個 `.app`**。
  現況能過 Gatekeeper（帶著 `com.apple.quarantine` 實測 `spctl` 回
  `accepted / Notarized Developer ID`），因為系統查得到線上紀錄——但**離線首次啟動
  沒有測過**，而那正是 spec 說「漏 staple 的症狀很賤」時擔心的情境。要補的話是多送
  一次 notarize：先送 `.app`、staple 它，再用那份打 dmg 再送審。兩次提交換一個離線
  保證，值不值得沒量過。
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
