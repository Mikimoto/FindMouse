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
SKIP=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# 第三種結果：這一條**沒有被評估**。
#
# 為什麼要跟 bad 分開：一條測不成的斷言不是產品的失敗。算成失敗，看的人會去追一個
# 不存在的 bug（實測踩過：使用者中途動了滑鼠，兩次 warp 都被蓋掉，於是「座標系翻了」
# 被報成失敗）；算成通過，真的 bug 就躲在「反正那條測不了」後面。兩種都不行。
#
# 所以它自成一類，而且**整輪的 exit code 仍然非零**（見檔尾「結果」）——
# 無法判定的一輪沒有證明完整的接線，它只是還沒證明反面。
#
# 用它的前提：干擾的判準必須是**可量化、而且在閒置機器上恆不成立**的訊號
# （「warp 之後讀回的位置與落點差超過 N 點」「輪詢期間游標累計移動超過 N 點」）。
# 「反正就是沒動」這種含糊的推論不算——那種寫法會讓真的壞掉的斷言永遠躲在這裡面。
skip() { printf '  \033[33m?\033[0m %s\n' "$1"; SKIP=$((SKIP + 1)); }

# 「游標被外力移動」的兩個門檻（點）。兩個都**由各自的斷言反推**，不是憑感覺挑的
# 安全邊際——門檻是「多大的位移才會改變這條斷言的結論」，訂得比它大就是在
# 替真的壞掉的斷言開後門，訂得比它小就是把測得準的一輪誤判成測不準。
#
# step 3：整段輪詢期間游標的**累計**位移。這一條比的是「settled 期間看過的最小
# distance」與 arrive.radius（76.8），而累計位移 d 最多讓那個最小值比真正的抵達
# 距離大 d。5 點對 76.8 是 6.5%，小到不會把一次真正的抵達推過界。
CURSOR_STILL_TOLERANCE=5
# step 6 / 6b：**單次** warp 的落點與稍後量到的位置之差。這兩條比的是相隔
# 450 / 650 點的兩個取樣之間的方向與落差，所以只有「與那個間距同量級」的位移
# 才改變得了結論；50 點是它的九分之一，翻不動任何一個號誌。
# 下限那邊也要留餘裕：實測游標被手碰到時的位移是 250–2600 點，而閒置時恆為 0，
# 中間這一段是空的，門檻放在空檔裡就好（曾經訂 5 點，一次 5.33 點的輕碰
# 就讓一條**其實測得準**的斷言變成無法判定）。
WARP_DRIFT_TOLERANCE=50

# 期望值比較。第三個參數是說明，出錯時把實際值印出來——
# 只印「失敗」的斷言會讓人得自己重跑一次才知道發生什麼事。
expect() {
    local actual="$1" wanted="$2" what="$3"
    if [[ "${actual}" == "${wanted}" ]]; then ok "${what}"
    else bad "${what}（期望 ${wanted}，實際 ${actual}）"; fi
}

# bundle id 從 Info.plist 讀而不是寫死。下面三個東西都要它：socket 路徑、
# 使用者 pack 目錄、以及 defaults 的 domain。寫死的話它們會各自漂掉。
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${ROOT}/Scripts/Info.plist")"
[[ -n "${BUNDLE_ID}" ]] || {
    echo "讀不到 ${ROOT}/Scripts/Info.plist 的 CFBundleIdentifier。"
    echo "先跑 plutil -lint Scripts/Info.plist 看它是不是壞了；檔案沒壞就是那個 key 不見了，補回去。"
    exit 1
}
# App 的沙盒容器。**沙盒之後這是 App 唯一寫得進去的地方**，所以下面兩個路徑
# 都從這裡長出來。
CONTAINER="${HOME}/Library/Containers/${BUNDLE_ID}/Data"

# 用自己的 socket 路徑跑，不要碰使用者真正在用的那個。
#
# App 與 CLI 都讀 FINDMOUSE_SOCKET（共用 FindMouseWire 的 ControlSocket.path），
# 而 `open --env` 可以把環境變數傳進 .app。這樣 e2e 就不必 killall 使用者的
# 實例、也不會搶走它的 socket——之前那些 killall 體操是因為兩邊都寫死路徑。
#
# **不能再用 `/tmp`**（2026-08-17 實測：沙盒下在 `/tmp` bind 回 errno 1／EPERM，
# 而不沙盒時成功——是沙盒擋的，不是權限或路徑問題）。所以隔離改在容器裡做：
# **同一個容器內靠檔名隔離仍然成立，靠目錄隔離不成立**——App 只寫得進自己的容器，
# 而它與使用者那個實例共用同一個容器，所以只能靠檔名不同來分開。
export FINDMOUSE_SOCKET="${CONTAINER}/fm-e2e-$$.sock"

# socket 隔離得了，**設定隔離不了**：`SettingsGateway` 用 `UserDefaults.standard`
# （`SettingsGateway.swift:15`），domain 是 .app 的 bundle id，沒有環境變數可以改。
# 而 `pack use` 成功時會把 `pack.id` 寫進去（`AppDelegate.performSwap` 的副作用），
# 所以跑一次 e2e 使用者的貓就換一套，而且**跑完不會有任何訊號**。
#
# 兩件事一起做：先記下原值供 cleanup 還原，再把它釘成**出廠預設**那套。
# 釘 mycat 而不是色塊，是因為 2026-08-19 起色塊不再出貨——而這樣一來「剛啟動
# 載入的是哪一套」驗的才是使用者真正的起始狀態。
# 釘住是因為「剛啟動載入的是 mycat」這類斷言否則會跟著使用者上次選了什麼
# 而變——失敗的原因與被測物無關（實測踩過：使用者在設定視窗把 rest.duration
# 調成 5，寫死出廠值 10 的那條斷言就紅了）。
# 與 socket、pack 目錄同一個來源（上面那個 BUNDLE_ID）。一旦漂掉，症狀是
# 「e2e 去寫一個沒人讀的 domain」——App 讀到的還是使用者自己的設定。
#
# **這個漂移以前會被下面那條 pack 斷言順手抓到，現在不會了**：釘的值從色塊改成
# mycat 之後，使用者自己的 pack.id 若也是 mycat（實測就是），漂掉時那條照樣綠。
# 這是刻意的取捨——那條斷言的本業是「使用者真正的起始狀態」，順手抓漂移只是副作用。
# 代價要講清楚：**漂移現在沒有任何一條斷言保證抓得到**，只有「使用者上次選的剛好
# 不是 mycat」時才會現形。要真的守它得另外寫一條，這裡沒有寫。
#
# 沙盒之後 `defaults` 這一側**不必改**：cfprefsd 認得容器，對同一個 domain
# 的讀寫兩邊都會被重導過去（2026-08-17 實測，連 `defaults read` 都跟著重導）。
DEFAULTS_DOMAIN="${BUNDLE_ID}"
SAVED_PACK_ID="$(defaults read "${DEFAULTS_DOMAIN}" pack.id 2>/dev/null || true)"
defaults write "${DEFAULTS_DOMAIN}" pack.id -string "mycat"

# 使用者放自己 pack 的地方（`PackCatalogRepository.userPacksDirectory`）。
# 這裡面可能有使用者自己的東西，所以只記下**自己造的 id**，收工只刪這些。
#
# **沙盒之後這條路徑在容器裡。** `userPacksDirectory` 走的是
# `applicationSupportDirectory`，而沙盒把它重導進容器——沒跟著改的話 cleanup 會
# 去刪一個空的舊路徑、**靜默地什麼都沒刪**，而 e2e 每跑一次就在容器裡多留兩套。
USER_PACKS="${CONTAINER}/Library/Application Support/FindMouse/Packs"
CREATED_PACK_IDS=""
# 要在收工時刪掉的暫存目錄。**掛在 trap 上而不是各段自己 rm**：中途失敗
# （任何一條 expect 讓腳本提早結束）時，段落結尾那行 rm 根本走不到。
TEMP_DIRS=""

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
    for d in ${TEMP_DIRS}; do rm -rf "${d:?}"; done
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

# 「寫入」那一段就在這裡驗，**緊接著 make-app.sh**：兩次取值之間的窗口從幾十秒
# 縮到毫秒級。窗口不是零——真的在那一瞬間改了 tracked 檔案，這條就會紅，而那時
# 報紅是誠實的（plist 與 describe 確實已經不一致）。
#
# 放在後面才是真的會假紅：隔幾十秒再算一次 describe 有兩條路——期間改了任何
# tracked 檔案會讓 -dirty 翻轉（而使用者本人常常就坐在這台機器前），以及 describe
# 失敗時（非 git 目錄／零 commit，都是 exit 128）期望值變成一個空前綴，而產品端
# 此時正確地顯示「開發版」。後者是確定性假紅：程式碼完全正確卻永遠紅。
PLIST_STAMP="$(/usr/libexec/PlistBuddy -c 'Print :FMSourceVersion' "${APP}/Contents/Info.plist" 2>/dev/null || true)"
DESCRIBE_NOW="$(git -C "${ROOT}" describe --tags --long --always --dirty 2>/dev/null || true)"
# describe 拿不到（tarball、零 commit）時**不要斷言 fallback**：那時「兩邊都空」會讓
# 這條通過，而下面那條的期望值變成「開發版」——恰好也是 BuildInfo 完全斷線時的產出。
# 兩條會一起變成恆真句，整個功能刪掉照樣綠，正是這裡最該防的事。
# 走第三種結果（無法判定）：它不算通過，而且整輪的 exit code 仍然非零。
if [[ -z "${DESCRIBE_NOW}" ]]; then
    skip "git describe 在這個 checkout 拿不到（tarball 或零 commit），建置身分這兩條沒被評估"
elif [[ "${PLIST_STAMP}" == "${DESCRIBE_NOW}" ]]; then
    ok "make-app.sh 把 describe 寫進了 plist（${PLIST_STAMP}）"
else
    bad "plist 的 FMSourceVersion 是「${PLIST_STAMP}」，而 describe 是「${DESCRIBE_NOW}」"
fi

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
expect "$(field 'd["pack"]["id"]')" "mycat" "載入的是出廠預設那套（使用者的起始狀態）"

# 建置身分的「讀取 → 顯示」那一段（「寫入」在建置那一步驗過，那裡的窗口是毫秒級）。
# 期望值從**plist 自己**組，不重算 describe：重算會在改過 tracked 檔案或 describe
# 失敗時假紅，而那兩種情況產品端的行為都是對的。
#
# 設定視窗右下角走同一支 BuildInfo.stamp()，所以這條也守住了那一列——
# 那一列本身沒有測試 target 驗得到。
#
# **不是非空檢查。** plist 沒寫、BuildInfo 沒接上，appVersion 都會是一個非空
# 字串（「開發版」）——非空檢查對整個機制壞掉的情況照樣通過。
#
# plist 沒有那個鍵時走無法判定，不斷言「開發版」：那個值同時也是「BuildInfo 完全
# 斷線」的產出，斷言它等於承認這條在該環境下沒有鑑別力（與上面那條同一個理由）。
if [[ -z "${PLIST_STAMP}" ]]; then
    skip "plist 沒有 FMSourceVersion，appVersion 這條沒被評估（期望值會與斷線時的產出同形）"
    EXPECTED_STAMP=""
else
    EXPECTED_STAMP="${PLIST_STAMP} (dev)"
fi
[[ -z "${EXPECTED_STAMP}" ]] || expect "$(field 'd["appVersion"]')" "${EXPECTED_STAMP}" \
       "appVersion 是 plist 的 FMSourceVersion ＋ (dev)"

# --- 3 -----------------------------------------------------------------------
step "3. summon → 抵達 resting，而且貓宣稱抵達時真的在游標附近"
"${FM}" summon >/dev/null

# 整段輪詢搬進**一個** python process。回傳一行：
#   <最後看到的 phase> <settled 期間看過的最小 distance（沒有就是 none）> <游標累計位移> <取樣數>
#
# 為什麼要搬：(1) 要記的是浮點數的最小值與累加位移，bash 沒有浮點運算；
# (2) 原本每取一次樣就開一個 python，取樣頻率被 process 啟動成本綁死在 0.5 秒，
#     而「貓剛坐下」那一段比 0.5 秒短得多。
#
# phase、distance、cursor 一定要取自**同一份快照**：分幾次讀的話，中間游標會動，
# 讀到的就不是同一個時刻的系統狀態，比對出來的關係是拼湊的。
arrival_probe() {
    /usr/bin/python3 - "${FM}" <<'PY'
import json, math, subprocess, sys, time

fm = sys.argv[1]
BUDGET, INTERVAL = 20.0, 0.15
# 「貓宣稱自己抵達了」的三個 phase。這三個之下貓是靜止的，不再往鼠標移動
# （`CatSessionUseCase.advance`：只有 hunting / exiting / teaser* 會呼叫 move）。
SETTLED = {"arriving", "sitting", "resting"}

phase, samples, travel, prev, best = "（沒取到任何狀態）", 0, 0.0, None, None
deadline = time.monotonic() + BUDGET
while time.monotonic() < deadline:
    try:
        out = subprocess.run([fm, "status", "--json"],
                             capture_output=True, timeout=5).stdout
        d = json.loads(out)["data"]
    except Exception:
        time.sleep(INTERVAL)
        continue
    samples += 1
    phase = d["phase"]
    cur = (d["cursor"]["x"], d["cursor"]["y"])
    if prev is not None:
        travel += math.hypot(cur[0] - prev[0], cur[1] - prev[1])
    prev = cur
    if phase in SETTLED:
        best = d["distance"] if best is None else min(best, d["distance"])
    if phase == "resting":
        break
    time.sleep(INTERVAL)

print(phase, "none" if best is None else repr(best), repr(travel), samples)
PY
}
read -r PHASE MIN_SETTLED TRAVEL SAMPLES <<< "$(arrival_probe)"

# 有沒有外力介入。這一步 e2e 一次都沒碰游標，所以任何位移都來自外力。
#
# 用 App 回報的游標算而不是 read-cursor.swift：要的是**整段期間的累計位移**
# （只比對頭尾會漏掉「移開又移回來」），而每開一支 swift 腳本要一秒，逐次取樣付不起。
# 產品若謊報游標，這個訊號會把斷言推向「無法判定」而不是「通過」；而且下面兩條要抓的
# bug（貓一直沒坐下、貓停在遠處就宣稱抵達）本身都不會製造游標位移，躲不進來。
# 回報的游標是否忠實另有 step 6 / 6b 在守。
DISTURBED=0
if /usr/bin/python3 -c "import sys; sys.exit(0 if ${TRAVEL} > ${CURSOR_STILL_TOLERANCE} else 1)"; then
    DISTURBED=1
fi

# resting 的貓一旦被拉開超過 rehunt.threshold（160）就會起身重追，所以
# 「20 秒內一定會休息」在游標持續被移動時根本不是系統承諾的性質——不是產品壞了。
if [[ "${PHASE}" == "resting" ]]; then
    ok "20 秒內抵達 resting（${SAMPLES} 次取樣）"
elif [[ "${DISTURBED}" -eq 1 ]]; then
    skip "20 秒內沒抵達 resting（停在 ${PHASE}），但期間游標被外力移動了 ${TRAVEL} 點，貓一直在重新追逐 → 無法判定"
else
    bad "20 秒內沒抵達 resting（停在 ${PHASE}），而且期間游標累計只動了 ${TRAVEL} 點"
fi

# 原本這一條寫成「輪詢到 resting 之後讀一次 distance，要求 <= arrive.radius」，**那是錯的**：
# 系統保證的只有「進入 sitting 的那一帧 distance <= arrive.radius」，之後貓就不動了，
# 而休息中的貓允許游標漂到 rehunt.threshold（160）才重新追。0.5 秒一次的輪詢抓不到
# 那一帧，抓到的是「抵達後某個時刻」——那個時刻的距離沒有任何上界約束，
# 所以原本的斷言在斷言一個系統根本不維持的性質（實測 108.18 > 76.8）。
#
# 改成「settled 期間看過的**最小** distance」：這三個 phase 下貓是靜止的，游標漂走
# 只會讓距離變大，所以最小值對干擾是穩健的；同時 arrive.radius 這個緊上限保得住——
# 貓若停在 500 點外就宣稱抵達，每一次取樣都會超標，一個都不會低於 76.8。
# （只放寬上限到 160 就不行：那等於承認「貓可以停在 rehunt 邊界上」，
#   而那正是 rehunt 會立刻把它拉回去的距離，斷言變成沒有經驗內容的恆真句。）
ARRIVE="$("${FM}" config get arrive.radius | awk '{print $3}')"
if [[ "${MIN_SETTLED}" != "none" ]] \
   && /usr/bin/python3 -c "import sys; sys.exit(0 if ${MIN_SETTLED} <= ${ARRIVE} else 1)"; then
    ok "貓宣稱抵達時真的在游標附近（最小 distance ${MIN_SETTLED} <= arrive.radius ${ARRIVE}）"
elif [[ "${DISTURBED}" -eq 1 ]]; then
    skip "settled 期間最小 distance 是 ${MIN_SETTLED}（arrive.radius ${ARRIVE}），但期間游標被外力移動了 ${TRAVEL} 點 → 無法判定"
else
    bad "貓宣稱抵達時距離游標 ${MIN_SETTLED}，超過 arrive.radius ${ARRIVE}（期間游標累計只動了 ${TRAVEL} 點）"
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
# 不是「我要求的位置」——多螢幕錯位排列下，我要求的點可能不在任何一片螢幕上，
# 系統會把游標吸到最近的合法位置，拿要求值去比會為了與被測物無關的理由失敗。
#
# 方向就是 spec 第 8.4 節真正承諾的東西：事件座標系是 Y 向下的，
# 所以「真實 y 變大時回報的 y 也變大」分得出兩個座標系。
#
# 原本這裡拿「兩次量到的真實 y 相差 > 100 點」當作「warp 生效了、可以判斷方向」的
# 前提，前提不成立就走 else 記一筆**失敗**，訊息卻寫著「無法判定」——訊息是對的，
# 歸類是錯的。使用者中途動滑鼠會把兩次 warp 都蓋掉（實測位移只剩 45.6 點），
# 於是一條沒被評估的斷言被算成產品失敗。
#
# 現在干擾有自己的判準：warp 腳本印出的**實際落點**與稍後量到的真實位置之差。
# 那個差在閒置機器上恆為 0，一旦超過 WARP_DRIFT_TOLERANCE 就記「無法判定」；
# 「> 100 點」那個檢查留著，但語意收窄成「warp 根本沒生效」——游標沒被外力動過
# 卻還是沒到位，那才是真的該紅（例如主螢幕放不下這兩個 y）。

# warp 到指定的全域座標，等 App 取樣一輪，回傳一行：
#   <落點x> <落點y> <之後量到的真實x> <之後量到的真實y> <App 回報的 y>
# 任何一段讀不到東西就回 ERR——空字串會讓下游的 python 算式語法錯誤，
# 而那個錯誤看起來會像「斷言失敗」。
warp_then_read() {
    local wx wy rx ry seen
    read -r wx wy <<< "$(swift "${ROOT}/Scripts/warp-cursor.swift" "$1" "$2" 2>/dev/null)"
    sleep 0.8
    # 先讀 App 再讀真實位置：干擾偵測的窗口要**涵蓋 App 那一次取樣**。
    # 反過來讀的話，落在兩者之間的外力移動會被判成「沒被動過」。
    seen="$(field 'd["cursor"]["y"]')"
    read -r rx ry <<< "$(swift "${ROOT}/Scripts/read-cursor.swift" 2>/dev/null)"
    if [[ -z "${wx}" || -z "${wy}" || -z "${rx}" || -z "${ry}" || -z "${seen}" ]]; then
        echo "ERR"; return
    fi
    echo "${wx} ${wy} ${rx} ${ry} ${seen}"
}

# 兩點距離（<x1> <y1> <x2> <y2>）。
gap() { /usr/bin/python3 -c "import math; print(math.hypot($3-$1, $4-$2))"; }

read -r LOW_WX LOW_WY LOW_RX LOW_RY LOW_SEEN <<< "$(warp_then_read 400 250)"
read -r HIGH_WX HIGH_WY HIGH_RX HIGH_RY HIGH_SEEN <<< "$(warp_then_read 400 700)"
if [[ "${LOW_WX}" == "ERR" || "${HIGH_WX}" == "ERR" ]]; then
    bad "讀不到游標位置（warp-cursor.swift / read-cursor.swift / status 有一支沒吐出東西）"
else
    LOW_DRIFT="$(gap "${LOW_WX}" "${LOW_WY}" "${LOW_RX}" "${LOW_RY}")"
    HIGH_DRIFT="$(gap "${HIGH_WX}" "${HIGH_WY}" "${HIGH_RX}" "${HIGH_RY}")"
    if /usr/bin/python3 -c "import sys; sys.exit(0 if max(${LOW_DRIFT}, ${HIGH_DRIFT}) > ${WARP_DRIFT_TOLERANCE} else 1)"; then
        skip "warp 之後游標被外力移走（偏離落點 ${LOW_DRIFT} / ${HIGH_DRIFT} 點），量到的不是我放的位置 → 無法判定"
    elif ! /usr/bin/python3 -c "import sys; sys.exit(0 if abs(${HIGH_RY} - ${LOW_RY}) > 100 else 1)"; then
        bad "游標沒被外力動過，卻也沒被 warp 挪開（${LOW_RY} → ${HIGH_RY}）：warp 沒生效，或主螢幕放不下這兩個 y"
    elif /usr/bin/python3 -c "import sys; sys.exit(0 if (${HIGH_SEEN}-${LOW_SEEN})*(${HIGH_RY}-${LOW_RY}) > 0 else 1)"; then
        ok "回報的 y 與真實 y 同向變化（真實 ${LOW_RY}→${HIGH_RY}、回報 ${LOW_SEEN}→${HIGH_SEEN}）"
    else
        bad "方向相反：真實 ${LOW_RY}→${HIGH_RY}，回報 ${LOW_SEEN}→${HIGH_SEEN}——座標系翻轉了"
    fi
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
expect "$(field 'd["visible"]')" "False" "前提：貓確實不可見"

# 這一條用的是與 step 6 完全相同的 warp 手法，所以**同樣會被使用者的手蓋掉**。
# 它的門檻是 300 點（位移 650 點）而 step 6 是 100 點（位移 450 點），看起來比較寬，
# 其實兩者都要求外力位移小於 350 點才判得準——step 6 先撞到只是運氣。
# 既然成因相同，處置也相同：干擾走「無法判定」，其餘照舊。
read -r HL_WX HL_WY HL_RX HL_RY HIDDEN_LOW <<< "$(warp_then_read 300 250)"
read -r HH_WX HH_WY HH_RX HH_RY HIDDEN_HIGH <<< "$(warp_then_read 300 900)"
if [[ "${HL_WX}" == "ERR" || "${HH_WX}" == "ERR" ]]; then
    bad "讀不到游標位置（warp-cursor.swift / read-cursor.swift / status 有一支沒吐出東西）"
else
    HL_DRIFT="$(gap "${HL_WX}" "${HL_WY}" "${HL_RX}" "${HL_RY}")"
    HH_DRIFT="$(gap "${HH_WX}" "${HH_WY}" "${HH_RX}" "${HH_RY}")"
    if /usr/bin/python3 -c "import sys; sys.exit(0 if max(${HL_DRIFT}, ${HH_DRIFT}) > ${WARP_DRIFT_TOLERANCE} else 1)"; then
        skip "warp 之後游標被外力移走（偏離落點 ${HL_DRIFT} / ${HH_DRIFT} 點）→ 無法判定"
    elif ! /usr/bin/python3 -c "import sys; sys.exit(0 if ${HH_RY} - ${HL_RY} > 300 else 1)"; then
        bad "游標沒被外力動過，卻也沒被 warp 挪開（真實 ${HL_RY} → ${HH_RY}）：warp 沒生效，或主螢幕放不下這兩個 y"
    elif /usr/bin/python3 -c "import sys; sys.exit(0 if ${HIDDEN_HIGH} - ${HIDDEN_LOW} > 300 else 1)"; then
        ok "hidden 狀態下鼠標仍然跟著動（回報 ${HIDDEN_LOW} → ${HIDDEN_HIGH}，真實 ${HL_RY} → ${HH_RY}）"
    else
        # 訊息只講量到的東西，不指定成因：這一條紅起來可能是「凍在啟動位置」
        # （它本來要防的），也可能是回報的座標系翻了或縮放錯了（實測用 mutation
        # 把回報的 y 換成事件座標時，紅的就是這一行）。寫死一個成因會害人追錯方向。
        bad "hidden 狀態下回報的鼠標跟不上真實鼠標：真實 ${HL_RY} → ${HH_RY}，回報卻是 ${HIDDEN_LOW} → ${HIDDEN_HIGH}"
    fi
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
expect "$(field 'd["pack"]["id"]')" "mycat" "回應來自一個正常載入 pack 的實例"
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
# 要換過去的那一套。2026-08-19 起色塊不再出貨，所以 e2e 自己現做——同一支產生器、
# 體高 240、**刻意缺 pounce**（step 11「缺 teaser 的 pack」就站在它上面）——這兩個
# 對得上 Tests/FindMouseAdaptersTests/Fixtures 底下那套 test-blocks-tall 的 manifest。
# 色相只影響顏色，這裡沒有斷言看它（那個參數也回推不出來，manifest 不記）。
# 只做這一套：其餘原本指向色塊的地方語意都是「內建／出廠預設」，那些改成 mycat。
make_pack e2e-blocks-tall 240 40 pounce

expect "$(field 'd["pack"]["id"]')" "mycat" "前提：現在跑的是出廠預設 mycat"
"${FM}" summon >/dev/null
for _ in $(seq 1 40); do
    [[ "$(field 'd["visible"]')" == "True" ]] && break
    sleep 0.5
done
expect "$(field 'd["visible"]')" "True" "前提：貓在場，所以待會走的是「先淡出」那條"

"${FM}" pack use e2e-blocks-tall >/dev/null
for _ in $(seq 1 40); do
    [[ "$(field 'd["pack"]["id"]')" == "e2e-blocks-tall" ]] && break
    sleep 0.5
done
expect "$(field 'd["pack"]["id"]')" "e2e-blocks-tall" "pack.id 換過去了"
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
expect "$(field 'd["pack"]["id"]')" "e2e-blocks-tall" "而且沒有真的換過去"

# --- 11 ----------------------------------------------------------------------
step "11. 缺 teaser 的 pack 讓逗貓棒不可用（M4 驗收條件三）"
# 驗收條件的原文是「⌥⌘T 無反應」，但**合成鍵盤事件打不到 Carbon 快捷鍵**：
# 一支獨立探針用與 `CarbonHotkeyDriver` 完全相同的方式註冊快捷鍵，
# `osascript` 與 `CGEvent` 兩條路都打不到它（M4 交接有對照組實測）。
# 拿那個管道驗，看到的「沒反應」證明不了任何事。
# 改走 `findmouse teaser on`：它與快捷鍵投遞的是同一個 `.setTeaser(true)`，
# 閘門也在同一個 `ControlUseCase`（`ControlUseCase.swift:59`）。
expect "$(field 'd["pack"]["id"]')" "e2e-blocks-tall" "前提：現在跑的是缺 pounce 的那套"
expect "$(field 'd["teaser"]["available"]')" "False" "缺 pounce → teaserAvailable: false"
OUT="$("${FM}" teaser on --json 2>&1)"; CODE=$?
expect "${CODE}" "1" "teaser on 回 exit 1"
# 同樣要驗碼：`APP_NOT_RESPONDING` 也是 exit 1，而那是「App 卡住」不是「閘門擋下」。
expect "$(errcode "${OUT}")" "TEASER_UNAVAILABLE" "錯誤碼是 TEASER_UNAVAILABLE"
expect "$(field 'd["teaser"]["enabled"]')" "False" "而且真的沒開起來"

# --- 12 ----------------------------------------------------------------------
step "12. 使用者目錄丟進去的 pack 切得過去；它在執行期消失就退回內建"
# 後半是這一段真正獨有的：spec 第 10 節「當前 pack 在執行期失效（檔案被刪）→
# 退回內建 pack 並記錄 log」。
#
# 前半（切得過去）在 2026-08-19 以前是使用者目錄那條路的**唯一**證明——當時 step 9
# 換過去的是內建的色塊，走的是 bundle。色塊不再出貨之後 step 9 換的也是自己造的
# pack，所以前半不再獨佔那個證明；它留在這裡是因為後半需要一個刪得掉的當前 pack。
#
# 內建那套刪不得（在 .app 的 bundle 裡），所以要先自己造一套放進使用者目錄。
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
expect "$(field 'd["pack"]["id"]')" "mycat" "正在用的 pack 被刪掉，重啟退回內建"
# 比的是 sitIdle 的格數而不是 logicalHeight。體高這個量在這裡撞過一次號（那次兩邊
# 都是 96，斷言變成沒有內容），所以換成比較不會撞的格數——mycat 的 sitIdle 是 4 格、
# 產生器做的色塊一律 2 格，而貓隱藏時的動作正是 sitIdle。
expect "$(field 'int(d["cat"]["frameCount"])')" "4" \
       "退回的是真的 mycat（sitIdle 4 格），不是只改了 id"

# --- 13 ----------------------------------------------------------------------
step "13. 逗貓棒真的跑起來（spec 第 3.2 / 4.5 節）"
# 逗貓棒到目前為止只有單元測試，而 e2e 這一層唯一驗過它的是 step 11 的**反面**
# （缺 pounce 的 pack 讓它不可用）。M3 的教訓是「每一層都綠而接線是壞的」，
# 所以正面那條也要有人走一次。
#
# 為什麼用 CLI 而不是按鍵：**合成鍵盤事件打不到 Carbon 快捷鍵**（理由見 step 11）。
# `findmouse teaser on` 與 ⌥⌘T 投遞的是同一個 `.setTeaser(true)`、過同一個
# `ControlUseCase` 閘門，所以驗的是同一條線。
#
# 為什麼放在 step 12 之後：step 9 把 pack 換成 e2e-blocks-tall，而那套**缺 pounce**
# （step 11 正是靠它驗 TEASER_UNAVAILABLE）。step 12 尾端的重啟把執行中的 pack
# 帶回**出廠預設**，這是整個腳本裡最後一段 teaser 可用的區間。
#
# 出廠預設 mycat 的 14 組動作齊全（含 pounce），所以 teaser 在這裡是可用的。
expect "$(field 'd["pack"]["id"]')" "mycat" "前提：跑的是 teaser 齊全的出廠預設 mycat"
expect "$(field 'd["teaser"]["available"]')" "True" "前提：teaserAvailable"
expect "$(field 'd["visible"]')" "False" "前提：貓不在畫面上（待會要看牠自己入場）"

OUT="$("${FM}" teaser on --json 2>&1)"; CODE=$?
expect "${CODE}" "0" "teaser on 回 exit 0"
# 要輪詢，不能讀一次就斷言。命令是**排進佇列**的（spec 第 8.3 節），下一帧才被
# 消費；而貓不在場時 display link 是停的，`wakeIfWorkPending` 叫醒它還要再等一個
# frame。實測直接讀會拿到還沒生效的 false——那是命令模型本來的樣子，不是 bug。
TEASER_ON=""
for _ in $(seq 1 40); do
    TEASER_ON="$(field 'd["teaser"]["enabled"]')"
    [[ "${TEASER_ON}" == "True" ]] && break
    sleep 0.25
done
expect "${TEASER_ON}" "True" "逗貓棒開起來了"

# 觀測窗要蓋過「休息 → 睡著 → 退場」的整條時程，否則「不會自動退場」那條
# 是恆真句。兩個時長讀自當前設定而不是寫死出廠值——使用者調過就會對不上。
REST_D="$("${FM}" config get rest.duration | awk '{print $3}')"
SLEEP_D="$("${FM}" config get sleep.duration | awk '{print $3}')"
PROBE_SECONDS="$(/usr/bin/python3 -c "print(max(24, ${REST_D} + ${SLEEP_D} + 10))")"

# 一個 python process 跑完整段輪詢。回傳一行：
#   <屁股搖次數> <游標累計位移> <取樣數> <逗貓棒階段的取樣數> <暗幕亮著的次數>
#   <看過最大的 rest/sleep 計時> <進入逗貓棒後又跑到非逗貓棒階段的次數> <走過的 phase>
#
# **判斷「循環有沒有跑完」用的是屁股搖的次數，不是看齊六個階段。**
# 游標是使用者的，隨時會被碰到，而逗貓棒的每一步都吃游標：潛伏的朝向、
# 屁股搖結束時鎖定的位置、命中判定的距離。所以「有沒有命中」「潛伏停了多久」
# 都不是系統承諾的性質，斷言它們必然 flaky。屁股搖不一樣——它是**固定 0.5 秒**、
# 與游標無關，所以次數不吃游標。壓縮掉連續重複之後看到兩次屁股搖，代表狀態機
# **離開屁股搖之後又回到了屁股搖**，中間那幾個階段不必被取樣到。
# 取樣間隔 0.05 秒（實測單次 status 花 4.4 毫秒），屁股搖本身就有約 9 次取樣。
#
# **這條證明到哪裡為止。** 它證明「回得到屁股搖」，不證明「撲擊真的發生過」——
# 狀態機若退化成 `windup → stalking → windup`，這個判準照樣成立。那條缺口由單元
# 測試守（`TeaserTests` 對每個轉移各一條，且每條都有 mutation 證明會紅）；e2e 在
# 這裡的職責是「整套在真的 App 裡跑得起來」，不是把轉移再測一遍。同理**命中路徑
# （`teaserTumbling`）不保證被走到**——連撲兩次空一樣湊得滿兩次屁股搖。
#
# 不把 `teaserPouncing` 加進斷言是刻意的：飛行只約 0.11 秒而取樣間隔 0.05 秒，
# 加了會 flaky，而 flaky 的 gate 比涵蓋窄一點的 gate 更糟。
teaser_probe() {
    /usr/bin/python3 - "${FM}" "$1" <<'PY'
import json, math, subprocess, sys, time

fm, budget = sys.argv[1], float(sys.argv[2])
INTERVAL = 0.05

seq, travel, prev = [], 0.0, None
samples = teaser_samples = lit = left = 0
worst_timer = 0.0
deadline = time.monotonic() + budget
while time.monotonic() < deadline:
    try:
        out = subprocess.run([fm, "status", "--json"], capture_output=True, timeout=5).stdout
        d = json.loads(out)["data"]
    except Exception:
        time.sleep(INTERVAL)
        continue
    samples += 1
    cur = (d["cursor"]["x"], d["cursor"]["y"])
    if prev is not None:
        travel += math.hypot(cur[0] - prev[0], cur[1] - prev[1])
    prev = cur

    phase = d["phase"]
    if not seq or seq[-1] != phase:
        seq.append(phase)
    if phase.startswith("teaser"):
        teaser_samples += 1
        if d["spotlight"]["active"]:
            lit += 1
        worst_timer = max(worst_timer, d["timers"]["rest"], d["timers"]["sleep"])
    elif teaser_samples:
        # 命令還沒被消費的開頭幾帧仍是 hidden，那不算「離開」；
        # 進過逗貓棒之後才跑出去的才算。
        left += 1
    time.sleep(INTERVAL)

print(seq.count("teaserWindup"), repr(travel), samples, teaser_samples,
      lit, repr(worst_timer), left, ",".join(sorted(set(seq))))
PY
}
read -r WINDUPS T_TRAVEL T_SAMPLES T_TEASER T_LIT T_TIMER T_LEFT T_PHASES \
    <<< "$(teaser_probe "${PROBE_SECONDS}")"

# 這一段 e2e 一次都沒碰游標，所以任何位移都來自外力。門檻沿用 step 3 的
# CURSOR_STILL_TOLERANCE：這條斷言沒有「位移小於 N 就一定判得準」的界線可以反推
# ——會跑的游標可以讓貓永遠追不進 stalkRange，不管總位移是大是小。所以判準只能是
# 「有沒有被碰過」，而那個量在閒置機器上恆為 0（實測連跑 3 遍都是 0.0）。
T_DISTURBED=0
if /usr/bin/python3 -c "import sys; sys.exit(0 if ${T_TRAVEL} > ${CURSOR_STILL_TOLERANCE} else 1)"; then
    T_DISTURBED=1
fi

if [[ "${WINDUPS}" -ge 2 ]]; then
    ok "逗貓棒循環至少完整跑了一圈（${WINDUPS} 次屁股搖／${T_SAMPLES} 次取樣；走過 ${T_PHASES}）"
elif [[ "${T_DISTURBED}" -eq 1 ]]; then
    skip "只看到 ${WINDUPS} 次屁股搖（走過 ${T_PHASES}），但期間游標被外力移動了 ${T_TRAVEL} 點——貓在追一個會跑的目標 → 無法判定"
else
    bad "只看到 ${WINDUPS} 次屁股搖（走過 ${T_PHASES}），而期間游標累計只動了 ${T_TRAVEL} 點"
fi

# 以下兩條與游標無關（外力移動游標既關不掉逗貓棒、也開不出暗幕），所以不走
# 「無法判定」——除非連一帧逗貓棒階段都沒取樣到，那時它們根本沒有被評估。
if [[ "${T_TEASER}" -eq 0 ]]; then
    if [[ "${T_DISTURBED}" -eq 1 ]]; then
        skip "${PROBE_SECONDS} 秒內一帧都沒進到逗貓棒階段（走過 ${T_PHASES}），期間游標被外力移動了 ${T_TRAVEL} 點 → 暗幕與自動退場兩條都沒被評估"
    else
        bad "${PROBE_SECONDS} 秒內一帧都沒進到逗貓棒階段（走過 ${T_PHASES}），游標累計只動了 ${T_TRAVEL} 點"
    fi
else
    expect "${T_LIT}" "0" "逗貓棒的任何階段都沒有暗幕（${T_TEASER} 帧取樣）"
    # spec 第 3.2 節第 7 條後半：逗貓棒模式下貓不會自動退場。
    # 兩個訊號都要——只看 phase 的話，「計時器在跑、只是還沒到門檻」躲得過去。
    if [[ "${T_LEFT}" -eq 0 ]] \
       && /usr/bin/python3 -c "import sys; sys.exit(0 if ${T_TIMER} == 0 else 1)"; then
        ok "逗貓棒 ${PROBE_SECONDS} 秒都不自動退場（rest ${REST_D} ＋ sleep ${SLEEP_D} 都過完了，退場計時器全程 0）"
    else
        bad "逗貓棒模式下貓自己退場了：離開逗貓棒 ${T_LEFT} 次、退場計時器最大跑到 ${T_TIMER}（走過 ${T_PHASES}）"
    fi
fi

# --- 13b ---------------------------------------------------------------------
step "13b. 再關一次逗貓棒 → 走完當前動作後回家（spec 第 3.2 節第 8 條）"
OUT="$("${FM}" teaser off --json 2>&1)"; CODE=$?
expect "${CODE}" "0" "teaser off 回 exit 0"
# 同樣要輪詢（理由見 step 13 的 teaser on）
TEASER_OFF=""
for _ in $(seq 1 40); do
    TEASER_OFF="$(field 'd["teaser"]["enabled"]')"
    [[ "${TEASER_OFF}" == "False" ]] && break
    sleep 0.25
done
expect "${TEASER_OFF}" "False" "逗貓棒關掉了"
# 「走完當前動作」＝ `pendingExit` 要等到**下一次逗貓棒階段轉換**才被消費
# （`CatSessionUseCase.enter`），而潛伏最久要等 teaser.stalkTimeout（值域上限 20 秒），
# 所以窗口取 30 秒。
#
# **這一條會被游標影響。** 原本這裡寫「退場由階段轉換觸發，游標怎麼動都還是會轉換」
# ——那句話是錯的，實測推翻過：把游標在左右兩片螢幕之間持續甩動（相距 6500 點，
# 而貓只有 900 點/秒），貓就永遠追不進 stalkRange、卡在 `teaserApproach`，
# 一次階段轉換都沒有，於是 30 秒到了還在場。那不是產品壞了，是這條斷言測不準：
# 「走完當前動作」的前提本來就是那個動作走得完。所以它跟 step 3 一樣要有干擾判準。
exit_probe() {
    /usr/bin/python3 - "${FM}" "$1" <<'PY'
import json, math, subprocess, sys, time

fm, budget = sys.argv[1], float(sys.argv[2])
INTERVAL = 0.1
visible, travel, prev, samples = "（沒取到任何狀態）", 0.0, None, 0
deadline = time.monotonic() + budget
while time.monotonic() < deadline:
    try:
        out = subprocess.run([fm, "status", "--json"], capture_output=True, timeout=5).stdout
        d = json.loads(out)["data"]
    except Exception:
        time.sleep(INTERVAL)
        continue
    samples += 1
    cur = (d["cursor"]["x"], d["cursor"]["y"])
    if prev is not None:
        travel += math.hypot(cur[0] - prev[0], cur[1] - prev[1])
    prev = cur
    visible = d["visible"]
    if not visible:
        break
    time.sleep(INTERVAL)
print(visible, repr(travel), samples)
PY
}
read -r EXIT_VIS EXIT_TRAVEL EXIT_SAMPLES <<< "$(exit_probe 30)"
if [[ "${EXIT_VIS}" == "False" ]]; then
    ok "30 秒內走完當前動作並退場（${EXIT_SAMPLES} 次取樣）"
elif /usr/bin/python3 -c "import sys; sys.exit(0 if ${EXIT_TRAVEL} > ${CURSOR_STILL_TOLERANCE} else 1)"; then
    skip "30 秒後貓還在場，但期間游標被外力移動了 ${EXIT_TRAVEL} 點——貓可能還沒追進潛伏範圍，一次階段轉換都還沒發生 → 無法判定"
else
    bad "30 秒內沒有退場，而期間游標累計只動了 ${EXIT_TRAVEL} 點"
fi

# --- 14 ----------------------------------------------------------------------
step "14. 開機啟動：不合格的位置會被擋（spec：login-item）"
# e2e 跑的是 build/FindMouse.app，依設計它永遠不在「應用程式」資料夾裡，
# 所以這裡驗得到的是**不合格**那條路——而那條路是真的端到端。
#
# **刻意不測 `login-item off`。** 它與 on 撞同一道閘門、同一個錯誤碼，
# 多驗一次只是多一份維護。要驗 off 的破壞性後果得在合格位置上做，
# 那屬於手動驗收（登入項目以 bundle id 為鍵，實測從不合格的拷貝
# unregister 會把裝在 /Applications 那份一起關掉）。
expect "$(field 'd["loginItem"]["state"]')" "ineligible" \
       "status 裡的 loginItem.state 是 ineligible"

OUT="$("${FM}" login-item --json 2>&1)"; CODE=$?
expect "${CODE}" "0" "查詢本身不是錯誤，回 exit 0"
expect "$(echo "${OUT}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["state"])')" \
       "ineligible" "login-item 回的狀態與 status 一致"

OUT="$("${FM}" login-item on --json 2>&1)"; CODE=$?
expect "${CODE}" "1" "login-item on 在不合格的位置回 exit 1"
expect "$(errcode "${OUT}")" "LOGIN_ITEM_INELIGIBLE" "錯誤碼是 LOGIN_ITEM_INELIGIBLE"

# --- 15 ----------------------------------------------------------------------
step "15. pack install／remove 的整條路（分發 C）"

# 用產生器現做一套，再**搬出使用者目錄**——不搬的話「安裝」等於原地複製，
# 什麼都驗不到。id 帶 e2e- 前綴（make_pack 的慣例），cleanup 只刪自己造的。
make_pack e2e-installable 96 120
STAGE_DIR="$(mktemp -d)"; TEMP_DIRS="${TEMP_DIRS} ${STAGE_DIR}"
mv "${USER_PACKS}/e2e-installable" "${STAGE_DIR}/e2e-installable"
STAGE_SRC="${STAGE_DIR}/e2e-installable"

"${FM}" pack install "${STAGE_SRC}" >/dev/null 2>&1
expect "$?" "0" "pack install 一個目錄來源回 exit 0"
expect "$(packentry "'e2e-installable' in ps")" "True" "裝好的那套出現在 pack list 裡"
expect "$(packentry "ps['e2e-installable']['usable']")" "True" "而且是可用的"

# 同 id 再裝一次要被擋，錯誤碼要對
OUT="$("${FM}" pack install "${STAGE_SRC}" --json 2>&1)"; CODE=$?
expect "${CODE}" "1" "同 id 再裝一次 exit 1"
expect "$(echo "${OUT}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["code"])' 2>/dev/null)" \
       "PACK_ALREADY_INSTALLED" "錯誤碼是 PACK_ALREADY_INSTALLED"

# --force 過得去
"${FM}" pack install "${STAGE_SRC}" --force >/dev/null 2>&1
expect "$?" "0" "--force 覆蓋同 id"

# 撞內建 id：連 --force 都不給過，而且錯誤碼與「移除內建」不同
BUILTIN_DIR="$(mktemp -d)"; TEMP_DIRS="${TEMP_DIRS} ${BUILTIN_DIR}"
# 撞的必須是**現在還內建的**那個 id。2026-08-19 起色塊不再出貨，拿 test-blocks 來
# 撞會裝得成功而不是被擋——那條斷言會安靜地驗錯東西。
cp -R "${STAGE_SRC}" "${BUILTIN_DIR}/mycat"
/usr/bin/python3 - "${BUILTIN_DIR}/mycat" <<'PYEOF'
import json, sys
path = f"{sys.argv[1]}/pack.json"
m = json.load(open(path)); m["id"] = "mycat"
json.dump(m, open(path, "w"))
PYEOF
OUT="$("${FM}" pack install "${BUILTIN_DIR}/mycat" --force --json 2>&1)"; CODE=$?
expect "${CODE}" "1" "撞內建 id 即使加 --force 也是 exit 1"
expect "$(echo "${OUT}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["code"])' 2>/dev/null)" \
       "PACK_ID_RESERVED" "錯誤碼是 PACK_ID_RESERVED（不是 PACK_BUILT_IN——處方不同）"

# 移除當前使用中的那套要被擋，而且不能被偷偷切走
"${FM}" pack use e2e-installable >/dev/null 2>&1
for _ in $(seq 1 20); do
    [[ "$(field 'd["pack"]["id"]')" == "e2e-installable" ]] && break
    sleep 0.25
done
expect "$(field 'd["pack"]["id"]')" "e2e-installable" "切到剛裝的那套"
OUT="$("${FM}" pack remove e2e-installable --json 2>&1)"; CODE=$?
expect "${CODE}" "1" "移除當前使用中的那套 exit 1"
expect "$(echo "${OUT}" | /usr/bin/python3 -c 'import json,sys; print("換成別的圖組" in json.load(sys.stdin)["error"]["message"])' 2>/dev/null)" \
       "True" "訊息講出下一步（先換成別的圖組）"
expect "$(field 'd["pack"]["id"]')" "e2e-installable" "被擋下之後仍在用那一套"

# 切走之後才移除得掉
"${FM}" pack use mycat >/dev/null 2>&1
for _ in $(seq 1 20); do
    [[ "$(field 'd["pack"]["id"]')" == "mycat" ]] && break
    sleep 0.25
done
"${FM}" pack remove e2e-installable >/dev/null 2>&1
expect "$?" "0" "切走之後 pack remove 回 exit 0"
expect "$(packentry "'e2e-installable' in ps")" "False" "移除後不在 pack list 裡"

# 內建拿不掉
OUT="$("${FM}" pack remove mycat --json 2>&1)"; CODE=$?
expect "${CODE}" "1" "移除內建 exit 1"
expect "$(echo "${OUT}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["code"])' 2>/dev/null)" \
       "PACK_BUILT_IN" "錯誤碼是 PACK_BUILT_IN"


# --- 16 ----------------------------------------------------------------------
step "16. .fmpack 打包與匯入（分發 C-2）"

# 這一段同時驗兩件單元測試碰不到的事：`tools/pack-fmpack.py` 打出來的東西
# 真的裝得進去（它的測試全部用假 CLI），以及 **zip 來源**這條匯入路徑
# ——step 15 用的是目錄來源，而 zip 那條在 C-1 只有單元測試。
make_pack e2e-fmpack 96 120
FMPACK_DIR="$(mktemp -d)"; TEMP_DIRS="${TEMP_DIRS} ${FMPACK_DIR}"
mv "${USER_PACKS}/e2e-fmpack" "${FMPACK_DIR}/e2e-fmpack"

/usr/bin/python3 "${ROOT}/tools/pack-fmpack.py" "${FMPACK_DIR}/e2e-fmpack" \
    --output "${FMPACK_DIR}/e2e-fmpack.fmpack" --findmouse "${FM}" >/dev/null 2>&1
expect "$?" "0" "pack-fmpack.py 對一套合格的 pack 回 exit 0"
if [[ -f "${FMPACK_DIR}/e2e-fmpack.fmpack" ]]; then FOUND=yes; else FOUND=no; fi
expect "${FOUND}" "yes" "而且真的產出 .fmpack"

"${FM}" pack install "${FMPACK_DIR}/e2e-fmpack.fmpack" >/dev/null 2>&1
expect "$?" "0" "從 .fmpack 匯入回 exit 0"
expect "$(packentry "'e2e-fmpack' in ps")" "True" "裝好的那套出現在 pack list 裡"
expect "$(packentry "ps['e2e-fmpack']['usable']")" "True" "而且是可用的"

# 反向：弄壞它，打包這一端就該擋下來——不擋的話作者會拿一個裝不起來的檔案去發布
rm -rf "${FMPACK_DIR}/e2e-fmpack/run"
rm -f "${FMPACK_DIR}/bad.fmpack"
/usr/bin/python3 "${ROOT}/tools/pack-fmpack.py" "${FMPACK_DIR}/e2e-fmpack" \
    --output "${FMPACK_DIR}/bad.fmpack" --findmouse "${FM}" >/dev/null 2>&1
expect "$?" "1" "不合格的 pack 打包回 exit 1"
if [[ -f "${FMPACK_DIR}/bad.fmpack" ]]; then LEFT=yes; else LEFT=no; fi
expect "${LEFT}" "no" "而且沒有留下半個檔案"

"${FM}" pack remove e2e-fmpack >/dev/null 2>&1

step "結果"
printf '  通過 %d、失敗 %d、無法判定 %d\n' "${PASS}" "${FAIL}" "${SKIP}"
if [[ "${SKIP}" -gt 0 ]]; then
    printf '  有 %d 條偵測到游標被外力移動，沒有被評估——既不算通過也不算失敗。\n' "${SKIP}"
    printf '  請在沒有人操作滑鼠的情況下重跑 Scripts/e2e.sh（或先關掉會自動移動游標的工具）。\n'
fi
# 無法判定不得被當成通過：只要有一條沒被評估，這一輪就沒有證明接線是完整的。
#
# 這裡刻意**不設**「無法判定的比例低於 X 就放行」的門檻。理由有二：
# (1) 任何一條無法判定都已經讓 exit code 非零，比例門檻沒有可放行的區間可管；
# (2) 「某條在沒有人碰滑鼠時也一直回無法判定」這個退化情境進不來——skip 的三個
#     觸發點都要求一個實測到的位移量超過 CURSOR_STILL_TOLERANCE 或
#     WARP_DRIFT_TOLERANCE，而閒置機器上那些量恆為 0（實測：連續 5 遍全部
#     通過 39、失敗 0、無法判定 0）；訊息也把量到的值印出來，真的出現
#     「無人碰滑鼠卻量到位移」就是那個數字自己在說話。
[[ "${FAIL}" -eq 0 && "${SKIP}" -eq 0 ]]
