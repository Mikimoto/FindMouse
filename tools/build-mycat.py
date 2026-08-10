#!/usr/bin/env python3
"""從 raw/ 重建內建的 mycat pack。`python3 tools/build-mycat.py`

切格 → 去背 → 排版 → 產 manifest，一路到可以直接 `findmouse pack validate` 的目錄。

這支不是通用工具，是**這一套 pack 的來源清單**——哪一張條子的哪一格對應哪一幀。
手動組過幾次之後就會組錯（尤其對照格在第一格還是最後一格，兩種都存在），
寫下來才有單一真實來源。

`control` 欄是對照格的索引（`None` 表示那張條子生成時還沒有對照格協定）。
有對照格的條子會先量它與定錨圖的 bbox 比，把倒數傳給 `slice --scale`——
同一張圖內各格的尺度一致，所以對照格偏幾倍，同張圖裡的新格就偏幾倍。
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import chroma  # noqa: E402
import layout  # noqa: E402

#: raw/ 底下有三個**衍生**的定錨圖，不是生圖服務的原始輸出。它們被刪掉時
#: 這支腳本會直接失敗，所以把來源記在這裡：
#:
#:   sit-final.png    ← sit-2.png 的第 2 格（去掉外框後裁出）
#:   sleep-final.png  ← sleep-pose.png 的第 2 格
#:                      （slice --frames 2 的 001.png）
#:   windup-final.png ← windup-1.png 的第 1 格
#:                      （slice --frames 3 --scale 0.9340 的 000.png）
#:
#: 其餘的 .png 都是生圖服務的原始輸出。ref.png / ref-clean.png 不被這支腳本
#: 使用，但是**每一次生成都要附的參考表**，而且無法從別的檔案復原，不要刪。
RAW = ROOT / "raw"
WORK = ROOT / "work"
#: 出貨位置。**直接輸出到 app 的內建 pack 目錄**，不再落在 gitignore 的
#: `packs/` 底下——mycat 是出廠預設，它必須跟著 .app 一起出貨。
#: `Package.swift` 的 `.copy("Resources/Packs")` 會把整個目錄打包進去。
#: 這也讓 `git diff` 順便變成「一鍵重建是否可重現」的檢查。
PACK = ROOT / "Sources" / "FindMouseAdapters" / "Resources" / "Packs" / "mycat"

#: 輸出畫布高度上限。素材原生是 1069px，而 logicalHeight 96pt 的貓在 Mac
#: 最高的 @2x 螢幕上（含 cat.scale 上限）也只要約 307px——原生尺寸是 12 倍的
#: 像素量，60 張就是 39MB。384px 留了兩成餘裕，整套約 7MB。
MAX_HEIGHT = 384
PIPELINE = ROOT / "tools" / "pipeline.py"
ANCHOR = RAW / "sit-final.png"

PACK_NAME = "橘白蓬鬆貓"
PACK_AUTHOR = "Gemini 2.5 Flash Image (Nano Banana)"
PACK_LICENSE = "TBD"

#: 動作 → [(條子, 格數, 對照格索引 或 None, [要用的格索引])]
#: 順序就是幀的順序。`match` 的那幾組是單張編輯出來的，靠 --match 對齊解析度。
SOURCES: dict[str, list[tuple[str, int, int | None, list[int]]]] = {
    "run":     [(f"run-{i}.png", 2, None, [0, 1]) for i in (1, 2, 3, 4)],
    "sit":     [(f"sit-{i}.png", 2, None, [0, 1]) for i in (1, 2)],
    "yawn":    [("yawn-1.png", 2, 0, [1]), ("yawn-2.png", 3, 0, [1, 2])],
    "stretch": [("stretch-1.png", 3, 2, [0, 1]), ("stretch-2.png", 3, 2, [0, 1])],
    "scratch": [("scratch-1.png", 3, 0, [1, 2]), ("scratch-2.png", 3, 2, [0, 1])],
    "lieDown": [("lieDown-1.png", 3, 0, [1, 2]), ("lieDown-2.png", 3, 2, [0, 1])],
    "brake":   [("brake-1.png", 3, 2, [0, 1]), ("brake-2.png", 3, 0, [1, 2])],
    "stalk":   [("stalk-1.png", 3, 2, [0, 1]), ("stalk-2.png", 3, 2, [0, 1])],
    "pounce":  [("pounce-1.png", 3, 2, [0, 1]), ("pounce-2.png", 3, 2, [0, 1])],
    "tumble":  [("tumble-1.png", 3, 2, [0, 1]), ("tumble-2.png", 3, 2, [0, 1])],
    "retreat": [("retreat-1.png", 3, 2, [0, 1]), ("retreat-2.png", 3, 2, [0, 1])],
}

#: 整隻騰空的動作。逐格對齊會把它壓回地面，所以 align 要用 --per-action。
AIRBORNE = ("pounce",)

#: 用單張編輯做出來的循環。第一格直接用定錨圖本身，接縫因此天生完美。
#: 對稱呼吸：靜止 → 半 → 全 → 半，所以第四格複用第二格。
#: 順序按**實測覆蓋率**排，不按檔名的標籤——模型不照要求的百分比縮放。
EDITED: dict[str, tuple[str, list[str]]] = {
    "sitIdle": ("sit-final.png",
                ["sit-final.png", "idle-test.png", "idle-full.png", "idle-test.png"]),
    "sleep":   ("sleep-final.png",
                ["sleep-final.png", "sleep-full.png", "sleep-half.png", "sleep-full.png"]),
    # windup 原本用生成法，四格裡有兩格站了起來或把尾巴翹上去。它其實是近乎
    # 靜止的循環（蹲著等撲），所以改用編輯法。定錨是生成版第一格那個好的蹲姿。
    # 實測抬高只有 7 px／594（1.2%），在 96pt 下是次像素——形同一張靜止的蹲姿。
    "windup":  ("windup-final.png",
                ["windup-final.png", "windup-half.png",
                 "windup-full.png", "windup-half.png"]),
}


class StepFailed(Exception):
    def __init__(self, argv: tuple[str, ...], output: str):
        super().__init__(output)
        self.argv = argv
        self.output = output


def run(*argv: str) -> None:
    proc = subprocess.run([sys.executable, str(PIPELINE), *argv],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise StepFailed(argv, proc.stdout + proc.stderr)


def subject_size(path: Path) -> tuple[int, int]:
    image = Image.open(path).convert("RGB")
    rgba, _ = chroma.key_frame(image, key=chroma.detect_key(image))
    alpha = np.array(rgba.getchannel("A"))
    ys, xs = np.nonzero(alpha > 0)
    return int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1)


def anchor_size() -> tuple[int, int]:
    image = Image.open(ANCHOR).convert("RGB")
    box = layout.key_bbox(image)
    return subject_size_of(image.crop(box) if box else image)


def subject_size_of(image: Image.Image) -> tuple[int, int]:
    rgba, _ = chroma.key_frame(image, key=chroma.detect_key(image))
    alpha = np.array(rgba.getchannel("A"))
    ys, xs = np.nonzero(alpha > 0)
    return int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1)


def main() -> int:
    scratch = WORK / "tmp"
    for path in (WORK / "cells", WORK / "keyed", scratch):
        shutil.rmtree(path, ignore_errors=True)
    aw, ah = anchor_size()
    print(f"定錨的貓 {aw}×{ah}\n")

    for action, strips in SOURCES.items():
        out = WORK / "cells" / action
        out.mkdir(parents=True)
        index = 0
        for strip, count, control, wanted in strips:
            plain = scratch / f"{action}-{strip}-plain"
            run("slice", str(RAW / strip), "--frames", str(count), "--out", str(plain))
            factor = 1.0
            if control is not None:
                cw, ch = subject_size(plain / f"{control:03d}.png")
                factor = ((aw / cw) + (ah / ch)) / 2
            sized = scratch / f"{action}-{strip}"
            run("slice", str(RAW / strip), "--frames", str(count),
                "--scale", f"{factor:.4f}", "--out", str(sized))
            if control is not None:
                cw, ch = subject_size(sized / f"{control:03d}.png")
                print(f"  {action:8s} {strip:16s} ×{factor:.4f}  "
                      f"對照格校正後 {cw / aw:.1%} / {ch / ah:.1%}")
            for cell in wanted:
                shutil.copy(sized / f"{cell:03d}.png", out / f"{index:03d}.png")
                index += 1

    for action, (match, frames) in EDITED.items():
        out = WORK / "cells" / action
        out.mkdir(parents=True)
        for index, source in enumerate(frames):
            single = scratch / f"{action}-{index}"
            run("slice", str(RAW / source), "--frames", "1",
                "--match", str(RAW / match), "--out", str(single))
            shutil.copy(single / "000.png", out / f"{index:03d}.png")
        print(f"  {action:8s} {len(frames)} 格（單張編輯，--match {match}）")

    # 一組壞掉不該擋住其餘的診斷——那會讓「還有哪幾組也有問題」要一輪一輪試才知道。
    print()
    broken: list[tuple[str, str]] = []
    for action in sorted({*SOURCES, *EDITED}):
        try:
            run("key", str(WORK / "cells" / action), "--out", str(WORK / "keyed" / action))
        except StepFailed as exc:
            broken.append((action, exc.output))
            shutil.rmtree(WORK / "keyed" / action, ignore_errors=True)
            print(f"  key {action} ✗")
            continue
        print(f"  key {action} ✓")
    shutil.rmtree(scratch, ignore_errors=True)

    if broken:
        print(f"\n{len(broken)} 組沒過，停在這裡不排版（排出來會缺動作而看不出是缺的）：")
        for action, output in broken:
            for line in output.splitlines():
                if line.lstrip().startswith("✗"):
                    print(f"  {action}: {line.strip()}")
        return 1

    print()
    shutil.rmtree(PACK, ignore_errors=True)
    run("align", str(WORK / "keyed"), "--per-action", ",".join(AIRBORNE),
        "--max-height", str(MAX_HEIGHT),
        "--out", str(PACK), "--report", str(WORK / "geom.json"))
    run("manifest", str(PACK), "--geometry", str(WORK / "geom.json"),
        "--name", PACK_NAME, "--author", PACK_AUTHOR, "--license", PACK_LICENSE)
    print(f"  align + manifest → {PACK}")
    print(f"\n驗收：findmouse pack validate {PACK}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
