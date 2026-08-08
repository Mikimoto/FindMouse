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

from dataclasses import dataclass

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
        }


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
              fg_tolerance: float = 0.06) -> tuple[Image.Image, KeyStats]:
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

    alpha_band = result.getchannel("A")
    stats = KeyStats(
        width=width,
        height=height,
        transparent=transparent,
        opaque=opaque,
        partial=partial,
        bbox=alpha_band.getbbox(),
        bbox_solid=alpha_band.point(lambda v: 255 if v >= 128 else 0).getbbox(),
        sampled_corner=sample_corner(rgb))
    return result, stats


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
