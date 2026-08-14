#!/usr/bin/env python3
"""`pack-fmpack.py` 的測試。跑法：`python3 tools/test_pack_fmpack.py`

形狀照 `test_pipeline.py`：每條測試吃一個 tmp 目錄，runner 負責建與清，
而且跑真測試之前先自檢一次——runner 自己也是沒被驗過的程式碼。

**零真實素材依賴、也不需要 App 在跑。** 要驗 validate 那條路時用一個假的
`findmouse`（一支 shell script）：真的那支要 control socket，而「App 有沒有在跑」
不該決定這幾條測試會不會過。
"""
# 系統的 python3 是 3.9（實測），而 `str | None` 這種註解在 3.9 是**執行期**
# 錯誤——def 當下就炸，不是型別檢查器才抱怨。`test_pipeline.py` 也是這樣開頭的。
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import traceback
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools" / "pack-fmpack.py"

MANIFEST = {
    "schemaVersion": 1, "id": "probe", "name": "測試", "logicalHeight": 96,
    "anchor": {"x": 0.5, "y": 0.94}, "facing": "right", "mirrorForOpposite": True,
    "actions": {"run": {"frames": 1, "fps": 14, "loop": True}},
}


def make_pack(root: Path, pack_id: str = "probe", dir_name: str | None = None) -> Path:
    """造一套最小的 pack 目錄。`dir_name` 與 `pack_id` 分開，才測得出「輸出名取自哪一邊」。"""
    pack = root / (dir_name or pack_id)
    (pack / "run").mkdir(parents=True)
    (pack / "pack.json").write_text(
        json.dumps(dict(MANIFEST, id=pack_id), ensure_ascii=False), encoding="utf-8")
    (pack / "run" / "000.png").write_bytes(b"x")
    return pack


def fake_findmouse(root: Path, body: str) -> Path:
    """一支假的 CLI。真的那支要 App 在跑，而這幾條測試不該綁在那件事上。"""
    path = root / "fake-findmouse"
    path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    path.chmod(0o755)
    return path


def ok_cli(root: Path) -> Path:
    """一支永遠說「合格」的假 CLI。不驗 validate 那條路的測試都用它——
    工具沒有 --skip-validate 旗標（那個旗標只為測試存在，而它剛好讓作者
    能跳過驗證去發布，正是這支工具要防的事）。"""
    return fake_findmouse(root, """echo '{"ok":true,"data":{"valid":true,"errors":[],"warnings":[]}}'
""")


def run(*args, expect_ok: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run([sys.executable, str(TOOL), *map(str, args)],
                          capture_output=True, text=True)
    if expect_ok:
        assert proc.returncode == 0, f"exit={proc.returncode}\n{proc.stdout}\n{proc.stderr}"
    return proc


def test_the_zip_root_is_the_pack_directory(tmp: Path) -> None:
    """防：打出來的 zip 把 pack 的**內容**當根。那個佈局匯入端擋不掉夾帶的檔案（CLAUDE.md）。"""
    pack = make_pack(tmp)
    out = tmp / "probe.fmpack"
    run(pack, "--output", out, "--findmouse", ok_cli(tmp))
    names = zipfile.ZipFile(out).namelist()
    assert "probe/pack.json" in names, names
    assert "probe/run/000.png" in names, names


def test_output_name_comes_from_the_manifest_not_the_directory(tmp: Path) -> None:
    """防：預設輸出名取自目錄名。兩者不一致的 pack 匯入時會被 PackValidator 擋下。"""
    pack = make_pack(tmp, pack_id="probe", dir_name="whatever")
    run(pack, "--findmouse", ok_cli(tmp))
    assert (tmp / "probe.fmpack").exists(), sorted(p.name for p in tmp.iterdir())


def test_macos_cruft_is_left_out(tmp: Path) -> None:
    """防：把 .DS_Store 與 ._* 打進去。匯入端會濾掉，但沒理由先塞進去讓別人下載。"""
    pack = make_pack(tmp)
    (pack / ".DS_Store").write_bytes(b"junk")
    (pack / "._pack.json").write_bytes(b"junk")
    out = tmp / "probe.fmpack"
    run(pack, "--output", out, "--findmouse", ok_cli(tmp))
    names = zipfile.ZipFile(out).namelist()
    assert not any(n.endswith(".DS_Store") or "/._" in n for n in names), names


def test_a_source_without_a_manifest_is_refused_before_zipping(tmp: Path) -> None:
    """防：沒有 pack.json 也照打，作者拿到一個匯入端一定會拒絕的檔案。"""
    empty = tmp / "empty"
    empty.mkdir()
    proc = run(empty, "--findmouse", ok_cli(tmp), expect_ok=False)
    assert proc.returncode != 0
    assert "pack.json" in proc.stdout + proc.stderr
    assert not list(tmp.glob("*.fmpack")), "被拒絕就不該留下檔案"


def test_json_mode_speaks_only_json(tmp: Path) -> None:
    """防：--json 混進人類看的文字。這個介面同時是測試介面，混了就兩邊都不能用。"""
    pack = make_pack(tmp)
    proc = run(pack, "--findmouse", ok_cli(tmp), "--json")
    payload = json.loads(proc.stdout)
    assert payload["ok"] is True and payload["id"] == "probe", payload
    assert payload["output"].endswith("probe.fmpack"), payload


def test_json_mode_also_speaks_json_when_it_fails(tmp: Path) -> None:
    """防：成功走 JSON、失敗吐散文。呼叫端得寫兩套解析，而它多半只寫一套。"""
    empty = tmp / "empty"
    empty.mkdir()
    proc = run(empty, "--findmouse", ok_cli(tmp), "--json", expect_ok=False)
    payload = json.loads(proc.stdout)
    assert payload["ok"] is False and "pack.json" in payload["error"], payload


def test_validation_failure_stops_before_writing_anything(tmp: Path) -> None:
    """防：validate 沒過還是產出檔案。作者會拿那個檔案去發布。"""
    pack = make_pack(tmp)
    out = tmp / "probe.fmpack"
    cli = fake_findmouse(tmp, """echo '{"ok":false,"error":{"code":"PACK_INVALID","message":"缺少必要動作：sit"}}'
exit 1
""")
    proc = run(pack, "--output", out, "--findmouse", cli, expect_ok=False)
    assert "sit" in proc.stdout + proc.stderr, proc.stdout + proc.stderr
    assert not out.exists(), "驗證沒過就不該留下檔案"


def test_an_unusable_pack_is_refused_with_the_reason_not_the_raw_json(tmp: Path) -> None:
    """防：把整包原始 JSON 當訊息吐給作者。實際踩過——先看 exit code 就會這樣。

    不合格的 pack 兩件事同時成立：回應是 ok:true / valid:false（spec 第 8.5 節），
    而 CLI 的 exit code 是 **1**（2026-08-13 對真 CLI 實測）。兩個 exit code 都跑
    一次：1 是實測值，0 是「驗證這件事成功了」那個語意的字面讀法，程式碼兩者都該扛。
    """
    for code in (0, 1):
        (tmp / f"c{code}").mkdir()
        pack = make_pack(tmp / f"c{code}")
        out = tmp / f"c{code}.fmpack"
        cli = fake_findmouse(tmp / f"c{code}", f"""echo '{{"ok":true,"data":{{"valid":false,"errors":["缺少必要動作：sit"],"warnings":[]}}}}'
exit {code}
""")
        proc = run(pack, "--output", out, "--findmouse", cli, expect_ok=False)
        blob = proc.stdout + proc.stderr
        assert "缺少必要動作：sit" in blob, f"exit={code}: {blob}"
        assert "warnings" not in blob, f"exit={code} 吐了原始 JSON：{blob}"
        assert not out.exists(), f"exit={code}"


def test_validate_runs_before_the_zip_is_written(tmp: Path) -> None:
    """防：先打包再驗。順序反了的話，驗證失敗那兩條測試看到的「檔案不存在」
    會是靠事後刪除達成的，而中途 crash 就會留下一個沒驗過的 .fmpack。"""
    pack = make_pack(tmp)
    out = tmp / "probe.fmpack"
    # 假 CLI 在被呼叫的當下就檢查輸出檔在不在，把答案寫進一個旁證檔
    cli = fake_findmouse(tmp, f"""[ -e '{out}' ] && echo yes > '{tmp}/existed' || echo no > '{tmp}/existed'
echo '{{"ok":true,"data":{{"valid":true,"errors":[],"warnings":[]}}}}'
""")
    run(pack, "--output", out, "--findmouse", cli)
    assert out.exists(), "驗證過了就該打包"
    assert (tmp / "existed").read_text().strip() == "no", "validate 跑的時候不該已經有 .fmpack"


def test_app_not_running_says_what_to_do(tmp: Path) -> None:
    """防：App 沒跑時只吐 exit 3，作者不知道那不是 pack 的問題。"""
    pack = make_pack(tmp)
    cli = fake_findmouse(tmp, "exit 3\n")
    proc = run(pack, "--findmouse", cli, expect_ok=False)
    assert "沒在執行" in proc.stdout + proc.stderr, proc.stdout + proc.stderr


def test_a_missing_cli_says_where_to_get_it(tmp: Path) -> None:
    """防：FileNotFoundError 的 traceback 直接噴到作者臉上。"""
    pack = make_pack(tmp)
    proc = run(pack, "--findmouse", tmp / "nope", expect_ok=False)
    assert "make-app.sh" in proc.stdout + proc.stderr, proc.stdout + proc.stderr


def _harness_self_check() -> None:
    """runner 自己也是沒被驗過的程式碼。跑真正的測試之前先確認它分得出成功與失敗。"""
    def passes(_: Path) -> None:
        assert True

    def fails(_: Path) -> None:
        assert False, "故意的"

    def crashes(_: Path) -> None:
        raise IndexError("故意的")

    assert _run_one(passes)[0] is True, "runner 把成功判成失敗"
    assert _run_one(fails)[0] is False, "runner 把失敗判成成功"
    assert _run_one(crashes)[0] is False, "runner 把 crash 判成成功"


def _run_one(func) -> tuple[bool, str]:
    tmp = Path(tempfile.mkdtemp(prefix="fm-fmpack-"))
    try:
        func(tmp)
        return True, ""
    except BaseException:  # noqa: BLE001 - crash 也是失敗，不能讓它靜靜溜過去
        return False, traceback.format_exc()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
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
