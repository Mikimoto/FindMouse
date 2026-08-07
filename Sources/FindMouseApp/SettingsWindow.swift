import AppKit
import FindMouseCore
import SwiftUI

/// 設定視窗（spec 第 9 節那張表 UI 欄打 ✓ 的 8 項）。
///
/// **這是全專案唯一用 SwiftUI 的地方**（`ArchitectureBoundaryTests`
/// 的 `swiftUIStaysInTheSettingsWindow` 釘住）。overlay 維持純 AppKit ＋ CALayer，
/// 因為那裡有 spec 第 7.4 節的每帧預算，而這個視窗一秒鐘畫不到一次。
///
/// 所有判斷都在 `SettingsFormStore`（Core，有測試）。這一層剩下版面配置，
/// 而版面配置本來就只能用眼睛驗——`FindMouseApp` 沒有測試 target。
@MainActor
final class SettingsWindowController {

    private let model: SettingsViewModel
    private var window: NSWindow?

    init(store: SettingsFormStore) {
        model = SettingsViewModel(store: store)
    }

    func show() {
        // 每次打開都重讀：上次關掉之後 CLI 可能改過任何一個值
        model.reload()
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsRootView(model: model))
            let created = NSWindow(contentViewController: hosting)
            created.title = "FindMouse 設定"
            created.styleMask = [.titled, .closable]
            // 關掉再打開要是同一個視窗。少了這行，關閉會釋放它而下次
            // `makeKeyAndOrderFront` 打在已釋放的物件上。
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        // `.accessory` 政策的 app 不會自動變成前景，不叫的話視窗收不到鍵盤輸入
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 值被別人改了（CLI 的 `config set`／`config reset`）。
    func reload() { model.reload() }

    /// 換 pack 的請求有結果了（成功或失敗）。
    func packSwapConcluded() { model.packSwapConcluded() }
}

/// `SettingsFormStore`（純邏輯）與 SwiftUI 之間的轉接。
///
/// 它自己不做任何判斷：每個方法都是「呼叫 store、把新的 snapshot 發佈出去」。
/// 判斷留在 store 裡才測得到。
@MainActor
final class SettingsViewModel: ObservableObject {

    private let store: SettingsFormStore
    @Published private(set) var snapshot = SettingsFormStore.Snapshot()

    init(store: SettingsFormStore) {
        self.store = store
    }

    func kind(of key: String) -> SettingKind? { store.kind(of: key) }

    func reload() { store.reload(); publish() }
    func draft(_ key: String, _ text: String) { store.draft(key, text); publish() }
    func commitDraft(_ key: String) { store.commitDraft(key); publish() }
    func submit(_ key: String, _ text: String) { store.submit(key, text); publish() }
    func submit(_ key: String, number: Double) { store.submit(key, number: number); publish() }
    func step(_ key: String, by delta: Double) { store.step(key, by: delta); publish() }
    func toggle(_ key: String) { store.toggle(key); publish() }
    func choosePack(_ id: String) { store.choosePack(id); publish() }
    func packSwapConcluded() { store.packSwapConcluded(); publish() }

    private func publish() { snapshot = store.snapshot }
}

private struct SettingsRootView: View {

    @ObservedObject var model: SettingsViewModel
    @State private var showAdvanced = false
    /// 哪個文字欄有焦點。`nil` 代表都沒有。
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            packSection
            Divider()
            scaleRow
            stepperRow("rest.duration", title: "休息多久後打瞌睡", unit: "秒")
            stepperRow("sleep.duration", title: "打瞌睡多久後離開", unit: "秒")
            Divider()
            toggleRow("spotlight.enabled", title: "顯示聚光燈")
            triggerRow
            Divider()
            hotkeyRow("hotkey.summon", title: "叫貓咪")
            hotkeyRow("hotkey.teaser", title: "逗貓棒")
            Divider()
            advancedSection
        }
        .padding(20)
        .frame(width: 480)
        // 焦點離開一個 hotkey 欄位就當作他打完了。單一個 onChange 掛在最外層，
        // 每個欄位各掛一個的話，切換焦點時兩個欄位會各收到一次。
        .onChange(of: focused) { previous, _ in
            if let previous { model.commitDraft(previous) }
        }
    }

    // MARK: - pack

    private var packSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("圖組").frame(width: 150, alignment: .leading)
                Menu {
                    ForEach(model.snapshot.packs, id: \.id) { pack in
                        Button { model.choosePack(pack.id) } label: {
                            // 顯示 id 而不是 manifest 的 name：兩套內建 pack 的
                            // name 都是「測試方塊」，顯示 name 會出現兩個
                            // 一模一樣的選項（M4 已裁決）。
                            Text(label(for: pack))
                        }
                        // 不合格的 pack 照列但不可選（spec 第 10 節）
                        .disabled(!pack.isUsable)
                    }
                } label: {
                    Text(model.snapshot.selectedPackID)
                }
            }
            ForEach(model.snapshot.packs.filter { !$0.isUsable }, id: \.id) { pack in
                Text("\(pack.id)：\(pack.problems.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func label(for pack: PackChoice) -> String {
        var text = pack.id
        if pack.isBuiltIn { text += "（內建）" }
        if !pack.isUsable { text += "　不合格" }
        return text
    }

    // MARK: - 數值

    /// 範圍取自 `SettingKind`，不在這裡寫第二份 0.5...2.0（spec 第 9 節：值域只有一份）。
    private var scaleRow: some View {
        HStack {
            Text("貓的大小").frame(width: 150, alignment: .leading)
            if case .number(let range)? = model.kind(of: "cat.scale") {
                Slider(value: Binding(
                    get: { model.snapshot.number("cat.scale") ?? range.lowerBound },
                    // 量化到兩位小數：slider 給的是 1.2999999999，那個字串
                    // 會原封不動出現在 `config get` 裡
                    set: { model.submit("cat.scale", number: ($0 * 100).rounded() / 100) }
                ), in: range, step: 0.05)
            }
            Text(model.snapshot.text("cat.scale"))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// 用 `onIncrement`／`onDecrement` 而不是 `Stepper(value:in:)`：後者的加減
    /// 以**畫面上那個值**為基準，而畫面可能落後於 CLI 剛改過的值
    /// （見 `SettingsFormStore.step`）。
    private func stepperRow(_ key: String, title: String, unit: String) -> some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            Stepper {
                Text("\(model.snapshot.text(key)) \(unit)").monospacedDigit()
            } onIncrement: {
                model.step(key, by: 1)
            } onDecrement: {
                model.step(key, by: -1)
            }
            Spacer()
            rangeHint(key)
        }
    }

    private func toggleRow(_ key: String, title: String) -> some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            Toggle("", isOn: Binding(get: { model.snapshot.flag(key) },
                                     set: { _ in model.toggle(key) }))
                .labelsHidden()
            Spacer()
        }
    }

    /// 兩選一。選項來自 `SettingKind.choice`——寫死兩個 case 的話，
    /// spec 哪天多一個觸發時機，這裡會靜默少一個選項。
    private var triggerRow: some View {
        HStack {
            Text("聚光燈時機").frame(width: 150, alignment: .leading)
            if case .choice(let options)? = model.kind(of: "spotlight.trigger") {
                Picker("", selection: Binding(
                    get: { model.snapshot.text("spotlight.trigger") },
                    set: { model.submit("spotlight.trigger", $0) }
                )) {
                    ForEach(options, id: \.self) { option in
                        // 沒有對應中文標籤時退回 rawValue，而不是漏掉這個選項
                        Text(Self.triggerLabels[option] ?? option).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Spacer()
        }
    }

    private static let triggerLabels = [
        "onSummonOnly": "只有叫出來的那一次",
        "everyHunt": "每次重新找鼠標都亮",
    ]

    // MARK: - 快捷鍵

    /// 最小版的錄製欄位：文字欄 ＋ 失焦／Enter 時驗證。
    ///
    /// **不在這裡呼叫 `HotkeySpec(text)` 判一次再決定要不要送**：值域住在
    /// `SettingsUseCase`（spec 第 9 節），UI 再驗一次就是第二份。
    /// 這裡只把它丟出的錯誤攤成紅框加一行紅字。
    private func hotkeyRow(_ key: String, title: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: Binding(get: { model.snapshot.text(key) },
                                            set: { model.draft(key, $0) }))
                    .focused($focused, equals: key)
                    .onSubmit { model.commitDraft(key) }
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(.red, lineWidth: model.snapshot.errors[key] == nil ? 0 : 2))
                if let problem = model.snapshot.errors[key] {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else {
                    rangeHint(key)
                }
            }
        }
    }

    @ViewBuilder
    private func rangeHint(_ key: String) -> some View {
        if let kind = model.kind(of: key) {
            Text(SettingsForm.text(for: kind)).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 進階

    /// 其餘 15 項只給命令，不給控制項（spec 第 9 節的理由：那些是上線後調手感用的，
    /// 而調手感用 CLI 比 UI 好——一行連改多個值再看效果）。
    ///
    /// 清單是從註冊表推導的，不是抄的：有人加了新設定就會自動出現在這裡。
    private var advancedSection: some View {
        DisclosureGroup("進階設定…", isExpanded: $showAdvanced) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.snapshot.advanced, id: \.key) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.command)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Text("範圍 \(entry.range)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 6)
            }
            .frame(height: 200)
        }
    }
}
