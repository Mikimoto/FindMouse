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

import numpy as np  # noqa: E402
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


def _framed_strip(shade: tuple[int, int, int], frame: int, gutter: int) -> Image.Image:
    """兩格的條子，外圍一圈白框、中間一條白間隔——生圖服務實際會吐的形狀。"""
    cell_w, cell_h = 100, 100
    width = frame * 2 + cell_w * 2 + gutter
    height = frame * 2 + cell_h
    strip = Image.new("RGB", (width, height), (255, 255, 255))
    cat = cat_silhouette(6, 60, 10, 80, 80)
    for i in range(2):
        cell, _ = composite(cell_w, cell_h, cat, (200, 160, 120), key=shade)
        strip.paste(cell, (frame + i * (cell_w + gutter), frame))
    return strip


def test_slice_trims_the_white_frame_the_service_adds(tmp: Path):
    """防：外圍白框留在格子裡。白不是洋紅、去背去不掉，每格 bbox 都會變成整格。"""
    shade = (253, 48, 247)
    _framed_strip(shade, frame=12, gutter=20).save(tmp / "strip.png")

    code, payload = run_cli("slice", str(tmp / "strip.png"), "--frames", "2",
                            "--out", str(tmp / "cells"))
    assert code == 0, payload
    assert all(c["trimmed_to"] for c in payload["cells"]), payload["cells"]

    for name in ("000.png", "001.png"):
        cell = Image.open(tmp / "cells" / name).convert("RGB")
        w, h = cell.size
        for corner in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
            r, g, b = cell.getpixel(corner)
            assert min(r, b) - g > 0, f"{name} 的 {corner} 還是白的：{(r, g, b)}"

    # 真正要證明的是下一步過得去：白框留著的話這裡會是 AMBIGUOUS_BACKGROUND
    code, payload = run_cli("key", str(tmp / "cells"), "--out", str(tmp / "keyed"))
    assert code == 0, payload
    assert [f["key"] for f in payload["frames"]] == [list(shade)] * 2, payload["frames"]
    # 邊緣不得留下半透明的白：裁切門檻對齊 bg_tolerance 就該一片都不剩
    for name in ("000.png", "001.png"):
        alpha = Image.open(tmp / "keyed" / name).convert("RGBA").getchannel("A")
        w, h = alpha.size
        edge = [alpha.getpixel((x, 0)) for x in range(w)] + \
               [alpha.getpixel((x, h - 1)) for x in range(w)] + \
               [alpha.getpixel((0, y)) for y in range(h)] + \
               [alpha.getpixel((w - 1, y)) for y in range(h)]
        assert max(edge) == 0, f"{name} 的最外圈還有 alpha={max(edge)} 的殘留"


def test_match_scales_an_edited_frame_back_to_the_reference(tmp: Path):
    """防：編輯生出來的那一格解析度不同，於是它的貓在整套 pack 裡大一號。"""
    # 不帶白框的單格：這條要驗的是縮放，混進 trim 會讓兩件事的失敗互相掩蓋
    ref, _ = composite(120, 120, cat_silhouette(8, 76, 12, 100, 100),
                       (200, 160, 120), key=(253, 48, 247))
    ref.save(tmp / "ref.png")
    # 同一張構圖、放大 1.6 倍輸出——生圖服務的編輯就是這個形狀
    ref.resize((192, 192), Image.LANCZOS).save(tmp / "edited.png")

    code, payload = run_cli("slice", str(tmp / "edited.png"), "--frames", "1",
                            "--match", str(tmp / "ref.png"), "--out", str(tmp / "out"))
    assert code == 0, payload
    assert payload["cells"][0]["resized_to"], payload["cells"][0]

    code, base = run_cli("slice", str(tmp / "ref.png"), "--frames", "1",
                         "--out", str(tmp / "base"))
    assert code == 0, base
    assert payload["cells"][0]["size"] == base["cells"][0]["size"], \
        f"{payload['cells'][0]['size']} vs {base['cells'][0]['size']}"

    # 真正要證明的是貓一樣大，不只是畫布一樣大
    got, want = (run_cli("key", str(d), "--out", str(tmp / f"k{i}"))[1]
                 for i, d in enumerate((tmp / "out", tmp / "base")))
    gb, wb = got["frames"][0]["bbox"], want["frames"][0]["bbox"]
    assert abs((gb[2] - gb[0]) - (wb[2] - wb[0])) <= 2 and \
           abs((gb[3] - gb[1]) - (wb[3] - wb[1])) <= 2, f"{gb} vs {wb}"


def test_scale_corrects_a_strip_the_service_drew_too_big(tmp: Path):
    """防：整張條子的貓都畫大了一號，而 --match 只管畫布尺寸、看不到內容大小。"""
    # 對照格與新格畫在同一張圖裡，所以兩格一起偏——這正是可以用倒數校正的前提
    big = Image.new("RGB", (240, 120), (253, 48, 247))
    for i, x0 in enumerate((10, 130)):
        cat, _ = composite(100, 100, cat_silhouette(8, 60, 10, 84, 84),
                           (200, 160, 120), key=(253, 48, 247))
        big.paste(cat.resize((100, 100)), (x0, 10))
    big.save(tmp / "strip.png")

    plain, _ = run_cli("slice", str(tmp / "strip.png"), "--frames", "2",
                       "--out", str(tmp / "a"))
    scaled, payload = run_cli("slice", str(tmp / "strip.png"), "--frames", "2",
                              "--scale", "0.5", "--out", str(tmp / "b"))
    assert plain == scaled == 0, payload
    assert all(c["scaled_by"] == 0.5 for c in payload["cells"]), payload["cells"]

    _, before = run_cli("key", str(tmp / "a"), "--out", str(tmp / "ka"))
    _, after = run_cli("key", str(tmp / "b"), "--out", str(tmp / "kb"))
    for i in range(2):
        b, a = before["frames"][i]["bbox"], after["frames"][i]["bbox"]
        assert abs((a[2] - a[0]) * 2 - (b[2] - b[0])) <= 2, f"格{i}：{a} 不是 {b} 的一半"
        assert abs((a[3] - a[1]) * 2 - (b[3] - b[1])) <= 2, f"格{i}：{a} 不是 {b} 的一半"


def test_match_refuses_a_different_composition(tmp: Path):
    """防：拿 --match 去縮一張構圖不同的圖，把貓拉扁。拉扁是靜默的。"""
    ref, _ = composite(120, 120, cat_silhouette(8, 76, 12, 100, 100),
                       (200, 160, 120), key=(253, 48, 247))
    ref.save(tmp / "ref.png")
    ref.resize((300, 150), Image.LANCZOS).save(tmp / "wrong.png")   # 長寬比整個變了

    code, payload = run_cli("slice", str(tmp / "wrong.png"), "--frames", "1",
                            "--match", str(tmp / "ref.png"), "--out", str(tmp / "out"))
    assert code != 0, payload
    assert [e["code"] for e in payload["errors"]] == ["ASPECT_MISMATCH"], payload
    assert not (tmp / "out" / "000.png").exists(), "失敗了卻還是寫了檔"


def test_slice_without_a_frame_is_left_alone(tmp: Path):
    """防：裁切在沒有白框時也動手，把貓的邊緣切掉一圈。"""
    shade = (253, 48, 247)
    _framed_strip(shade, frame=0, gutter=0).save(tmp / "strip.png")
    code, payload = run_cli("slice", str(tmp / "strip.png"), "--frames", "2",
                            "--out", str(tmp / "cells"))
    assert code == 0, payload
    assert [c["trimmed_to"] for c in payload["cells"]] == [None, None], payload["cells"]
    assert [c["size"] for c in payload["cells"]] == [[100, 100], [100, 100]], payload["cells"]


def test_auto_key_reads_the_actual_background_of_each_frame(tmp: Path):
    """防：把背景當成 FF00FF。生圖服務吐的洋紅每張都不同，差一點就要把門檻開大去吸收。"""
    shades = [(250, 56, 244), (255, 53, 242), (251, 68, 240)]
    for i, shade in enumerate(shades):
        image, _ = composite(80, 80, cat_silhouette(6, 40, 10, 52, 52),
                             (200, 160, 120), key=shade)
        image.save(tmp / f"{i:03d}.png")

    code, payload = run_cli("key", str(tmp), "--out", str(tmp / "out"))
    assert code == 0, payload
    assert [f["key"] for f in payload["frames"]] == [list(s) for s in shades], \
        f"逐格判定沒生效：{[f['key'] for f in payload['frames']]}"
    # 判對了，預設門檻就足夠：背景要全透明，不留一層薄霧
    for i in range(len(shades)):
        alpha = Image.open(tmp / "out" / f"{i:03d}.png").convert("RGBA").getchannel("A")
        assert alpha.getpixel((79, 0)) == 0, f"{i:03d} 的背景沒去乾淨"


def test_auto_key_is_not_fooled_by_a_cat_in_the_corner(tmp: Path):
    """防：貓頂到角落時把貓的顏色當成背景。那種錯完全沒有訊號——整格會被判成前景。"""
    shade = (250, 56, 244)
    cat = cat_silhouette(6, 40, 10, 52, 52)
    # **兩個**角落被貓蓋住。一個的話光靠四角取中位數就擋得下來（實測：拿掉
    # d<=0 過濾，這條照樣綠），那樣就驗不到過濾器本身。兩個才讓它成為必要條件——
    # 沒有過濾時 G 通道的中位數會落在貓身上，key 變成 (250,160,244)。
    corners = [soft_disc(0, 0, 12.0), soft_disc(0, 80, 12.0)]
    image, _ = composite(80, 80,
                         lambda x, y: max(cat(x, y), *(c(x, y) for c in corners)),
                         (200, 160, 120), key=shade)
    image.save(tmp / "000.png")

    # --despeckle 0：這個 fixture 的兩塊角落刻意與貓分離，那是 DISCONNECTED_SUBJECT
    # 的守備範圍。這條只驗 key 判定，讓兩個守衛的失敗不互相掩蓋。
    code, payload = run_cli("key", str(tmp / "000.png"), "--despeckle", "0",
                            "--out", str(tmp / "out"))
    assert code == 0, payload
    assert payload["frames"][0]["key"] == list(shade), \
        f"被角落的貓帶走了：{payload['frames'][0]['key']}"
    alpha = Image.open(tmp / "out" / "000.png").convert("RGBA").getchannel("A")
    assert alpha.getpixel((79, 40)) == 0, "key 判歪了，背景沒去乾淨"


def test_auto_key_refuses_rather_than_guesses(tmp: Path):
    """防：取樣不到背景時硬猜一個。猜錯的後果是整格被判成前景，而輸出仍是合法 PNG。"""
    image, _ = composite(80, 80, lambda x, y: 1.0, (200, 160, 120))   # 整格都是貓
    image.save(tmp / "000.png")

    code, payload = run_cli("key", str(tmp / "000.png"), "--out", str(tmp / "out"))
    assert code != 0, payload
    assert [e["code"] for e in payload["errors"]] == ["AMBIGUOUS_BACKGROUND"], payload


def _cat_plus_blob(blob_radius: float):
    """一隻貓，外加一塊完全分離、大小可調的圓形雜物（模擬角落簽名／崩壞的殘影）。"""
    cat = cat_silhouette(6, 70, 10, 90, 90)
    blob = soft_disc(102, 102, blob_radius)
    return lambda x, y: max(cat(x, y), blob(x, y))


def test_corner_signature_is_removed_and_reported(tmp: Path):
    """防：生圖服務蓋在角落的簽名把 bbox 撐到整格。它是真的不透明像素，色度門檻碰不到。"""
    image, _ = composite(120, 120, _cat_plus_blob(3.0), (200, 160, 120))
    image.save(tmp / "000.png")
    code, payload = run_cli("key", str(tmp / "000.png"), "--out", str(tmp / "out"))
    assert code == 0, payload
    frame = payload["frames"][0]

    assert len(frame["specks_removed"]) == 1, frame["specks_removed"]
    assert frame["blobs_remaining"] == 1, frame
    # bbox 必須收回貓身上——簽名在 (102,102)，貓最右到 x=90
    assert frame["bbox"][2] <= 92 and frame["bbox"][3] <= 92, \
        f"簽名還在 bbox 裡：{frame['bbox']}"
    kept = Image.open(tmp / "out" / "000.png").convert("RGBA")
    assert kept.getchannel("A").getpixel((102, 102)) == 0, "報告說抹掉了，檔案裡還在"


def test_coverage_excludes_what_despeckle_removed(tmp: Path):
    """防：報表把已經刪掉的像素算進 coverage。一個「報表說有、圖上沒有」的差距。"""
    image, _ = composite(120, 120, _cat_plus_blob(3.0), (200, 160, 120))
    image.save(tmp / "000.png")
    on, _ = run_cli("key", str(tmp / "000.png"), "--out", str(tmp / "a"))
    off, _ = run_cli("key", str(tmp / "000.png"), "--despeckle", "0", "--out", str(tmp / "b"))
    assert on == off == 0
    _, with_speck = run_cli("key", str(tmp / "000.png"), "--despeckle", "0",
                            "--out", str(tmp / "c"))
    _, without = run_cli("key", str(tmp / "000.png"), "--out", str(tmp / "d"))
    assert without["frames"][0]["coverage"] < with_speck["frames"][0]["coverage"], \
        "抹掉了東西，coverage 卻沒變小"
    opaque = Image.open(tmp / "d" / "000.png").convert("RGBA").getchannel("A")
    actual = sum(1 for v in opaque.getdata() if v > 0) / (120 * 120)
    assert abs(actual - without["frames"][0]["coverage"]) < 1e-6, \
        f"報表 {without['frames'][0]['coverage']} vs 實際 {actual}"


def test_a_large_detached_blob_is_kept_and_fails_loudly(tmp: Path):
    """防：把「生圖崩壞長出第二條尾巴」的壞格悄悄修成好格。大塊的東西要留著並報錯。"""
    image, _ = composite(120, 120, _cat_plus_blob(30.0), (200, 160, 120))
    image.save(tmp / "000.png")
    code, payload = run_cli("key", str(tmp / "000.png"), "--out", str(tmp / "out"))
    assert code != 0, payload
    assert [e["code"] for e in payload["errors"]] == ["DISCONNECTED_SUBJECT"], payload
    assert payload["frames"][0]["specks_removed"] == [], "大塊不該被抹掉"
    assert not (tmp / "out" / "000.png").exists(), "失敗了卻還是寫了檔"


def test_an_edge_hugging_sliver_is_removed_but_a_fat_one_is_not(tmp: Path):
    """防：分隔線殘留觸發 DISCONNECTED_SUBJECT，或反過來把貼邊的鬼影悄悄抹掉。"""
    cat = cat_silhouette(10, 70, 12, 100, 80)      # 尾巴止於 x=80，與直條之間留空隙

    def with_bar(width: int) -> Image.Image:
        # 貼著右緣、貫穿全高的一條——實測的分隔線殘留就是這個形狀
        def shape(x: int, y: int) -> float:
            return 1.0 if (cat(x, y) or (120 - width <= x < 120 and 8 <= y < 118)) else 0.0
        return composite(120, 120, shape, (200, 160, 120))[0]

    with_bar(4).save(tmp / "sliver.png")       # 4/120 = 3.3%，細 → 抹掉
    with_bar(20).save(tmp / "fat.png")         # 20/120 = 17%，不細 → 留著並報錯

    code, payload = run_cli("key", str(tmp / "sliver.png"), "--out", str(tmp / "a"))
    assert code == 0, payload
    assert payload["frames"][0]["blobs_remaining"] == 1, payload["frames"][0]
    bbox = payload["frames"][0]["bbox"]
    assert bbox[2] <= 82, f"細條沒被抹掉，bbox 還是 {bbox}"

    code, payload = run_cli("key", str(tmp / "fat.png"), "--out", str(tmp / "b"))
    assert code != 0, payload
    assert [e["code"] for e in payload["errors"]] == ["DISCONNECTED_SUBJECT"], payload


def test_two_strips_merge_into_one_action_and_refuse_to_overwrite(tmp: Path):
    """防：8 格分兩張生時第二張蓋掉第一張。覆蓋不留缺號，manifest 的跳號檢查看不到。"""
    def strip(tag: int) -> Path:
        # 每張條子四格，格內顏色帶著 tag，混到一起時分得出誰是誰
        img = Image.new("RGB", (40, 10), KEY)
        img.putdata([(tag, x, y) for y in range(10) for x in range(40)])
        path = tmp / f"strip{tag}.png"
        img.save(path)
        return path

    out = tmp / "cells"
    code, _ = run_cli("slice", str(strip(1)), "--frames", "4", "--out", str(out))
    assert code == 0
    code, payload = run_cli("slice", str(strip(2)), "--frames", "4",
                            "--out", str(out), "--start", "4")
    assert code == 0, payload
    assert [c["file"] for c in payload["cells"]] == \
        ["004.png", "005.png", "006.png", "007.png"], payload["cells"]

    names = sorted(p.name for p in out.glob("*.png"))
    assert names == [f"{i:03d}.png" for i in range(8)], f"合起來不是連號的 8 格：{names}"
    # 前四格必須還是第一張的內容，不能被第二張蓋掉
    assert Image.open(out / "000.png").convert("RGB").getpixel((0, 0))[0] == 1
    assert Image.open(out / "004.png").convert("RGB").getpixel((0, 0))[0] == 2

    # --start 給錯（忘了加、或接錯位）必須當場失敗，而不是默默覆蓋
    code, payload = run_cli("slice", str(strip(3)), "--frames", "4", "--out", str(out))
    assert code != 0 and [e["code"] for e in payload["errors"]] == ["FRAME_EXISTS"], payload
    assert Image.open(out / "000.png").convert("RGB").getpixel((0, 0))[0] == 1, \
        "失敗了卻還是寫了檔"
    code, payload = run_cli("slice", str(strip(3)), "--frames", "4",
                            "--out", str(out), "--force")
    assert code == 0, payload
    assert Image.open(out / "000.png").convert("RGB").getpixel((0, 0))[0] == 3, \
        "--force 沒生效"


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
    dx, dy = layout.offsets(geoms, geometry, "run")
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
    dx, _ = layout.offsets([geom], geometry, "run")

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
        dx, dy = layout.offsets(geoms[name], geometry, name)
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
    dx, dy = layout.offsets([geom], geometry, "run")
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

    # 明確給錯 key 才是這條要守的路徑；auto 判不出來是另一條（見 auto 那三條）
    code, payload = run_cli("key", str(cells), "--out", str(tmp / "keyed"), "--key", "FF00FF")
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
        dx, dy = layout.offsets(geoms, geometry, "pounce")
        bottoms = [layout.place(img, g, dx, dy[g.name], geometry)
                   .getchannel("A").getbbox()[3] for img, g in zip(images, geoms)]
        assert (len(set(bottoms)) == 1) is want_same, \
            f"{mode}：各格底緣 {bottoms}，{'應該' if want_same else '不應該'}全部相同"
        if mode == "per-action":
            assert max(bottoms) == geometry.foot_y + 1, "最低的那一格沒落在腳底線上"


def test_align_mode_is_per_action_not_per_pack(tmp: Path):
    """防：整包只能挑一種對齊。貼地的動作要逐格修漂移，騰空的逐格會被壓回地面。"""
    def blob(top: int, bottom: int) -> Image.Image:
        return rgba_shape(80, 120, lambda x, y: 1.0 if 20 <= x < 60 and top <= y < bottom else 0.0)

    # sit：兩格的底部差 12 px（生圖服務的框位漂移），逐格對齊要把它們拉齊
    # pounce：第二格整個離地 30 px，逐動作對齊要原樣保留那個高度差
    for action, frames in (("sit", [(30, 100), (30, 88)]),
                           ("pounce", [(30, 100), (10, 70)])):
        (tmp / "keyed" / action).mkdir(parents=True)
        for i, (top, bottom) in enumerate(frames):
            blob(top, bottom).save(tmp / "keyed" / action / f"{i:03d}.png")

    code, payload = run_cli("align", str(tmp / "keyed"), "--per-action", "pounce",
                            "--out", str(tmp / "pack"))
    assert code == 0, payload
    assert payload["geometry"]["per_action"] == ["pounce"], payload["geometry"]

    def bottoms(action: str) -> list[int]:
        out = []
        for path in sorted((tmp / "pack" / action).glob("*.png")):
            alpha = np.array(Image.open(path).convert("RGBA").getchannel("A"))
            out.append(int(np.nonzero(alpha > 0)[0].max()))
        return out

    assert len(set(bottoms("sit"))) == 1, f"sit 沒有被逐格拉齊：{bottoms('sit')}"
    air = bottoms("pounce")
    assert air[0] - air[1] == 30, f"pounce 的騰空高度沒保住：{air}（應差 30）"
    assert air[0] == bottoms("sit")[0], "兩組動作的著地格沒有落在同一條腳底線上"


def test_per_action_rejects_an_action_that_does_not_exist(tmp: Path):
    """防：--per-action 打錯字時默默當成沒指定，於是騰空的那組被壓回地面。"""
    (tmp / "keyed" / "pounce").mkdir(parents=True)
    rgba_shape(80, 120, lambda x, y: 1.0 if 20 <= x < 60 and 30 <= y < 100 else 0.0) \
        .save(tmp / "keyed" / "pounce" / "000.png")

    code, payload = run_cli("align", str(tmp / "keyed"), "--per-action", "pounse",
                            "--out", str(tmp / "pack"))
    assert code != 0, payload
    assert [e["code"] for e in payload["errors"]] == ["UNKNOWN_ACTION"], payload


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


def test_command_line_flags_actually_reach_the_algorithm(tmp: Path):
    """防：旗標是裝飾品。上面的測試都直接呼叫函式，argparse 接錯的話一條都不會紅。"""
    # --key：背景偏成 F20AEE。指定成 FF00FF 會整格找不到背景（硬失敗），給對才過
    drifted, _ = composite(40, 40, soft_disc(20, 24, 12), (200, 200, 200), key=(242, 10, 238))
    cells = tmp / "drifted"
    cells.mkdir()
    drifted.save(cells / "000.png")
    code, payload = run_cli("key", str(cells), "--out", str(tmp / "k1"), "--key", "FF00FF")
    assert code == 1 and "NO_BACKGROUND_FOUND" in [e["code"] for e in payload["errors"]], payload
    code, payload = run_cli("key", str(cells), "--out", str(tmp / "k2"), "--key", "F20AEE")
    assert code == 0, payload

    # --bg-tolerance：髒背景，門檻歸零時 bbox 會被雜訊撐大。
    # 抖動必須**逐像素**：整片均勻位移的話 --key auto 會判得剛剛好，門檻就沒事做了
    # （原本這裡寫成均勻位移，auto 上線後這個子案例就悄悄失去鑑別力）。
    noisy = Image.new("RGB", (40, 40))
    clean, _ = composite(40, 40, soft_disc(20, 24, 10, feather=1), (200, 200, 200))
    def jitter(i, c, sign):
        return max(0, min(255, c + sign * ((i * 2654435761) % 9 - 4)))
    noisy.putdata([(jitter(i, r, -1), jitter(i + 1, g, +1), b) if (r, g, b) == (255, 0, 255)
                   else (r, g, b)
                   for i, (r, g, b) in enumerate(clean.get_flattened_data())])
    dirty = tmp / "noisy"
    dirty.mkdir()
    noisy.save(dirty / "000.png")
    _, loose = run_cli("key", str(dirty), "--out", str(tmp / "k3"))
    _, strict = run_cli("key", str(dirty), "--out", str(tmp / "k4"), "--bg-tolerance", "0")
    assert loose["frames"][0]["bbox"] != strict["frames"][0]["bbox"], \
        f"--bg-tolerance 改了也沒差：兩次都是 {loose['frames'][0]['bbox']}"

    # --align：per-action 時整組共用同一個垂直位移，per-frame 則各格不同
    keyed = tmp / "keyed" / "pounce"
    keyed.mkdir(parents=True)
    for i, bottom in enumerate((60, 44)):
        rgba_shape(60, 80, cat_silhouette(10, 30, bottom - 30, bottom, 40)).save(
            keyed / f"{i:03d}.png")
    dys = {}
    for mode in layout.ALIGN_MODES:
        code, payload = run_cli("align", str(tmp / "keyed"), "--out", str(tmp / f"p-{mode}"),
                                "--align", mode)
        assert code == 0 and payload["geometry"]["align"] == mode, payload
        dys[mode] = {f["dy"] for f in payload["actions"][0]["frames"]}
    assert len(dys["per-frame"]) == 2, f"per-frame 各格的位移應該不同：{dys['per-frame']}"
    assert len(dys["per-action"]) == 1, f"per-action 應該整組共用一個位移：{dys['per-action']}"

    # manifest 的 --fps / --loop 覆寫
    pack = tmp / "flag-pack"
    for action in ("run", "sit", "sitIdle", "sleep"):
        (pack / action).mkdir(parents=True)
        Image.new("RGBA", (20, 20)).save(pack / action / "000.png")
    code, payload = run_cli("manifest", str(pack), "--anchor", "0.5,0.94",
                            "--fps", "run=30", "--loop", "run=false")
    assert code == 0, payload
    run_spec = payload["manifest"]["actions"]["run"]
    assert run_spec["fps"] == 30 and run_spec["loop"] is False, run_spec
    assert payload["manifest"]["actions"]["sleep"]["fps"] == 3, "沒被覆寫的動作不該跟著變"


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



def test_downscale_does_not_bleed_colour_from_transparent_pixels(tmp: Path):
    """防：縮圖直接對 unpremultiplied RGBA 做 LANCZOS，邊緣長出一圈色暈。"""
    # 去背之後，全透明像素的 RGB 是**任意值**——`key_frame` 只保證 alpha 正確。
    # 這裡把那些值放成一個絕不該出現在結果裡的顏色，讓汙染看得見。
    fg = (240, 60, 60)
    poison = (0, 255, 0)
    disc = soft_disc(32, 32, 22, feather=3)
    image = Image.new("RGBA", (64, 64))
    image.putdata([
        (*(fg if disc(x, y) > 0 else poison), round(disc(x, y) * 255))
        for y in range(64) for x in range(64)
    ])

    small = chroma.downscale_rgba(image, 32, 32)
    assert small.size == (32, 32), f"縮出來是 {small.size}"

    checked = 0
    for r, g, b, a in small.getdata():
        # 門檻取 32 而不是 1：LANCZOS 的振鈴會在圖形外緣造出「有一點 alpha
        # 但本來就沒有顏色」的像素，那些位置的 RGB 是 0 屬正常，不是汙染。
        if a < 32:
            continue
        checked += 1
        assert g < 120, f"縮圖後出現綠色汙染：({r},{g},{b},a={a})——透明像素被加權進來了"
        assert r > g, f"紅色不再主導：({r},{g},{b},a={a})"
    assert checked > 200, f"只驗到 {checked} 個不透明像素，樣本太少"



def test_max_height_caps_the_canvas_and_keeps_the_anchor_fraction(tmp: Path):
    """防：--max-height 是裝飾品，或縮圖把 anchor 的相對位置弄歪。"""
    # 造一組明顯高於上限的格子
    for i in range(3):
        d = tmp / "keyed" / "run"
        d.mkdir(parents=True, exist_ok=True)
        rgba_shape(400, 600, cat_silhouette(120, 260, 200, 520 + i * 10, 320)) \
            .save(d / f"{i:03d}.png")

    big = tmp / "big"
    small = tmp / "small"
    code, full = run_cli("align", str(tmp / "keyed"), "--out", str(big))
    assert code == 0, full
    code, capped = run_cli("align", str(tmp / "keyed"), "--out", str(small),
                           "--max-height", "128")
    assert code == 0, capped

    for path in sorted((small / "run").glob("*.png")):
        w, h = Image.open(path).size
        assert h <= 128, f"{path.name} 高 {h}，超過上限 128"

    # 沒有上限那次一定比 128 高，否則這條測試是恆真句
    tall = Image.open(sorted((big / "run").glob("*.png"))[0]).height
    assert tall > 128, f"未設上限時只有 {tall} 高，這個 fixture 證明不了 --max-height 有作用"

    # anchor 是**相對座標**，等比縮放不該改變它——改變了就代表縮圖動到了版面
    assert abs(full["geometry"]["anchor"]["x"] - capped["geometry"]["anchor"]["x"]) < 1e-9
    assert abs(full["geometry"]["anchor"]["y"] - capped["geometry"]["anchor"]["y"]) < 1e-9


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
