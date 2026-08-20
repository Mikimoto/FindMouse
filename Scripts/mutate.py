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
import atexit
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 目前被破壞的檔案與它的原始內容。
#
# 為什麼不是只靠 try/finally：SIGTERM（Ctrl-C 之外的任何 kill）預設**不會**跑
# finally，被破壞的檔案就留在工作目錄裡。實測踩過一次——kill 掉一個跑太久的
# 批次之後，注入的那個 return 留在 accept 迴圈裡，接下來每一輪除錯都在追一個
# 我自己剛剛種下的 bug，而 git status 只顯示「檔案有修改」，看不出是誰改的。
_patched = {}


def _restore_all(*_):
    for path, original in list(_patched.items()):
        Path(path).write_text(original)
        print(f"已還原 {path}", file=sys.stderr)
    _patched.clear()
    sys.exit(130)


atexit.register(lambda: [Path(p).write_text(o) for p, o in _patched.items()])
for _sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(_sig, _restore_all)


TIMEOUT_SECONDS = 300


def run_tests(test_filter):
    """回 (output, timed_out)。

    逾時要獨立成一種結果：破壞掉的程式碼可能讓測試**掛住**而不是轉紅
    （socket 少了收訊逾時就是這樣），而那既不是紅也不是綠。
    沒有這個上限的話，一個 mutation 會讓整批停在那裡不動、沒有任何訊息。
    """
    try:
        proc = subprocess.run(
            ["swift", "test", "--filter", test_filter],
            cwd=ROOT, capture_output=True, text=True, timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as expired:
        partial = (expired.stdout or b"") + (expired.stderr or b"")
        if isinstance(partial, bytes):
            partial = partial.decode(errors="replace")
        return partial, True
    return proc.stdout + proc.stderr, False


def classify(output):
    """三態：crash / build-failed / red / green。綠必須正面確認。

    「process 被訊號殺掉」要與「編不過」分開。兩者都沒有 `Test run with` 收尾行，
    但意義相反：前者是**紅**（守衛有效，破壞它就死給你看），後者是這批不算數。
    實測踩過：拿掉 SIGPIPE 的忽略之後，test process 被 SIGPIPE 殺掉，
    輸出裡沒有 `Fatal error:`（那是 Swift 自己的 trap 才有），於是被誤判成 build-failed，
    而那個守衛其實正是有效的。判別依據是「有沒有測試真的跑起來過」。
    """
    started = bool(re.search(r"Test \w+\(\) (?:started|passed|recorded)", output))
    finished = "Test run with" in output

    if "Fatal error:" in output or re.search(r"Exited with signal code", output):
        return "red-crash", sorted(set(re.findall(r"Test (\w+)\(\) recorded", output)))
    if started and not finished:
        # 測試跑到一半 process 就沒了——訊號殺掉最常見
        return "red-crash", sorted(set(re.findall(r"Test (\w+)\(\) recorded", output)))
    if re.search(r"error: .*\n", output) and "Compiling" in output and not started:
        return "build-failed", []
    if "error: " in output and not finished and not started:
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
    _patched[str(path)] = text
    path.write_text(text.replace(find, replace))
    _bump_mtime(path)
    return text, None


def _bump_mtime(path):
    """把 mtime 推到未來一點。

    **沒有這一步，整批 mutation 可能全部在測同一個舊 binary。**
    Swift 的建置系統靠 mtime 判斷要不要重編，而程式化編輯常常落在
    「上一次建置的同一秒」裡——實測過：連續四次 `swift build` 都回
    「Build complete (0.16s)」而編出來的執行檔一個字都沒變，
    `touch` 之後才真的重編。手打編輯不會遇到，因為人沒那麼快。
    """
    future = time.time() + 2
    os.utime(path, (future, future))


# 對照組要插一句「在該檔案裡語法合法」的註解，所以每一種副檔名都得明講。
#
# **這張表不設退路，是因為猜錯過兩次。** 原本寫死 `//`，插進 `Scripts/Info.plist`
# 讓整份 XML 解析不了（2026-08-13）；補上 plist/xml/html 之後改成「不認得就走 `#`」，
# 於是 `Scripts/FindMouse.entitlements`（也是 XML）掉進那條退路，同一個症狀再來一次
# （2026-08-19）。兩次的輸出都是「對照組不是全綠、整批不可採信」——而那個判決
# 會被讀成「這些守衛沒有測試」，一個完全不同、而且更糟的結論。
#
# 補一種新的副檔名比追一次假結論便宜，所以不認得就停下來。`.json` 刻意不在表上：
# 它根本沒有註解語法，真要突變 JSON 得換一種對照組，不是插一行進去。
_COMMENT_SYNTAX = {
    ".swift": "// {}", ".c": "// {}", ".h": "// {}", ".m": "// {}",
    ".js": "// {}", ".ts": "// {}",
    ".plist": "<!-- {} -->", ".xml": "<!-- {} -->", ".html": "<!-- {} -->",
    ".entitlements": "<!-- {} -->", ".md": "<!-- {} -->",
    # .xcprivacy 是 XML plist（Apple 的隱私宣告清單），與 .plist 同一種語法。
    # **註解內文不能有 ASCII 的兩個連字號**，XML 不允許——這裡插的是固定字串
    # 所以沒問題，但寫新的對照組文字時要記得（InfoPlistTests 有一條在掃 Scripts/）。
    ".xcprivacy": "<!-- {} -->",
    ".sh": "# {}", ".bash": "# {}", ".zsh": "# {}",
    ".py": "# {}", ".toml": "# {}", ".yml": "# {}", ".yaml": "# {}",
}


def _comment(path, text):
    """依副檔名包出一句該檔案語法合法的註解。不認得就停下來，不猜。"""
    suffix = Path(path).suffix.lower()
    template = _COMMENT_SYNTAX.get(suffix)
    if template is None:
        sys.exit(f"對照組不知道「{suffix or '（沒有副檔名）'}」的註解語法。"
                 f"請補進 mutate.py 的 _COMMENT_SYNTAX——猜一個會讓整批結果被判成"
                 f"不可採信，而那看起來與「這些守衛沒有測試」一模一樣。")
    return template.format(text)


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
        "replace": first_line + "\n" + _comment(control_file, "mutation runner 對照組"),
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
            output, timed_out = run_tests(test_filter)
            verdict, reds = ("timeout", []) if timed_out else classify(output)
        finally:
            path.write_text(original)
            _patched.pop(str(path), None)

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
