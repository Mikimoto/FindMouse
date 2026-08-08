#!/usr/bin/env python3
"""tools/ 這條素材管線的守衛。`python3 tools/test_pipeline.py` 直接跑。

為什麼不引 pytest：這個 repo 沒有 Python 測試框架的慣例（Scripts/mutate.py 也是
零第三方依賴的獨立腳本），為了 17 條斷言裝一個框架不划算。

**這裡沒有一張真實素材，但整條管線都測得起來**——合成的 fixture 我知道正確答案，
真實素材我不知道。所以每一條測試都是「餵一個我算得出答案的輸入，斷言算出來的
就是那個答案」，而不是「跑跑看有沒有爆炸」。

每條測試的名字說的是它在防什麼，docstring 第一行說的是「錯了會怎樣」。
判讀規則跟 Scripts/mutate.py 一樣：**綠必須由「看到預期數量的 passed」正面確認**，
所以最後會印出通過數與總數，總數是 0 一律當成失敗（runner 自己壞掉的形狀）。
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))

from PIL import Image  # noqa: E402

import chroma  # noqa: E402
import layout  # noqa: E402

PIPELINE = TOOLS / "pipeline.py"
KEY = (255, 0, 255)


# ── fixture 工廠 ────────────────────────────────────────────
#
# 兩條原則貫穿所有 fixture：
# 1. **上下不對稱**。腳底線的 y 軸方向搞反不會有錯誤訊息，只會讓貓浮在半空；
#    上下對稱的方塊測不出來（`make-test-blocks.swift` 那種置中方塊正是測不出來的形狀）。
# 2. **左右也不對稱，而且腳底中心 ≠ bbox 中心**。否則「拿 bbox 中心當腳底中心」
#    這個錯誤會照樣通過。

def composite(width: int, height: int, shape, fg: tuple[int, int, int],
              key: tuple[int, int, int] = KEY) -> tuple[Image.Image, list[float]]:
    """把一個「(x,y) → 覆蓋率 0…1」的形狀疊在背景色上，回 (RGB 圖, 真實 alpha 表)。

    真實 alpha 是我們自己給的，所以「去背算出來的 alpha 對不對」是可判定的。
    """
    pixels = []
    truth = []
    for y in range(height):
        for x in range(width):
            a = shape(x, y)
            truth.append(a)
            pixels.append(tuple(round(a * fg[i] + (1 - a) * key[i]) for i in range(3)))
    image = Image.new("RGB", (width, height))
    image.putdata(pixels)
    return image, truth


def rgba_shape(width: int, height: int, shape,
               fg: tuple[int, int, int] = (200, 160, 120)) -> Image.Image:
    """直接造一張 RGBA，用來測排版（跳過去背，讓兩件事的失敗不會互相掩蓋）。"""
    image = Image.new("RGBA", (width, height))
    image.putdata([(*fg, round(shape(x, y) * 255))
                   for y in range(height) for x in range(width)])
    return image


def cat_silhouette(x0: int, x1: int, top: int, bottom: int, tail_to: int):
    """一個貓形剪影：身體 ＋ 底部一小塊腳掌 ＋ 往右上翹的尾巴。

    刻意讓 bbox 的水平中心遠離腳掌中心（尾巴把 bbox 拉到右邊），
    這樣「anchor.x 取 bbox 中心」與「取腳底中心」兩種寫法會算出不同的值。
    """
    foot_x0 = x0 + 2
    foot_x1 = x0 + 10

    def shape(x: int, y: int) -> float:
        if x0 <= x < x1 and top <= y < bottom - 6:
            return 1.0
        if foot_x0 <= x < foot_x1 and bottom - 6 <= y <= bottom:
            return 1.0
        # 尾巴：一條斜線，離地很遠
        if x1 <= x < tail_to and top + 2 <= y < top + 6:
            return 1.0
        return 0.0

    return shape


def soft_disc(cx: float, cy: float, radius: float, feather: float = 2.0):
    """柔邊圓：離圓心 r 時覆蓋率從 1 線性降到 0，中間那圈就是抗鋸齒邊。"""
    def shape(x: int, y: int) -> float:
        d = ((x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2) ** 0.5
        if d <= radius - feather:
            return 1.0
        if d >= radius:
            return 0.0
        return (radius - d) / feather
    return shape


def run_cli(*argv: str) -> tuple[int, dict]:
    """跑一次 CLI，回 (exit code, 解析後的 JSON)。

    測試打的是 CLI 而不是函式：`--json` 是這條管線對外的契約，
    直接呼叫函式會讓「參數接錯、旗標沒生效」這一類完全測不到。
    """
    proc = subprocess.run([sys.executable, str(PIPELINE), *argv, "--json"],
                          capture_output=True, text=True)
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise AssertionError(
            f"--json 沒吐出可解析的 JSON（exit {proc.returncode}）：{exc}\n"
            f"stdout: {proc.stdout[:400]}\nstderr: {proc.stderr[:400]}") from exc
    return proc.returncode, payload


def alpha_of(image: Image.Image) -> list[int]:
    return list(image.getchannel("A").get_flattened_data())


def opaque_count(image: Image.Image) -> int:
    return sum(1 for a in alpha_of(image) if a > 0)


# ── 測試 ────────────────────────────────────────────────────

def test_slice_loses_no_pixel_even_when_width_is_indivisible(tmp: Path):
    """防：切格悄悄丟掉最後幾個像素。丟了之後每一格看起來都很正常。"""
    for width, count in ((400, 4), (401, 4), (1000, 7), (13, 5)):
        strip = Image.new("RGB", (width, 9))
        # 每一欄一個獨一無二的顏色，丟一欄或重複一欄都會在比對時現形
        strip.putdata([(x % 251, (x * 7) % 251, y * 20) for y in range(9) for x in range(width)])
        cells = layout.slice_strip(strip, count)

        assert sum(c.width for c in cells) == width, \
            f"{width}/{count}：各格寬度總和 {sum(c.width for c in cells)} ≠ 原圖寬 {width}"
        joined = Image.new("RGB", (width, 9))
        x = 0
        for cell in cells:
            joined.paste(cell, (x, 0))
            x += cell.width
        assert joined.tobytes() == strip.tobytes(), f"{width}/{count}：接回去和原圖不一樣"


def test_slice_cells_are_contiguous_and_within_one_pixel(tmp: Path):
    """防：某一格暴寬（1000 切 7 格時最後一格會多 6 px），或格與格之間有縫。"""
    for width, count in ((400, 4), (401, 4), (1000, 7), (2049, 8)):
        ranges = layout.cell_ranges(width, count)
        assert ranges[0][0] == 0 and ranges[-1][1] == width, f"{width}/{count}：頭尾沒蓋滿"
        for (_, prev_end), (next_start, _) in zip(ranges, ranges[1:]):
            assert prev_end == next_start, f"{width}/{count}：{prev_end} 與 {next_start} 之間有縫"
        widths = [b - a for a, b in ranges]
        assert max(widths) - min(widths) <= 1, f"{width}/{count}：格寬差 {max(widths) - min(widths)} px"


def test_alpha_is_recovered_from_the_antialiased_edge(tmp: Path):
    """防：alpha 公式算錯。錯了邊緣會硬掉或整圈半透明，但圖仍然「看得到貓」。"""
    for fg in ((200, 200, 200), (250, 60, 60)):
        # 一條由左到右的 alpha 斜坡，涵蓋整個 0…1 區間
        width, height = 64, 4
        ramp = lambda x, y: x / (width - 1)  # noqa: E731
        image, truth = composite(width, height, ramp, fg)
        # 吸附門檻關掉，測的是模型本身；門檻的行為另有測試
        keyed, _ = chroma.key_frame(image, key=KEY, bg_tolerance=0.0, fg_tolerance=0.0)

        got = alpha_of(keyed)
        spread = max(truth) - min(truth)
        assert spread > 0.9, f"fixture 的 alpha 只跨了 {spread}，測不到中間地帶"
        for i, (a_true, a_got) in enumerate(zip(truth, got)):
            assert abs(a_got / 255 - a_true) <= 3 / 255, \
                f"fg={fg} 第 {i} 個像素：真實 alpha {a_true:.4f}、算出 {a_got / 255:.4f}"


def test_no_magenta_survives_on_any_visible_pixel(tmp: Path):
    """防：去色暈沒做。邊緣會鑲一圈洋紅，在深色桌布上非常明顯。"""
    fg = (210, 150, 150)  # min(R,B) == G，所以合格的輸出只能剛好相等，沒有容錯空間
    image, _ = composite(48, 48, soft_disc(24, 26, 18, feather=3), fg)

    # 先證明這條測試有東西可抓：輸入的邊緣像素確實嚴重偏洋紅
    contaminated = sum(1 for (r, g, b) in image.convert("RGB").get_flattened_data()
                       if 0 < min(r, b) - g < 200)
    assert contaminated > 20, f"fixture 只有 {contaminated} 個混色像素，抓不到色暈"

    keyed, _ = chroma.key_frame(image, key=KEY)
    for i, (r, g, b, a) in enumerate(keyed.get_flattened_data()):
        if a == 0:
            continue
        assert min(r, b) <= g + 1, \
            f"第 {i} 個像素 rgba=({r},{g},{b},{a}) 仍帶洋紅：min(R,B)={min(r, b)} > G={g}"


def test_edge_colour_is_not_darkened_by_missing_unpremultiply(tmp: Path):
    """防：忘了除回 alpha。邊緣會整圈偏暗，去色暈的測試照樣會過。"""
    fg = (240, 90, 90)
    image, truth = composite(48, 48, soft_disc(24, 26, 18, feather=4), fg)
    keyed, _ = chroma.key_frame(image, key=KEY, bg_tolerance=0.0, fg_tolerance=0.0)

    checked = 0
    for (r, g, b, a), a_true in zip(keyed.get_flattened_data(), truth):
        if not 0.3 <= a_true <= 0.9:
            continue
        checked += 1
        for got, want, ch in ((r, fg[0], "R"), (g, fg[1], "G"), (b, fg[2], "B")):
            assert abs(got - want) <= 4, \
                f"半透明邊緣的 {ch}={got}，中心色是 {want}（alpha={a_true:.3f}）"
    assert checked > 40, f"只驗到 {checked} 個半透明像素，樣本太少"


def test_every_frame_lands_on_one_footline_and_anchor_y_points_down(tmp: Path):
    """防：腳底線沒對齊，或 anchor.y 的方向搞反（貓浮空／陷進桌面，無錯誤訊息）。"""
    frames = []
    for i in range(4):
        bottom = 60 + i * 7          # 每格底部刻意落在不同 y
        frames.append(rgba_shape(80, 100, cat_silhouette(20, 44, bottom - 40, bottom, 56)))
    geoms = [layout.frame_geometry(img, f"run/{i:03d}.png") for i, img in enumerate(frames)]

    geometry = layout.plan({"run": geoms})
    dx, dy = layout.offsets(geoms, geometry)
    placed = [layout.place(img, g, dx, dy[g.name], geometry) for img, g in zip(frames, geoms)]

    bottoms = {p.getchannel("A").getbbox()[3] for p in placed}
    assert bottoms == {geometry.foot_y + 1}, \
        f"對齊後各格的底緣是 {sorted(bottoms)}，腳底線應該只有 {geometry.foot_y + 1}"

    expected = (geometry.foot_y + 1) / geometry.canvas_height
    assert abs(geometry.anchor_y - expected) < 1e-9
    # y 由上往下（spec 第 6.2 節）：腳在下方，所以這個值必須靠近 1。
    # 方向反過來會得到 1 − expected；下面這條把兩者分得開。
    assert expected > 0.55, f"fixture 上下太對稱（anchor.y={expected}），測不出翻轉"
    assert geometry.anchor_y > 0.55, f"anchor.y={geometry.anchor_y}，y 軸方向像是反的"


def test_anchor_x_is_the_foot_centre_not_the_bounding_box_centre(tmp: Path):
    """防：拿 bbox 中心當腳底中心。貓側身伸腿或尾巴翹起來時，轉身會橫移一大段。"""
    image = rgba_shape(80, 100, cat_silhouette(20, 44, 20, 60, 70))
    geom = layout.frame_geometry(image, "run/000.png")
    geometry = layout.plan({"run": [geom]})
    dx, _ = layout.offsets([geom], geometry)

    bbox_centre = (geom.bbox[0] + geom.bbox[2]) / 2 + dx
    foot_centre = geom.foot_x + dx
    assert abs(bbox_centre - foot_centre) > 5, \
        f"fixture 的 bbox 中心 {bbox_centre} 與腳底中心 {foot_centre} 差太少，兩種寫法分不出來"
    assert abs(geometry.anchor_col - foot_centre) <= 1, \
        f"anchor 落在 {geometry.anchor_col}，腳底中心在 {foot_centre}"
    assert abs(geometry.anchor_col - bbox_centre) > 4, \
        f"anchor 落在 {geometry.anchor_col}，看起來是照 bbox 中心 {bbox_centre} 算的"


def test_all_actions_share_one_canvas_and_one_anchor(tmp: Path):
    """防：每組動作各自算畫布與 anchor。manifest 只有一組，切動作時貓會瞬移。"""
    actions = {
        "run": [rgba_shape(80, 100, cat_silhouette(20, 44, 18, 62, 56)) for _ in range(3)],
        # sit 刻意矮一截、位置也偏，逼出「兩組各自算」的差異
        "sit": [rgba_shape(80, 100, cat_silhouette(34, 50, 40, 74, 58)) for _ in range(2)],
    }
    geoms = {name: [layout.frame_geometry(img, f"{name}/{i:03d}.png")
                    for i, img in enumerate(imgs)] for name, imgs in actions.items()}
    geometry = layout.plan(geoms)

    sizes = set()
    for name, imgs in actions.items():
        dx, dy = layout.offsets(geoms[name], geometry)
        for img, g in zip(imgs, geoms[name]):
            placed = layout.place(img, g, dx, dy[g.name], geometry)
            sizes.add(placed.size)
            assert placed.getchannel("A").getbbox()[3] == geometry.foot_y + 1, \
                f"{g.name} 的底緣沒落在腳底線上"
        landed = layout.action_foot_x(geoms[name]) + dx
        assert abs(landed - geometry.anchor_col) <= 1, \
            f"{name} 的腳底中心落在 {landed}，anchor 欄在 {geometry.anchor_col}"

    assert sizes == {(geometry.canvas_width, geometry.canvas_height)}, \
        f"輸出尺寸不只一種：{sizes}"


def test_content_touching_the_cell_edge_is_not_cropped(tmp: Path):
    """防：貓頂到格子邊時被裁掉。裁掉之後仍是一張合法 PNG，PackValidator 看不出來。"""
    full = rgba_shape(40, 50, lambda x, y: 1.0)  # 整格滿版，四邊全部貼邊
    geom = layout.frame_geometry(full, "run/000.png")
    assert geom.bbox == (0, 0, 40, 50), f"fixture 沒有真的貼邊：{geom.bbox}"

    geometry = layout.plan({"run": [geom]})
    dx, dy = layout.offsets([geom], geometry)
    placed = layout.place(full, geom, dx, dy[geom.name], geometry)

    assert opaque_count(placed) == opaque_count(full), \
        f"貼進畫布後不透明像素從 {opaque_count(full)} 變成 {opaque_count(placed)}"
    box = placed.getchannel("A").getbbox()
    assert box[2] - box[0] == 40 and box[3] - box[1] == 50, f"內容被裁成 {box}"


def test_blank_cell_fails_loudly_and_writes_nothing(tmp: Path):
    """防：生圖失敗的空白格被輸出成一張全透明 PNG，然後整條管線裝作成功。"""
    cells = tmp / "cells"
    cells.mkdir()
    Image.new("RGB", (40, 40), KEY).save(cells / "000.png")
    rgba_shape(40, 40, soft_disc(20, 20, 12)).convert("RGB").save(cells / "001.png")

    out = tmp / "keyed"
    code, payload = run_cli("key", str(cells), "--out", str(out))
    assert code == 1, f"空白格居然 exit {code}"
    assert payload["ok"] is False
    codes = [e["code"] for e in payload["errors"]]
    assert "EMPTY_FRAME" in codes, f"錯誤碼是 {codes}"
    # 「一張都不寫」是重點：寫一半的話下一步會拿上一輪的舊檔跑得很開心
    assert not list(out.glob("*.png")), f"失敗卻寫出了 {list(out.glob('*.png'))}"


def test_cell_with_no_background_at_all_fails_loudly(tmp: Path):
    """防：--key 給錯時整格被判成不透明，去背等於沒做，而輸出看起來完全正常。"""
    cells = tmp / "cells"
    cells.mkdir()
    Image.new("RGB", (32, 32), (120, 130, 140)).save(cells / "000.png")

    code, payload = run_cli("key", str(cells), "--out", str(tmp / "keyed"))
    assert code == 1
    assert "NO_BACKGROUND_FOUND" in [e["code"] for e in payload["errors"]], payload["errors"]


def test_background_noise_does_not_inflate_the_bounding_box(tmp: Path):
    """防：門檻寫死。JPEG 雜訊留下的碎點會撐大 bbox，腳底線與 anchor 一起算歪。"""
    width = height = 48
    shape = soft_disc(24, 30, 10, feather=1)
    clean, truth = composite(width, height, shape, (200, 200, 200))
    true_background = sum(1 for a in truth if a == 0)

    noisy = Image.new("RGB", (width, height))
    pixels = list(clean.get_flattened_data())
    amplitude = 0
    for i, (r, g, b) in enumerate(pixels):
        if shape(i % width, i // width) > 0:
            continue  # 只弄髒背景
        # 決定性的 ±8，正是 --bg-tolerance 預設值所宣稱撐得住的量級。
        # 故意讓 min(R,B) 往下、G 往上（最壞方向）——那才是 d 誤差的上界。
        wobble = (i * 37) % 17 - 8
        amplitude = max(amplitude, abs(wobble))
        pixels[i] = (max(0, min(255, r - abs(wobble))),
                     max(0, min(255, g + abs(wobble))), b)
    noisy.putdata(pixels)
    assert amplitude == 8, f"雜訊振幅只有 ±{amplitude}，沒有測到預設門檻的設計點"

    truth_box = chroma.key_frame(clean, key=KEY)[0].getchannel("A").getbbox()
    strict = chroma.key_frame(noisy, key=KEY, bg_tolerance=0.0, fg_tolerance=0.0)[1]
    default = chroma.key_frame(noisy, key=KEY)[1]

    # 非空檢查：門檻關掉時雜訊確實會撐大 bbox，否則這條測試沒有在防任何東西
    assert strict.bbox != truth_box, \
        f"bg-tolerance=0 也沒被雜訊影響（{strict.bbox}），fixture 的雜訊不夠"
    assert default.bbox == truth_box, \
        f"預設門檻下 bbox 是 {default.bbox}，乾淨圖是 {truth_box}"
    # 拿真實的背景像素數當基準。圓盤本身就佔了一成多，憑印象寫「> 0.9」
    # 只會得到一條為了錯的理由而紅（或綠）的斷言。
    assert default.transparent >= true_background * 0.99, \
        f"預設門檻只認出 {default.transparent} 個背景像素，實際有 {true_background} 個"


def test_key_colour_is_configurable_and_actually_used(tmp: Path):
    """防：--key 只是裝飾。生圖服務吐出來的洋紅常常不是精確的 FF00FF。"""
    drifted = (242, 10, 238)
    shape = soft_disc(20, 24, 12)
    image, truth = composite(40, 40, shape, (200, 200, 200), key=drifted)
    true_background = sum(1 for a in truth if a == 0)

    wrong = chroma.key_frame(image, key=KEY)[1]
    right = chroma.key_frame(image, key=drifted)[1]
    # 拿真實的背景像素數當基準，不憑印象猜一個比例——圓盤本身就佔了近三成。
    assert right.transparent >= true_background * 0.99, \
        f"用對 key 只認出 {right.transparent} 個背景像素，實際有 {true_background} 個"
    assert wrong.transparent < true_background * 0.1, \
        f"用錯 key 也認出 {wrong.transparent} 個背景像素，--key 等於沒作用"

    # 綠幕／藍幕不是這個模型能處理的，硬跑會把整隻貓當背景 → 必須擋下來
    try:
        chroma.key_strength((0, 255, 0))
        raise AssertionError("綠色的 key 居然被接受了")
    except chroma.ChromaError as error:
        assert error.code == "INVALID_KEY_COLOUR", error.code


def test_per_action_align_keeps_a_frame_in_the_air(tmp: Path):
    """防：騰空的動作（pounce/tumble）被逐格對齊黏回地面，看起來像在地上滑行。"""
    grounded = rgba_shape(60, 80, cat_silhouette(10, 30, 30, 60, 40))
    airborne = rgba_shape(60, 80, cat_silhouette(10, 30, 14, 44, 40))  # 整隻往上 16 px
    images = [grounded, airborne]
    geoms = [layout.frame_geometry(img, f"pounce/{i:03d}.png") for i, img in enumerate(images)]

    for mode, want_same in (("per-frame", True), ("per-action", False)):
        geometry = layout.plan({"pounce": geoms}, align=mode)
        dx, dy = layout.offsets(geoms, geometry)
        bottoms = [layout.place(img, g, dx, dy[g.name], geometry)
                   .getchannel("A").getbbox()[3] for img, g in zip(images, geoms)]
        assert (len(set(bottoms)) == 1) is want_same, \
            f"{mode}：各格底緣 {bottoms}，{'應該' if want_same else '不應該'}全部相同"
        if mode == "per-action":
            assert max(bottoms) == geometry.foot_y + 1, "最低的那一格沒落在腳底線上"


def test_manifest_counts_real_files_and_rejects_gaps(tmp: Path):
    """防：宣告的格數與目錄裡的檔案數不符（PackValidator 的 error），或檔名跳號錯格播。"""
    pack = tmp / "fixture-pack"
    for action, count in (("run", 3), ("sit", 2), ("sitIdle", 2), ("sleep", 2)):
        directory = pack / action
        directory.mkdir(parents=True)
        for i in range(count):
            Image.new("RGBA", (30, 40), (10, 20, 30, 255)).save(directory / f"{i:03d}.png")

    code, payload = run_cli("manifest", str(pack), "--anchor", "0.5,0.94")
    assert code == 0, payload.get("errors")
    actions = payload["manifest"]["actions"]
    assert {n: a["frames"] for n, a in actions.items()} == \
        {"run": 3, "sit": 2, "sitIdle": 2, "sleep": 2}, actions
    assert actions["run"]["loop"] is True and actions["sit"]["loop"] is False, actions
    assert (pack / "pack.json").exists()

    # 檔名跳號：SpriteRepository 依排序後的位置取格，跳號會整段錯格播而不報錯
    (pack / "run" / "001.png").rename(pack / "run" / "007.png")
    (pack / "pack.json").unlink()
    code, payload = run_cli("manifest", str(pack), "--anchor", "0.5,0.94")
    assert code == 1 and "FRAME_NAME_GAP" in [e["code"] for e in payload["errors"]], payload
    assert not (pack / "pack.json").exists(), "有錯還是把 pack.json 寫出去了"


def test_pinned_geometry_reproduces_byte_identical_frames(tmp: Path):
    """防：之後補一組動作時整套 pack 的 anchor 悄悄漂掉（既有動作全部要重出）。"""
    keyed = tmp / "keyed"
    for action, top in (("run", 20), ("sit", 30)):
        directory = keyed / action
        directory.mkdir(parents=True)
        for i in range(2):
            rgba_shape(60, 80, cat_silhouette(10, 30, top, 62 + i * 3, 42)).save(
                directory / f"{i:03d}.png")

    first = tmp / "pack-a"
    code, payload = run_cli("align", str(keyed), "--out", str(first),
                            "--report", str(tmp / "geom.json"))
    assert code == 0, payload

    second = tmp / "pack-b"
    code, again = run_cli("align", str(keyed), "--out", str(second),
                          "--geometry", str(tmp / "geom.json"))
    assert code == 0, again
    assert again["geometry"] == payload["geometry"], "pin 住版面之後 anchor 還是變了"
    for path in sorted(first.rglob("*.png")):
        mirror = second / path.relative_to(first)
        assert path.read_bytes() == mirror.read_bytes(), f"{path.name} 重跑後位元不同"

    # 比原本高的一格擺不進 pin 住的畫布 → 必須硬失敗，不能悄悄裁掉
    tall = tmp / "keyed-tall"
    (tall / "sleep").mkdir(parents=True)
    rgba_shape(60, 200, cat_silhouette(10, 30, 5, 190, 42)).save(tall / "sleep" / "000.png")
    code, payload = run_cli("align", str(tall), "--out", str(tmp / "pack-c"),
                            "--geometry", str(tmp / "geom.json"))
    assert code == 1 and payload["errors"][0]["code"] == "FRAME_EXCEEDS_CANVAS", payload


def test_every_subcommand_speaks_json(tmp: Path):
    """防：--json 混進人類看的文字。這個介面同時是測試介面，混了就兩邊都不能用。"""
    strip, _ = composite(120, 60, soft_disc(60, 34, 20), (200, 170, 140))
    strip_path = tmp / "strip.png"
    strip.save(strip_path)

    code, payload = run_cli("slice", str(strip_path), "--frames", "2",
                            "--out", str(tmp / "cells" / "run"))
    assert code == 0 and payload["command"] == "slice" and payload["ok"] is True
    assert payload["cells"][0]["width"] == 60 and payload["even_split"] is True

    code, payload = run_cli("key", str(tmp / "cells" / "run"), "--out", str(tmp / "keyed" / "run"))
    assert code == 0 and payload["command"] == "key", payload
    assert payload["frames"][0]["bbox"] is not None

    code, payload = run_cli("align", str(tmp / "keyed"), "--out", str(tmp / "pack"))
    assert code == 0 and payload["command"] == "align", payload
    assert 0 <= payload["geometry"]["anchor"]["x"] <= 1


def test_end_to_end_produces_a_pack_that_satisfies_the_validator_rules(tmp: Path):
    """防：每一段各自正確、串起來卻產不出一套合法 pack。這條是四段真的接得起來的證據。"""
    pack_dir = build_synthetic_pack(tmp, "e2e-pack")
    manifest = json.loads((pack_dir / "pack.json").read_text())

    # 逐條對照 spec 第 6.4 節 / PackValidator 的 error 規則
    assert manifest["schemaVersion"] == 1
    assert manifest["id"] == pack_dir.name
    assert all("a" <= c <= "z" or "0" <= c <= "9" or c == "-" for c in manifest["id"])
    assert 0 <= manifest["anchor"]["x"] <= 1 and 0 <= manifest["anchor"]["y"] <= 1
    assert 24 <= manifest["logicalHeight"] <= 400
    assert len(manifest["actions"]) == 14, f"只宣告了 {sorted(manifest['actions'])}"
    assert set(manifest["actions"]) >= {"run", "sit", "sitIdle", "sleep"}

    sizes = set()
    for action, spec in manifest["actions"].items():
        files = sorted((pack_dir / action).glob("*.png"))
        assert len(files) == spec["frames"], f"{action}：宣告 {spec['frames']} 格、實際 {len(files)}"
        assert [p.name for p in files] == [f"{i:03d}.png" for i in range(len(files))]
        sizes |= {Image.open(p).size for p in files}
    assert len(sizes) == 1, f"跨動作尺寸不一致：{sizes}"


def build_synthetic_pack(tmp: Path, pack_id: str = "synthetic-cat") -> Path:
    """合成素材 → 四段管線 → 一套 pack 目錄。

    端對端測試與 `--emit-pack` 共用同一份。共用是重點：拿去餵真正的
    `PackValidator`（Swift）的那套 pack，必須就是測試裡驗過的那一套，
    不然兩邊各驗各的，中間那段沒人管。
    """
    # 14 組全上，不是只做 core 四組：這樣真正的 PackValidator 才會順便確認
    # ACTION_DEFAULTS 那張表裡每一個動作名都是它認得的（打錯一個字只會變成
    # unknownActionName warning，pack 照樣「有效」，而那組動作就靜靜地不存在）。
    plan = [("run", 4, 62), ("sit", 3, 66), ("sitIdle", 2, 60), ("sleep", 2, 70)]
    plan += [(name, 2, 64) for name in
             ("brake", "stretch", "yawn", "scratch", "lieDown",
              "stalk", "windup", "pounce", "tumble", "retreat")]
    keyed_root = tmp / "keyed"

    for action, frames, bottom in plan:
        width, height = 90 * frames, 110
        strip = Image.new("RGB", (width, height), KEY)
        for i in range(frames):
            x0 = width * i // frames
            # 每格底部、身長都不同：對齊沒做的話端對端就會露餡
            cell = rgba_shape(90, height,
                              cat_silhouette(18, 52, bottom - 34 - i * 2, bottom + i * 3, 66))
            strip.paste(cell.convert("RGB"), (x0, 0), cell)
        strip_path = tmp / f"{action}-strip.png"
        strip.save(strip_path)

        code, _ = run_cli("slice", str(strip_path), "--frames", str(frames),
                          "--out", str(tmp / "cells" / action))
        assert code == 0, f"{action} 切格失敗"
        code, payload = run_cli("key", str(tmp / "cells" / action),
                                "--out", str(keyed_root / action))
        assert code == 0, f"{action} 去背失敗：{payload.get('errors')}"

    pack_dir = tmp / pack_id
    code, payload = run_cli("align", str(keyed_root), "--out", str(pack_dir),
                            "--report", str(tmp / "geometry.json"))
    assert code == 0, payload
    code, payload = run_cli("manifest", str(pack_dir), "--geometry", str(tmp / "geometry.json"),
                            "--name", "合成測試貓", "--author", "FindMouse tools",
                            "--license", "CC0")
    assert code == 0, payload
    return pack_dir


# ── runner ──────────────────────────────────────────────────

def _harness_self_check() -> None:
    """runner 自己也是沒被驗過的程式碼。跑真正的測試之前先確認它分得出成功與失敗。"""
    def passes(_: Path) -> None:
        assert True

    def fails(_: Path) -> None:
        assert False, "故意的"

    def crashes(_: Path) -> None:
        raise IndexError("故意的")

    results = [_run_one(f) for f in (passes, fails, crashes)]
    if [ok for ok, _ in results] != [True, False, False]:
        sys.exit(f"runner 自檢失敗：{[ok for ok, _ in results]}，之後所有結果都不可採信")


def _run_one(func) -> tuple[bool, str]:
    tmp = Path(tempfile.mkdtemp(prefix="fm-tools-"))
    try:
        func(tmp)
        return True, ""
    except BaseException:  # noqa: BLE001 - crash 也是失敗，不能讓它靜靜溜過去
        return False, traceback.format_exc()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    # `--emit-pack <dir>`：把端對端那套合成 pack 落到磁碟，讓 Swift 那邊的
    # 真 PackValidator 去驗它。Python 這邊只能驗「我以為 PackValidator 要什麼」，
    # 唯一能證明產出真的餵得進程式的，是讓那份 Swift 判定親自跑一次。
    if len(sys.argv) == 3 and sys.argv[1] == "--emit-pack":
        target = Path(sys.argv[2]).resolve()
        target.mkdir(parents=True, exist_ok=True)
        pack = build_synthetic_pack(target)
        print(pack)
        return 0

    _harness_self_check()

    tests = [(name, obj) for name, obj in globals().items()
             if name.startswith("test_") and callable(obj)]
    if not tests:
        print("一條測試都沒收集到——runner 壞了，不要把這個當成通過")
        return 1

    passed = 0
    failures = []
    for name, func in tests:
        ok, detail = _run_one(func)
        summary = (func.__doc__ or "").strip().splitlines()[0] if func.__doc__ else ""
        print(f"{'✓' if ok else '✗'} {name}\n    {summary}")
        if ok:
            passed += 1
        else:
            failures.append((name, detail))

    for name, detail in failures:
        print(f"\n─── {name} ───\n{detail}")

    print(f"\n通過 {passed}／共 {len(tests)}")
    return 0 if passed == len(tests) else 1


if __name__ == "__main__":
    sys.exit(main())
