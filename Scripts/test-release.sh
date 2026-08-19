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
# 跑之前先記下時間戳。build number 是 date 產生的，所以不能比對「相等」
# ——release.sh 執行到那一行時分鐘可能已經跳掉。改成比對「不早於此刻」，
# 這個零填充格式的字串比較等同時間順序。
BEFORE_BUILD="$(date -u +%Y.%m%d.%H%M)"
Scripts/release.sh 9.9.9 --dry-run >/dev/null 2>&1 || bad "--dry-run 自己就失敗了"
PL="${ROOT}/build/release/FindMouse.app/Contents/Info.plist"
if [[ -f "${PL}" ]]; then
    GOT_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PL}")"
    GOT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PL}")"
    [[ "${GOT_SHORT}" == "9.9.9" ]] \
        && ok "CFBundleShortVersionString = 9.9.9" \
        || bad "CFBundleShortVersionString 是 ${GOT_SHORT}"
    [[ "${GOT_BUILD}" =~ ^[0-9]{4}\.[0-9]{4}\.[0-9]{4}$ ]] \
        && ok "CFBundleVersion = ${GOT_BUILD}（三段時間戳，格式正確）" \
        || bad "CFBundleVersion 是 ${GOT_BUILD}，不是 YYYY.MMDD.HHMM 三段各四位數的形狀"
    # 單調遞增是這個欄位存在的理由。用 rev-list --count 時它被歷史重寫打回頭過
    # （195 → 136，比已經發出去的還小），所以這裡要真的驗一次方向。
    [[ ! "${GOT_BUILD}" < "${BEFORE_BUILD}" ]] \
        && ok "CFBundleVersion 不早於發布開始的那一刻（${BEFORE_BUILD}）" \
        || bad "CFBundleVersion ${GOT_BUILD} 比跑之前的 ${BEFORE_BUILD} 還早——時間倒退了？"
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

# --- 2b ------------------------------------------------------------------
step "2b. 開發旗標的型別守衛分得出 bool 與 string（雙向對照組）"
# release.sh 用 `plutil -p | grep -q` 而不是 `PlistBuddy Print` 驗這個鍵，因為後者
# 對 `bool false` 與 `string false` **都印 false**，而 Swift 側 `as? Bool` 對字串回
# nil、落到「當成開發建置」的安全預設——`Add :K string false` 這一個字的手滑就會
# 出貨一份標著「0.4.0 (dev)」的發布版，而每一條驗收都通過。
#
# 只有負向不夠：光證明它會擋，擋不住「這個判別式整個壞掉、對什麼都不匹配」。
# 所以兩個方向都要。
if [[ -f "${PL}" ]]; then
    plutil -p "${PL}" | grep -q '"FMIsDevelopmentBuild" => false' \
        && ok "真實的 dry-run 產物通過型別守衛" \
        || bad "真實產物沒通過型別守衛——release.sh 的那條 die 會擋住每一次發布"
fi
TYPEDIR="$(mktemp -d)"
for form in string bool; do
    T="${TYPEDIR}/${form}.plist"
    /usr/libexec/PlistBuddy -c "Save" "${T}" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Add :FMIsDevelopmentBuild ${form} false" "${T}" >/dev/null
    if plutil -p "${T}" | grep -q '"FMIsDevelopmentBuild" => false'; then
        [[ "${form}" == bool ]] \
            && ok "守衛放行 bool false" \
            || bad "守衛對 string false 放行了——那條驗收沒有鑑別力"
    else
        [[ "${form}" == string ]] \
            && ok "守衛擋下 string false" \
            || bad "守衛連正確的 bool false 都擋下——發布會停在驗收之前"
    fi
done
rm -rf "${TYPEDIR}"

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
# **標籤不再寫死，從 verify_dmg() 自己抽出來。**
#
# 原本這裡是一份手寫清單加一個「數量要等於 6」的守衛。那個守衛設計得對——它就是
# 為了抓「verify_dmg 多一條 check 而這裡沒跟上」——而它也真的抓到了：#12 加了
# stapler validate app 與 syspolicy_check 之後，這支腳本從那時起就一直是紅的，
# 只是沒有人跑它。抓到了卻沒人看，等於沒抓到。
#
# 所以改成從來源抽，讓那一整類漂移不再可能發生，而不是再補一次清單。
# 只抽 verify_dmg() 裡的：釘票之後那條 check 屬於第 7 步，--verify-only 走不到它，
# 拿整份檔案去數必然對不上（實測 9 vs 8）。
#
# 巢狀那條的標籤含 `$(basename …)`，原始碼裡的字串與印出來的不同，
# 所以在 `$(` 處截斷，用前綴比對。
LABELS=()
while IFS= read -r label; do
    LABELS+=("${label}")
done < <(awk '/^verify_dmg\(\)/,/^}/' "${ROOT}/Scripts/release.sh" \
         | grep -oE '^ *check "[^"]*"' | sed 's/^ *check "//; s/"$//; s/\$(.*//')

# 抽到 0 個的話，下面整個迴圈會**無聲通過**——那正是這支腳本要防的東西。
[[ "${#LABELS[@]}" -ge 6 ]] \
    && ok "從 verify_dmg() 抽出 ${#LABELS[@]} 條 check 的標籤" \
    || bad "只從 verify_dmg() 抽到 ${#LABELS[@]} 條 check——抽取式壞了，下面的逐條點名等於沒做"

# 拿一個沒簽過的 .app 包成 dmg。六條驗收會跑兩輪（原檔一輪、加了隔離屬性的
# 副本一輪），十二條應該全部踩紅——實測 ad-hoc 產物：codesign 回 1、spctl 回 1、
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
    # 剛好就是三條，門檻照樣過——**測試全綠，而六條驗收一條都沒執行**。
    # 所以改成逐條點名，每條都要在兩輪裡各出現一次。
    #
    # 巢狀那條是**每個 bundle 各跑一次**，不是一次。它在 release.sh 裡是一行，
    # 但執行次數等於 bundle 數——多一個帶 resources 的 target 就變 4 次，
    # 寫死 2 會紅在「有驗收沒跑到」這個與事實無關的訊息上。
    NESTED_BUNDLES="$(/usr/bin/find "${ROOT}/build/release/FindMouse.app/Contents/Resources" \
        -maxdepth 1 -name '*.bundle' 2>/dev/null | grep -c . || true)"
    # 數到 0 的話下面的期望值也會是 0，而 0 次出現剛好等於 0——這一條會**無聲通過**。
    # 那正是這支腳本存在要防的東西，所以先擋掉。
    [[ "${NESTED_BUNDLES}" -ge 1 ]] \
        || bad "build/release/FindMouse.app 裡找不到任何 *.bundle，巢狀那條驗收根本沒有對象（期望值會變成 0 次而自動通過）"

    # 比對用**完整標籤**而不是關鍵字。原本寫 "stapler validate"，而它同時比中
    # 「stapler validate（票沒釘上…）」與「stapler validate app（拖出來那份…）」，
    # 於是數到 4、期望 2，紅在一個與事實無關的訊息上。
    #
    # **兩段 grep，不是一個 pattern。** 標籤要用固定字串比（`-F`）——它含中文與
    # 全形括號，當成 regex 會出事；而「有沒有報紅」得另外問，因為 `check()` 成功時
    # 印的是同一個標籤（`release.sh:22` 的 `ok()`）。只數標籤出現幾次的話，一條在
    # 兩輪都**通過**的驗收照樣數到 2、正好等於期望值，於是這一段對它說「報紅了」
    # ——負向對照組整段失去鑑別力。63dfec2 把 pattern 改成 `-F` 時就是這樣弄丟了
    # `✗`（2026-08-19 抓到）。
    #
    # 先濾 `✗` 再比標籤，也順帶避開「✗ 與標籤之間夾著 ANSI 重設碼（`\033[0m`）」
    # 這件事——寫成單一 pattern 的話 `✗ <標籤>` 永遠對不上。
    MISSING=""
    for label in "${LABELS[@]}"; do
        want=2
        [[ "${label}" == 巢狀* ]] && want=$((2 * NESTED_BUNDLES))
        n="$(echo "${OUT}" | grep '✗' | grep -cF "${label}")"
        [[ "${n}" -eq "${want}" ]] || MISSING="${MISSING} ${label}(${n}次，期望 ${want})"
    done
    [[ -z "${MISSING}" ]] \
        && ok "${#LABELS[@]} 條驗收各自報紅該有的次數（原檔一輪＋加隔離屬性一輪，巢狀那條 ×${NESTED_BUNDLES} 個 bundle）" \
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

# --- 6 -------------------------------------------------------------------
step "6. app-sandbox 的斷言分得出有簽與沒簽（雙向對照組）"

# **這一段的來歷**：release.sh 的那條斷言第一版寫成 `=> 1`，而 `plutil -p` 對布林
# 印的是 `true`。後果不是「漏掉一個沒沙盒的產物」，是**每一次發版都被擋在第 5 步**，
# 訊息還宣稱一個明明在的鍵不見了。它從寫下來就是壞的，只因為那條路要真的發版
# 才走得到，所以沒有人知道。
#
# 只有正向不夠：一個永遠說 yes 的斷言與沒有斷言等價。所以兩個方向都要。
SANDBOX_PRED='"com.apple.security.app-sandbox" => true'

# 正向：一份真的簽過的 .app。用 make-app.sh 的產物而不是 release.sh 的——
# 後者要 Developer ID 憑證，而這支測試要能在沒有憑證的機器上跑完負向那半。
DEV_APP="${ROOT}/build/FindMouse.app"
if [[ ! -d "${DEV_APP}" ]]; then
    Scripts/make-app.sh >/dev/null 2>&1 || true
fi
if [[ -d "${DEV_APP}" ]]; then
    E="$(mktemp)"
    codesign -d --entitlements - --xml "${DEV_APP}" >"${E}" 2>/dev/null || true
    plutil -p "${E}" 2>/dev/null | grep -q "${SANDBOX_PRED}" \
        && ok "斷言認得真的簽進去的 app-sandbox" \
        || bad "斷言對一份真的沙盒 .app 說不——release.sh 會擋住每一次發布（實際讀到：$(plutil -p "${E}" 2>/dev/null | tr '\n' ' '))"
    rm -f "${E}"
else
    bad "建不出 build/FindMouse.app，這一段的正向對照組沒跑到"
fi

# 負向：一份沒有那個鍵的 entitlements。
NOSANDBOX="$(mktemp)"
/usr/libexec/PlistBuddy -c "Save" "${NOSANDBOX}" >/dev/null 2>&1
/usr/libexec/PlistBuddy -c "Add :com.apple.security.files.user-selected.read-only bool true" \
    "${NOSANDBOX}" >/dev/null
plutil -p "${NOSANDBOX}" | grep -q "${SANDBOX_PRED}" \
    && bad "斷言對一份沒有 app-sandbox 的 entitlements 說 yes——它沒有鑑別力" \
    || ok "斷言擋下沒有 app-sandbox 的 entitlements"
rm -f "${NOSANDBOX}"

# --- 7 -------------------------------------------------------------------
step "7. 圖示的守衛分得出有圖示與沒圖示（雙向對照組）"

# **這一段的來歷**：這個 App 到 v0.5.1 都沒有圖示，而整條發布管線一次都沒有紅過
# ——因為沒有任何一層在問這件事。所以新加的守衛必須自己證明它會紅，否則它只是
# 一句好聽的話。
#
# 正向用 make-app.sh 的產物而不是 release.sh 的：後者要 Developer ID 憑證，
# 而這支測試要能在沒有憑證的機器上跑完（與第 6 段同一個理由）。
ICON_NAME_T="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${ROOT}/Scripts/Info.plist" 2>/dev/null || true)"
if [[ -z "${ICON_NAME_T}" ]]; then
    bad "Scripts/Info.plist 沒有 CFBundleIconFile，這一段沒有對象可驗"
else
    DEV_APP_I="${ROOT}/build/FindMouse.app"
    [[ -d "${DEV_APP_I}" ]] || Scripts/make-app.sh >/dev/null 2>&1 || true
    SHIPPED_I="${DEV_APP_I}/Contents/Resources/${ICON_NAME_T}.icns"

    # 正向：真的產出來的那份要拆得開、10 個尺寸、最大 1024
    if [[ -f "${SHIPPED_I}" ]]; then
        B="$(mktemp -d)"
        if /usr/bin/iconutil -c iconset -o "${B}/ok.iconset" "${SHIPPED_I}" 2>/dev/null; then
            N="$(/usr/bin/find "${B}/ok.iconset" -name '*.png' | grep -c . || true)"
            W="$(/usr/bin/sips -g pixelWidth "${B}/ok.iconset/icon_512x512@2x.png" 2>/dev/null | awk '/pixelWidth/{print $2}' || true)"
            [[ "${N}" -eq 10 && "${W}" == "1024" ]] \
                && ok "守衛認得一份完整的圖示（10 個尺寸、最大 1024）" \
                || bad "守衛對一份真的完整圖示說不（數到 ${N} 個尺寸、最大 ${W}px）——release.sh 會擋住每一次發布"
        else
            bad "make-app.sh 產出的 icns 拆不開"
        fi
        rm -rf "${B}"
    else
        bad "建不出 ${SHIPPED_I}，這一段的正向對照組沒跑到"
    fi

    # 負向：只有一個尺寸的 icns。它是**合法的 icns**，所以「拆得開」那一關過得去
    # ——會擋下它的只有數量那一關。這正是這個對照組要證明的事。
    T="$(mktemp -d)"
    mkdir -p "${T}/thin.iconset"
    if [[ -f "${SHIPPED_I}" ]]; then
        /usr/bin/iconutil -c iconset -o "${T}/full.iconset" "${SHIPPED_I}" 2>/dev/null || true
        cp "${T}/full.iconset/icon_16x16.png" "${T}/thin.iconset/icon_16x16.png" 2>/dev/null || true
    fi
    if /usr/bin/iconutil -c icns -o "${T}/thin.icns" "${T}/thin.iconset" 2>/dev/null; then
        NT="$(/usr/bin/iconutil -c iconset -o "${T}/back.iconset" "${T}/thin.icns" 2>/dev/null \
              && /usr/bin/find "${T}/back.iconset" -name '*.png' | grep -c . || echo 0)"
        [[ "${NT}" -eq 10 ]] \
            && bad "只有一個尺寸的 icns 也被數成 10 個——那一關沒有鑑別力" \
            || ok "守衛擋下只有 ${NT} 個尺寸的 icns"
    else
        bad "造不出只有一個尺寸的 icns，負向對照組沒跑到"
    fi
    rm -rf "${T}"
fi

# --- 8 -------------------------------------------------------------------
step "8. 出貨 pack 的精確相等判準分得出「只有預設那套」與「多了一套」（雙向對照組）"

# **這一段的來歷**：2026-08-19 以前有兩套開發用的色塊跟著出貨，使用者在圖組選單裡
# 看得到，其中一套還顯示「缺少逗貓棒動作」。舊守衛只問「預設那套在不在」，所以它
# 對那個狀態說 yes 說了好幾個版本。色塊搬走之後就沒有自然出現的反例了，而一個
# 永遠說 yes 的斷言與沒有斷言等價。
#
# **為什麼不直接跑 release.sh 來驗。** 原訂做法是在 Sources/.../Packs 底下種一個
# 誘餌再跑 `--dry-run`，實測行不通：誘餌是 untracked，release.sh 第 1／12 步的
# 乾淨工作樹檢查會先把它擋掉，於是紅的是「工作樹不乾淨」而不是精確相等那一條
# ——一個為了錯的理由而紅的測試，證明不了那條守衛有鑑別力。繞過那個檢查更糟：
# 它正是本檔第 1 段在守的東西。
#
# 所以這裡對**組好的 .app 的拋棄式複本**動手，驗的是那個判準的形狀。與第 6 段
# 同一個取捨（那一段也是把斷言的 pattern 重新表達一次，而不是呼叫 release.sh）：
# 權威的那一份在 release.sh 裡，這裡證明的是「這個形狀真的分得出兩種狀態」。
DEFAULT_PACK_T="$(sed -nE 's/.*static let factory = "([a-z0-9-]+)".*/\1/p' \
    "${ROOT}/Sources/FindMouseCore/SettingsUseCase.swift")"
if [[ "$(printf '%s\n' "${DEFAULT_PACK_T}" | grep -c .)" -ne 1 ]]; then
    bad "從 SettingsUseCase.swift 讀不到唯一的出廠預設 pack id（讀到「${DEFAULT_PACK_T}」）"
else
    DEV_APP_P="${ROOT}/build/FindMouse.app"
    [[ -d "${DEV_APP_P}" ]] || Scripts/make-app.sh >/dev/null 2>&1 || true
    if [[ ! -d "${DEV_APP_P}" ]]; then
        bad "建不出 ${DEV_APP_P}，這一段兩個方向都沒跑到"
    else
        P8="$(mktemp -d)"
        # ditto 而不是 cp -R：這台機器的 shell 對 cp 有帶 -r 的 alias，
        # `cp -R` 直接失敗而 && 鏈會整條短路——那會讓下面的比對拿空字串去比，
        # 印出一個看起來正常的「通過」。
        /usr/bin/ditto "${DEV_APP_P}" "${P8}/app" 2>/dev/null || true

        # 與 release.sh 同一個形狀：找唯一的 Resources/Packs，列出它底下的目錄集合。
        packs_of() {
            local app="$1" dir
            dir="$(/usr/bin/find "${app}" -type d -path '*/Resources/Packs' 2>/dev/null || true)"
            [[ "$(printf '%s\n' "${dir}" | grep -c .)" -eq 1 ]] || { echo "__NOT_UNIQUE__"; return; }
            (cd "${dir}" && /usr/bin/find . -mindepth 1 -maxdepth 1 -type d \
                | sed 's|^\./||' | sort | paste -sd' ' -)
        }

        # 正向：乾淨的複本必須恰好等於出廠預設那一套
        CLEAN8="$(packs_of "${P8}/app")"
        [[ "${CLEAN8}" == "${DEFAULT_PACK_T}" ]] \
            && ok "判準對「只有出廠預設那套」說 yes（讀到「${CLEAN8}」）" \
            || bad "判準對乾淨的產物說不（讀到「${CLEAN8}」，期望「${DEFAULT_PACK_T}」）——release.sh 會擋住每一次發布"

        # 負向：在複本裡多種一套。**要有 pack.json**，否則擋下它的可能是別的判準。
        DECOY8="$(/usr/bin/find "${P8}/app" -type d -path '*/Resources/Packs' | head -1)/zz-decoy"
        mkdir -p "${DECOY8}"
        cat >| "${DECOY8}/pack.json" <<'DECOYEOF'
{"schemaVersion":1,"id":"zz-decoy","name":"decoy","logicalHeight":96,
 "anchor":{"x":0.5,"y":0.9},"facing":"right","mirrorForOpposite":true,
 "actions":{"run":{"frames":1,"fps":10,"loop":true}}}
DECOYEOF
        DIRTY8="$(packs_of "${P8}/app")"
        # 正面確認誘餌真的種進去了，否則「不相等」可能只是因為前面某步失敗
        if [[ "${DIRTY8}" != *"zz-decoy"* ]]; then
            bad "誘餌沒種進去（讀到「${DIRTY8}」），負向對照組沒跑到"
        elif [[ "${DIRTY8}" == "${DEFAULT_PACK_T}" ]]; then
            bad "多了一套 pack 而判準照樣說相等——它沒有鑑別力"
        else
            ok "判準擋下多出來的 zz-decoy（讀到「${DIRTY8}」）"
        fi
        rm -rf "${P8}"
    fi
fi

# --- 9 -------------------------------------------------------------------
step "9. 兩支腳本對隱私宣告清單講的是同一個路徑"

# **這一段守的是路徑漂移，而兩個方向的後果不對稱。** make-app.sh 寫它、
# release.sh 檢查它，兩邊各寫死一份字面路徑。
#
#   make-app.sh 那份漂掉  → 它自己的 plutil -lint 照樣過（它 lint 的是它剛寫的
#                          那個新位置），而 release.sh 找不到 → 擋住發版。吵，安全。
#   release.sh 那份漂掉   → 檔案在、只是沒人檢查那個位置 → **靜默出貨**。
#
# 後者沒有任何其他東西會發現：執行、簽章、notarize、Homebrew 那條通路全部不受
# 影響，只有上傳 App Store 時才知道。所以這裡比對兩邊的字面值。
PRIV_PATH="Contents/Resources/PrivacyInfo.xcprivacy"
MK_N="$(grep -c "${PRIV_PATH}" "${ROOT}/Scripts/make-app.sh" || true)"
RL_N="$(grep -c "${PRIV_PATH}" "${ROOT}/Scripts/release.sh" || true)"
if [[ "${MK_N}" -ge 1 && "${RL_N}" -ge 1 ]]; then
    ok "make-app.sh（${MK_N} 處）與 release.sh（${RL_N} 處）用的是同一個路徑"
else
    bad "兩支腳本對隱私宣告清單的路徑對不上（make-app.sh ${MK_N} 處、release.sh ${RL_N} 處）——release.sh 那邊漂掉會靜默出貨"
fi

# 而且組出來的那份 .app 真的有它。空洞地比對兩個字串是不夠的——兩邊可以一起
# 寫錯，那時 grep 依然相等。
DEV_APP_P9="${ROOT}/build/FindMouse.app"
[[ -d "${DEV_APP_P9}" ]] || Scripts/make-app.sh >/dev/null 2>&1 || true
if [[ -f "${DEV_APP_P9}/${PRIV_PATH}" ]]; then
    ok "組出來的 .app 在那個路徑上真的有一份（$(/usr/bin/stat -f%z "${DEV_APP_P9}/${PRIV_PATH}") bytes）"
else
    bad "組出來的 .app 在 ${PRIV_PATH} 沒有東西——兩邊的字面值一致，但一起指錯了地方"
fi

step "結果"
printf '  通過 %d、失敗 %d\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
