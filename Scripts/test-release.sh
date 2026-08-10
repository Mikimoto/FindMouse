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
FOUND="$(/usr/bin/find "${ROOT}/build/release/FindMouse.app" -name '*Tests*' 2>/dev/null)"
[[ -z "${FOUND}" ]] && ok "app 裡沒有 *Tests*" || bad "app 裡有測試素材：${FOUND}"

# --- 4 -------------------------------------------------------------------
step "4. 驗收會對壞產物說 no（負向對照組）"
# 拿一個沒簽過的 .app 包成 dmg。它該把五條驗收全部踩紅——
# 實測 ad-hoc 產物：codesign 回 1、spctl 回 1、stapler 回 65。
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
    # 不只要非零，還要看得出**是哪幾條**紅的。全部紅才代表五條都真的跑了；
    # 只紅一條可能是前面某條 die 掉，後面根本沒執行。
    N_BAD="$(echo "${OUT}" | grep -c '✗')"
    [[ "${N_BAD}" -ge 3 ]] \
        && ok "至少三條各自報紅（實際 ${N_BAD} 條），不是第一條就 die 掉" \
        || bad "只有 ${N_BAD} 條報紅，其他幾條可能根本沒跑到：${OUT}"
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
    Scripts/release.sh --verify-only "${GOOD_DMG}" >/dev/null 2>&1 \
        && ok "已簽章 notarize 過的 dmg 通過五條驗收" \
        || bad "已發布的 dmg 沒通過驗收：$(Scripts/release.sh --verify-only "${GOOD_DMG}" 2>&1 | tail -20)"
fi

step "結果"
printf '  通過 %d、失敗 %d\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
