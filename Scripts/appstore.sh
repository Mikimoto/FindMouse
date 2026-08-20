#!/bin/bash
# 組出可上傳 Mac App Store 的 .pkg。
#
# 用法：
#   Scripts/appstore.sh <版本>              # 完整：建置 → 簽章 → 打包 → 驗收
#   Scripts/appstore.sh <版本> --dry-run    # 只做不需要外部憑證的那半段
#   Scripts/appstore.sh --check             # 只印前置條件清單，什麼都不做
#
# **這支與 release.sh 是兩條通路，不是兩個模式。** 差別不只是憑證：
#
#              release.sh（Homebrew）        appstore.sh（Mac App Store）
#   app 簽章   Developer ID Application      Apple Distribution
#   描述檔     不需要                        必須內嵌 embedded.provisionprofile
#   entitl.    FindMouse.entitlements        FindMouse.appstore.entitlements（多兩個身分鍵）
#   容器       .dmg                          .pkg（productbuild）
#   審查       notarize + staple             App Store 審查，**不 notarize**
#   驗收       spctl / syspolicy_check       altool --validate-app
#
# 共用的是 make-app.sh：同一份 bundle 內容、同一份 Info.plist、同一份 pack 與圖示。
# 那是刻意的——兩條通路出貨的必須是同一個 App。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

TEAM_ID="JA387Z4D7Q"
IDENTITY_APP="Apple Distribution: DeepThought Co., Ltd. (${TEAM_ID})"
# App Store 的 .pkg 要用 Installer 憑證簽，那是與上面**不同的一張**。
# 名稱有兩種可能的前綴（新申請的是「3rd Party Mac Developer Installer」），
# 所以下面用前綴比對而不是完整字串。
IDENTITY_PKG_PREFIX="3rd Party Mac Developer Installer"
PROFILE="${ROOT}/Scripts/embedded.provisionprofile"
STAGE="${ROOT}/build/appstore"

die()  { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
say()  { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
miss() { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      → %s\n' "$2"; }

MODE=full
VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) MODE=dry; shift ;;
        --check)   MODE=check; shift ;;
        -*)        die "不認得的選項 ${1}。用法見 Scripts/appstore.sh 檔頭。" ;;
        *)         [[ -z "${VERSION}" ]] \
                       || die "版本號給了兩個：「${VERSION}」與「${1}」。只能給一個。"
                   VERSION="$1"; shift ;;
    esac
done
[[ "${MODE}" == check || -n "${VERSION}" ]] \
    || die "要給版本號。例：Scripts/appstore.sh 0.6.0 --dry-run"

# --- 1 前置條件 --------------------------------------------------------------
# **一次列出全部缺的，不要撞到第一個就死。** 這三樣都要去 Apple 的網站辦，
# 而在那裡辦事情的時候你想知道的是「總共要辦幾件」，不是一件一件回來重跑。
say "1 前置條件"
MISSING=0

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "${IDENTITY_APP}"; then
    ok "app 簽章身分：${IDENTITY_APP}"
else
    miss "找不到簽章身分「${IDENTITY_APP}」" \
         "Apple Developer 網站 → Certificates → 建一張 Apple Distribution，下載後雙擊裝進 keychain"
    MISSING=$((MISSING + 1))
fi

# Installer 憑證用前綴比對：名稱裡的公司名與 TeamID 由 Apple 決定，寫死完整字串
# 會在名稱有一點不同時報「找不到」，而那個訊息會把人指去辦一張他已經有的憑證。
PKG_IDENTITY="$(security find-identity -v 2>/dev/null \
    | grep -F "${IDENTITY_PKG_PREFIX}" \
    | head -1 \
    | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-F]+[[:space:]]+"(.*)"$/\1/' || true)"
if [[ -n "${PKG_IDENTITY}" ]]; then
    ok "pkg 簽章身分：${PKG_IDENTITY}"
else
    miss "找不到「${IDENTITY_PKG_PREFIX}」開頭的憑證（.pkg 簽不了）" \
         "Apple Developer 網站 → Certificates → Mac Installer Distribution。它與 Apple Distribution 是不同的兩張"
    MISSING=$((MISSING + 1))
fi

if [[ ! -f "${PROFILE}" ]]; then
    miss "找不到描述檔 ${PROFILE}" \
         "Apple Developer 網站 → Profiles → 建一個 Mac App Store 的 Distribution 描述檔，下載後改名放到那個路徑（它在 .gitignore 裡，不進版控）"
    MISSING=$((MISSING + 1))
else
    # 解碼一次，下面五個欄位都從這一份讀。
    PROF="$(mktemp)"
    if ! security cms -D -i "${PROFILE}" >| "${PROF}" 2>/dev/null || [[ ! -s "${PROF}" ]]; then
        rm -f "${PROF}"
        miss "描述檔解不開（${PROFILE} 不是一份簽章過的 profile）" \
             "重新下載一次。存成文字檔或下載到一半都會長這樣"
        MISSING=$((MISSING + 1))
    else
        # **PlistBuddy 而不是 `plutil -extract`。** 後者把 `.` 當 keypath 分隔符，
        # 讀不到任何 entitlement 鍵（見 CLAUDE.md）；PlistBuddy 用 `:` 分隔，
        # 所以鍵名裡的點不會被誤讀。ExpirationDate 沒有點，那個用 plutil 沒問題
        # 而且它給的是可以直接算的 ISO 8601。
        pv() { /usr/libexec/PlistBuddy -c "Print :$1" "${PROF}" 2>/dev/null; }
        P_NAME="$(pv Name)"
        P_PLAT="$(pv 'Platform:0')"
        P_APPID="$(pv 'Entitlements:com.apple.application-identifier')"
        P_TEAM="$(pv 'Entitlements:com.apple.developer.team-identifier')"
        P_EXP="$(/usr/bin/plutil -extract ExpirationDate raw -o - "${PROF}" 2>/dev/null || true)"
        rm -f "${PROF}"

        # **描述檔不會列沙盒那些 entitlement，那是正常的。**
        # 2026-08-20 實測一份真的 Mac App Store 描述檔，`Entitlements` 只有四個鍵：
        # application-identifier、team-identifier、keychain-access-groups，
        # 以及 Apple 自己塞的 game-center。`com.apple.security.*` 那一族不受限、
        # 不需要描述檔授權——所以**不要**寫成「我們的清單必須是它的子集」，
        # 那會對正確的輸入說不。有經驗內容的不變式只有下面三個。
        OUR_APPID="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' \
            "${ROOT}/Scripts/FindMouse.appstore.entitlements" 2>/dev/null || true)"
        OUR_TEAM="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' \
            "${ROOT}/Scripts/FindMouse.appstore.entitlements" 2>/dev/null || true)"
        PROF_BAD=0
        [[ "${P_PLAT}" == OSX ]] || {
            miss "描述檔的平台是「${P_PLAT}」不是 OSX" \
                 "建的時候平台要選 macOS（fastlane 的旗標是 --platform macos，注意 produce 那支要的是 osx）"
            PROF_BAD=1
        }
        [[ -n "${OUR_APPID}" && "${P_APPID}" == "${OUR_APPID}" ]] || {
            miss "描述檔授權的 application-identifier 是「${P_APPID}」，而 Scripts/FindMouse.appstore.entitlements 寫的是「${OUR_APPID}」" \
                 "兩邊要一字不差。不符的話簽得過、本機跑得動，上傳才被退"
            PROF_BAD=1
        }
        [[ -n "${OUR_TEAM}" && "${P_TEAM}" == "${OUR_TEAM}" ]] || {
            miss "描述檔的 team-identifier 是「${P_TEAM}」，而清單寫的是「${OUR_TEAM}」" \
                 "兩邊要一致"
            PROF_BAD=1
        }

        # 到期。過期的描述檔**簽得過**，只有上傳會被退——所以這裡是唯一會出聲的地方。
        # `plutil -extract raw` 給的是 ISO 8601 UTC（實測 `2027-04-06T17:12:11Z`），
        # 而 `date -j -f` 對爛字串回非零，所以算不出來時走的是「不知道」那條而不是
        # 「沒過期」。
        EXP_EPOCH="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "${P_EXP}" +%s 2>/dev/null || true)"
        if [[ -z "${EXP_EPOCH}" ]]; then
            miss "讀不出描述檔的到期日（拿到「${P_EXP}」）" "重新下載一次"
            PROF_BAD=1
        else
            DAYS_LEFT=$(( (EXP_EPOCH - $(date +%s)) / 86400 ))
            if [[ "${DAYS_LEFT}" -le 0 ]]; then
                miss "描述檔已經過期（${P_EXP}）" "重新產一份"
                PROF_BAD=1
            elif [[ "${DAYS_LEFT}" -lt 30 ]]; then
                printf '  \033[33m!\033[0m 描述檔還有 %d 天到期（%s），發版前先換一份\n' \
                    "${DAYS_LEFT}" "${P_EXP}"
            fi
        fi

        if [[ "${PROF_BAD}" -eq 0 ]]; then
            ok "描述檔：${P_NAME}（OSX、${DAYS_LEFT} 天後到期、兩個身分鍵與清單相符）"
        else
            MISSING=$((MISSING + 1))
        fi
    fi
fi

if [[ "${MODE}" == check ]]; then
    say "結果"
    [[ "${MISSING}" -eq 0 ]] \
        && ok "三樣都齊了，可以跑 Scripts/appstore.sh <版本>" \
        || printf '  還缺 %d 樣，上面每一條的第二行是去哪裡辦\n' "${MISSING}"
    exit 0
fi

if [[ "${MISSING}" -gt 0 ]]; then
    if [[ "${MODE}" == dry ]]; then
        printf '\n  （--dry-run：上面缺的 %d 樣在簽章那一步才用得到，先跳過）\n' "${MISSING}"
    else
        die "還缺 ${MISSING} 樣前置條件，見上面每一條的第二行。只想先驗建置那半段就加 --dry-run。"
    fi
fi

# --- 2 建置 ------------------------------------------------------------------
say "2 建置與組裝"
[[ -z "$(git status --porcelain)" ]] \
    || die "工作樹不乾淨。送出去的東西必須對得上一個 commit——先 commit 或 stash。"
SHA="$(git rev-parse --short HEAD)"

# 與 release.sh 同一個方案，理由也同一個（見那支的註解）：不用 rev-list --count，
# 它在歷史被重寫時會倒退，而 App Store Connect 用這個數字判新舊。
#
# **前導零這件事在這條通路上更要緊**：release.sh 的註解已經標了「App Store Connect
# 收不收前導零本專案還沒驗過」，而這裡就是那個要驗的地方。第一次上傳前先確認。
BUILD_NUMBER="$(date -u +%Y.%m%d.%H%M)"

rm -rf "${STAGE}"
mkdir -p "${STAGE}"
APP_DIR="${STAGE}/FindMouse.app" Scripts/make-app.sh release >/dev/null
APP="${STAGE}/FindMouse.app"
[[ -x "${APP}/Contents/MacOS/FindMouse" ]] || die "組不出 .app"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${APP}/Contents/Info.plist"
for key in FMSourceVersion FMSourceCommit FMIsDevelopmentBuild; do
    /usr/libexec/PlistBuddy -c "Delete :${key}" "${APP}/Contents/Info.plist" 2>/dev/null || true
done
/usr/libexec/PlistBuddy -c "Add :FMSourceVersion string ${VERSION}" "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :FMSourceCommit string ${SHA}" "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :FMIsDevelopmentBuild bool false' "${APP}/Contents/Info.plist"
# 型別要驗，不只驗值。`Print` 對 `bool false` 與 `string false` 都印 false，
# 而 Swift 那側 `as? Bool` 對字串回 nil、落到 `?? true` 的安全預設。
plutil -p "${APP}/Contents/Info.plist" | grep -q '"FMIsDevelopmentBuild" => false' \
    || die "FMIsDevelopmentBuild 不是 bool false。上架版會被標成 (dev)。"
ok "${VERSION}（build ${BUILD_NUMBER}）@ ${SHA}"

# App Store 那條通路自己要檢的兩個鍵。make-app.sh 與 release.sh 各自驗過圖示、
# pack、隱私清單，但**類別**只有這裡用得到——Homebrew 那條不看它。
CATEGORY="$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "${APP}/Contents/Info.plist")" || CATEGORY=""
[[ -n "${CATEGORY}" ]] || die "剛組出來那份 Info.plist 讀不到 LSApplicationCategoryType，App Store Connect 會退件。"
ok "主類別：${CATEGORY}"
[[ -f "${APP}/Contents/Resources/PrivacyInfo.xcprivacy" ]] \
    || die "隱私宣告清單不在組出來的 .app 裡。make-app.sh 應該在簽章前放進去。"
ok "隱私宣告清單在"

if [[ "${MODE}" == dry ]]; then
    say "--dry-run：不需要外部憑證的那半段沒問題，停在內嵌描述檔之前"
    echo "  ${APP}"
    exit 0
fi

# --- 3 內嵌描述檔 ------------------------------------------------------------
# **要在簽章之前。** 描述檔放在 Contents/embedded.provisionprofile，而簽章封印
# 整個 Contents——之後才放進去的話 codesign --verify 會報 resource added，
# 與圖示那條完全同一個坑（那個訊息一個字都不會提到描述檔）。
say "3 內嵌描述檔"
cp "${PROFILE}" "${APP}/Contents/embedded.provisionprofile"
ok "已放進 Contents/embedded.provisionprofile"

# --- 4 簽章 ------------------------------------------------------------------
# 由內而外。SwiftPM 給資源 bundle 蓋的是 ad-hoc 章，留著它會讓外層的
# Apple Distribution 簽章包著一個非 Apple Distribution 的巢狀 bundle。
# entitlements 只給主 bundle：沙盒是 process 層級的屬性，資源 bundle 不會被執行。
say "4 簽章"
while IFS= read -r nested; do
    [[ -n "${nested}" ]] || continue
    codesign --force --options runtime --timestamp --sign "${IDENTITY_APP}" "${nested}"
done < <(/usr/bin/find "${APP}/Contents/Resources" -maxdepth 1 -name '*.bundle' 2>/dev/null)
codesign --force --options runtime --timestamp \
    --entitlements "${ROOT}/Scripts/FindMouse.appstore.entitlements" \
    --sign "${IDENTITY_APP}" "${APP}"
ok "已簽 ${IDENTITY_APP}"

# --- 5 驗簽出來的結果 --------------------------------------------------------
# **驗簽出來的東西，不是驗那個檔案。** 那份 entitlements 檔案由
# InfoPlistTests 釘住，這裡要答的是另一個問題：實際封進簽章的是什麼。
# 兩者會不一樣——`--entitlements` 哪天被拿掉，檔案照樣完好而簽章裡什麼都沒有。
say "5 驗簽章"
# **用 PlistBuddy 不用 `plutil -extract`。** entitlement 的鍵名全是點分隔的，
# 而 `plutil -extract` 把點當 keypath 分隔符——`plutil -extract
# com.apple.security.app-sandbox` 對一份**確實含有那個鍵**的 plist 回
# 「No value at that key path」並 exit 1（2026-08-20 實測）。兩個後果，第二個更糟：
# 四個鍵的迴圈會在第一個就假性 die 擋掉每一次上架建置；而 get-task-allow 那條
# 變成**恆真句**——它會在那個鍵真的存在時照樣通過，也就是完全不守。
# PlistBuddy 對同一份輸入回 `true` / exit 0，不存在的鍵 exit 1。
SIGNED_ENT="$(mktemp)"
codesign -d --entitlements - --xml "${APP}" 2>/dev/null >| "${SIGNED_ENT}" || true
for key in com.apple.security.app-sandbox \
           com.apple.security.files.user-selected.read-only \
           com.apple.application-identifier \
           com.apple.developer.team-identifier; do
    /usr/libexec/PlistBuddy -c "Print :${key}" "${SIGNED_ENT}" >/dev/null 2>&1 \
        || { rm -f "${SIGNED_ENT}"; die "簽出來的 entitlements 沒有 ${key}。上傳會被退，而 App 在本機執行完全正常。"; }
done
# get-task-allow 讓別的 process 附加 debugger。**帶著它上傳一定被退**，
# 而本機執行看不出任何差別。這裡驗的是簽章而不是檔案，所以它也涵蓋
# 「從別處被合成進來」那種情況。
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "${SIGNED_ENT}" >/dev/null 2>&1; then
    rm -f "${SIGNED_ENT}"
    die "簽出來的 entitlements 含 get-task-allow，帶著它上傳一定被退。"
fi
rm -f "${SIGNED_ENT}"
ok "四個鍵都在，沒有 get-task-allow"

codesign --verify --deep --strict --verbose=2 "${APP}" 2>/dev/null \
    || die "codesign --verify 不過。"
ok "簽章結構有效"

# --- 6 打包 ------------------------------------------------------------------
# **App Store 那條不 notarize。** notarize 是 Gatekeeper 那條路的門檻，
# App Store 走的是審查。對 .pkg 送 notarytool 只是浪費時間。
say "6 打包"
# productbuild 會印四行 `write: Permission denied`，而它照樣成功。那幾行沒有指出
# 想寫哪裡，本專案沒有追出來——判斷產物好壞看下面那兩條斷言（檔案在、
# pkgutil --check-signature 過），不要看那幾行。
PKG="${STAGE}/FindMouse-${VERSION}.pkg"
productbuild --component "${APP}" /Applications --sign "${PKG_IDENTITY}" "${PKG}"
[[ -f "${PKG}" ]] || die "productbuild 回 0 但 ${PKG} 不在。"
pkgutil --check-signature "${PKG}" >/dev/null || die "打出來的 .pkg 簽章驗不過。"
ok "$(basename "${PKG}")（$(/usr/bin/stat -f%z "${PKG}") bytes）"

# --- 7 下一步 ----------------------------------------------------------------
# **不自己上傳。** 上傳需要 App Store Connect 的 API 金鑰，而那是一個「送出去就
# 收不回來」的動作——這支腳本到產物為止，最後一步留給人按。
say "7 下一步"
cat <<EOF
  1. App Store Connect 要先有這個 app 的紀錄（bundle id ${TEAM_ID} 底下的
     tw.com.deepthought.findmouse），還沒有就先去建。

  2. 驗一次再上傳（不會真的送出）：
       xcrun altool --validate-app -f "${PKG}" -t macos \\
         --apiKey <KeyID> --apiIssuer <IssuerID>

  3. 上傳：
       xcrun altool --upload-app -f "${PKG}" -t macos \\
         --apiKey <KeyID> --apiIssuer <IssuerID>

     金鑰放 ~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8，
     altool 會自己去那裡找，不必給路徑。

  4. build ${BUILD_NUMBER} 有前導零（月／日／時分那幾段）。**本專案還沒驗過
     App Store Connect 收不收**——第一次上傳時特別看一下這個數字有沒有被改寫或退回。
EOF
