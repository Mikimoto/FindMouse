#!/bin/bash
# 證明 release.sh 的守衛與驗收**會紅**。
#
# 這支的存在理由只有一個：一個永遠說 yes 的驗收比沒有驗收更糟。所以每一條都
# 餵一個**已知該失敗**的輸入，看它有沒有失敗。
#
# 用法：
#   Scripts/test-release.sh                      # 只跑負向那半
#   Scripts/test-release.sh <某個已發布的.dmg>    # 連正向對照組一起跑
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

PASS=0; FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

GOOD_DMG="${1:-}"

# 幾條測試需要乾淨的工作樹（版本戳記那條要 release.sh 真的跑得起來）。
# 髒的時候直接停下，不要跑一半得到看不懂的結果。
if [[ -n "$(git status --porcelain)" ]]; then
    echo "工作樹不乾淨，這支測試需要乾淨的工作樹才跑得準。先 commit 或 stash。"
    git status --porcelain
    exit 1
fi

# --- 1 -------------------------------------------------------------------
step "1. 工作樹髒的時候拒跑"
PROBE="${ROOT}/.release-test-probe"
cleanup_probe() { rm -f "${PROBE}"; }
trap cleanup_probe EXIT
touch "${PROBE}"
OUT="$(Scripts/release.sh 9.9.9 --dry-run 2>&1)"; CODE=$?
cleanup_probe
if [[ "${CODE}" -ne 0 ]] && echo "${OUT}" | grep -q "乾淨"; then
    ok "髒工作樹 → 非零退出，訊息講得出原因"
else
    bad "髒工作樹沒被擋（exit=${CODE}）：${OUT}"
fi

# --- 2 -------------------------------------------------------------------
step "2. --dry-run 把版本戳對地方"
WANT_BUILD="$(git rev-list --count HEAD)"
Scripts/release.sh 9.9.9 --dry-run >/dev/null 2>&1 || bad "--dry-run 自己就失敗了"
PL="${ROOT}/build/release/FindMouse.app/Contents/Info.plist"
if [[ -f "${PL}" ]]; then
    GOT_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PL}")"
    GOT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PL}")"
    [[ "${GOT_SHORT}" == "9.9.9" ]] \
        && ok "CFBundleShortVersionString = 9.9.9" \
        || bad "CFBundleShortVersionString 是 ${GOT_SHORT}"
    [[ "${GOT_BUILD}" == "${WANT_BUILD}" ]] \
        && ok "CFBundleVersion = ${WANT_BUILD}（git rev-list --count）" \
        || bad "CFBundleVersion 是 ${GOT_BUILD}，期望 ${WANT_BUILD}"
else
    bad "--dry-run 沒組出 .app"
fi

# 來源檔不准被動到。第 1 步剛檢查過工作樹乾淨，發布流程若去改
# Scripts/Info.plist 就是自己打自己。
if [[ -z "$(git status --porcelain)" ]]; then
    ok "跑完之後工作樹仍然乾淨（改的是複製品）"
else
    bad "跑完之後工作樹髒了：$(git status --porcelain)"
fi

# --- 3 -------------------------------------------------------------------
step "3. 測試素材不會混進 .app"
# 先確認那個 .app 真的在。少了這一步，`--dry-run` 若在組裝之前就失敗
# （`rm -rf "${STAGE}"` 已經執行過），`find` 對不存在的路徑回空字串，
# 這一條就報 ✓ 而其實什麼都沒檢查。
if [[ ! -d "${ROOT}/build/release/FindMouse.app" ]]; then
    bad "build/release/FindMouse.app 不存在，這一條沒有被評估（前一組的 --dry-run 大概沒跑完）"
else
    FOUND="$(/usr/bin/find "${ROOT}/build/release/FindMouse.app" -name '*Tests*' 2>/dev/null)"
    [[ -z "${FOUND}" ]] && ok "app 裡沒有 *Tests*" || bad "app 裡有測試素材：${FOUND}"
fi

# --- 4 -------------------------------------------------------------------
step "4. 驗收會對壞產物說 no（負向對照組）"
# 下面逐條點名的標籤是寫死的。verify_dmg() 日後多一條 check 而沒有跟著加進來，
# 那條就會永遠不被檢查——所以先確認兩邊的數量對得上。
N_CHECKS="$(grep -c '^ *check "' "${ROOT}/Scripts/release.sh")"
[[ "${N_CHECKS}" -eq 6 ]] \
    && ok "release.sh 裡剛好六條 check，與下面列舉的標籤數相符" \
    || bad "release.sh 裡有 ${N_CHECKS} 條 check，但這裡只列舉了 6 個標籤——補上去，否則多的那條永遠不會被驗"

# 拿一個沒簽過的 .app 包成 dmg。四條驗收會跑兩輪（原檔一輪、加了隔離屬性的
# 副本一輪），八條應該全部踩紅——實測 ad-hoc 產物：codesign 回 1、spctl 回 1、
# stapler 回 65。
TMP="$(mktemp -d)"
BAD_DMG="${TMP}/unsigned.dmg"
if hdiutil create -volname "FindMouse bad" -srcfolder "${ROOT}/build/release" \
        -ov -format UDZO "${BAD_DMG}" >/dev/null 2>&1; then
    OUT="$(Scripts/release.sh --verify-only "${BAD_DMG}" 2>&1)"; CODE=$?
    if [[ "${CODE}" -ne 0 ]]; then
        ok "沒簽的 dmg 被擋下（exit=${CODE}）"
    else
        bad "沒簽的 dmg 竟然通過驗收——驗收沒有鑑別力，整個 A 等於沒做"
    fi
    # 不只要非零，還要看得出**每一條**都真的跑了。
    #
    # 原本這裡寫「至少三條報紅」，那個門檻鬆到失去意義：`hdiutil attach` 若哪天
    # 壞掉（改錯旗標、mountpoint 撞名），兩輪各印一條「掛不起來」加上結尾的 die
    # 剛好就是三條，門檻照樣過——**測試全綠，而四條驗收一條都沒執行**。
    # 所以改成逐條點名，每條都要在兩輪裡各出現一次。
    #
    # grep 的 pattern 用 `✗.*<標籤>` 而不是 `✗ <標籤>`：✗ 與標籤之間夾著
    # 一段 ANSI 重設碼（`\033[0m`），寫成一個空格永遠對不上。
    MISSING=""
    for label in "codesign --verify" "簽章者是我們" "巢狀 bundle 的簽章者也是我們" "spctl app" "spctl dmg" "stapler validate"; do
        n="$(echo "${OUT}" | grep -c "✗.*${label}")"
        [[ "${n}" -eq 2 ]] || MISSING="${MISSING} ${label}(${n}次)"
    done
    [[ -z "${MISSING}" ]] \
        && ok "六條驗收各自報紅兩次（原檔一輪＋加隔離屬性一輪）" \
        || bad "有驗收沒跑到或次數不對：${MISSING}"
else
    bad "造不出測試用的 dmg"
fi
rm -rf "${TMP}"

# --- 5 -------------------------------------------------------------------
# 正向對照組。只有負向的話，「驗收整個壞掉」與「產物真的有問題」外觀相同。
step "5. 驗收會對好產物說 yes（正向對照組）"
if [[ -z "${GOOD_DMG}" ]]; then
    echo "  （沒給已發布的 dmg，跳過。發完第一版之後跑：Scripts/test-release.sh build/FindMouse-<版本>-<sha>.dmg）"
elif [[ ! -f "${GOOD_DMG}" ]]; then
    bad "找不到 ${GOOD_DMG}"
else
    # 只跑一次就把輸出留著。原本失敗分支裡又跑了一次 --verify-only 來取訊息，
    # 那會把 dmg 多掛載兩次，而且第二次的結果不保證與第一次相同。
    if GOOD_OUT="$(Scripts/release.sh --verify-only "${GOOD_DMG}" 2>&1)"; then
        ok "已簽章 notarize 過的 dmg 通過六條驗收（原檔一輪＋加隔離屬性一輪）"
    else
        bad "已發布的 dmg 沒通過驗收：$(echo "${GOOD_OUT}" | tail -20)"
    fi
fi

step "結果"
printf '  通過 %d、失敗 %d\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
