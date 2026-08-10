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
        # 先驗參數個數再 shift。`shift 2` 在只剩一個參數時會失敗，而 set -e
        # 讓整支當場死掉——實測 `release.sh --verify-only` 回 exit=1 且**零輸出**，
        # 底下那句「找不到 …」永遠走不到。用錯旗標的人只會看到一片空白。
        --verify-only) [[ $# -ge 2 ]] || die "--verify-only 後面要接一個 .dmg 路徑。"
                       MODE=verify; VERIFY_TARGET="$2"; shift 2 ;;
        --profile)     [[ $# -ge 2 ]] || die "--profile 後面要接 keychain profile 名稱。先跑一次：xcrun notarytool store-credentials <名稱>"
                       PROFILE="$2"; shift 2 ;;
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
# staging 副本。六條都跑完才回報，不在第一條就 die：只紅一條與六條全紅
# 是完全不同的診斷，而前者常常代表後面幾條根本沒執行。
# spctl 在「assessments disabled」下對任何東西都回 accepted（man spctl：assessment
# APIs "always report success"）。開發機為了測未簽版本關掉 Gatekeeper 是常見的事，
# 而症狀是六條驗收裡的兩條**靜默變成恆真句**——正好是這份驗收最該防的東西。
require_gatekeeper_on() {
    spctl --status 2>&1 | grep -q 'assessments enabled' || die \
        "這台機器的 Gatekeeper 評估是關的（spctl --status），兩條 spctl 驗收會一律回 accepted、等於沒驗。先跑 sudo spctl --master-enable 再重來。"
}

verify_dmg() {
    # `req` 要 local。原本它沒宣告、名字又和後半段存 submission id 的那個變數
    # 撞在一起，兩個都是全域。今天沒事只因為執行順序剛好（驗收跑在最後一次用到
    # submission id 之後）；哪天有人在結尾的成功訊息裡多印一次 id，印出來的會是
    # codesign 的 requirement 字串——而那看起來只是「訊息怪怪的」，不像 bug。
    local dmg="$1" mnt app rc=0 req
    mnt="$(mktemp -d)"
    hdiutil attach "${dmg}" -readonly -nobrowse -mountpoint "${mnt}" >/dev/null 2>&1 \
        || { printf '  \033[31m✗\033[0m 掛不起來：%s\n' "${dmg}"; rmdir "${mnt}"; return 1; }

    app="$(/usr/bin/find "${mnt}" -maxdepth 1 -name '*.app' -print -quit)"
    if [[ -z "${app}" ]]; then
        printf '  \033[31m✗\033[0m dmg 裡沒有 .app\n'; rc=1
    else
        check "codesign --verify（巢狀二進位漏簽）" \
              codesign --verify --deep --strict --verbose=2 "${app}" || rc=1
        # 上面那條驗的是**封緘一致性**，不是信任鏈——一個好好地 ad-hoc 簽過的
        # bundle 照樣回 0。所以要另外斷言「是誰簽的」，否則整份驗收對身分的判定
        # 100% 押在 spctl 上，而 spctl 有被全域關掉的可能（見 require_gatekeeper_on）。
        # `-R` 沒有 --deep，只驗**外層** bundle 的身分。巢狀的資源 bundle
        # （SwiftPM 蓋的是 ad-hoc 章）若漏簽，這條照樣過——而那正是第 5 步
        # 由內而外簽存在的理由。所以連巢狀的一起驗。
        req='=anchor apple generic and certificate leaf[subject.OU] = "JA387Z4D7Q"'
        check "簽章者是我們（Apple 根 ＋ team JA387Z4D7Q）" \
              codesign --verify -R "${req}" "${app}" || rc=1
        while IFS= read -r nested; do
            [[ -n "${nested}" ]] || continue
            check "巢狀 bundle 的簽章者也是我們（$(basename "${nested}")）" \
                  codesign --verify -R "${req}" "${nested}" || rc=1
        done < <(/usr/bin/find "${app}/Contents/Resources" -maxdepth 1 -name '*.bundle' 2>/dev/null)
        check "spctl app（Gatekeeper 對 app 的判定）" \
              spctl -a --no-cache -vvv -t exec "${app}" || rc=1
    fi
    # -t open 是給 dmg 的；-t install 是給 .pkg 的，型別用錯會得到看似通過的
    # 無意義結果。這一條是使用者實際遇到的那一關。
    #
    # --no-cache：第二輪驗的是 bit-identical 的副本，cdhash 相同，不加的話很可能
    # 直接命中第一輪留下的 assessment cache，隔離屬性那一輪等於沒評估。
    check "spctl dmg（使用者實際遇到的那一關）" \
          spctl -a --no-cache -vvv -t open --context context:primary-signature "${dmg}" || rc=1
    check "stapler validate（票沒釘上，使用者離線就被擋）" \
          stapler validate "${dmg}" || rc=1

    hdiutil detach "${mnt}" -quiet >/dev/null 2>&1 \
        || hdiutil detach "${mnt}" -force -quiet >/dev/null 2>&1 || true
    rmdir "${mnt}" 2>/dev/null || true
    return "${rc}"
}

# 第二輪：對加了隔離屬性的**副本**再跑一次同樣六條。
#
# 對副本做是因為原檔加了再拿掉，殘留的 xattr 會讓下一次驗證的前提悄悄變成
# 不同的東西。
#
# **這一輪目前沒有被證明有鑑別力。** 2026-08-11 拿三種產物各實測一次（六條版本；
# 前一次量的是加巢狀 bundle 那條之前的五條版本，數字已作廢），兩輪的結果完全相同：
#   完全沒簽          → 兩輪都 6 紅
#   簽了但沒送審      → 兩輪都 4 綠 2 紅（spctl dmg 回 source=Unnotarized Developer ID、
#                        stapler validate 找不到票）
#   簽＋送審＋釘票    → 兩輪都 6 綠（拿真的發出去的 0.2.0 dmg 量的）
# 也就是說，「使用者從網路下載會被擋」這件事，在這台機器上構造不出一個能讓
# 隔離屬性改變結論的樣本。留著它是因為它便宜、而且是使用者真正會遇到的狀態
# （加上 --no-cache 之後至少強迫了一次不吃快取的重新評估）——但不要宣稱它
# 「守住了」什麼，那會是一個沒有證據的覆蓋主張。找到能區分的樣本再改這段。
verify_quarantined() {
    local dmg="$1" dir tmp rc=0
    dir="$(mktemp -d)"; tmp="${dir}/$(basename "${dmg}")"
    cp "${dmg}" "${tmp}"
    xattr -w com.apple.quarantine "0081;00000000;Safari;$(uuidgen)" "${tmp}"
    # 讀回來確認屬性真的在。少了這一步，`cp` 或 `xattr -w` 失敗時第二輪會在一個
    # **沒有隔離屬性**的副本上跑完六條、全部通過，卻仍掛在「已加隔離屬性」的標題
    # 底下回報——而這一輪正是整個驗收唯一測得到「使用者從網路下載會不會被擋」的
    # 地方（前一輪在本機幾乎必過）。那會讓最重要的那條變成沒有內容的恆真句。
    xattr -p com.apple.quarantine "${tmp}" >/dev/null 2>&1 || {
        printf '  \033[31m✗\033[0m 隔離屬性沒設上去，這一輪測不到「從網路下載」那條路徑\n'
        rm -rf "${dir}"
        return 1
    }
    verify_dmg "${tmp}" || rc=1
    rm -rf "${dir}"
    return "${rc}"
}

if [[ "${MODE}" == verify ]]; then
    [[ -f "${VERIFY_TARGET}" ]] || die "找不到 ${VERIFY_TARGET}"
    require_gatekeeper_on
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
# 版本號會進檔名（`rm -f "${DMG}"` 打得到它）、dmg 卷標、與 Info.plist。
# 沒有 shell injection 的風險（全程雙引號、無 eval），但 `0.2.0/../../x` 這種值
# 會讓那個 rm 打到 build/ 之外，而且產物標籤與 plist 會對不起來。
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
    || die "版本號格式不對：「${VERSION}」。要 x.y.z 或 x.y.z-suffix（例：0.2.0、0.2.0-beta.1）。"
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

# 出廠預設的那套 pack 必須真的在 .app 裡。
#
# **這道守衛存在的理由是它已經發生過一次。** 0.2.0 簽好、notarize 過、十條
# 驗收全綠地發出去了，而裡面只有開發用的色塊——真正的貓住在我的家目錄，
# 不在 dmg 裡。陌生人裝完按下快捷鍵，跑過來的是彩色方塊。整條發布管線
# 沒有任何一個環節會發現，因為它們驗的都是「簽章對不對」。
#
# 預設 pack 的 id 從**它的來源**讀，不寫死在這裡：寫死的話，改了預設而忘了
# 改這裡，守衛會繼續為舊的那套背書。
DEFAULT_PACK="$(sed -nE 's/.*static let factory = "([a-z0-9-]+)".*/\1/p' \
    "${ROOT}/Sources/FindMouseCore/SettingsUseCase.swift")"
# 抓到的必須恰好一筆。零筆代表那行的寫法變了而這個 sed 沒跟上——那時它會
# 安靜地拿空字串去比對，而空字串找得到東西。
[[ "$(printf '%s\n' "${DEFAULT_PACK}" | grep -c .)" -eq 1 ]] \
    || die "從 SettingsUseCase.swift 讀不到唯一的出廠預設 pack id（讀到「${DEFAULT_PACK}」）。那行的寫法可能改了，去更新 release.sh 這段 sed。"

SHIPPED="$(/usr/bin/find "${APP}" -type d -path '*/Packs/*' -name "${DEFAULT_PACK}" 2>/dev/null || true)"
[[ -n "${SHIPPED}" ]] \
    || die "出廠預設的 pack「${DEFAULT_PACK}」不在 .app 裡。使用者裝了會看到開發用的色塊而不是貓。內建 pack 要放在 Sources/FindMouseAdapters/Resources/Packs/ 底下才會被 SwiftPM 打包。"
[[ -f "${SHIPPED}/pack.json" ]] \
    || die "「${DEFAULT_PACK}」的目錄在 .app 裡，但沒有 pack.json——那不是一套能載入的 pack。"
ok "出廠預設的 pack「${DEFAULT_PACK}」有跟著出貨"
# 這條守衛只證明「預設那套在」，**不**證明「預設是對的那一套」——開發用的
# test-blocks 也跟著出貨（`.copy("Resources/Packs")` 複製整個目錄，目前刻意不濾），
# 所以預設若被改回 test-blocks，find 照樣找得到、這裡照樣放行。
# 釘住預設值本身的是 SettingsUseCaseTests 的 factoryDefaultPackIsTheShippedCat()，
# 而它蓋得到 App 的全新安裝路徑，是因為 AppDelegate 的退路讀的是同一個
# `PackDefaults.factory` 而不是自己那份字面值。

if [[ "${MODE}" == dry ]]; then
    say "--dry-run：本機那半段沒問題，停在簽章之前"
    echo "  ${APP}"
    exit 0
fi

say "5／9 簽章"
# 由內而外簽。SwiftPM 給資源 bundle 蓋的是 ad-hoc 章（實測
# `codesign -dv` 回 Signature=adhoc、Identifier=findmouse.FindMouseAdapters.resources），
# 留著它會讓外層的 Developer ID 簽章包著一個非 Developer ID 的巢狀 bundle。
#
# --timestamp 是 notarize 的硬性要求，不是可選的保險；
# --options runtime 是 hardened runtime，同樣是 notarize 的門檻。
while IFS= read -r nested; do
    [[ -n "${nested}" ]] || continue
    codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${nested}"
done < <(/usr/bin/find "${APP}/Contents/Resources" -maxdepth 1 -name '*.bundle' 2>/dev/null)
codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${APP}"
ok "已簽 ${IDENTITY}"

say "6／9 打包 dmg"
# 為什麼是 dmg 不是 zip：**票釘不釘得上**。zip 不能 staple，流程會變成
# 「簽 → 壓 → notarize → staple 裡面的 .app → 重壓」，多一次拆裝、多一個漏掉
# 最後那步的機會。而漏 staple 的症狀很賤——本機測都過，使用者離線時被擋。
DMG="${ROOT}/build/FindMouse-${VERSION}-${SHA}.dmg"
rm -f "${DMG}"
ln -sfn /Applications "${STAGE}/Applications"
hdiutil create -volname "FindMouse ${VERSION}" -srcfolder "${STAGE}" \
    -ov -format UDZO "${DMG}" >/dev/null
codesign --force --timestamp --sign "${IDENTITY}" "${DMG}"
ok "$(basename "${DMG}")"

say "7／9 notarize（要等 Apple，通常數分鐘）"
SUBMIT_LOG="$(mktemp)"
xcrun notarytool submit "${DMG}" --keychain-profile "${PROFILE}" --wait 2>&1 \
    | tee "${SUBMIT_LOG}" || true
SUBMISSION_ID="$(grep -Eo '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' "${SUBMIT_LOG}" | head -1)"
# 不拿 exit code 當判準。notarytool 對「命令自己失敗」是有紀律的（實測：profile
# 不存在回 69、檔案不存在回 64、合約過期回 403 且非零），但「送出成功、而 Apple
# 判 Invalid」會不會也回非零，本專案**還沒有樣本**。看它印出來的 status 在兩種
# 情況下都對，不必賭一個沒驗過的前提。第一次真的發布時順手記下 Invalid 的 exit
# code，那時這段註解才有資格講得更肯定。
if ! grep -qE 'status: *Accepted' "${SUBMIT_LOG}"; then
    printf '\033[31mnotarize 沒過。以下是 Apple 給的原因：\033[0m\n'
    # 失敗最常見的回覆只有一個 request id，要再下一個指令才看得到原因。
    # 「還要再問一次才知道為什麼」不留給未來的自己。
    # `|| true`：在 set -e ＋ pipefail 底下，這條管線失敗（憑證過期、斷網）會讓
    # 整支當場終止，下面的 die 與 submission id 那句話就永遠印不出來——失敗診斷
    # 反而被失敗吃掉。這正是檔頭記過的同一個坑。
    if [[ -n "${SUBMISSION_ID}" ]]; then
        xcrun notarytool log "${SUBMISSION_ID}" --keychain-profile "${PROFILE}" 2>&1 | sed 's/^/  /' || true
    fi
    rm -f "${SUBMIT_LOG}"
    die "notarize 失敗（submission ${SUBMISSION_ID:-未知}）"
fi
rm -f "${SUBMIT_LOG}"
ok "Accepted（submission ${SUBMISSION_ID}）"

say "8／9 staple"
xcrun stapler staple "${DMG}"

say "9／9 驗收"
require_gatekeeper_on
RC=0
verify_dmg "${DMG}" || RC=1
say "再驗一次（已加隔離屬性，模擬從網路下載）"
verify_quarantined "${DMG}" || RC=1
[[ "${RC}" -eq 0 ]] || die "驗收沒過。這份產物不能發出去。"

printf '\n\033[32m✓\033[0m %s\n' "${DMG}"
printf '  版本 %s（build %s）@ %s\n' "${VERSION}" "${BUILD_NUMBER}" "${SHA}"
printf '  最後一關本機測不到：傳給一台沒有這些憑證的機器（或另一個使用者帳號）雙擊一次。\n'
