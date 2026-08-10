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


APP="${ROOT}/build/FindMouse.app"
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
shopt -s nullglob
for bundle in "${BIN_DIR}"/*.bundle; do
    cp -R "${bundle}" "${APP}/Contents/Resources/"
done
shopt -u nullglob

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${ROOT}/Scripts/Info.plist")"
echo "已組出 ${APP}"
echo "跑：open ${APP}    （看 log：log stream --predicate 'subsystem == \"${BUNDLE_ID}\"'）"
