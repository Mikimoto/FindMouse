#!/bin/bash
# 把 SwiftPM 的裸執行檔組成可雙擊的 .app。
# 用法：Scripts/make-app.sh [debug|release]（預設 debug）
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# 一個 product 一次呼叫。`--product A --product B` **不是**「兩個都建」——
# 後面那個把前面的蓋掉，於是 FindMouseApp 從來沒被重建過，`.app` 裡裝的是
# `.build` 裡剛好還留著的那一份。實測（Swift 6.4）：改掉 AppDelegate.swift 之後
# 跑那條命令回 `Build complete! (0.17秒)` 且產物 md5 一個位元都沒變，
# 換成單一 `--product FindMouseApp` 才真的重編。
#
# 這件事讓 e2e 整個失去意義：它跑的是舊 binary，而「跑起來的東西有沒有反映
# 我的原始碼」在外面完全看不出來——`Build complete!` 照印、e2e 照綠。
swift build -c "${CONFIG}" --product FindMouseApp
swift build -c "${CONFIG}" --product findmouse
BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"


# 輸出路徑可被覆寫。release.sh 用它把發布版組到 build/release/，
# 免得蓋掉開發用的那個——e2e 跑的是 build/FindMouse.app。
APP="${APP_DIR:-${ROOT}/build/FindMouse.app}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN_DIR}/FindMouseApp" "${APP}/Contents/MacOS/FindMouse"
# Info.plist 放在 Scripts/ 而不是 Sources/FindMouse/：它是打包輸入不是原始碼，
# 而放在 target 目錄裡會讓 SwiftPM 警告「未處理的檔案」，消掉那個警告只能用
# `exclude:` 或宣告成 resource——前者是 ArchitectureBoundaryTests 明文禁止的
# 關鍵字（它能讓檔案躲過分層掃描），後者語意不對（執行期不讀它）。
cp "${ROOT}/Scripts/Info.plist" "${APP}/Contents/Info.plist"

# SwiftPM 把 target 的 resources 放在執行檔旁的 *.bundle 裡，Bundle.module 靠它找資源。
# 不複製進去的話，載入內建 pack 會在執行期失敗（而不是編譯期）。
#
# **跳過測試 target 的 bundle。** 這個迴圈原本抓 bin 目錄裡每一個 bundle，
# 而跑過 swift test 之後那裡就有一個 FindMouse_FindMouseAdaptersTests.bundle
# （裡面是壞 pack 的 fixture）。實測 debug 的 .app 裡真的裝著它——測試素材
# 跟著出貨，而且沒有任何訊號。
shopt -s nullglob
for bundle in "${BIN_DIR}"/*.bundle; do
    case "$(basename "${bundle}")" in
        *Tests*) continue ;;
    esac
    cp -R "${bundle}" "${APP}/Contents/Resources/"
done
shopt -u nullglob

# 讀不到就硬失敗，不要只是少印一句提示。走到這裡代表上面那個 cp 成功了，
# 所以 Info.plist 檔案是在的——讀不出 key 只剩兩種可能：plist 壞掉、或 key 真的
# 不見了。兩種都表示剛組出來的那個 .app 帶著一份沒有 bundle id 的 Info.plist，
# 它根本啟動不了。這時候安靜地少印一行提示，等於把一個壞掉的 .app 交出去。
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${ROOT}/Scripts/Info.plist")" || BUNDLE_ID=""
[[ -n "${BUNDLE_ID}" ]] || {
    echo "讀不到 ${ROOT}/Scripts/Info.plist 的 CFBundleIdentifier，剛組出來的 .app 會沒有 bundle id、啟動不了。" >&2
    echo "先跑 plutil -lint Scripts/Info.plist 看它是不是壞了；檔案沒壞就是那個 key 不見了，補回去再重組。" >&2
    exit 1
}
# 開發用的色塊 fixture 不出貨。
#
# 它們是 SwiftPM resource bundle 的一部分（Package.swift 的
# `.copy("Resources/Packs")` 複製整個目錄），所以只能在組完之後拿掉。
#
# 兩個理由：陌生人在設定的 pack 選單裡看到「test-blocks（內建）」是荒謬的；
# 而且拿掉之後，release.sh 那道「出廠預設有沒有跟著出貨」的守衛才**真的**
# 擋得住「預設被改回 test-blocks」——留著的話 find 找得到，守衛會放行，
# 而那正是 0.2.0 出貨色塊的原始形態。
#
# debug 版留著：e2e 與單元測試都靠它們。
if [[ "${CONFIG}" == "release" ]]; then
    while IFS= read -r fixture; do
        [[ -n "${fixture}" ]] || continue
        rm -rf "${fixture}"
    done < <(/usr/bin/find "${APP}" -type d -path '*/Packs/*' -name 'test-blocks*')
fi

echo "已組出 ${APP}"
echo "跑：open ${APP}    （看 log：log stream --predicate 'subsystem == \"${BUNDLE_ID}\"'）"
