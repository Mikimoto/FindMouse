#!/usr/bin/env python3
"""把 AI 生圖的橫排多格圖變成一套 sprite pack（spec 第 11 節第 5 條）。

四個子命令，各自可以單獨跑：

    slice     一張橫排 N 格的圖  → N 張原色格子
    key       原色格子           → 去背後的 RGBA
    align     去背後的 RGBA      → 共同畫布 ＋ 對齊腳底線 ＋ 算出 anchor
    manifest  排好的 pack 目錄   → pack.json

為什麼不做成一個黑箱：spec 第 11 節第 6 條要求「抖的那格只重生那一格，
不重生整組」。四段拆開，重生一格之後只要對那一格跑 key，再對整組跑 align 即可；
要在既有的 pack 上補一個新動作，則用 `align --geometry` pin 住舊版面，
其他動作的 PNG 一個位元都不會變。

每個子命令都吃 `--json`，輸出機器可讀的結果（每格的 bbox、背景比例、算出來的
anchor…）。這個介面同時是測試介面——`test_pipeline.py` 驗的就是它，
而不是拿眼睛看圖。

失敗一律 exit code 1 並在 `--json` 的 `errors` 裡帶錯誤碼；參數寫錯是 2（argparse）。
「什麼都沒做卻回報成功」的路徑要一條都不留：空白格、找不到背景、放不進畫布、
檔名跳號，全部是硬失敗。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from PIL import Image  # noqa: E402

import chroma  # noqa: E402
import layout  # noqa: E402
from chroma import ChromaError  # noqa: E402

#: 生圖指引（docs/superpowers/plans/2026-08-08-m6-asset-generation-guide.md）那張表的
#: fps 與 loop。frames **不在這裡**——它一律用目錄裡實際的檔案數，
#: 因為「宣告 N 格但目錄裡不是 N 張」正好是 PackValidator 的一條 error，
#: 由這支腳本數出來就從構造上消掉整個錯誤類別。
ACTION_DEFAULTS: dict[str, tuple[float, bool]] = {
    "run": (14, True),
    "brake": (12, False),
    "sit": (10, False),
    "sitIdle": (6, True),
    "stretch": (10, False),
    "yawn": (8, False),
    "scratch": (12, False),
    "lieDown": (8, False),
    "sleep": (3, True),
    "stalk": (8, True),
    "windup": (8, True),
    "pounce": (18, False),
    "tumble": (14, False),
    "retreat": (12, False),
}

CORE_ACTIONS = ("run", "sit", "sitIdle", "sleep")

FRAME_NAME = "%03d.png"


# ── 共用小工具 ─────────────────────────────────────────────

def parse_hex_colour(text: str) -> tuple[int, int, int]:
    value = text.lstrip("#")
    if len(value) != 6:
        raise ChromaError("INVALID_KEY_COLOUR", f"背景色要寫成 RRGGBB，收到 {text!r}")
    try:
        return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]
    except ValueError as exc:
        raise ChromaError("INVALID_KEY_COLOUR", f"背景色解不開：{text!r}") from exc


def png_files(directory: Path) -> list[Path]:
    """依檔名排序的 PNG。

    排序不可省，理由與 `SpritePackRepository.listing` 相同：frameIndex 是位置索引，
    目錄列舉的順序沒有保證，不排的話動畫的格序是隨機的。
    """
    return sorted(p for p in directory.iterdir()
                  if p.is_file() and p.suffix.lower() == ".png")


def action_dirs(root: Path) -> dict[str, Path]:
    return {p.name: p for p in sorted(root.iterdir()) if p.is_dir()}


def ensure_out(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def emit(args: argparse.Namespace, payload: dict, lines: list[str]) -> int:
    """統一的輸出。ok 為 false 時 exit 1。"""
    if args.json:
        json.dump(payload, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        for line in lines:
            print(line)
    return 0 if payload.get("ok") else 1


# ── slice ──────────────────────────────────────────────────

def cmd_slice(args: argparse.Namespace) -> int:
    strip = Image.open(args.strip)
    ranges = layout.cell_ranges(strip.width, args.frames)
    out = ensure_out(Path(args.out))

    cells = list(zip(layout.slice_strip(strip, args.frames), ranges))

    # 先檢查再寫：--start 給錯會覆蓋掉前一張條子切出來的格子，而覆蓋不留缺號，
    # 所以 manifest 的 FRAME_NAME_GAP 抓不到——那是一套格數對、內容錯的 pack。
    if not args.force:
        clashes = [FRAME_NAME % (args.start + i) for i in range(len(cells))
                   if (out / (FRAME_NAME % (args.start + i))).exists()]
        if clashes:
            raise ChromaError(
                "FRAME_EXISTS",
                f"{out} 底下已經有 {', '.join(clashes[:4])}"
                f"{' 等' if len(clashes) > 4 else ''}。"
                "--start 是不是給錯了？確定要蓋就加 --force")

    written = []
    for index, (cell, (x0, x1)) in enumerate(cells, start=args.start):
        path = out / (FRAME_NAME % index)
        cell.save(path)
        written.append({"index": index, "file": path.name,
                        "x0": x0, "x1": x1, "width": x1 - x0})

    widths = [c["width"] for c in written]
    even = len(set(widths)) == 1
    payload = {
        "ok": True,
        "command": "slice",
        "source": str(args.strip),
        "source_size": [strip.width, strip.height],
        "frames": args.frames,
        # 寬度不整除時各格會差 1 px。這不是錯，但值得看得見——差很多就代表
        # --frames 給錯了，而那種圖切出來每一格都是半隻貓，人反而看得出來。
        "even_split": even,
        "cells": written,
        "out": str(out),
    }
    lines = [f"切出 {args.frames} 格 → {out}／"
             f"{written[0]['file']}–{written[-1]['file']}",
             f"  原圖 {strip.width}×{strip.height}，"
             f"格寬 {min(widths)}–{max(widths)} px，{'等寬' if even else '不整除（差 1 px）'}"]
    return emit(args, payload, lines)


# ── key ────────────────────────────────────────────────────

def cmd_key(args: argparse.Namespace) -> int:
    auto = args.key.lower() == "auto"
    key = None if auto else parse_hex_colour(args.key)
    source = Path(args.input)
    sources = [source] if source.is_file() else png_files(source)
    if not sources:
        raise ChromaError("NO_INPUT_FRAMES", f"{source} 底下找不到 PNG")

    out = ensure_out(Path(args.out))
    frames: list[dict] = []
    errors: list[dict] = []
    keyed: list[tuple[Path, Image.Image]] = []

    for path in sources:
        image = Image.open(path)
        # auto 是逐格判定的：同一張條子裡每格的背景色都不一樣，這正是重點。
        # 判不出來要跟其他每格問題一樣收集成 error，不能 raise 掉整批——
        # 一格壞掉就看不到其餘各格的診斷，等於要一格一格試才知道全貌。
        try:
            frame_key = chroma.detect_key(image.convert("RGB")) if auto else key
        except ChromaError as exc:
            errors.append({"code": exc.code, "file": path.name, "detail": exc.message})
            frames.append({"file": path.name, "key": None})
            continue
        rgba, stats = chroma.key_frame(image, key=frame_key,
                                       bg_tolerance=args.bg_tolerance,
                                       fg_tolerance=args.fg_tolerance,
                                       despeckle_fraction=args.despeckle)
        keyed.append((path, rgba))
        record = {"file": path.name, "key": list(frame_key), **stats.to_json()}

        # 三條硬失敗。共同點是「產出會是一張合法 PNG，但內容毫無意義」——
        # 不擋的話後面每一步都會照常成功，最後得到一套看起來完整的空 pack。
        if stats.coverage <= 0:
            errors.append({"code": "EMPTY_FRAME", "file": path.name,
                           "detail": "整格都是背景。生圖失敗的空格，重生這一格。"})
        elif stats.coverage < args.min_coverage:
            errors.append({"code": "NEARLY_EMPTY_FRAME", "file": path.name,
                           "detail": f"只有 {stats.coverage:.4%} 的像素留下來，"
                                     f"低於 --min-coverage {args.min_coverage:.4%}。"})
        if stats.blobs_remaining > 1:
            errors.append({"code": "DISCONNECTED_SUBJECT", "file": path.name,
                           "detail": f"去背後還有 {stats.blobs_remaining} 塊互不相連的東西。"
                                     "貓應該是一塊——多出來的通常是生圖崩壞長出的第二條"
                                     "尾巴或殘影，重生這一格。真的是刻意分離的造型就調"
                                     "--despeckle。"})
        if stats.background_ratio <= 0:
            errors.append({"code": "NO_BACKGROUND_FOUND", "file": path.name,
                           "detail": f"沒有任何像素被判為背景，四角取樣到 "
                                     f"{stats.sampled_corner}。--key {args.key} 大概不對。"})

        frames.append(record)

    payload = {
        "ok": not errors,
        "command": "key",
        "key": "auto" if auto else list(key),
        "bg_tolerance": args.bg_tolerance,
        "fg_tolerance": args.fg_tolerance,
        "frames": frames,
        "errors": errors,
        "out": str(out),
    }

    # 有任何一格壞掉就一張都不寫。寫一半的目錄會讓下一步用舊檔跑得很開心，
    # 而那些舊檔來自上一輪——這是這個 repo 踩過的「靜默用了舊內容」那一類。
    if not errors:
        for path, rgba in keyed:
            rgba.save(out / path.name)

    lines = [f"去背 {len(sources)} 格（key={args.key}）"]
    if auto:
        lines[0] += "，逐格自動判定"
    for record in frames:
        if record.get("key") is None:
            lines.append(f"  {record['file']}: 判不出背景色，見下方錯誤")
            continue
        lines.append(f"  {record['file']}: 覆蓋 {record['coverage']:.2%}"
                     f"、背景 {record['background_ratio']:.2%}、bbox {record['bbox']}"
                     + (f"、key #{bytes(record['key']).hex().upper()}" if auto else ""))
        for speck in record["specks_removed"]:
            lines.append(f"      抹掉碎塊 {speck['pixels']} px @ {speck['bbox']}")
    for error in errors:
        lines.append(f"  ✗ [{error['code']}] {error['file']}：{error['detail']}")
    lines.append(f"→ {out}" if not errors else "→ 有失敗的格，一張都沒寫出")
    return emit(args, payload, lines)


# ── align ──────────────────────────────────────────────────

def cmd_align(args: argparse.Namespace) -> int:
    root = Path(args.input)
    dirs = action_dirs(root)
    if not dirs:
        raise ChromaError("NO_ACTIONS", f"{root} 底下沒有動作子目錄")

    loaded: dict[str, list[tuple[Path, Image.Image]]] = {}
    geoms: dict[str, list[layout.FrameGeom]] = {}
    for name, directory in dirs.items():
        files = png_files(directory)
        if not files:
            raise ChromaError("EMPTY_ACTION_DIRECTORY", f"{name}/ 裡沒有 PNG")
        loaded[name] = [(p, Image.open(p).convert("RGBA")) for p in files]
        geoms[name] = [layout.frame_geometry(img, f"{name}/{p.name}", args.foot_band)
                       for p, img in loaded[name]]

    if args.geometry:
        geometry = layout.Geometry.from_json(json.loads(Path(args.geometry).read_text()))
    else:
        geometry = layout.plan(geoms, align=args.align,
                               pad_frac=args.pad, bottom_pad_frac=args.bottom_pad)

    out = ensure_out(Path(args.out))
    actions_report = []
    for name in dirs:
        dx, dy = layout.offsets(geoms[name], geometry)
        action_out = ensure_out(out / name)
        frames_report = []
        for index, ((path, image), geom) in enumerate(zip(loaded[name], geoms[name])):
            placed = layout.place(image, geom, dx, dy[geom.name], geometry)
            target = action_out / (FRAME_NAME % index)
            placed.save(target)
            frames_report.append({
                "index": index,
                "source": path.name,
                "file": target.name,
                "bbox": list(geom.bbox),
                "foot_x": round(geom.foot_x, 3),
                "dx": dx,
                "dy": dy[geom.name],
            })
        actions_report.append({
            "action": name,
            "frames": frames_report,
            "foot_x_mean": round(layout.action_foot_x(geoms[name]), 3),
            # 組內腳底中點的跨度。跑步循環幾 px 是正常的，幾十 px 就是框位漂了。
            "horizontal_drift_px": round(layout.horizontal_drift(geoms[name]), 3),
        })

    payload = {
        "ok": True,
        "command": "align",
        "geometry": geometry.to_json(),
        "actions": actions_report,
        "out": str(out),
    }
    if args.report:
        Path(args.report).write_text(
            json.dumps(geometry.to_json(), ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    lines = [f"排版 {len(dirs)} 組動作 → {out}",
             f"  畫布 {geometry.canvas_width}×{geometry.canvas_height}"
             f"、腳底線 y={geometry.foot_y}（{args.align if not args.geometry else geometry.align}）",
             f"  anchor = ({geometry.anchor_x:.4f}, {geometry.anchor_y:.4f})"]
    for report in actions_report:
        lines.append(f"  {report['action']}: {len(report['frames'])} 格"
                     f"、腳底中點跨度 {report['horizontal_drift_px']} px")
    return emit(args, payload, lines)


# ── manifest ───────────────────────────────────────────────

def cmd_manifest(args: argparse.Namespace) -> int:
    pack = Path(args.pack)
    dirs = action_dirs(pack)
    errors: list[dict] = []
    warnings: list[dict] = []

    if args.geometry:
        geometry = layout.Geometry.from_json(json.loads(Path(args.geometry).read_text()))
        anchor = (geometry.anchor_x, geometry.anchor_y)
    elif args.anchor:
        try:
            ax, ay = (float(v) for v in args.anchor.split(","))
        except ValueError as exc:
            raise ChromaError("INVALID_ANCHOR", f"--anchor 要寫成 x,y，收到 {args.anchor!r}") from exc
        anchor = (ax, ay)
    else:
        raise ChromaError("MISSING_ANCHOR",
                          "要嘛 --geometry 指向 align 產生的檔，要嘛 --anchor x,y。"
                          "沒有 anchor 的 pack 換一套貓就會浮在半空（spec 第 6.2 節）。")

    # 與 PackValidator.isValidID 同一條規則：ASCII 的 [a-z0-9-]+。
    # 不能用 str.islower()／isdigit()——那是 Unicode 全域屬性，會放行 ünïcode 與 ٣，
    # 而 id 下一步就是目錄名，正規化差異會讓「id 與目錄名不符」這條檢查看不出來。
    pack_id = args.id or pack.name
    if not pack_id or not all("a" <= c <= "z" or "0" <= c <= "9" or c == "-" for c in pack_id):
        errors.append({"code": "INVALID_ID", "detail": f"id {pack_id!r} 不符 [a-z0-9-]+"})
    if pack_id != pack.name:
        errors.append({"code": "ID_DIRECTORY_MISMATCH",
                       "detail": f"id {pack_id!r} 與目錄名 {pack.name!r} 不同"})
    if not 0 <= anchor[0] <= 1 or not 0 <= anchor[1] <= 1:
        errors.append({"code": "ANCHOR_OUT_OF_RANGE", "detail": f"anchor={anchor}"})
    if not 24 <= args.logical_height <= 400:
        errors.append({"code": "LOGICAL_HEIGHT_OUT_OF_RANGE",
                       "detail": f"logicalHeight={args.logical_height} 不在 24…400"})

    overrides_fps = dict(kv.split("=", 1) for kv in args.fps)
    overrides_loop = dict(kv.split("=", 1) for kv in args.loop)

    actions: dict[str, dict] = {}
    sizes: set[tuple[int, int]] = set()
    for name, directory in dirs.items():
        if name not in ACTION_DEFAULTS:
            errors.append({"code": "UNKNOWN_ACTION",
                           "detail": f"{name}/ 不是 14 個動作之一，pack.json 不會宣告它"})
            continue
        files = png_files(directory)
        if not files:
            errors.append({"code": "EMPTY_ACTION_DIRECTORY", "detail": f"{name}/ 裡沒有 PNG"})
            continue

        # 檔名必須是 000…N-1 的連號。`SpriteRepository` 依排序後的**位置**取格，
        # 跳號不會有錯誤，只會讓整段動畫錯格播——這是 PackValidator 看不到的洞
        # （它只數張數）。
        expected = [FRAME_NAME % i for i in range(len(files))]
        actual = [p.name for p in files]
        if actual != expected:
            errors.append({"code": "FRAME_NAME_GAP",
                           "detail": f"{name}/ 的檔名不是 000…{len(files) - 1:03d} 連號：{actual}"})

        frame_sizes = {Image.open(p).size for p in files}
        if len(frame_sizes) > 1:
            errors.append({"code": "INCONSISTENT_SIZE_WITHIN_ACTION",
                           "detail": f"{name}/ 有 {sorted(frame_sizes)} 兩種以上尺寸"})
        sizes |= frame_sizes

        fps, loop = ACTION_DEFAULTS[name]
        if name in overrides_fps:
            fps = float(overrides_fps[name])
        if name in overrides_loop:
            loop = overrides_loop[name].lower() in ("1", "true", "yes")
        actions[name] = {"frames": len(files), "fps": fps, "loop": loop}

    missing_core = [a for a in CORE_ACTIONS if a not in actions]
    if missing_core:
        errors.append({"code": "MISSING_CORE_ACTIONS", "detail": f"缺 {missing_core}"})
    if len(sizes) > 1:
        warnings.append({"code": "INCONSISTENT_SIZE_ACROSS_ACTIONS",
                         "detail": f"跨動作有 {sorted(sizes)} 兩種以上尺寸"})
    missing_teaser = [a for a in ("stalk", "windup", "pounce", "tumble", "retreat")
                      if a not in actions]
    if missing_teaser:
        warnings.append({"code": "MISSING_TEASER_ACTIONS",
                         "detail": f"逗貓棒不可用，缺 {missing_teaser}"})

    manifest = {
        "schemaVersion": 1,
        "id": pack_id,
        "name": args.name or pack_id,
        "author": args.author,
        "license": args.license,
        "logicalHeight": args.logical_height,
        "anchor": {"x": round(anchor[0], 6), "y": round(anchor[1], 6)},
        "facing": args.facing,
        "mirrorForOpposite": not args.no_mirror,
        "actions": actions,
    }

    target = pack / "pack.json"
    if not errors:
        target.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    payload = {
        "ok": not errors,
        "command": "manifest",
        "pack": str(pack),
        "manifest": manifest,
        "errors": errors,
        "warnings": warnings,
        "written": str(target) if not errors else None,
    }
    lines = [f"{'寫出' if not errors else '未寫出'} {target}",
             f"  {len(actions)} 個動作、共 {sum(a['frames'] for a in actions.values())} 格"
             f"、anchor=({anchor[0]:.4f}, {anchor[1]:.4f})"]
    lines += [f"  ✗ [{e['code']}] {e['detail']}" for e in errors]
    lines += [f"  ! [{w['code']}] {w['detail']}" for w in warnings]
    return emit(args, payload, lines)


# ── 進入點 ─────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pipeline.py", description="AI 生圖的橫排多格圖 → FindMouse sprite pack")
    # --json 只掛在子命令上，不掛在最外層：兩邊都掛的話 `pipeline.py --json slice`
    # 會被子命令的預設值蓋回 False，而使用者看到的是「加了旗標卻沒作用」。
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("slice", help="橫排 N 格 → N 張")
    p.add_argument("strip")
    p.add_argument("--frames", type=int, required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--start", type=int, default=0,
                   help="第一格的編號（預設 0）。一組動作分成兩張條子生的時候，"
                        "第二張用 --start 接續，例如 8 格分 4+4 就是 --start 4")
    p.add_argument("--force", action="store_true",
                   help="允許覆蓋既有的格子")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_slice)

    p = sub.add_parser("key", help="chroma key 去背（含去色暈與 unpremultiply）")
    p.add_argument("input", help="一張 PNG 或一個裝著 PNG 的目錄")
    p.add_argument("--out", required=True)
    p.add_argument("--key", default="auto",
                   help="背景色 RRGGBB，或 auto（預設）＝逐格從四角判定。"
                        "生圖服務吐的洋紅每張都不一樣，同一張裡每格也不一樣，所以 auto 才是常態")
    # 預設值的理由：平坦洋紅經過 JPEG／色彩管理之後每個通道抖 ±n/255（n 約 8），
    # 而 alpha 看的是 min(R,B) − G，最壞情況兩邊反向各抖 n → 誤差 2n/255。
    # 取 0.08 就是「撐得住每通道 ±10」。背景更髒才調大，
    # 調大會開始吃掉貓最外圈那層半透明邊。
    p.add_argument("--bg-tolerance", type=float, default=0.08,
                   help="alpha 低於這個值就當成純背景（預設 0.08 ≈ 撐得住每通道 ±10 的雜訊）")
    # 反過來的那一端：貓身上偏洋紅的部位（粉紅鼻子、耳廓、舌頭）會被算出
    # alpha < 1。6% 蓋得住淡粉紅；真的有一大塊桃紅色的貓要調到 0.10 以上，
    # 代價是最外圈那層 alpha 會被吸到 1，邊緣硬一點。
    p.add_argument("--despeckle", type=float, default=0.01,
                   help="抹掉小於「最大區塊 × 這個比例」的連通分量（預設 0.01）。"
                        "生圖服務蓋在角落的簽名就是靠這個清掉；0 為停用")
    p.add_argument("--fg-tolerance", type=float, default=0.06,
                   help="alpha 高於 1−這個值就當成全不透明（預設 0.06）")
    p.add_argument("--min-coverage", type=float, default=0.005,
                   help="留下來的像素比例低於這個值就判定生圖失敗（預設 0.005）")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_key)

    p = sub.add_parser("align", help="統一畫布、對齊腳底線、算出 anchor")
    p.add_argument("input", help="一個根目錄，每個子目錄是一組動作")
    p.add_argument("--out", required=True)
    p.add_argument("--align", default="per-frame", choices=layout.ALIGN_MODES,
                   help="per-frame：每格各自壓到腳底線（預設）。"
                        "per-action：整組一起平移，保留組內騰空（pounce/tumble）")
    p.add_argument("--pad", type=float, default=0.05, help="上緣與左右留白（佔內容高的比例）")
    p.add_argument("--bottom-pad", type=float, default=0.07, help="下緣留白（佔內容高的比例）")
    p.add_argument("--foot-band", type=float, default=0.03,
                   help="腳底帶的厚度（佔該格外框高的比例）")
    p.add_argument("--geometry", help="pin 住既有版面的 JSON（align --report 產生）")
    p.add_argument("--report", help="把算出來的版面寫到這個檔，之後用 --geometry 餵回來")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_align)

    p = sub.add_parser("manifest", help="產生 pack.json")
    p.add_argument("pack")
    p.add_argument("--geometry", help="align --report 產生的檔（anchor 從這裡來）")
    p.add_argument("--anchor", help="手動指定 anchor，寫成 x,y")
    p.add_argument("--id")
    p.add_argument("--name")
    p.add_argument("--author", default=None)
    p.add_argument("--license", default=None)
    p.add_argument("--logical-height", type=float, default=96)
    p.add_argument("--facing", default="right", choices=("left", "right"))
    p.add_argument("--no-mirror", action="store_true",
                   help="素材左右不對稱（單邊花色、缺耳）時加這個")
    p.add_argument("--fps", action="append", default=[], metavar="ACTION=N")
    p.add_argument("--loop", action="append", default=[], metavar="ACTION=BOOL")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_manifest)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except ChromaError as error:
        payload = {"ok": False, "command": args.command,
                   "errors": [{"code": error.code, "detail": error.message}]}
        if args.json:
            json.dump(payload, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
            sys.stdout.write("\n")
        else:
            print(f"✗ [{error.code}] {error.message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
