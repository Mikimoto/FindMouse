# tools/ — 素材後處理管線

spec 第 11 節第 5 條的實作：**AI 生圖的橫排多格圖 → 一套 sprite pack**。

分界線畫在這裡：`docs/superpowers/plans/2026-08-08-m6-asset-generation-guide.md`
負責「怎麼生出一張含 N 格的圖」，本目錄從那張圖開始，到 `pack.json` 為止。
產出要能通過 `Sources/FindMouseDomain/PackValidator.swift`——那份判定是權威，
這裡的每一條檢查都只是提早在同一個地方失敗而已。

## 依賴

**Pillow** 與 **SciPy**（`python3 -c "import PIL, scipy"` 驗一下）。這是本 repo
第一個需要第三方套件的東西——`Scripts/mutate.py` 是零依賴的。**不建 venv、
不寫 requirements.txt**：repo 沒有那個慣例，而這條管線一輩子只會在開發機上
跑幾十次。裝法 `python3 -m pip install --user Pillow scipy`。

SciPy 只用到一個東西：`ndimage.label` 做連通分量（見下面的 despeckle）。
純 Python 的 flood fill 在 1000×1000 的格子上要跑好幾秒，一套 pack 八十幾格
就是好幾分鐘。

## 四個子命令

```
slice     一張橫排 N 格的圖  → N 張原色格子
key       原色格子           → 去背後的 RGBA
align     去背後的 RGBA      → 共同畫布 ＋ 對齊腳底線 ＋ 算出 anchor
manifest  排好的 pack 目錄   → pack.json
```

每個都吃 `--json`，吐機器可讀的結果（每格的 bbox、背景比例、腳底中點、
算出來的 anchor…）。**那個介面同時是測試介面**：`test_pipeline.py` 驗的是它，
不是拿眼睛看圖。

為什麼拆成四段而不是一個黑箱：spec 第 11 節第 6 條要求「抖的那格只重生那一格，
不重生整組」。拆開之後，重生一格只要對那一格跑 `key`、再對整組跑 `align`；
要在既有的 pack 上補一組新動作，則用 `align --geometry` pin 住舊版面，
其他動作的 PNG 一個位元都不會變。

## 一趟完整的流程

```sh
# 1. 每組動作一張橫排圖，先切格
python3 tools/pipeline.py slice raw/run-strip.png --frames 8 --out work/cells/run

#    一組動作分兩張條子生的話（解析度撐不住 8 格），第二張用 --start 接續：
#    python3 tools/pipeline.py slice raw/run-b.png --frames 4 \
#        --out work/cells/run --start 4

# 2. 去背。背景色預設逐格自動判定，不用自己量
python3 tools/pipeline.py key work/cells/run --out work/keyed/run

#    …對 14 組動作各跑一次，全部落在 work/keyed/<動作>/ 底下

# 3. 一次排完全部動作（anchor 是整套一個值，所以這一步必須看到全部的格）
python3 tools/pipeline.py align work/keyed \
    --out packs/fluffy-orange --report work/geometry.json

# 4. 產 manifest。frames 一律用目錄裡實際的檔案數，不用宣告
python3 tools/pipeline.py manifest packs/fluffy-orange \
    --geometry work/geometry.json --name "橘色蓬鬆貓" --license "…"

# 5. 拿真正的判定驗一次
findmouse pack validate packs/fluffy-orange
```

**只重生一格**（第 3 格抖了）：換掉 `work/cells/run/002.png` → 對它跑 `key`
→ 重跑步驟 3、4。`align` 會重排整套，anchor 可能因此微調，這是對的——
新的那一格若比原本高，整套的畫布本來就該跟著變。

**之後補一組動作**（core 四組先上線，flourish 後補）：把新動作放進一個只有它的
`keyed` 目錄，`align 那個目錄 --geometry work/geometry.json --out packs/fluffy-orange`。
pin 住版面之後既有動作的 PNG 完全不動，而新的一格塞不進舊畫布時會硬失敗
（`FRAME_EXCEEDS_CANVAS`），不會被悄悄裁掉。

## 三個做了判斷的地方

### anchor.x ＝ 腳底接觸範圍的中點，不是 bounding box 的中心

決定這件事的不是美感，是渲染端：`OverlayView` 用 `CATransform3DMakeScale(-1,1,1)`
做左右鏡像，而 CALayer 的 transform 是**繞 anchorPoint** 做的。設 anchor.x 為真正的
腳底中心，貓轉身時就繞著腳原地翻；設成別的值（包含盲目的 0.5），每次轉身腳底會
橫移 `2·(腳底 − anchor)·寬`。bbox 中心會被尾巴與頭拉走，而它們離地面很遠。

取「接觸範圍的左右極值中點」而不是像素數平均：平均會被面積大的那隻腳拉過去
（貓側身時後腳掌比前腳掌大得多），而我們要的是兩隻腳中間那一點。
組內各格取平均，因為跑步循環裡前後腳輪流伸出去，任何單一格都偏一邊。

### anchor 是整套 pack 一個值，這規定了管線的順序

manifest 只有一組 `anchor: {x, y}`，14 組動作共用。所以：

- 畫布尺寸與腳底線必須**先對全部的格算出一組共同值、再逐格擺進去**，
  不能一組一組各自裁切再事後湊一個 anchor。
- 每一組動作都要被平移到**同一個 anchor 欄**上，否則從 `run` 切到 `sit`
  的瞬間貓會橫移。
- 組**內**的水平位移原樣保留（前腳往前伸、身體前後晃是真的動畫）；
  只有組與組之間被拉齊。垂直則相反，逐格壓到腳底線（見下）。

### `--align per-frame`（預設）vs `per-action`

`per-frame` 是每一格自己最低的那排像素都壓到腳底線上——修掉的是生圖服務的
框位漂移。（spec 第 11 節第 5 條只寫「對齊腳底線」，沒有指定逐格還是逐動作；
逐格是生圖指引那句 ground line 的自然讀法，不是 spec 明文。）
代價是**騰空的動作會被黏回地面**。

所以 `pounce`（整隻在空中）與 `tumble`（翻滾）要單獨用 `per-action` 跑一次：
整組一起平移，讓該組最低的那一格落在線上，組內的上下位移保留。
預設取 `per-frame`，因為漂移每一組都會發生，而騰空只有兩三組——
而且騰空被壓平看得出來，漂移看不出來。

## 門檻與它們的預設值

| 旗標 | 預設 | 理由 |
|---|---|---|
| `--key` | `auto` | **逐格**從四角判定實際的背景色。生圖服務吐的洋紅從來不是精確的 `FF00FF`（實測 `#FD35FA`、`#FE3CF4`…），而且同一張條子裡每格還不一樣。判不出來就硬失敗，不猜。要寫死就給 `RRGGBB` |
| `--despeckle` | `0.02` | 抹掉小於「最大區塊 × 這個比例」的連通分量。給 `0` 停用。2% 是量出來的：簽名實測佔 0.70%–1.03%，而該擋下的「崩壞長出的第二條尾巴」佔 9% |
| `--bg-tolerance` | `0.08` | 平坦洋紅經 JPEG 每通道抖 ±n（n 約 8），而 alpha 看的是 `min(R,B) − G`，最壞情況兩邊反向各抖 n → 誤差 **2n**/255。0.08 撐得住每通道 ±10。**這個值只負責雜訊**——key 判準了就不必開大（實測真實素材在 0.08 與 0.20 算出的 bbox 幾乎相同；而用一個全域 `--key` 時 0.08 會整個失效） |
| `--fg-tolerance` | `0.06` | 反過來那一端：貓身上偏洋紅的部位（粉紅鼻子、耳廓）會被算出 alpha < 1。0.06 蓋得住淡粉紅；真的有大塊桃紅色要調到 0.10 以上 |
| `--min-coverage` | `0.005` | 低於這個比例就判定生圖失敗。貓佔格子八成高，不可能只留 0.5% |
| `--pad` / `--bottom-pad` | `0.05` / `0.07` | 算出來 anchor.y = 0.9375，和 spec 第 6.2 節範例的 0.94 對得上。留白是為了讓之後補的一格高個兩三 px 時不必換整套畫布 |
| `--foot-band` | `0.03` | 腳底帶的厚度（佔該格外框高）。太薄會抓到單一根趾頭，太厚會把小腿算進來 |

## 會硬失敗的情況

「什麼都沒做卻回報成功」的路徑一條都不留。以下全部 exit 1，`--json` 帶錯誤碼：

| 錯誤碼 | 什麼情況 |
|---|---|
| `EMPTY_FRAME` | 整格都是背景（生圖失敗的空格）。**同一批只要有一格壞掉就一張都不寫**，避免下一步拿上一輪的舊檔繼續跑 |
| `NEARLY_EMPTY_FRAME` | 留下來的像素低於 `--min-coverage` |
| `NO_BACKGROUND_FOUND` | 沒有任何像素被判為背景 → 明確指定的 `--key` 大概不對 |
| `AMBIGUOUS_BACKGROUND` | `--key auto` 在四角取樣不到兩個像洋紅的角落。多半是貓佔滿整格，或背景根本不是洋紅系 |
| `DISCONNECTED_SUBJECT` | despeckle 之後還有超過一塊互不相連的東西。貓應該是一塊 |
| `FRAME_EXISTS` | `slice` 要寫的檔名已經存在（`--start` 給錯了）。覆蓋不留缺號，`FRAME_NAME_GAP` 抓不到，所以只能在寫之前擋。確定要蓋就 `--force` |
| `INVALID_KEY_COLOUR` | key 的 `min(R,B) ≤ G`（例如綠幕）。這個模型只處理洋紅系 |
| `FRAME_EXCEEDS_CANVAS` | 用 `--geometry` pin 住版面時新的一格擺不下 |
| `FRAME_NAME_GAP` | 檔名不是 `000…N-1` 連號。`SpriteRepository` 依排序後的**位置**取格，跳號會整段錯格播而不報錯——這是 `PackValidator` 看不到的洞（它只數張數） |
| `MISSING_CORE_ACTIONS` | 缺 `run`/`sit`/`sitIdle`/`sleep` 任一（spec 第 6.3 節） |
| `STRIP_TOO_NARROW` | 圖寬小於格數 |

### despeckle：抹掉生圖服務蓋在角落的簽名

Gemini 在每張產出的右下角蓋一個 `✦`。它是**後製貼上去的，prompt 禁不掉**
（實測連兩張都在），而且是真的不透明像素，任何色度門檻都碰不到它。
它會把 bbox 從 `[3,247,947,943]` 撐成 `[3,247,1032,1024]`，於是腳底線與
anchor 全錯——而輸出仍然是一套看起來完全正常的 pack。

門檻取「相對於最大區塊」而不是絕對像素數，因為畫布尺寸會隨生圖服務改變
（實測那個簽名佔最大區塊的 0.27%，預設門檻 1%）。每一塊被抹掉的都會列進
`--json` 的 `specks_removed` 與人類輸出——**刪東西不能靜悄悄**。

刻意**不**做成「只留最大的一塊」：那樣會把「生圖崩壞長出第二條尾巴」的壞格
悄悄修成好格。大塊的東西留著，改由 `blobs_remaining > 1` 觸發
`DISCONNECTED_SUBJECT` 硬失敗。

這是一張**部分的網**，不是完整的網：實測它抓到了跨格的殘影，但同一批裡另有
一格的殘影**與貓身相連**，連通分量只算一塊，它抓不到。眼睛還是要看。

## 去背的模型

只有一條式子，其餘都是它的推論：

```
觀測像素 O = a·F + (1−a)·K
```

三個方程式、四個未知數，缺一條約束。取的約束是**「還原出來的 F 不含洋紅」**
（`min(F_r,F_b) ≤ F_g`），取等號解出：

```
a = 1 − ( min(O_r,O_b) − O_g ) / ( min(K_r,K_b) − K_g )
F = ( O − (1−a)·K ) / a
```

所以**去色暈不是額外一步，而是這個 alpha 選法的定義**；而 `/ a` 就是
unpremultiply（不除回去邊緣會整圈偏暗）。`test_pipeline.py` 直接斷言這兩個性質。

已知代價：chroma key 本來就分不出「背景透出來」與「前景本來就是那個顏色」，
所以粉紅鼻子會被吃掉一點。緩解是 `--fg-tolerance`，沒有免費的解法。

## 測試

```sh
python3 tools/test_pipeline.py
```

沒有真實素材，但整條管線都測得起來——**合成的 fixture 我知道正確答案**。
26 條，每一條的名字說的是它在防什麼。runner 開跑前會先自檢一次
（確認它分得出通過、失敗、crash 三種），總數是 0 一律當失敗。

端對端那條另外提供：

```sh
python3 tools/test_pipeline.py --emit-pack /tmp/fm-e2e
```

會用合成素材跑完整條管線，落出一套 14 組動作的 pack。拿去餵真正的
`PackValidator`（`findmouse pack validate`，或一支依賴 `FindMouseDomain` 的
一次性 Swift 執行檔）就能確認「管線的產出真的餵得進程式」——
Python 這邊只驗得了「我以為 PackValidator 要什麼」。
