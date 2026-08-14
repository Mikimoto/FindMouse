#!/usr/bin/env python3
"""把一個 pack 目錄打包成 `.fmpack`。

先跑一次 `findmouse pack validate`，過了才 zip——**不在這裡重寫一份 validator**。
規則住在 `PackValidator`（Swift 那邊，有測試），第二份 python 實作只會漂掉，
而漂掉的症狀是「打包時說可以、別人裝的時候說不行」。

沒有「跳過驗證」的旗標：那個旗標的唯一用途就是產出一個沒驗過的 `.fmpack`，
而這支工具存在的理由正是不要有那種東西。真的只想壓縮就用 `ditto -c -k`。

用法：
    python3 tools/pack-fmpack.py <pack 目錄> [--output <檔案>] [--json]
                                 [--findmouse <路徑>]

`pack validate` 走 control socket，所以 **FindMouse 要在執行中**。
"""
import argparse
import json
import subprocess
import sys
import zipfile
from pathlib import Path

# `findmouse` 對「App 沒在跑」的 exit code。CLI 是薄用戶端，那不是 pack 的問題。
APP_NOT_RUNNING = 3

# validate 的等待上限。訊息裡也用它，不要寫第二個字面值。
VALIDATE_TIMEOUT = 30


def die(message, as_json):
    """**失敗也走 JSON。** 成功走 JSON、失敗吐散文的話，呼叫端得寫兩套解析，
    而它多半只寫一套——然後在失敗那條路上炸得莫名其妙。"""
    if as_json:
        print(json.dumps({"ok": False, "error": message}, ensure_ascii=False))
    else:
        print(message, file=sys.stderr)
    sys.exit(1)


def read_manifest(pack, as_json):
    manifest_path = pack / "pack.json"
    if not manifest_path.is_file():
        die(f"{pack} 裡沒有 pack.json，這不是一套 sprite pack。", as_json)
    try:
        return json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        die(f"{manifest_path} 不是合法的 JSON：{exc}", as_json)


def validate(findmouse, pack):
    """跑 CLI 的 validate。回 `None` 表示過了，否則回一句給人看的話。"""
    try:
        # 有逾時：CLI 連上 socket 之後就等 App 回話，而 App 卡在主執行緒時那個
        # 等待沒有上限。沒有這個參數的話，打包工具會**無聲地**停在那裡。
        proc = subprocess.run([str(findmouse), "pack", "validate", str(pack), "--json"],
                              capture_output=True, text=True, timeout=VALIDATE_TIMEOUT)
    except (FileNotFoundError, PermissionError):
        return (f"執行不了 {findmouse}。用 --findmouse 指定路徑，"
                "或先跑 Scripts/make-app.sh 把 CLI 建出來。")
    except subprocess.TimeoutExpired:
        return (f"{findmouse} pack validate 等了 {VALIDATE_TIMEOUT} 秒還沒回話，"
                "FindMouse 可能卡住了。")

    if proc.returncode == APP_NOT_RUNNING:
        return ("FindMouse 沒在執行，而 pack validate 走 control socket。"
                "先把 App 打開再跑一次。")

    # 訊息優先從 JSON 取，取不到才退回原始輸出。那條退路只在**非零 exit** 時走得到
    # （見下面），所以它涵蓋的是「CLI 非零離開但沒吐合法 JSON」。exit 0 而 stdout
    # 解不開的話這裡回 None、照樣打包——那個形狀在真 CLI 不存在（`Output.swift` 的
    # 每條路都吐 JSON），要防它得先有一個會那樣的 CLI。
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        payload = None

    # **`data.valid` 要在看 exit code 之前先問。** 不合格的 pack 兩件事同時成立：
    # 回應是 `ok:true` / `valid:false`（spec 第 8.5 節：驗證這件事成功了，不合格
    # 的是 pack），而 CLI 的 exit code 是 **1**（2026-08-13 實測）。先看 exit code
    # 的話就會落到下面那條退路，把整包原始 JSON 當成訊息吐給作者——實際踩過。
    data = payload.get("data") if isinstance(payload, dict) else None
    if isinstance(data, dict) and data.get("valid") is False:
        problems = "、".join(data.get("errors", [])) or "（CLI 沒說是哪裡）"
        return f"驗證沒過：{problems}"

    # 剩下的非零：路徑不存在（實測 exit 2）、協定不符之類。那些帶的是 error 物件。
    if proc.returncode != 0:
        if isinstance(payload, dict) and isinstance(payload.get("error"), dict):
            return f"驗證沒過：{payload['error'].get('message', proc.stdout.strip())}"
        return f"驗證沒過：{(proc.stdout + proc.stderr).strip()}"
    return None


def write_zip(pack, output):
    """zip 的根是 pack 目錄**本身**，所以解開之後 `<id>/pack.json` 在第二層。

    匯入端兩種佈局都認得（`ExtractedTree.packRoot`），但根是空字串時它擋不掉
    夾帶的檔案（見 CLAUDE.md 那條 ditto 攤平的紀錄），所以打包這一端一律用
    「有一層目錄」的形狀——那是我們控制得了的一半。
    """
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(pack.rglob("*")):
            if path.is_dir():
                continue
            # macOS cruft。匯入端也會濾，但沒理由先塞進去讓別人下載。
            if path.name == ".DS_Store" or path.name.startswith("._"):
                continue
            archive.write(path, arcname=str(Path(pack.name) / path.relative_to(pack)))


def main():
    parser = argparse.ArgumentParser(description="把一個 pack 目錄打包成 .fmpack")
    parser.add_argument("pack", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--findmouse", default="findmouse",
                        help="CLI 的路徑（預設從 PATH 找）")
    args = parser.parse_args()

    pack = args.pack.resolve()
    if not pack.is_dir():
        die(f"{pack} 不是一個目錄。", args.json)

    manifest = read_manifest(pack, args.json)
    pack_id = manifest.get("id")
    if not pack_id:
        die(f"{pack}/pack.json 沒有 id 欄位。", args.json)

    # 輸出名取自 manifest 的 id 而不是目錄名：兩者不一致的 pack 匯入時會被
    # PackValidator 擋下，而檔名叫錯會讓作者以為是別的問題。
    output = args.output or pack.parent / f"{pack_id}.fmpack"

    # **驗完才寫。** 反過來的話，失敗路徑得靠事後刪除來善後，而中途 crash
    # 就會留下一個沒驗過的 .fmpack。
    problem = validate(args.findmouse, pack)
    if problem:
        die(problem, args.json)

    write_zip(pack, output)

    if args.json:
        print(json.dumps({"ok": True, "id": pack_id, "output": str(output)},
                         ensure_ascii=False))
    else:
        print(f"已打包 {output}")


if __name__ == "__main__":
    main()
