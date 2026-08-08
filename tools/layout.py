"""切格與版面：把橫排圖切成等距格，把去背後的各格排到同一張畫布上並算出 anchor。

這個模組的三個決定都寫在下面，因為它們**做錯了畫面上也只是「貓怪怪的」**，
沒有任何錯誤訊息可看。

一、anchor 是整套 pack 一個值，不是每格一個。
   manifest（spec 第 6.2 節）只有一組 `anchor: {x, y}`，14 個動作共用它。
   所以「對齊腳底線」的意思是**把每一格搬到同一條線上**，而不是每格各記自己的
   腳底在哪。這反過來規定了管線的順序：畫布尺寸與腳底線必須是**先對全部的格
   算出一組共同值、再逐格擺進去**，不能一格一格各自裁切再事後湊一個 anchor。

二、anchor.x 取「腳底接觸範圍的中點」，不是 bounding box 的水平中心。
   兩者在貓側身伸腿、或尾巴往後甩的時候差很多——bbox 中心會被尾巴與頭拉走，
   而它們離地面很遠。真正決定 anchor.x 的是渲染端：`OverlayView` 用
   `CATransform3DMakeScale(-1,1,1)` 做左右鏡像，而 CALayer 的 transform 是
   **繞 anchorPoint** 做的。設 anchor.x = 真正的腳底中心，貓轉身時就繞著腳
   原地翻；設成別的值（含盲目的 0.5），每次轉身腳底會橫移 2·(腳底−anchor)·寬。
   所以這個值不是美感問題，是有唯一正確答案的。

三、垂直對齊預設逐格（--align per-frame），可切成逐動作（per-action）。
   逐格＝每一格自己最低的那排像素都壓到腳底線上，這是 spec「對齊腳底線」
   與生圖指引「every cell the cat's feet rest on the SAME line」的字面意思，
   修掉的是生圖服務的框位漂移。代價是**騰空的動作會被黏回地面**（pounce 整隻
   在空中、tumble 翻滾），所以那類動作要用 per-action：整組一起平移，讓該組
   最低的那一格落在線上，組內的上下位移保留。預設取 per-frame，因為漂移是
   每一組都會發生的事，而騰空只有兩三組，而且後者看得出來、前者看不出來。
"""

from __future__ import annotations

from dataclasses import dataclass

from PIL import Image

from chroma import ChromaError


def cell_ranges(width: int, count: int) -> list[tuple[int, int]]:
    """把 [0, width) 切成 count 段，回傳每段的 [x0, x1)。

    生圖服務的輸出寬度不保證整除格數，所以不能用 `width // count` 再讓最後一格
    收尾——那會讓最後一格寬上好幾個像素（1000 寬切 7 格時多 6 px）。
    這裡用 `width*i//count` 的分配式取整：每一段寬度最多差 1 px，
    而且逐段首尾相接、聯集正好是整張圖，一個像素都不會被丟掉或算兩次。
    """
    if count < 1:
        raise ChromaError("INVALID_FRAME_COUNT", f"格數要 ≥ 1，收到 {count}")
    if width < count:
        raise ChromaError(
            "STRIP_TOO_NARROW",
            f"圖寬 {width} px 切不出 {count} 格（會有零寬的格）。確認 --frames 是否寫錯。")
    return [(width * i // count, width * (i + 1) // count) for i in range(count)]


def slice_strip(strip: Image.Image, count: int) -> list[Image.Image]:
    """橫排 N 格 → N 張。原樣裁切，不縮放、不補邊。"""
    width, height = strip.size
    return [strip.crop((x0, 0, x1, height)) for x0, x1 in cell_ranges(width, count)]


@dataclass(frozen=True)
class FrameGeom:
    """一格去背後的幾何。全部以**該格自己的**像素座標表示。"""

    name: str
    #: alpha > 0 的外框，right/bottom 不含
    bbox: tuple[int, int, int, int]
    #: 腳底接觸範圍的中點（連續座標：像素 i 佔 [i, i+1)，所以中點會有 .5）
    foot_x: float
    #: 最下面一排有 alpha 的列（含）
    bottom: int

    @property
    def left(self) -> int:
        return self.bbox[0]

    @property
    def top(self) -> int:
        return self.bbox[1]

    @property
    def right(self) -> int:
        return self.bbox[2]

    @property
    def height(self) -> int:
        return self.bbox[3] - self.bbox[1]


def frame_geometry(rgba: Image.Image, name: str, foot_band_frac: float = 0.03) -> FrameGeom:
    """量一格：外框、最低列、腳底接觸中點。

    腳底帶取「最低列往上 foot_band_frac × 外框高」那幾排，取那些排裡有 alpha 的
    像素的**左右極值中點**，而不是像素數的平均。理由：平均會被面積大的那隻腳
    拉過去（貓側身時後腳掌比前腳掌大得多），而我們要的是兩隻腳中間那一點。
    """
    bbox = rgba.getchannel("A").getbbox()
    if bbox is None:
        raise ChromaError("EMPTY_FRAME", f"{name}：整格沒有任何不透明像素")

    left, top, right, bottom_ex = bbox
    bottom = bottom_ex - 1
    band = max(1, round((bottom_ex - top) * foot_band_frac))
    band_top = max(top, bottom - band + 1)

    strip = rgba.crop((left, band_top, right, bottom_ex)).getchannel("A")
    band_box = strip.getbbox()
    if band_box is None:  # 量到的帶裡沒有東西 —— 依 bbox 的定義不可能發生
        raise ChromaError("EMPTY_FOOT_BAND", f"{name}：腳底帶取不到像素")
    foot_x = left + (band_box[0] + band_box[2]) / 2

    return FrameGeom(name=name, bbox=bbox, foot_x=foot_x, bottom=bottom)


@dataclass(frozen=True)
class Geometry:
    """整套 pack 共用的一組版面。pin 住它就能只重跑一部分動作而不動到其他動作。"""

    canvas_width: int
    canvas_height: int
    #: 腳底線落在畫布的哪一列（含）
    foot_y: int
    #: anchor 的水平位置，畫布像素（連續座標）
    anchor_col: float
    align: str

    @property
    def anchor_x(self) -> float:
        return self.anchor_col / self.canvas_width

    @property
    def anchor_y(self) -> float:
        """腳底線是「最低那排像素的下緣」，也就是連續座標 foot_y + 1。

        y 由上往下（spec 第 6.2 節）。方向反過來不會有任何錯誤訊息，
        只會讓貓浮在半空——`OverlayPresenter` 那邊還要再翻一次成 CALayer 的
        由下往上，兩邊都翻或都不翻才對得起來。
        """
        return (self.foot_y + 1) / self.canvas_height

    def to_json(self) -> dict:
        return {
            "canvas": {"width": self.canvas_width, "height": self.canvas_height},
            "foot_y": self.foot_y,
            "anchor_col": self.anchor_col,
            "align": self.align,
            "anchor": {"x": round(self.anchor_x, 6), "y": round(self.anchor_y, 6)},
        }

    @staticmethod
    def from_json(data: dict) -> "Geometry":
        try:
            return Geometry(canvas_width=int(data["canvas"]["width"]),
                            canvas_height=int(data["canvas"]["height"]),
                            foot_y=int(data["foot_y"]),
                            anchor_col=float(data["anchor_col"]),
                            align=str(data["align"]))
        except (KeyError, TypeError, ValueError) as exc:
            raise ChromaError("BAD_GEOMETRY_FILE",
                              f"geometry 檔缺欄位或型別不對：{exc}") from exc


def key_bbox(cell: Image.Image, purity: float = 0.92) -> tuple[int, int, int, int] | None:
    """一格裡「像背景色」的像素的外框。找不到就回 None。

    用途是切掉生圖服務加在外圍的白框與格間留白：實測 Gemini 會在整張圖外圍加
    一圈白邊（10–20 px）、兩格之間再留一條白間隔，切一半之後每格四邊都帶一圈白。
    白不是洋紅，去背去不掉，於是每格的 bbox 都會被撐到整格；而四角取樣拿到的
    是白色，`detect_key` 會直接判不出背景。

    判別用 d = min(R,B) − G 而不是比對某個 key，因為這一步跑在 key 判定**之前**。
    三者離得很開：白 d=0、貓身 d<0、洋紅 d≈190。

    門檻取「這一格最純的背景 × purity」而不是固定值：白與洋紅的交界有抗鋸齒
    混色，固定的低門檻會把混色一起算進外框，於是最外圈留下一兩欄半透明的白，
    而那正好是四角取樣會踩到的地方。取相對值也讓它不必假設背景有多飽和。

    purity 的預設值不是挑的，是對齊 `key` 的判準：那邊「算全背景」的條件是
    `raw <= bg_tolerance`，也就是純度 >= 1 − 0.08。裁到這條線，留在邊上的像素
    去背後 alpha 必為 0；設鬆一點（試過 0.75）留下的就是 25% 不透明的一圈白，
    它會沿著整個邊長連成一大塊，大到 despeckle 都吃不掉。改 bg_tolerance 時
    這個值要一起想。

    回的是背景的外框而不是白框的內緣：兩者在「白框是完整一圈」時等價，
    但貓若頂到格子邊，背景外框仍然涵蓋得到貓（貓被洋紅包著），而白框內緣
    要靠「每一邊都是純白」才算得出來，貓一碰邊就整條失效。
    """
    width, height = cell.size
    pixels = list(cell.convert("RGB").get_flattened_data())
    purest = max((r if r < b else b) - g for r, g, b in pixels)
    if purest <= 0:
        return None
    min_d = purest * purity
    left, top, right, bottom = width, height, -1, -1
    for y in range(height):
        row = y * width
        for x in range(width):
            r, g, b = pixels[row + x]
            if (r if r < b else b) - g > min_d:
                if x < left: left = x
                if x > right: right = x
                if y < top: top = y
                if y > bottom: bottom = y
    if right < 0:
        return None
    return (left, top, right + 1, bottom + 1)


ALIGN_MODES = ("per-frame", "per-action")


def _reference_bottoms(frames: list[FrameGeom], align: str) -> dict[str, int]:
    """每一格「要被壓到腳底線上」的那一列。

    per-frame：各自的最低列。per-action：整組取最低的那一格，組內位移保留。
    """
    if align == "per-frame":
        return {f.name: f.bottom for f in frames}
    if align == "per-action":
        lowest = max(f.bottom for f in frames)
        return {f.name: lowest for f in frames}
    raise ChromaError("INVALID_ALIGN_MODE", f"--align 只吃 {ALIGN_MODES}，收到 {align}")


def plan(actions: dict[str, list[FrameGeom]],
         align: str = "per-frame",
         pad_frac: float = 0.05,
         bottom_pad_frac: float = 0.07) -> Geometry:
    """對全部動作的全部格算出一組共同版面。

    padding 不是裝飾：內容貼著畫布邊時，之後補生一格高 2 px 的貓就會逼整套
    pack 換畫布尺寸（而 `PackValidator` 對跨動作尺寸不一致只給 warning，
    所以那件事會靜靜地發生）。下緣留白同時決定 anchor.y——預設 5% / 7% 算出來
    是 0.9375，和 spec 第 6.2 節範例的 0.94 對得上，不是隨手挑的。
    """
    if not actions:
        raise ChromaError("NO_ACTIONS", "沒有任何動作可以排版")

    refs = {name: _reference_bottoms(frames, align) for name, frames in actions.items()}

    # 垂直：腳底線之上要容得下最高的那一格
    above = max(refs[name][f.name] - f.top
                for name, frames in actions.items() for f in frames)
    content_h = above + 1
    pad_top = round(content_h * pad_frac)
    pad_bottom = round(content_h * bottom_pad_frac)
    canvas_h = pad_top + content_h + pad_bottom
    foot_y = pad_top + above

    # 水平：每組先各自把腳底中點對到 0，量出聯集範圍，再一起往右推 side
    provisional = {name: -round(action_foot_x(frames)) for name, frames in actions.items()}
    lo = min(f.left + provisional[name] for name, frames in actions.items() for f in frames)
    hi = max(f.right + provisional[name] for name, frames in actions.items() for f in frames)
    side = max(1, round(content_h * pad_frac))
    canvas_w = (hi - lo) + 2 * side
    anchor_col = float(side - lo)

    return Geometry(canvas_width=canvas_w, canvas_height=canvas_h, foot_y=foot_y,
                    anchor_col=anchor_col, align=align)


def action_foot_x(frames: list[FrameGeom]) -> float:
    """一組動作的腳底中點：組內各格取平均。

    取平均而不是取某一格：跑步循環裡前後腳輪流伸出去，任何單一格都偏一邊。
    """
    return sum(f.foot_x for f in frames) / len(frames)


def offsets(action_frames: list[FrameGeom], geometry: Geometry) -> tuple[int, dict[str, int]]:
    """一組動作在既定版面下的貼上位移：(水平位移, {格名: 垂直位移})。

    水平位移整組共用，所以組內的前後位移（前腳往前伸、身體前後晃）原樣保留；
    組與組之間則被拉到同一個 anchor 欄，否則從 run 切到 sit 的瞬間貓會橫移。
    """
    dx = round(geometry.anchor_col - action_foot_x(action_frames))
    refs = _reference_bottoms(action_frames, geometry.align)
    dy = {f.name: geometry.foot_y - refs[f.name] for f in action_frames}
    return dx, dy


def place(rgba: Image.Image, frame: FrameGeom, dx: int, dy: int,
          geometry: Geometry) -> Image.Image:
    """把一格貼進共同畫布。放不下就大聲失敗，不裁掉。

    裁掉是最壞的結果：產出仍然是一張合法 PNG，只是貓少一隻耳朵或半條尾巴，
    而 `PackValidator` 只看尺寸與張數，永遠不會發現。
    """
    left, top, right, bottom_ex = frame.bbox
    x = left + dx
    y = top + dy
    w = right - left
    h = bottom_ex - top
    if x < 0 or y < 0 or x + w > geometry.canvas_width or y + h > geometry.canvas_height:
        raise ChromaError(
            "FRAME_EXCEEDS_CANVAS",
            f"{frame.name}：內容 {w}×{h} 擺在 ({x},{y}) 超出畫布 "
            f"{geometry.canvas_width}×{geometry.canvas_height}。"
            "若是用 --geometry pin 住舊版面，代表新的一格比原本的貓大，"
            "要拿掉 --geometry 重排整套。")

    canvas = Image.new("RGBA", (geometry.canvas_width, geometry.canvas_height), (0, 0, 0, 0))
    canvas.paste(rgba.crop(frame.bbox), (x, y))
    return canvas


def horizontal_drift(frames: list[FrameGeom]) -> float:
    """組內腳底中點的最大跨度（px）。

    只回報不阻擋：跑步循環本來就會有幾 px 的合理位移，但生圖服務框位漂掉時
    這個數字會是幾十 px，而人眼在逐格看圖時反而看不出來。
    """
    if not frames:
        return 0.0
    xs = [f.foot_x for f in frames]
    return max(xs) - min(xs)
