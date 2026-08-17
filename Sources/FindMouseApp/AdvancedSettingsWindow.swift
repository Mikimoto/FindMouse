// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import FindMouseCore
import SwiftUI

/// 進階設定視窗的內容（spec 第 9 節那張表 UI 欄沒打 ✓ 的那些）。
///
/// **第二個用 SwiftUI 的檔案**，所以檔名要加進
/// `ArchitectureBoundaryTests.swiftUIStaysInTheSettingsWindow` 的白名單。
/// 那條測試用的是精確比對而不是 `contains`：下一個人加檔案時必須回去登記一次，
/// 那個「必須回去登記」正是它存在的理由（別讓 SwiftUI 擴散到 overlay）。
///
/// 這一層與主視窗同樣沒有判斷：分組、順序、哪一列該不該顯示 ↺，
/// 全部來自 `snapshot.advancedSections`（Core，有測試）。
/// 視窗殼與生命週期在 `SettingsWindowController`。
struct AdvancedSettingsRootView: View {

    @ObservedObject var model: SettingsViewModel
    /// 哪個文字欄有焦點。與主視窗各有一份——兩個視窗的焦點本來就互不相干。
    @FocusState private var focused: String?
    @State private var confirmingReset = false

    var body: some View {
        // 「全部還原」放在捲動區**外面**：15 列捲得動，而那顆鈕不該跟著捲走。
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.snapshot.advancedSections, id: \.group) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.group.title).font(.headline)
                            ForEach(section.rows, id: \.key) { row in
                                advancedRow(row)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 寫死高度而不是讓內容決定：`HostedWindow` 建的視窗不可調整大小，
            // 而這些列疊起來比筆電螢幕高（15 列各約 40pt，加上五個組標題）。
            // 不封頂的話視窗會長到超出畫面，而超出的部分完全拿不到。
            .frame(width: 560, height: 560)

            Divider()

            HStack {
                Spacer()
                Button("全部還原") { confirmingReset = true }
            }
            .padding(12)
        }
        .confirmationDialog("要把進階設定全部還原成預設嗎？",
                            isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("全部還原", role: .destructive) { model.resetAdvanced() }
            Button("取消", role: .cancel) {}
        } message: {
            // 不寫數字：這句話裡的「幾項」會在有人往註冊表加設定時靜默變假。
            // 講範圍就永遠為真——`resetAdvanced` 動的正是 `advancedKeys`，
            // 而這個視窗畫的也是同一份（`advancedSectionsCoverExactlyTheAdvancedKeys`）。
            Text("只會動這個視窗裡的設定，主設定視窗那些不受影響。")
        }
        // 焦點離開一個欄位就當作他打完了。理由與主視窗那個一模一樣：
        // 單一個 onChange 掛在最外層，每個欄位各掛一個的話，切換焦點時
        // 兩個欄位會各收到一次。
        .onChange(of: focused) { previous, _ in
            if let previous { model.commitDraft(previous) }
        }
    }

    /// 唯一的列建構器，依 `kind` 分派。加一種 `SettingKind` 時只動這裡。
    @ViewBuilder
    private func advancedRow(_ row: SettingsForm.AdvancedRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(row.presentation.title)
                // key 也印出來：這個視窗的每一項都有對應的 `config set <key>`，
                // 而回報問題與寫腳本要的是 key 不是中文標題。
                Text(row.key)
                    .font(.caption2).monospaced()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(width: 170, alignment: .leading)

            switch row.kind {
            case .number:
                // 滑軌與欄位都吃註冊表的 `SliderSpec`，所以量化位數不可能與 step 矛盾
                // （`AdvancedPresentation.SliderSpec` 只有 `init(step:)`）。
                // `row.presentation.slider` 對 `.number` 必定非 nil，
                // 由 `sliderSpecExistsExactlyForNumberKinds` 釘住。
                if let slider = row.presentation.slider {
                    SettingSlider(model: model, key: row.key, slider: slider)
                }
                // 欄位這一**欄**的寬度寫死，比欄位本身寬。`SettingField` 的第二行
                // 是錯誤訊息，而它比欄位長得多——caption 10pt 下實測
                // 「「abc」不合法，要的是 500–6000」是 154.8pt，欄位是 72pt。
                // 不封住的話，打錯一個值就把這一欄撐開、同一列的滑軌當場變短；
                // 封住之後它改成換行。值域提示不會撐開（最長的「500–6000」50.8pt）。
                SettingField(model: model, key: row.key, width: 72, focused: $focused)
                    .frame(width: 96, alignment: .leading)
                // 單位**無條件畫**，沒有的那兩項（`spotlight.dimOpacity`、
                // `spotlight.feather`）畫一個空字串佔位。只在有單位時畫的話，
                // 這兩列後面的 ↺ 會往左跳，而它們正好夾著有單位的 `spotlight.margin`。
                // 寬度取最長的「pt/s」（實測 18.5pt）再留一點。
                Text(row.presentation.unit ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .leading)
            case .choice:
                SettingChoice(model: model, key: row.key, labels: Self.choiceLabels)
                Spacer()
            case .boolean, .hotkey, .packID:
                // 目前沒有這三種進階 key。真的加了而這裡沒補，這一列會有標題卻沒有
                // 控制項——`sliderSpecExistsExactlyForNumberKinds` 只擋得住「展示資料
                // 與型別互相矛盾」那一半，擋不住「新型別沒人畫」這一半，Core 會全綠。
                // 所以寧可吵一句：說出它是誰、現在改得動它的路是什麼。
                Text("這個型別還沒有控制項，先用 findmouse config set \(row.key) <值>")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }

            resetButton(row)
        }
    }

    /// **一定要走 `reset(key)`，不可以「把值寫成算出來的預設」。**
    ///
    /// Task 2 實測：mycat 的 `arrive.radius` 預設是 96 × 1.0 × 0.8 =
    /// 76.80000000000001，而它的 step 是 5、量化 0 位——滑桿只吐得出整數，
    /// **表達不了自己的預設值**。所以「拖回預設」不存在，唯一的回頭路就是這顆鍵；
    /// 它清掉覆寫、讓衍生預設重新生效，剛好正確。
    ///
    /// 已經是預設的那些列用 `opacity` 藏起來而不是整顆拿掉：拿掉會讓同一列的
    /// 滑軌在「改了值」與「還原」之間變寬變窄。`disabled` 是配套的——
    /// 看不見卻按得到的按鈕比沒有按鈕更糟。
    private func resetButton(_ row: SettingsForm.AdvancedRow) -> some View {
        Button { model.reset(row.key) } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .buttonStyle(.borderless)
        .help("還原成預設")
        .opacity(row.isAtDefault ? 0 : 1)
        .disabled(row.isAtDefault)
    }

    /// `window.level` 的中文標籤。**不標「（預設）」**：預設是哪一個已經由
    /// ↺ 有沒有亮起來表達，寫進標籤就是第二份會漂掉的事實。
    private static let choiceLabels = [
        "overlay": "覆蓋層",
        "screenSaver": "螢幕保護程式層",
        "floating": "浮動層",
    ]
}
