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

# 用自己的 socket 路徑跑，不要碰使用者真正在用的那個。
#
# App 與 CLI 都讀 FINDMOUSE_SOCKET（共用 FindMouseWire 的 ControlSocket.path），
# 而 `open --env` 可以把環境變數傳進 .app。這樣 e2e 就不必 killall 使用者的
# 實例、也不會搶走它的 socket——之前那些 killall 體操是因為兩邊都寫死路徑。
export FINDMOUSE_SOCKET="/tmp/fm-e2e-$$.sock"

# socket 隔離得了，**設定隔離不了**：`SettingsGateway` 用 `UserDefaults.standard`
# （`SettingsGateway.swift:15`），domain 是 .app 的 bundle id，沒有環境變數可以改。
# 而 `pack use` 成功時會把 `pack.id` 寫進去（`AppDelegate.performSwap` 的副作用），
# 所以跑一次 e2e 使用者的貓就換一套，而且**跑完不會有任何訊號**。
#
# 兩件事一起做：先記下原值供 cleanup 還原，再把它釘成內建那套。
# 釘住是因為「剛啟動載入的是 test-blocks」這類斷言否則會跟著使用者上次選了什麼
# 而變——失敗的原因與被測物無關（實測踩過：使用者在設定視窗把 rest.duration
# 調成 5，寫死出廠值 10 的那條斷言就紅了）。
DEFAULTS_DOMAIN="com.findmouse.app"
SAVED_PACK_ID="$(defaults read "${DEFAULTS_DOMAIN}" pack.id 2>/dev/null || true)"
defaults write "${DEFAULTS_DOMAIN}" pack.id -string "test-blocks"

# 使用者放自己 pack 的地方（`PackCatalogRepository.userPacksDirectory`）。
# 這裡面可能有使用者自己的東西，所以只記下**自己造的 id**，收工只刪這些。
USER_PACKS="${HOME}/Library/Application Support/FindMouse/Packs"
CREATED_PACK_IDS=""

# 只收拾自己啟動的那些 pid。使用者自己的 FindMouse 不關我們的事。
STARTED_PIDS=""

# 殺掉自己啟動的實例，並**等到它們真的不在了**才回來。
# 不等的話，接下來的 `defaults write` 可能與 App 最後的寫入交錯，
# 而還原失敗是靜默的——要到使用者下次開 App 才會看到貓換了一套。
kill_started() {
    local pid alive
    for pid in ${STARTED_PIDS}; do kill "${pid}" 2>/dev/null; done
    for _ in $(seq 1 40); do
        alive=0
        for pid in ${STARTED_PIDS}; do kill -0 "${pid}" 2>/dev/null && alive=1; done
        [[ "${alive}" -eq 0 ]] && break
        sleep 0.25
    done
    STARTED_PIDS=""
}

cleanup() {
    kill_started
    rm -f "${FINDMOUSE_SOCKET}"
    # 只刪自己造的那幾套。`rm -rf` 整個 Packs 目錄會刪掉使用者自己放的 pack，
    # 而那是不可逆的。
    for id in ${CREATED_PACK_IDS}; do rm -rf "${USER_PACKS:?}/${id}"; done
    # 還原設定。刻意不走 `findmouse config set`：cleanup 掛在 trap EXIT 上，
    # 失敗路徑上 App 可能早就不在了（那時 CLI 只會回 exit 3）。
    if [[ -n "${SAVED_PACK_ID}" ]]; then
        defaults write "${DEFAULTS_DOMAIN}" pack.id -string "${SAVED_PACK_ID}"
    else
        defaults delete "${DEFAULTS_DOMAIN}" pack.id 2>/dev/null || true
    fi
}
trap cleanup EXIT

# 啟動一個實例並記下 pid（用 -n 強制開新的，不要只是 activate 既有的）
launch_app() {
    local before after
    before="$(pgrep -f 'FindMouse.app/Contents/MacOS/FindMouse' | tr '\n' ' ')"
    open -n --env "FINDMOUSE_SOCKET=${FINDMOUSE_SOCKET}" "${APP}"
    sleep 2
    after="$(pgrep -f 'FindMouse.app/Contents/MacOS/FindMouse' | tr '\n' ' ')"
    for pid in ${after}; do
        case " ${before} " in
            *" ${pid} "*) ;;
            *) STARTED_PIDS="${STARTED_PIDS} ${pid}" ;;
        esac
    done
}

# 造一套 e2e 專用的 pack 到使用者目錄。參數同 `make-test-blocks.swift`：
# <id> <體高> <色相偏移> [<要略過的動作>...]
#
# 用產生器現做而不是複製 `Tests/.../Fixtures` 裡的 fixture：目錄名必須等於
# manifest id（`idDirectoryMismatch` 是 error），而 `e2e-` 前綴讓它不可能撞到
# 使用者自己的 pack。撞到了就整條停下——寧可少驗一條，也不要覆蓋別人的檔案。
make_pack() {
    local id="$1"; shift
    if [[ -e "${USER_PACKS}/${id}" ]]; then
        bad "使用者目錄裡已經有 ${id}；不覆蓋、也不會刪它"
        return 1
    fi
    mkdir -p "${USER_PACKS}"
    swift "${ROOT}/Scripts/make-test-blocks.swift" "${USER_PACKS}" "${id}" "$@" >/dev/null \
        || { bad "產不出 pack ${id}"; return 1; }
    CREATED_PACK_IDS="${CREATED_PACK_IDS} ${id}"
}

step "建置"
Scripts/make-app.sh >/dev/null || { echo "建置失敗"; exit 1; }
BIN="$(swift build --show-bin-path)"
FM="${BIN}/findmouse"
APP="${ROOT}/build/FindMouse.app"
echo "  findmouse：${FM}"

echo "  socket：${FINDMOUSE_SOCKET}（不是使用者的那個）"
rm -f "${FINDMOUSE_SOCKET}"

# --- 1 -----------------------------------------------------------------------
step "1. App 沒開時 status → exit 3、APP_NOT_RUNNING"
OUT="$("${FM}" status --json 2>&1)"; CODE=$?
expect "${CODE}" "3" "exit code 是 3（腳本靠它與 1 分辨「程式沒開」）"
expect "$(echo "${OUT}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["code"])' 2>/dev/null)" \
       "APP_NOT_RUNNING" "--json 仍是合法 JSON，且 error.code 正確"

# --- 2 -----------------------------------------------------------------------
step "2. 啟動 App → visible == false"
launch_app
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
# 比對的是「跟送出前一樣」而不是出廠值 10：設定是使用者共用的
# （見檔案開頭 `SAVED_PACK_ID` 那段），而使用者在設定視窗調過 rest.duration
# 之後，寫死 10 的那條斷言就會紅——紅的原因與「拒絕不是 clamp」無關。
# 這一條真正要證明的是「被拒絕的值一格都沒被寫進去」，而那與原值是多少無關。
BEFORE_REST="$("${FM}" config get rest.duration | awk '{print $3}')"
OUT="$("${FM}" config set rest.duration 999999 --json 2>&1)"; CODE=$?
expect "${CODE}" "1" "exit code 1"
expect "$(echo "${OUT}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["code"])')" \
       "CONFIG_VALUE_OUT_OF_RANGE" "錯誤碼正確"
expect "$("${FM}" config get rest.duration | awk '{print $3}')" "${BEFORE_REST}" \
       "拒絕不是 clamp——值完全沒被改動（送出前是 ${BEFORE_REST}）"

# --- 6 -----------------------------------------------------------------------
step "6. 座標系：鼠標往上移，cursor.y 要變大（AppKit 全域座標 Y 向上）"
# 比對的是「同一時刻的真實游標」與「App 回報的游標」的**變化方向**，
# 不是「我要求的位置」——本機的游標會自己漂移（要求 (400,300)，一秒後可能
# 停在 (1111,477)），拿要求值去比會偶發失敗，而失敗的原因與被測物無關。
#
# 方向就是 spec 第 8.4 節真正承諾的東西：事件座標系是 Y 向下的，
# 所以「真實 y 變大時回報的 y 也變大」分得出兩個座標系。
read_pair() {
    local real seen
    seen="$(field 'd["cursor"]["y"]')"
    real="$(swift "${ROOT}/Scripts/read-cursor.swift" 2>/dev/null | awk '{print $2}')"
    echo "${real} ${seen}"
}
swift "${ROOT}/Scripts/warp-cursor.swift" 400 250 >/dev/null 2>&1
sleep 0.8
read -r LOW_REAL LOW_SEEN <<< "$(read_pair)"
swift "${ROOT}/Scripts/warp-cursor.swift" 400 700 >/dev/null 2>&1
sleep 0.8
read -r HIGH_REAL HIGH_SEEN <<< "$(read_pair)"

if /usr/bin/python3 -c "import sys; sys.exit(0 if abs(${HIGH_REAL} - ${LOW_REAL}) > 100 else 1)"; then
    if /usr/bin/python3 -c "import sys; sys.exit(0 if (${HIGH_SEEN}-${LOW_SEEN})*(${HIGH_REAL}-${LOW_REAL}) > 0 else 1)"; then
        ok "回報的 y 與真實 y 同向變化（真實 ${LOW_REAL}→${HIGH_REAL}、回報 ${LOW_SEEN}→${HIGH_SEEN}）"
    else
        bad "方向相反：真實 ${LOW_REAL}→${HIGH_REAL}，回報 ${LOW_SEEN}→${HIGH_SEEN}——座標系翻轉了"
    fi
else
    bad "游標沒有真的移動（${LOW_REAL} → ${HIGH_REAL}），這一條無法判定"
fi

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
launch_app
sleep 1
"${FM}" status >/dev/null 2>&1
expect "$?" "0" "原本的實例仍然在服務 CLI"
expect "$(field 'd["pack"]["id"]')" "test-blocks" "回應來自一個正常載入 pack 的實例"
echo "  （本次啟動的 pid：${STARTED_PIDS}；第二個停在提示視窗，收工時一併關掉）"

# 以下四條是 spec 第 15 節 M4 的驗收條件。**它們是 M4 唯一能證明自己做完的東西**——
# 每一層的單元測試都綠，證明不了接線是對的（M3 的教訓：CLI 的 summon 回 ok
# 而貓永遠不出現，兩邊的單元測試全綠）。

# 取 --json 輸出裡的錯誤碼。取不到時回一句看得懂的話，不要回空字串——
# 空字串在 expect 的失敗訊息裡與「欄位存在但是空的」分不出來。
errcode() {
    echo "$1" | /usr/bin/python3 -c \
        'import json,sys; d=json.load(sys.stdin); print(d.get("error",{}).get("code","（沒有 error 欄位，ok=%s）" % d.get("ok")))' \
        2>/dev/null
}

# `pack list --json` 裡指名那一套的欄位。
# 驗收條件說「缺 core 的 pack 被**紅字**拒絕」，而紅字在設定視窗與選單列，
# e2e 驅動不了 UI；但那兩處畫的就是這份 usable / errors（`SettingsForm` 與
# `MenuBarController` 都吃 `PackSummary`），所以驗這份資料等於驗紅字的內容來源。
packentry() {
    "${FM}" pack list --json 2>/dev/null | /usr/bin/python3 -c \
        "import json,sys
ps = {p['id']: p for p in json.load(sys.stdin)['data']['packs']}
try: print($1)
except KeyError: print('（清單裡沒有這個 id）')"
}

# --- 9 -----------------------------------------------------------------------
step "9. 換 pack（M4 驗收條件一：放入第二套 pack 能切換）"
# **先把貓叫出來再換。** spec 第 6.5 節的時序（先淡出、換完立刻重新召喚）
# 只在貓在場時才走得到——貓不在場時 `PackSwapUseCase.request` 當場回 `.swap`，
# 「先淡出」那條路一步都沒踩到，這條 e2e 就沒有涵蓋 6.5。
expect "$(field 'd["pack"]["id"]')" "test-blocks" "前提：現在跑的是內建 test-blocks"
"${FM}" summon >/dev/null
for _ in $(seq 1 40); do
    [[ "$(field 'd["visible"]')" == "True" ]] && break
    sleep 0.5
done
expect "$(field 'd["visible"]')" "True" "前提：貓在場，所以待會走的是「先淡出」那條"

"${FM}" pack use test-blocks-tall >/dev/null
for _ in $(seq 1 40); do
    [[ "$(field 'd["pack"]["id"]')" == "test-blocks-tall" ]] && break
    sleep 0.5
done
expect "$(field 'd["pack"]["id"]')" "test-blocks-tall" "pack.id 換過去了"
# **這條才是真正的驗收。** 只比對 id 的話，「更新了 packID 欄位、七個協作者
# 一個都沒換」會照樣通過，而那正是 M4 最大的風險（`SpriteRepository` 有七個
# 持有者）。體高讀的是 `pack.sprites.logicalHeight`，換的是整包 `PackBinding`。
# 轉成 int 再比：JSONEncoder 把 240.0 寫成 `240`，python 那頭是 int 還是 float
# 取決於編碼細節，拿字面值比會為了與被測物無關的理由紅。
expect "$(field 'int(d["pack"]["logicalHeight"])')" "240" "體高也跟著換（不是只換了 id）"

# 換完貓要自己回來——那是 6.5 的另一半，也是唯一抓得到「換個 pack 貓就永久消失」
# 的觀測：`pack use` 與 `summon` 兩個命令都回 ok，少掉的只有畫面上那隻貓。
for _ in $(seq 1 40); do
    [[ "$(field 'd["visible"]')" == "True" ]] && break
    sleep 0.5
done
expect "$(field 'd["visible"]')" "True" "換完之後貓自己回來了（換完立刻重新召喚）"

# --- 10 ----------------------------------------------------------------------
step "10. 缺 core 的 pack 不能選（M4 驗收條件二）"
make_pack e2e-bad-core 96 180 sit   # 少了 sit（core 級）→ 整套無效
expect "$(packentry 'ps["e2e-bad-core"]["usable"]')" "False" "清單裡列得出來，但不可用"
if packentry 'ps["e2e-bad-core"]["errors"]' | grep -q "必要動作"; then
    ok "而且說得出原因（紅字的內容來源）"
else
    bad "errors 沒有指出缺少必要動作：$(packentry 'ps["e2e-bad-core"]["errors"]')"
fi

OUT="$("${FM}" pack use e2e-bad-core --json 2>&1)"; CODE=$?
expect "${CODE}" "1" "壞 pack 回 exit 1"
# 錯誤碼要一起驗：`PACK_NOT_FOUND` 的 exit code 也是 1，所以只看 exit code 的話，
# 「這套 pack 根本沒被掃到」與「掃到了、判定不合格」分不出來——前者會讓這一條
# 在驗證邏輯整個不存在的情況下照樣通過。
expect "$(errcode "${OUT}")" "PACK_INVALID" "錯誤碼是 PACK_INVALID（不是沒找到）"
expect "$(field 'd["pack"]["id"]')" "test-blocks-tall" "而且沒有真的換過去"

# --- 11 ----------------------------------------------------------------------
step "11. 缺 teaser 的 pack 讓逗貓棒不可用（M4 驗收條件三）"
# 驗收條件的原文是「⌥⌘T 無反應」，但**合成鍵盤事件打不到 Carbon 快捷鍵**：
# 一支獨立探針用與 `CarbonHotkeyDriver` 完全相同的方式註冊快捷鍵，
# `osascript` 與 `CGEvent` 兩條路都打不到它（M4 交接有對照組實測）。
# 拿那個管道驗，看到的「沒反應」證明不了任何事。
# 改走 `findmouse teaser on`：它與快捷鍵投遞的是同一個 `.setTeaser(true)`，
# 閘門也在同一個 `ControlUseCase`（`ControlUseCase.swift:59`）。
expect "$(field 'd["pack"]["id"]')" "test-blocks-tall" "前提：現在跑的是缺 pounce 的那套"
expect "$(field 'd["teaser"]["available"]')" "False" "缺 pounce → teaserAvailable: false"
OUT="$("${FM}" teaser on --json 2>&1)"; CODE=$?
expect "${CODE}" "1" "teaser on 回 exit 1"
# 同樣要驗碼：`APP_NOT_RESPONDING` 也是 exit 1，而那是「App 卡住」不是「閘門擋下」。
expect "$(errcode "${OUT}")" "TEASER_UNAVAILABLE" "錯誤碼是 TEASER_UNAVAILABLE"
expect "$(field 'd["teaser"]["enabled"]')" "False" "而且真的沒開起來"

# --- 12 ----------------------------------------------------------------------
step "12. 使用者目錄丟進去的 pack 切得過去；它在執行期消失就退回內建"
# 前半是驗收條件一的字面意思（「**放入**第二套 pack」——test-blocks-tall 是內建的，
# 從 bundle 載入，證明不了使用者目錄那條路）。後半是 spec 第 10 節：
# 「當前 pack 在執行期失效（檔案被刪）→ 退回內建 pack 並記錄 log」。
#
# 內建的兩套都刪不得（在 .app 的 bundle 裡），所以要先自己造一套放進使用者目錄。
make_pack e2e-dropin 120 60
"${FM}" pack use e2e-dropin >/dev/null
for _ in $(seq 1 40); do
    [[ "$(field 'd["pack"]["id"]')" == "e2e-dropin" ]] && break
    sleep 0.5
done
expect "$(field 'd["pack"]["id"]')" "e2e-dropin" "使用者目錄的 pack 切得過去"
expect "$(field 'int(d["pack"]["logicalHeight"])')" "120" "而且真的載入了它的體高"

rm -rf "${USER_PACKS:?}/e2e-dropin"
# 重啟才驗得到退回：`pack.id` 留在設定裡是 e2e-dropin（退回那條路刻意不改寫它，
# 見 `AppDelegate.makeSettingsFormStore` 的註解），所以新實例會先去要那一套、
# 要不到才退回內建。
kill_started
launch_app
for _ in $(seq 1 40); do "${FM}" status >/dev/null 2>&1 && break; sleep 0.5; done
expect "$(field 'd["pack"]["id"]')" "test-blocks" "正在用的 pack 被刪掉，重啟退回內建"
expect "$(field 'int(d["pack"]["logicalHeight"])')" "96" "退回的是真的內建那套，不是只改了 id"

step "結果"
printf '  通過 %d、失敗 %d\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
