# FindMouse — 給 Claude 的工作守則

專案介紹在 `README.md`，設計權威在 `docs/superpowers/specs/2026-08-05-findmouse-design.md`。
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

`mise.toml` **刻意沒有 `[tools]` 區段**：Swift 來自 Xcode（本機只能用 27.0 Beta 4，
macOS 27 上跑不動 26.6），而 Python 必須維持系統那一份——`tools/` 的 Pillow 與
SciPy 裝在它上面，讓 mise 換一個 python 進來會讓素材管線立刻找不到套件。

- **`FindMouseApp` 沒有測試 target**。那一層的東西只有 `e2e.sh` 驗得到。
- **`e2e.sh` 有三種結果**，第三種是「無法判定」。某些斷言需要獨占游標，使用者
  在動滑鼠時它會如實說「沒證明」。把「無法判定」讀成通過就是自欺。
- **突變的判讀是三態**：紅（含 crash）／綠／編不過。`grep -c FAIL` 回 0 有兩種
  成因——全綠，與根本沒跑。每一批 `mutate.py` 會自動附 no-op 對照組，它若不是
  全綠，整批結果不可採信。
- 架構的 import 允許清單由 `Tests/FindMouseDomainTests/ArchitectureBoundaryTests.swift`
  強制。它擋不住刻意規避（一行兩個 import、跨行），那不是它的目的。

## 會咬人的地方

- **`Scripts/make-app.sh` 一次只建一個 product。** `swift build --product A --product B`
  不是「兩個都建」，後面那個把前面的蓋掉——`.app` 裡會裝著上一次剛好還留在
  `.build` 裡的舊執行檔，而且沒有任何錯誤訊息。判斷「我的修改有沒有進到跑起來的
  那個東西」唯一可信的是**比對產物的雜湊**，不是 mtime、也不是看建置有沒有印錯誤。
- **同時只能有一個 FindMouse 實例。** 身分是 unix socket，第二個實例會自己退出。
  測試前要斷言零個實例，不能「殺完就當作乾淨」；`pgrep -f <路徑片段>` 比
  `pgrep -x <名字>` 可靠（bundle 內執行檔名與 SwiftPM 產物名不同）。
- **`findmouse pack validate` 走 socket，App 必須在跑。** CLI 是薄用戶端，
  App 沒跑會回 `APP_NOT_RUNNING`（exit 3），那不是 pack 有問題。
- **`toggle` 不是幂等的。** 腳本裡一律用 `summon` / `dismiss`。
- SwiftUI **只給設定視窗**。Overlay 維持純 AppKit ＋ CALayer——那裡有 spec 第 7.4 節
  的每帧預算，設定視窗一秒鐘畫不到一次。

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
