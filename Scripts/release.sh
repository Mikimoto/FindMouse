#!/bin/bash
# 簽章 → 打包 → notarize → staple → 驗收。
# 設計在 docs/superpowers/specs/2026-08-10-distribution-a-signing-design.md
#
# 用法：
#   Scripts/release.sh <版本> --profile <keychain profile>   # 完整發布
#   Scripts/release.sh <版本> --dry-run                      # 只做本機那半段
#   Scripts/release.sh --verify-only <某個.dmg>               # 只驗一個既有產物
#
# --profile 是 `xcrun notarytool store-credentials <名稱>` 存過的 keychain profile
# 名稱。密鑰不進 repo、不進環境變數、不進腳本參數——這支只知道那個名稱。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

IDENTITY="Developer ID Application: DeepThought Co., Ltd. (JA387Z4D7Q)"
STAGE="${ROOT}/build/release"

die() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
say() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }

MODE=full
VERSION=""
PROFILE=""
VERIFY_TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)     MODE=dry; shift ;;
        --verify-only) MODE=verify; VERIFY_TARGET="${2:-}"; shift 2 ;;
        --profile)     PROFILE="${2:-}"; shift 2 ;;
        -*)            die "不認得的選項 ${1}。用法見 Scripts/release.sh 檔頭。" ;;
        *)             VERSION="$1"; shift ;;
    esac
done

# --- 驗收 -------------------------------------------------------------------
# 跑一條驗收命令。**不接管線**——`cmd | tail` 的 exit code 來自 tail，
# 那會讓每一條都「通過」。輸出寫檔，只在失敗時印出來。
check() {
    local what="$1"; shift
    local log; log="$(mktemp)"
    if "$@" >"${log}" 2>&1; then
        ok "${what}"; rm -f "${log}"; return 0
    fi
    printf '  \033[31m✗\033[0m %s\n' "${what}"
    sed 's/^/      /' "${log}"
    rm -f "${log}"
    return 1
}

# 掛起來驗 dmg 裡面那個 .app——驗的是使用者真的會拿到的東西，不是手邊那份
# staging 副本。四條都跑完才回報，不在第一條就 die：只紅一條與五條全紅
# 是完全不同的診斷，而前者常常代表後面幾條根本沒執行。
verify_dmg() {
    local dmg="$1" mnt app rc=0
    mnt="$(mktemp -d)"
    hdiutil attach "${dmg}" -readonly -nobrowse -mountpoint "${mnt}" >/dev/null 2>&1 \
        || { printf '  \033[31m✗\033[0m 掛不起來：%s\n' "${dmg}"; rmdir "${mnt}"; return 1; }

    app="$(/usr/bin/find "${mnt}" -maxdepth 1 -name '*.app' -print -quit)"
    if [[ -z "${app}" ]]; then
        printf '  \033[31m✗\033[0m dmg 裡沒有 .app\n'; rc=1
    else
        check "codesign --verify（巢狀二進位漏簽）" \
              codesign --verify --deep --strict --verbose=2 "${app}" || rc=1
        check "spctl app（Gatekeeper 對 app 的判定）" \
              spctl -a -vvv -t exec "${app}" || rc=1
    fi
    # -t open 是給 dmg 的；-t install 是給 .pkg 的，型別用錯會得到看似通過的
    # 無意義結果。這一條是使用者實際遇到的那一關。
    check "spctl dmg（使用者實際遇到的那一關）" \
          spctl -a -vvv -t open --context context:primary-signature "${dmg}" || rc=1
    check "stapler validate（票沒釘上，使用者離線就被擋）" \
          stapler validate "${dmg}" || rc=1

    hdiutil detach "${mnt}" -quiet >/dev/null 2>&1 \
        || hdiutil detach "${mnt}" -force -quiet >/dev/null 2>&1 || true
    rmdir "${mnt}" 2>/dev/null || true
    return "${rc}"
}

# 第二輪：對加了隔離屬性的**副本**再跑一次同樣四條。
#
# 前四條在本機幾乎必過——只有帶著隔離屬性才走得到 Gatekeeper 真正會擋的那條
# 路徑，而那正是「我這邊好好的」最常見的成因。對副本做是因為原檔加了再拿掉，
# 殘留的 xattr 會讓下一次驗證的前提悄悄變成不同的東西。
verify_quarantined() {
    local dmg="$1" dir tmp rc=0
    dir="$(mktemp -d)"; tmp="${dir}/$(basename "${dmg}")"
    cp "${dmg}" "${tmp}"
    xattr -w com.apple.quarantine "0081;00000000;Safari;$(uuidgen)" "${tmp}"
    verify_dmg "${tmp}" || rc=1
    rm -rf "${dir}"
    return "${rc}"
}

if [[ "${MODE}" == verify ]]; then
    [[ -f "${VERIFY_TARGET}" ]] || die "找不到 ${VERIFY_TARGET}"
    say "驗 $(basename "${VERIFY_TARGET}")"
    RC=0
    verify_dmg "${VERIFY_TARGET}" || RC=1
    say "再驗一次（已加隔離屬性，模擬從網路下載）"
    verify_quarantined "${VERIFY_TARGET}" || RC=1
    [[ "${RC}" -eq 0 ]] || die "驗收沒過。這份產物不能發出去。"
    exit 0
fi

# --- 本機那半段 --------------------------------------------------------------
[[ -n "${VERSION}" ]] || die "要給版本號。例：Scripts/release.sh 0.2.0 --profile findmouse-release"
[[ "${MODE}" == dry || -n "${PROFILE}" ]] \
    || die "要給 --profile <名稱>。先跑一次：xcrun notarytool store-credentials <名稱>"

say "1／9 工作樹與版本"
[[ -z "$(git status --porcelain)" ]] \
    || die "工作樹不乾淨。發出去的東西必須對得上一個 commit——先 commit 或 stash。"
SHA="$(git rev-parse --short HEAD)"
# CFBundleVersion 必須單調遞增。寫死 1 的話，發三個測試版全都是 1，
# 「你手上是哪一版」就無法回答——而那正是 A 的全部目的。
BUILD_NUMBER="$(git rev-list --count HEAD)"
ok "${VERSION}（build ${BUILD_NUMBER}）@ ${SHA}"

# Xcode 27 還是 beta。等正式版出來要送 App Store Connect 時，得知道先前發出去的
# 哪幾版是 beta SDK 建的——那些不能直接送審。不手寫 DTXcode 之類的鍵：
# Apple 會讀它們，手寫等於謊報。
say "2／9 工具鏈"
swift --version 2>&1 | sed 's/^/  /'
xcodebuild -version 2>&1 | sed 's/^/  /'

say "3／9 · 4／9 建置與組裝"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
APP_DIR="${STAGE}/FindMouse.app" Scripts/make-app.sh release >/dev/null
APP="${STAGE}/FindMouse.app"
[[ -x "${APP}/Contents/MacOS/FindMouse" ]] || die "組不出 .app"

# 版本寫進**已經複製到 .app 裡**的那份 Info.plist，不動 Scripts/Info.plist。
# 動來源檔的話每次發布都會弄髒工作樹，而第 1 步剛檢查過它乾淨——自己打自己。
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${APP}/Contents/Info.plist"
ok "Info.plist：$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist") / $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP}/Contents/Info.plist")"

# 測試素材不能跟著出貨。make-app.sh 已經過濾，這條是證明它有效的守衛——
# 把那個過濾拿掉，這裡就該紅。
LEAKED="$(/usr/bin/find "${APP}" -name '*Tests*' 2>/dev/null || true)"
[[ -z "${LEAKED}" ]] || die "app 裡有測試素材：${LEAKED}"
ok "沒有測試素材混進去"

if [[ "${MODE}" == dry ]]; then
    say "--dry-run：本機那半段沒問題，停在簽章之前"
    echo "  ${APP}"
    exit 0
fi

die "簽章以後的步驟還沒實作（Task 4）"
