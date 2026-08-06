#!/usr/bin/env python3
"""破壞一段程式碼，看測試會不會轉紅。

為什麼要有這支腳本：手寫的 mutation runner 已經騙過我兩次——
一次把 `Fatal error: Index out of range` 判成「全綠」（crash 不產生失敗斷言訊息），
一次把測試名稱裡的 `Crash` 當成真的 crash。所以這裡的判定是**三態**，
而且「綠」必須由「看到預期數量的 passed」正面確認，不能靠「沒看到失敗」推論。

用法：
    Scripts/mutate.py mutations.json [--json]

mutations.json：
    {"filter": "FindMouseCoreTests",
     "mutations": [
       {"label": "拿掉閘門", "file": "Sources/…", "find": "…", "replace": "…",
        "expect": ["testA", "testB"]}
     ]}

`expect` 是預期會轉紅的測試名（可省略，省略時只要求「有測試紅」）。
每一批都會自動附一個 no-op 對照組：它若不是全綠，代表 runner 本身壞了，
這一批的結果全部不可採信。
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run_tests(test_filter):
    proc = subprocess.run(
        ["swift", "test", "--filter", test_filter],
        cwd=ROOT, capture_output=True, text=True)
    return proc.stdout + proc.stderr


def classify(output):
    """三態：crash / build-failed / red / green。綠必須正面確認。"""
    if "Fatal error:" in output or re.search(r"^Crash:", output, re.M):
        return "red-crash", sorted(set(re.findall(r"Test (\w+)\(\) recorded", output)))
    if re.search(r"error: .*\n", output) and "Compiling" in output:
        return "build-failed", []
    if "error: " in output and "Test run with" not in output:
        return "build-failed", []
    failed = sorted(set(re.findall(r"Test (\w+)\(\) (?:recorded an issue|failed)", output)))
    if failed:
        return "red", failed
    m = re.search(r"Test run with (\d+) tests? .* passed", output)
    if m:
        return "green", []
    return "unknown", []


def apply_patch(path, find, replace):
    text = path.read_text()
    if text.count(find) != 1:
        return None, f"find 片段出現 {text.count(find)} 次，必須剛好 1 次"
    path.write_text(text.replace(find, replace))
    return text, None


def main():
    spec_path = Path(sys.argv[1])
    as_json = "--json" in sys.argv
    spec = json.loads(spec_path.read_text())
    test_filter = spec["filter"]

    mutations = list(spec["mutations"])
    # no-op 對照組：證明 runner 分得出「全綠」與其他狀態
    control_file = mutations[0]["file"]
    control_text = (ROOT / control_file).read_text()
    first_line = control_text.split("\n", 1)[0]
    mutations.append({
        "label": "（對照組）no-op",
        "file": control_file,
        "find": first_line,
        "replace": first_line + "\n// mutation runner 對照組",
        "expect": [],
        "control": True,
    })

    results = []
    for m in mutations:
        path = ROOT / m["file"]
        original, err = apply_patch(path, m["find"], m["replace"])
        if err:
            results.append({"label": m["label"], "verdict": "patch-failed", "detail": err})
            continue
        try:
            verdict, reds = classify(run_tests(test_filter))
        finally:
            path.write_text(original)

        expected = m.get("expect", [])
        if m.get("control"):
            ok = verdict == "green"
        elif expected:
            ok = verdict.startswith("red") and set(expected).issubset(set(reds))
        else:
            ok = verdict.startswith("red")

        results.append({"label": m["label"], "verdict": verdict,
                        "red": reds, "expected": expected, "ok": ok})

    if as_json:
        print(json.dumps({"results": results}, ensure_ascii=False, indent=2))
    else:
        for r in results:
            mark = "OK " if r.get("ok") else "!! "
            print(f"{mark}{r['verdict']:<13} {r['label']}")
            if r.get("red"):
                print(f"      紅：{', '.join(r['red'])}")
            if r.get("detail"):
                print(f"      {r['detail']}")

    control = results[-1]
    if not control.get("ok"):
        print("\n對照組不是全綠——runner 本身有問題，本批結果不可採信。", file=sys.stderr)
        return 2
    return 0 if all(r.get("ok") for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
