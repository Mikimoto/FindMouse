#!/usr/bin/env python3
"""從 raw/ 重建 packs/mycat。`python3 tools/build-mycat.py`

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

RAW = ROOT / "raw"
WORK = ROOT / "work"
PIPELINE = ROOT / "tools" / "pipeline.py"
ANCHOR = RAW / "sit-final.png"

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
}

#: 用單張編輯做出來的循環。第一格直接用定錨圖本身，接縫因此天生完美。
#: 對稱呼吸：靜止 → 半 → 全 → 半，所以第四格複用第二格。
#: 順序按**實測覆蓋率**排，不按檔名的標籤——模型不照要求的百分比縮放。
EDITED: dict[str, tuple[str, list[str]]] = {
    "sitIdle": ("sit-final.png",
                ["sit-final.png", "idle-test.png", "idle-full.png", "idle-test.png"]),
    "sleep":   ("sleep-final.png",
                ["sleep-final.png", "sleep-full.png", "sleep-half.png", "sleep-full.png"]),
}


def run(*argv: str) -> None:
    proc = subprocess.run([sys.executable, str(PIPELINE), *argv],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"失敗：{' '.join(argv)}\n{proc.stdout}{proc.stderr}")


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

    print()
    for action in sorted({*SOURCES, *EDITED}):
        run("key", str(WORK / "cells" / action), "--out", str(WORK / "keyed" / action))
        print(f"  key {action} ✓")
    shutil.rmtree(scratch, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
