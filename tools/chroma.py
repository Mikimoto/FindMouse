"""Chroma key 的像素層運算：算 alpha、扣掉洋紅、還原非預乘顏色。

為什麼這一段要獨立成純函式模組：這裡每一行都是「錯了也不會有錯誤訊息」的那種
程式碼。alpha 算偏一點、忘了 unpremultiply，產出仍然是一張看得到貓的 PNG，
只是邊緣髒或偏暗——要等貓真的跑在桌面上、而且是在淺色背景前，才看得出來。
所以判定不能靠眼睛，只能靠可判定的性質（見 test_pipeline.py）。

整個模型只有一條式子，其餘都是它的推論：

    觀測像素 O = a·F + (1−a)·K

K 是背景色，F 是貓的真實顏色，a 是這個像素被貓覆蓋的比例。三個方程式、
四個未知數，缺一條約束才解得開。這裡取的約束是**「還原出來的 F 不含洋紅」**，
也就是 min(F_r, F_b) ≤ F_g（洋紅的特徵正是 R 與 B 高、G 低）。取等號解出來：

    a = 1 − ( min(O_r,O_b) − O_g ) / ( min(K_r,K_b) − K_g )

這條式子有兩個好處。第一，它不是拼湊的：把它代回 F = (O − (1−a)·K) / a，
還原出來的 F 必然滿足 min(F_r,F_b) ≤ F_g，所以**「去色暈」不是額外一步，
而是這個 alpha 選法的定義**，而且那個性質可以被測試直接斷言。第二，除以 a
就是 unpremultiply——扣掉背景之後剩下的是 a·F（預乘值），不除回去邊緣就會偏暗。

已知的限制（不是 bug，是這個模型的代價）：貓身上真的偏洋紅的部位（粉紅鼻子、
耳廓、舌頭）會被判成「有一點背景」而變成半透明並被去掉一點紅。緩解手段是把
--fg-tolerance 調大（見 pipeline.py 的說明），沒有免費的解法——chroma key
本來就分不出「背景透出來」與「前景本來就是那個顏色」。
"""

from __future__ import annotations

from dataclasses import dataclass, field

from PIL import Image

KEY_MAGENTA = (255, 0, 255)


class ChromaError(Exception):
    """帶錯誤碼的失敗。code 會原樣進 --json 的輸出。"""

    def __init__(self, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


def key_strength(key: tuple[int, int, int]) -> int:
    """背景色本身的「洋紅程度」，也就是 alpha 公式的分母。

    純 #FF00FF 是 255。生圖服務吐出來的背景常常偏一點（JPEG、色彩管理），
    分母跟著那個實際值走，`--key` 才會真的有效——寫死 255 的話，
    背景是 (250,10,245) 時算出來的 alpha 永遠到不了 0，整片背景留一層薄霧。
    """
    strength = min(key[0], key[2]) - key[1]
    if strength <= 0:
        raise ChromaError(
            "INVALID_KEY_COLOUR",
            f"背景色 {key} 的 min(R,B) 不大於 G，這個模型只處理洋紅系的背景。"
            "綠幕或藍幕請換別的工具，硬用會把整隻貓當成背景。")
    return strength


def alpha_table(strength: int, bg_tolerance: float,
                fg_tolerance: float) -> list[tuple[float, float]]:
    """d（= max(0, min(R,B) − G)）→ (模型算出的 alpha, 實際要寫進 PNG 的 alpha)。

    做成查表不只是為了快：兩端的吸附門檻只在這裡出現一次，
    不會散落在迴圈裡各寫一次而漂移。

    兩個吸附的用途不同：
    - bg_tolerance 吃掉背景的雜訊。平坦洋紅經過 JPEG 之後每個通道會抖 ±n/255
      （n 約 8），不吸附的話整片背景會留下碎點，而那些碎點會把 bounding box
      撐大 → 腳底線與 anchor 一起算歪。這是靜默的。門檻要抓
      **2n/255 而不是 n/255**：d = min(R,B) − G，最壞情況下 min(R,B) 往下抖、
      G 往上抖，兩邊各 n 就是 2n。（實測過：一開始照 n/255 取 0.05，
      ±7 的雜訊就穿過去把 bbox 從 20×20 撐成 46×48。）
    - fg_tolerance 保住貓身上偏洋紅的部位（粉紅鼻子、耳廓）。

    **回兩個值而不是一個**：顏色一律用模型算出的那個 alpha 還原，
    只有寫進 PNG 的 alpha 才吸附。吸附的那個拿去還原顏色的話，
    a=0.96 被吸到 1 的像素會原樣保留它身上那 4% 的洋紅——去色暈就在
    最外圈那一層破功，而那一層正好是唯一看得出色暈的地方。
    """
    if not 0.0 <= bg_tolerance < 1.0:
        raise ChromaError("INVALID_TOLERANCE", f"bg-tolerance 要在 [0,1)，收到 {bg_tolerance}")
    if not 0.0 <= fg_tolerance < 1.0:
        raise ChromaError("INVALID_TOLERANCE", f"fg-tolerance 要在 [0,1)，收到 {fg_tolerance}")

    table: list[tuple[float, float]] = []
    for d in range(256):
        raw = 1.0 - d / strength
        if raw < 0.0:
            raw = 0.0
        if raw <= bg_tolerance:
            out = 0.0
        elif raw >= 1.0 - fg_tolerance:
            out = 1.0
        else:
            out = raw
        table.append((raw, out))
    return table


@dataclass(frozen=True)
class KeyStats:
    """一格去背後的可觀測事實。全部會進 --json，讓人不用開圖就看得出哪裡不對。"""

    width: int
    height: int
    transparent: int
    opaque: int
    partial: int
    #: alpha > 0 的外框，(left, top, right, bottom)，right/bottom 不含。None 表示整格空的。
    bbox: tuple[int, int, int, int] | None
    #: alpha ≥ 128 的外框。與 bbox 差很多就代表邊緣糊掉或有碎點。
    bbox_solid: tuple[int, int, int, int] | None
    #: 四角取樣到的背景色。與 --key 差很遠就是門檻抓錯的前兆。
    sampled_corner: tuple[int, int, int]
    #: 被 despeckle 抹掉的小區塊（生圖服務的角落簽名之類）。刪東西不能靜悄悄。
    specks_removed: list[dict] = field(default_factory=list)
    #: 抹完之後還剩幾塊互不相連的東西。貓是一塊；>1 代表這格生壞了。
    blobs_remaining: int = -1

    @property
    def pixels(self) -> int:
        return self.width * self.height

    @property
    def background_ratio(self) -> float:
        return self.transparent / self.pixels

    @property
    def coverage(self) -> float:
        """alpha > 0 的像素比例。空白格是 0。"""
        return (self.opaque + self.partial) / self.pixels

    def to_json(self) -> dict:
        return {
            "width": self.width,
            "height": self.height,
            "transparent": self.transparent,
            "opaque": self.opaque,
            "partial": self.partial,
            "background_ratio": round(self.background_ratio, 6),
            "coverage": round(self.coverage, 6),
            "bbox": list(self.bbox) if self.bbox else None,
            "bbox_solid": list(self.bbox_solid) if self.bbox_solid else None,
            "sampled_corner": list(self.sampled_corner),
            "specks_removed": self.specks_removed,
            "blobs_remaining": self.blobs_remaining,
        }


def detect_key(rgb: Image.Image) -> tuple[int, int, int]:
    """從四角推出這一格實際的背景色。取樣不到就硬失敗，絕不猜。

    為什麼這件事值得做，而不是叫人自己量：生圖服務吐出來的洋紅每次都不一樣
    （實測 #FD35FA、#FA38F4…），而且**同一張條子裡每一格還不一樣**——四格四角
    量到的 d 落在 168…211。一個全域的 `--key` 對每一格都差一點，那個誤差只好
    由 `--bg-tolerance` 去吸收，於是門檻被迫開大，連帶把貓的軟邊也吃掉。
    逐格取真值，門檻就只需要負責雜訊。

    `sample_corner` 的註解擔心的是「貓剛好頂到角落，於是把貓的顏色當成背景」。
    這裡靠 d 的符號擋掉：洋紅背景的 d 是 +170 以上，而貓身上任何顏色的 d 都
    ≤ 0（白掌 0、奶油色 −20、橘 −60），中間隔著一整個色相的距離。所以丟掉
    d ≤ 0 的角落就等於丟掉「這一角是貓」的取樣，不是憑經驗抓的門檻。
    """
    pixels = list(rgb.convert("RGB").get_flattened_data())
    histogram = [0] * 256                      # 只統計 d>0，索引即 d
    for r, g, b in pixels:
        value = (r if r < b else b) - g
        if value > 0:
            histogram[value] += 1
    modal = max(range(256), key=histogram.__getitem__)
    if histogram[modal] == 0:
        raise ChromaError(
            "AMBIGUOUS_BACKGROUND",
            f"整格找不到任何洋紅系的像素（四角取樣到 "
            f"{[corner_colour(rgb, cx, cy) for cx in (0, 1) for cy in (0, 1)]}）。"
            "多半是貓佔滿了整格或背景根本不是洋紅系——用 --key 明確指定，不要讓它猜。")

    sample = [p for p in pixels
              if (p[0] if p[0] < p[2] else p[2]) - p[1] == modal][:4096]
    return tuple(sorted(c[i] for c in sample)[len(sample) // 2] for i in range(3))  # type: ignore[return-value]


def corner_colour(rgb: Image.Image, right: int, bottom: int) -> tuple[int, int, int]:
    """一個角落的代表色：取一小塊 patch 裡 d 落在中位數的那個像素。

    **不能只讀角落那一個像素**。生圖服務會在整張圖外圍加白邊，裁掉之後最外圈
    仍留著一兩個抗鋸齒混色；實測角落像素的 d 是 32 與 83，而同一角 16×16 的
    中位數是 196 與 203——差了一個數量級，而那個 d 就是 alpha 公式的分母。
    分母取小了，整片背景會留一層薄霧，卻沒有任何錯誤訊息。

    取「d 的中位數所在的那個像素」而不是各通道各自取中位數：後者會拼出一個
    不存在於圖上的顏色。中位數而非最大值，是因為最大值會抓到 JPEG 的離群點。
    """
    w, h = rgb.size
    size = max(1, min(16, w // 4, h // 4))
    x0 = w - size if right else 0
    y0 = h - size if bottom else 0
    patch = [rgb.getpixel((x0 + x, y0 + y)) for y in range(size) for x in range(size)]
    patch.sort(key=lambda c: min(c[0], c[2]) - c[1])
    return patch[len(patch) // 2]


def sample_corner(rgb: Image.Image) -> tuple[int, int, int]:
    """取四角的中位數當作「實際的背景色」。

    只是診斷用，不拿來自動改 key：自動猜背景色會在貓剛好頂到角落時
    悄悄把貓的顏色當成背景，那種錯完全沒有訊號。寧可把數字印出來讓人自己判斷。
    """
    w, h = rgb.size
    corners = [rgb.getpixel(p) for p in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1))]
    return tuple(sorted(c[i] for c in corners)[1] for i in range(3))  # type: ignore[return-value]


def key_frame(image: Image.Image,
              key: tuple[int, int, int] = KEY_MAGENTA,
              bg_tolerance: float = 0.08,
              fg_tolerance: float = 0.06,
              despeckle_fraction: float = 0.02) -> tuple[Image.Image, KeyStats]:
    """一張圖 → 去背後的 RGBA ＋ 統計。

    輸出是**非預乘**的 straight alpha，PNG 的定義就是這個；CoreGraphics 讀進去
    才會自己預乘。這裡如果留著預乘值，貓的邊緣在畫面上會整圈偏暗。
    """
    strength = key_strength(key)
    table = alpha_table(strength, bg_tolerance, fg_tolerance)
    kr, kg, kb = key

    rgb = image.convert("RGB")
    width, height = rgb.size
    source = list(rgb.get_flattened_data())
    out: list[tuple[int, int, int, int]] = [(0, 0, 0, 0)] * len(source)

    transparent = opaque = partial = 0

    for i, (r, g, b) in enumerate(source):
        d = (r if r < b else b) - g
        raw, alpha = (1.0, 1.0) if d <= 0 else table[d]

        if alpha <= 0.0:
            transparent += 1
            continue  # out[i] 已經是全透明
        if alpha >= 1.0:
            opaque += 1
        else:
            partial += 1

        if raw >= 1.0:
            out[i] = (r, g, b, round(alpha * 255))
            continue

        # F = (O − (1−a)·K) / a：扣掉背景貢獻（去色暈）再除回去（unpremultiply）。
        # 兩件事其實是同一條式子的兩半，拆開寫反而容易只做一半。
        rest = 1.0 - raw
        fr = (r - rest * kr) / raw
        fg = (g - rest * kg) / raw
        fb = (b - rest * kb) / raw
        out[i] = (_byte(fr), _byte(fg), _byte(fb), round(alpha * 255))

    result = Image.new("RGBA", (width, height))
    result.putdata(out)
    removed, remaining = despeckle(result, min_fraction=despeckle_fraction)

    alpha_band = result.getchannel("A")
    if removed:
        # 三個計數器是抹之前算的。不重算的話 coverage 會把已經被刪掉的簽名
        # 算進去——一個「報表說有、圖上沒有」的差距，正是這支工具要消滅的東西。
        histogram = alpha_band.histogram()
        transparent = histogram[0]
        opaque = histogram[255]
        partial = width * height - transparent - opaque
    stats = KeyStats(
        width=width,
        height=height,
        transparent=transparent,
        opaque=opaque,
        partial=partial,
        bbox=alpha_band.getbbox(),
        bbox_solid=alpha_band.point(lambda v: 255 if v >= 128 else 0).getbbox(),
        sampled_corner=sample_corner(rgb),
        specks_removed=removed,
        blobs_remaining=remaining)
    return result, stats


def despeckle(rgba: Image.Image, min_fraction: float) -> tuple[list[dict], int]:
    """就地抹掉小於「最大區塊 × min_fraction」的連通分量，回 (被抹掉的, 剩下幾塊)。

    這不是為了 JPEG 雜訊（那是 bg_tolerance 的工作，而且雜訊碎點通常只有幾個
    像素）。這是為了**生圖服務蓋在角落的簽名**——Gemini 每張圖右下角都有一個
    ✦，它是後製貼上去的，prompt 禁不掉（實測連兩次都在）。那是真的不透明像素，
    任何色度門檻都碰不到它，而它會把 bbox 撐到整格，於是腳底線與 anchor 全錯。

    門檻取「相對於最大區塊」而不是絕對像素數，因為畫布尺寸會隨生圖服務改變。
    預設 2% 是量出來的：18 格真實素材裡那個簽名佔最大區塊的 0.70%–1.03%
    （多數 ~0.75%，最大那次 5,681 px / 550,801 px），而真正該擋下來的東西——
    生圖崩壞長出的第二條尾巴——實測是 9%。2% 落在兩者中間，兩邊各有餘裕。
    原本設 1%，那 1.03% 的一格就穿過去了。
    刻意**不**做成「只留最大的一塊」：那樣會把 001 那種「多長出一條浮空尾巴」
    的壞格悄悄修成好格。大塊的東西留著，然後由 blobs_remaining 讓它現形。
    """
    if min_fraction <= 0:
        return [], -1

    import numpy as np
    from scipy import ndimage

    alpha = np.array(rgba.getchannel("A"))
    labels, count = ndimage.label(alpha > 0)
    if count <= 1:
        return [], count

    sizes = np.bincount(labels.ravel())
    sizes[0] = 0                      # 0 是背景標籤，不是分量
    threshold = sizes.max() * min_fraction

    # 除了「太小」，還要抹掉**碰到邊又不是最大塊**的東西。裁切後格子的四邊
    # 按定義就是背景（外框取的就是背景的外框），所以貼著邊的東西必然是殘留——
    # 實測有一條 17 px 寬、佔貓 3.36% 的白色分隔線殘留，大到穿過 min_fraction，
    # 而它只從 y=132 開始，上方的洋紅從它頭上連過去，所以連「取最大連通背景」
    # 也排除不掉。最大塊永遠保留，所以貓本身不可能被這條規則誤刪。
    largest = int(sizes.argmax())
    height, width = alpha.shape
    edge_sliver = np.zeros(len(sizes), bool)
    on_edge = set()
    for edge in (labels[0, :], labels[-1, :], labels[:, 0], labels[:, -1]):
        on_edge.update(np.unique(edge).tolist())
    for index in on_edge:
        if index == 0 or index == largest:
            continue
        ys, xs = np.nonzero(labels == index)
        # 貼邊還不夠——真正的生成缺陷（鬼影、第二條尾巴）也可能貼邊，那種要
        # 硬失敗而不是被悄悄抹掉。殘留的分隔線是**細長的直條**，鬼影不是。
        thin = min((xs.max() - xs.min() + 1) / width,
                   (ys.max() - ys.min() + 1) / height) <= 0.05
        edge_sliver[index] = thin

    removed = []
    for index in np.flatnonzero((sizes > 0) & ((sizes < threshold) | edge_sliver)):
        ys, xs = np.nonzero(labels == index)
        removed.append({"pixels": int(sizes[index]),
                        "bbox": [int(xs.min()), int(ys.min()),
                                 int(xs.max()) + 1, int(ys.max()) + 1]})
        alpha[labels == index] = 0

    if removed:
        rgba.putalpha(Image.fromarray(alpha))
    return removed, int(count - len(removed))


def _byte(value: float) -> int:
    """夾到 0…255 再取整。

    夾是必要的：a 很小的時候除法會把背景的量化誤差放大十幾倍，
    算出 −7 或 268 都很正常。不夾會讓 putdata 丟例外或悄悄繞回。
    """
    v = round(value)
    if v < 0:
        return 0
    if v > 255:
        return 255
    return v


def downscale_rgba(rgba: Image.Image, width: int, height: int) -> Image.Image:
    """等比縮小一張 RGBA。**先預乘、縮完再除回去。**

    直接對 unpremultiplied 的 RGBA 做 LANCZOS 是錯的：去背之後全透明像素的
    RGB 是任意值（`key_frame` 只保證 alpha 對，透明處的顏色沒有意義），
    重取樣會依權重把那些值帶進半透明的邊緣，長出一圈色暈——正是
    `key_frame` 裡那個 unpremultiply 花力氣消掉的東西。

    所以順序是：RGB × alpha（回到預乘域，透明像素的貢獻歸零）→ 縮 → 再除回去。
    """
    import numpy as np

    src = np.asarray(rgba.convert("RGBA"), dtype=np.float64)
    alpha = src[..., 3:4] / 255.0
    premultiplied = np.concatenate([src[..., :3] * alpha, src[..., 3:4]], axis=2)

    # 逐通道以 32-bit 浮點重取樣。**不可以先量化成 uint8 再縮**：預乘域裡
    # 低 alpha 的像素其 RGB 也很小（alpha=0.04、色 240 → 預乘值 10），
    # 四捨五入到 0 之後除回去就是純黑，邊緣會冒出一圈黑點。
    planes = [
        np.asarray(
            Image.fromarray(
                # ascontiguousarray 不可省：`premultiplied[..., c]` 是 stride 為 4 的
                # 非連續切片，而 `Image.fromarray(…, "F")` 直接照 buffer 解讀，
                # 餵非連續的進去會拿到錯位的資料（實測：不透明像素變純黑）。
                np.ascontiguousarray(premultiplied[..., c], dtype=np.float32), "F")
                 .resize((width, height), Image.LANCZOS),
            dtype=np.float64)
        for c in range(4)
    ]
    out = np.stack(planes, axis=2)

    # **alpha 也要 clip。** LANCZOS 會振鈴出負值（實測 -5.86），而
    # `astype(np.uint8)` 對負數是回繞不是飽和——-5.86 會變成 250，
    # 於是圖形外緣散出幾顆「幾乎不透明的純黑點」。那種東西 PackValidator
    # 看不出來（它只驗尺寸與張數），要到貓畫在螢幕上才看得到。
    alpha_out = out[..., 3:4].clip(0, 255)
    a = alpha_out / 255.0
    # a 是 0 的地方除不回去，也不需要——那些像素完全透明，RGB 留 0 就好。
    rgb = np.divide(out[..., :3], a, out=np.zeros_like(out[..., :3]), where=a > 0)
    return Image.fromarray(
        np.concatenate([rgb.clip(0, 255), alpha_out], axis=2).round().astype(np.uint8),
        "RGBA")
