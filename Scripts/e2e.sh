#!/bin/bash
# spec 第 12 節第三層：真的啟動 .app、真的跑 findmouse 執行檔。
#
# 這一層抓得到單元測試抓不到的東西——實測抓到的第一個 bug 是
# 「CLI 的 summon 回 ok，但貓永遠不出現」：命令進了佇列，而喚醒 display link
# 的程式碼只寫在快捷鍵那條路徑上。兩邊的單元測試都是綠的。
#
# 用法：Scripts/e2e.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

PASS=0
FAIL=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# 期望值比較。第三個參數是說明，出錯時把實際值印出來——
# 只印「失敗」的斷言會讓人得自己重跑一次才知道發生什麼事。
expect() {
    local actual="$1" wanted="$2" what="$3"
    if [[ "${actual}" == "${wanted}" ]]; then ok "${what}"
    else bad "${what}（期望 ${wanted}，實際 ${actual}）"; fi
}

# 兩個名字都要殺：.app 裡的執行檔叫 FindMouse，而直接跑 SwiftPM 產物時
# process 名是 FindMouseApp。只殺其中一個的話，殘留的那個仍然握著 socket，
# 之後每一次 `open` 都會被判成「第二個實例」而自己退出——於是 CLI 一直在跟
# 一個**舊 binary** 說話。實測被這件事騙了好幾輪。
cleanup() { killall FindMouse FindMouseApp 2>/dev/null; }
trap cleanup EXIT

# 起跑前一定要是乾淨的，否則整份報告都在描述別的 process
assert_no_instances() {
    local n
    n="$(pgrep -f 'FindMouse.app/Contents/MacOS/FindMouse|Products/Debug/FindMouseApp' | wc -l | tr -d ' ')"
    if [[ "${n}" != "0" ]]; then
        echo "錯誤：還有 ${n} 個 FindMouse 在跑，先關掉再測（它們握著 socket）" >&2
        pgrep -fl 'FindMouse.app/Contents/MacOS/FindMouse|Products/Debug/FindMouseApp' >&2
        exit 1
    fi
}

step "建置"
Scripts/make-app.sh >/dev/null || { echo "建置失敗"; exit 1; }
BIN="$(swift build --show-bin-path)"
FM="${BIN}/findmouse"
APP="${ROOT}/build/FindMouse.app"
echo "  findmouse：${FM}"

# 每次從乾淨狀態開始，腳本才能重複執行
killall FindMouse FindMouseApp 2>/dev/null
sleep 1
assert_no_instances

# --- 1 -----------------------------------------------------------------------
step "1. App 沒開時 status → exit 3、APP_NOT_RUNNING"
OUT="$("${FM}" status --json 2>&1)"; CODE=$?
expect "${CODE}" "3" "exit code 是 3（腳本靠它與 1 分辨「程式沒開」）"
expect "$(echo "${OUT}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["code"])' 2>/dev/null)" \
       "APP_NOT_RUNNING" "--json 仍是合法 JSON，且 error.code 正確"

# --- 2 -----------------------------------------------------------------------
step "2. 啟動 App → visible == false"
open "${APP}"
for _ in $(seq 1 40); do "${FM}" status >/dev/null 2>&1 && break; sleep 0.5; done
json() { "${FM}" status --json 2>/dev/null; }
field() { json | /usr/bin/python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print($1)"; }

expect "$(field 'd["visible"]')" "False" "剛啟動時貓不可見"
expect "$(field 'd["pack"]["id"]')" "test-blocks" "載入的是內建 pack"

# --- 3 -----------------------------------------------------------------------
step "3. summon → 輪詢到 resting → distance <= arrive.radius"
"${FM}" summon >/dev/null
PHASE=""
DIST=""
for _ in $(seq 1 40); do
    # phase 與 distance 一定要取自**同一份快照**。分兩次 status 讀的話，
    # 兩次之間游標會動，於是「抵達時的距離」變成「抵達後某個時刻的距離」——
    # 而抵達之後貓是靜止的，游標一漂走距離就超標，斷言隨機失敗。
    read -r PHASE DIST <<< "$(json | /usr/bin/python3 -c \
        'import json,sys; d=json.load(sys.stdin)["data"]; print(d["phase"], d["distance"])')"
    [[ "${PHASE}" == "resting" ]] && break
    sleep 0.5
done
expect "${PHASE}" "resting" "20 秒內抵達 resting"

# 只在**抵達的那一刻**成立：resting 的貓允許游標漂到 rehunt.threshold（160）
# 才重新追，所以「休息中的貓距離一定 <= arrive.radius」是假的。
ARRIVE="$("${FM}" config get arrive.radius | awk '{print $3}')"
if /usr/bin/python3 -c "import sys; sys.exit(0 if ${DIST} <= ${ARRIVE} else 1)"; then
    ok "抵達當下 distance ${DIST} <= arrive.radius ${ARRIVE}"
else
    bad "抵達當下 distance ${DIST} 超過 arrive.radius ${ARRIVE}"
fi

# --- 4 -----------------------------------------------------------------------
step "4. pack validate 一套壞掉的 pack → exit 1、valid == false"
BAD="${ROOT}/Tests/FindMouseAdaptersTests/Fixtures/bad-missing-core"
OUT="$("${FM}" pack validate "${BAD}" --json 2>&1)"; CODE=$?
expect "${CODE}" "1" "exit code 1（pack 不合格，不是命令失敗）"
expect "$(echo "${OUT}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])')" \
       "True" "ok 仍是 true——驗證這件事成功了"
expect "$(echo "${OUT}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["valid"])')" \
       "False" "data.valid 是 false"
if echo "${OUT}" | /usr/bin/python3 -c 'import json,sys; e=json.load(sys.stdin)["data"]["errors"]; sys.exit(0 if any("必要動作" in x for x in e) else 1)'; then
    ok "errors 指出缺少必要動作"
else
    bad "errors 沒有指出缺少必要動作：$(echo "${OUT}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["errors"])')"
fi

step "4b. pack validate 不存在的路徑 → exit 2"
"${FM}" pack validate /nonexistent/pack-e2e >/dev/null 2>&1
expect "$?" "2" "路徑讀不到是用法錯誤（2），不是 pack 壞掉（1）"

# --- 5 -----------------------------------------------------------------------
step "5. config set 超出範圍 → exit 1、CONFIG_VALUE_OUT_OF_RANGE"
OUT="$("${FM}" config set rest.duration 999999 --json 2>&1)"; CODE=$?
expect "${CODE}" "1" "exit code 1"
expect "$(echo "${OUT}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["code"])')" \
       "CONFIG_VALUE_OUT_OF_RANGE" "錯誤碼正確"
expect "$("${FM}" config get rest.duration | awk '{print $3}')" "10" "拒絕不是 clamp——值完全沒被改動"

# --- 6 -----------------------------------------------------------------------
step "6. 座標系：鼠標往上移，cursor.y 要變大（AppKit 全域座標 Y 向上）"
# warp-cursor 會印出**實際**落點：系統不保證游標停在要求的位置
# （多螢幕錯位時要求的點可能不在任何一片上）。拿實際落點來比對，
# 才是在測 App 有沒有如實回報，而不是在測那支小腳本準不準。
LOW_ACTUAL="$(swift "${ROOT}/Scripts/warp-cursor.swift" 400 200 2>/dev/null)"
sleep 0.6
LOW_Y="$(field 'd["cursor"]["y"]')"
HIGH_ACTUAL="$(swift "${ROOT}/Scripts/warp-cursor.swift" 400 700 2>/dev/null)"
sleep 0.6
HIGH_Y="$(field 'd["cursor"]["y"]')"

if /usr/bin/python3 -c "import sys; sys.exit(0 if ${HIGH_Y} > ${LOW_Y} else 1)"; then
    ok "往上移之後 y 從 ${LOW_Y} 變成 ${HIGH_Y}（變大）"
else
    bad "y 沒有變大：低點 ${LOW_Y}、高點 ${HIGH_Y}——座標系翻轉了"
fi
# 這裡**刻意只驗方向，不驗數值**。
#
# 方向就是 spec 第 8.4 節真正承諾的東西：全域座標 Y 向上。事件座標系是
# Y 向下的，所以「要求更大的 y、回報的 y 也更大」這件事分得出兩者，
# 而它在本機每一輪都穩定成立。
#
# 數值相等則驗不了：實測本機的游標會持續漂移（要求 warp 到 (400, 300)，
# 一秒後實際停在 (1111, 477)，而且每次讀都不同）。App 沒有任何一行會移動
# 游標——`CursorGateway` 只讀不寫，全 repo 只有 Scripts/warp-cursor.swift
# 呼叫過 CGWarpMouseCursorPosition——所以那是環境，不是被測物。
# 在會漂移的游標上斷言「兩次讀數相等」，測到的是漂移速度。
echo "  （實際落點：低 ${LOW_ACTUAL} / 高 ${HIGH_ACTUAL}；只驗方向，理由見註解）"

# --- 6b ----------------------------------------------------------------------
step "6b. 貓不可見時 status 的鼠標也要是現在的"
# hidden 是**預設狀態**，而 display link 在那時是停的。狀態若直接讀最後一帧，
# 剛啟動的 App 會永遠回報啟動當下的鼠標位置——而這個 App 的主題就是鼠標在哪。
# 前面每一條斷言都在「有事發生」的時候讀 status，所以都看不到這件事。
"${FM}" dismiss >/dev/null
for _ in $(seq 1 40); do
    [[ "$(field 'd["visible"]')" == "False" ]] && break
    sleep 0.5
done
swift "${ROOT}/Scripts/warp-cursor.swift" 300 250 >/dev/null 2>&1
sleep 0.8
HIDDEN_LOW="$(field 'd["cursor"]["y"]')"
swift "${ROOT}/Scripts/warp-cursor.swift" 300 900 >/dev/null 2>&1
sleep 0.8
HIDDEN_HIGH="$(field 'd["cursor"]["y"]')"

expect "$(field 'd["visible"]')" "False" "前提：貓確實不可見"
# 漂移是幾十點，這裡的位移是 650 點，所以門檻設 300 分得開
if /usr/bin/python3 -c "import sys; sys.exit(0 if ${HIDDEN_HIGH} - ${HIDDEN_LOW} > 300 else 1)"; then
    ok "hidden 狀態下鼠標仍然跟著動（${HIDDEN_LOW} → ${HIDDEN_HIGH}）"
else
    bad "hidden 狀態下鼠標凍住了：${HIDDEN_LOW} → ${HIDDEN_HIGH}"
fi

# --- 7 -----------------------------------------------------------------------
step "7. dismiss → 輪詢到 visible == false"
"${FM}" dismiss >/dev/null
VIS=""
for _ in $(seq 1 40); do
    VIS="$(field 'd["visible"]')"
    [[ "${VIS}" == "False" ]] && break
    sleep 0.5
done
expect "${VIS}" "False" "20 秒內退場"

# --- 8 -----------------------------------------------------------------------
step "8. 第二個實例不會搶走 socket"
# 斷言的是「原本那個仍在服務」，而不是「只剩一個 process」：
# 第二個實例會跳一個 NSAlert 再結束，而那個 modal 要人按才會關。
# 真正會壞事的是它**搶走 socket**——啟動流程若沒先偵測就 unlink + bind，
# 第一個 App 會從此對 CLI 隱形，而它的畫面完全正常。
BEFORE_PHASE="$(field 'd["phase"]')"
open -n "${APP}" 2>/dev/null
sleep 3
"${FM}" status >/dev/null 2>&1
expect "$?" "0" "原本的實例仍然在服務 CLI"
expect "$(field 'd["pack"]["id"]')" "test-blocks" "回應來自一個正常載入 pack 的實例"
echo "  （目前有 $(pgrep -x FindMouse | wc -l | tr -d ' ') 個 FindMouse process；"
echo "    第二個停在提示視窗，收工時一併關掉）"

step "結果"
printf '  通過 %d、失敗 %d\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
