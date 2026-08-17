// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import AppKit
import FindMouseAdapters
import FindMouseCore
import FindMouseDomain
import SwiftUI

/// 設定視窗（spec 第 9 節那張表 UI 欄打 ✓ 的 8 項）。
///
/// 它同時持有**進階設定視窗**（`AdvancedSettingsRootView`，其餘那些 key）。
/// 兩個視窗一個 controller、一個 `model`：這樣「值變了」只要通知一次，
/// 而兩邊可以同時開著看同一份狀態。
///
/// **SwiftUI 只出現在這裡與 `AdvancedSettingsWindow.swift`**（`ArchitectureBoundaryTests`
/// 的 `swiftUIStaysInTheSettingsWindow` 用檔名白名單釘住這兩個）。
/// overlay 維持純 AppKit ＋ CALayer，
/// 因為那裡有 spec 第 7.4 節的每帧預算，而這個視窗一秒鐘畫不到一次。
///
/// 所有判斷都在 `SettingsFormStore`（Core，有測試）。這一層剩下版面配置，
/// 而版面配置本來就只能用眼睛驗——`FindMouseApp` 沒有測試 target。
@MainActor
final class SettingsWindowController {

    private let model: SettingsViewModel
    private let hosted: HostedWindow
    /// 進階設定視窗。與主視窗**共用同一個 `model`**，所以 CLI 改了值之後
    /// `AppDelegate.settingsDidChange()` 那一次 `reload()` 兩邊一起更新，
    /// 不必各自監聽。
    private let advanced: HostedWindow

    init(store: SettingsFormStore, loginItem: LoginItemGateway) {
        let model = SettingsViewModel(store: store, loginItem: loginItem)
        self.model = model
        // 提交範圍是 `advancedKeys` 而不是 `windowKeys`：這個視窗畫的就是那 15 項，
        // 關掉時要接住的也只有它們。理由與下面主視窗那段同一條。
        let advanced = HostedWindow(
            title: "FindMouse 進階設定",
            onWillClose: {
                for key in SettingsForm.advancedKeys { model.commitDraft(key) }
            },
            content: { NSHostingController(rootView: AdvancedSettingsRootView(model: model)) })
        self.advanced = advanced
        // 兩個回呼捕的都是這個**區域變數**而不是 `self`：它們只需要 model，
        // 繞過 self 就沒有「controller → HostedWindow → 回呼 → controller」這個環，
        // 也就不必寫 `[weak self]`——視窗由 `HostedWindow` 獨佔持有、它又由
        // controller 獨佔持有，controller 沒了視窗就跟著沒了，關閉回呼不可能在
        // self 已死時抵達；寫了也只是多一條走不到的靜默分支，
        // 而下面那段註解說的正是「不要靜默地丟掉使用者打的字」。
        //
        // 視窗本身仍然是延遲建立的（`HostedWindow.show()` 才生），這裡只是先把
        // 「要怎麼生」記下來。
        hosted = HostedWindow(
            title: "FindMouse 設定",
            onWillClose: {
                // 打了字但沒按 Enter 就把視窗關掉——把還沒提交的都提交掉。
                //
                // 為什麼要這個而不是只靠失焦（`SettingsRootView` 的 `onChange(of: focused)`）：
                // 關視窗時焦點變化不保證會走到那條路，而「我明明打了，關掉再開卻沒生效」
                // 是完全沒有訊號的資料遺失。這裡重複提交是安全的——`commitDraft` 對
                // 「沒有草稿」與「草稿等於現值」都是 no-op（`leavingAnUntouchedFieldWritesNothing`）。
                //
                // 非法值在這裡照樣被拒絕、照樣不寫入；使用者下次打開會看到那個紅字。
                for key in SettingsForm.windowKeys { model.commitDraft(key) }
            },
            content: {
                NSHostingController(rootView: SettingsRootView(model: model, openAdvanced: {
                    // 與下面 `show()` 同一條理由：打開之前先重讀，
                    // 上次關掉之後 CLI 可能改過任何一個值。
                    model.reload()
                    advanced.show()
                }))
            })
    }

    func show() {
        // 每次打開都重讀：上次關掉之後 CLI 可能改過任何一個值
        model.reload()
        hosted.show()
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
    private let loginItem: LoginItemGateway
    @Published private(set) var snapshot = SettingsFormStore.Snapshot()
    /// 開機啟動的當下狀態。**不是我們存的設定，是系統狀態的快照**——
    /// `refreshLoginItem()` 是唯一寫它的地方。
    @Published private(set) var loginItemState: LoginItem.State = .ineligible
    /// 上一次操作失敗的說明。**不能只是吞掉**：操作沒達成時，狀態多半停在一個
    /// 沒有說明文字的格子（`notRegistered` 與 `notFound` 都沒有），於是勾彈回去、
    /// 畫面一個字都不說——正是這個設計最想避免的「按了沒反應」。
    ///
    /// CLI 走同一條路會拿到 `LOGIN_ITEM_REGISTER_FAILED` 加一句可行動的訊息，
    /// 兩邊不該有落差。這條分支已經有三輪 review 抓到「只修了其中一面」，
    /// 所以這裡列出必須同時成立的三件事，改任何一邊都回來對一次：
    /// **訊息要分方向**、**呼叫沒丟例外但狀態沒動也要說話**、兩者 CLI 與 GUI 都要有。
    @Published private(set) var loginItemError: String?

    init(store: SettingsFormStore, loginItem: LoginItemGateway) {
        self.store = store
        self.loginItem = loginItem
    }

    /// 重讀一次系統狀態。順便清掉上一次的錯誤：重讀代表我們現在顯示的是
    /// 系統實況，舊的失敗訊息留著只會誤導。
    func refreshLoginItem() {
        loginItemState = loginItem.state
        loginItemError = nil
    }

    func setLoginItem(_ on: Bool) {
        // 決策走 Domain 那張表，UI 不自己判斷「現在該註冊還是取消」。
        let outcome = LoginItem.decide(on ? .on : .off, from: loginItem.state)
        var failure: String?
        do {
            switch outcome.effect {
            case .none:       break
            case .register:   try loginItem.register()
            case .unregister: try loginItem.unregister()
            }
        } catch {
            // 訊息要分方向。「重新拖進應用程式資料夾」對關閉失敗是錯的建議，
            // 而且是可證明錯的：走得到 .unregister 表示狀態是 enabled 或
            // requiresApproval，兩者都已經通過合格性閘門，所以 App 必然已經
            // 在那個資料夾裡了。這裡刻意不提「它現在還開著」之類的狀態斷言
            // ——unregister() 丟例外之後狀態停在哪裡沒有量過。
            failure = outcome.effect == .unregister
                ? "關閉開機啟動時失敗了：\(error.localizedDescription)。"
                    + "到「系統設定 → 一般 → 登入項目」可以直接關掉它。"
                : "跟 macOS 註冊時失敗了：\(error.localizedDescription)。"
                    + "把 FindMouse 重新拖進「應用程式」資料夾再試一次。"
        }
        // 立刻重讀。使用者在 requiresApproval 下按勾時，勾會自己彈回去——
        // 那看起來像「按了沒反應」，所以說明那一行必須在**同一次更新**裡出現。
        refreshLoginItem()

        // 沒丟例外，但狀態也沒動。`RequestRouter` 對 CLI 有同一道守衛
        // （loginItemCommand 的 final.effect == .register 那條），GUI 少了它
        // 就會在**最常見的第一次點擊**上沉默：全新安裝是 notFound，
        // presentation 給的是「沒打勾、沒有說明」，於是勾彈回去、一個字都沒有。
        //
        // 與 CLI 那條同樣只罩 register：unregister 之後狀態會回報什麼沒有量過。
        if failure == nil, outcome.effect == .register,
           LoginItem.decide(.on, from: loginItemState).effect == .register {
            failure = "跟 macOS 註冊時沒有回報錯誤，但開機啟動仍然沒有生效。"
                    + "到「系統設定 → 一般 → 登入項目」看一下 FindMouse 的狀態。"
        }

        // refreshLoginItem 會清掉錯誤，所以這一行要在它之後。
        loginItemError = failure
    }

    func openLoginItemSettings() { loginItem.openSystemSettings() }

    func kind(of key: String) -> SettingKind? { store.kind(of: key) }

    func reload() { store.reload(); publish() }
    func draft(_ key: String, _ text: String) { store.draft(key, text); publish() }
    func commitDraft(_ key: String) { store.commitDraft(key); publish() }
    func submit(_ key: String, _ text: String) { store.submit(key, text); publish() }
    func submit(_ key: String, number: Double) { store.submit(key, number: number); publish() }
    func step(_ key: String, by delta: Double) { store.step(key, by: delta); publish() }
    func toggle(_ key: String) { store.toggle(key); publish() }
    // 這兩支與其他 forward 一樣只有「呼叫 store、發佈」：清草稿、清紅字、重讀、
    // 通知 `AppDelegate` 都在 store 裡（`SettingsFormStore.reset`），
    // 在這一層再做一次等於把有測試的判斷抄一份到沒有測試的地方。
    func reset(_ key: String) { store.reset(key); publish() }
    func resetAdvanced() { store.resetAdvanced(); publish() }
    func choosePack(_ id: String) { store.choosePack(id); publish() }
    func packSwapConcluded() { store.packSwapConcluded(); publish() }
    func importPacks(_ urls: [URL]) { store.importPacks(from: urls); publish() }
    func confirmPendingImport() { store.confirmPendingImport(); publish() }
    func cancelPendingImport() { store.cancelPendingImport(); publish() }
    func removePack(_ id: String) { store.removePack(id); publish() }
    // 沒有 publish()：它不改任何狀態，只是叫 Finder 開一個視窗。
    func revealPacks() { store.revealPacks() }

    private func publish() { snapshot = store.snapshot }
}

private struct SettingsRootView: View {

    @ObservedObject var model: SettingsViewModel
    /// 打開進階設定視窗。視窗由 `SettingsWindowController` 持有，
    /// View 只負責發出這個要求——它不該知道視窗是怎麼生出來的。
    let openAdvanced: () -> Void
    /// 哪個文字欄有焦點。`nil` 代表都沒有。
    @FocusState private var focused: String?
    /// 複製版本字串後的短暫回饋。1.5 秒後自己復原。
    @State private var copiedStamp = false
    /// 拖放游標正懸在 pack 區上面。純視覺回饋，不參與任何判斷。
    @State private var packDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            loginItemRow
            Divider()
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
            buildStampRow
        }
        .padding(20)
        .frame(width: 480)
        // 焦點離開一個 hotkey 欄位就當作他打完了。單一個 onChange 掛在最外層，
        // 每個欄位各掛一個的話，切換焦點時兩個欄位會各收到一次。
        .onChange(of: focused) { previous, _ in
            if let previous { model.commitDraft(previous) }
        }
        // 勾選框是系統狀態的鏡子，我們不自己存一份——代價是要在這兩個時機
        // 重讀。不輪詢，但要接住最常見的那條路：使用者跑去系統設定關掉、
        // 再切回來。不加的話畫面會停在一個過期的勾。
        .onAppear { model.refreshLoginItem() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginItem()
        }
    }

    // MARK: - 開機啟動

    /// 判斷全在 `LoginItem.presentation`（Domain，有測試），這裡只有版面配置
    /// ——與檔頭那條「所有判斷都在有測試的那一層」一致。
    private var loginItemRow: some View {
        let p = LoginItem.presentation(for: model.loginItemState)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("開機時啟動").frame(width: 150, alignment: .leading)
                Toggle("", isOn: Binding(get: { p.checked },
                                         set: { model.setLoginItem($0) }))
                    .labelsHidden()
                    .disabled(!p.interactive)
                Spacer()
            }
            if let note = p.note {
                HStack(spacing: 8) {
                    Text(noteText(note))
                        .font(.caption).foregroundStyle(.secondary)
                    if note == .needsApproval {
                        Button("打開登入項目設定") { model.openLoginItemSettings() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.leading, 150)
            }
            // 失敗訊息與 note 並存：note 講的是「這個狀態是什麼」，
            // 這一行講的是「你剛剛那一下為什麼沒成功」。
            if let error = model.loginItemError {
                Text(error)
                    .font(.caption).foregroundStyle(.red)
                    .padding(.leading, 150)
            }
        }
    }

    private func noteText(_ note: LoginItem.Note) -> String {
        switch note {
        case .mustBeInApplications:
            return "要先把 FindMouse 拖進「應用程式」資料夾才能設定"
        case .needsApproval:
            return "macOS 需要你核准才會生效"
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
                Spacer()
                Button("顯示資料夾") { model.revealPacks() }
            }

            // 每套拿得掉的 pack 一列移除鈕。**清單而不是「移除當前選取」**：
            // 下拉選單的選取值是「要用哪一套」，拿它兼差當「要刪哪一套」會讓
            // 使用者為了刪 B 而先切到 B——而切到 B 之後它就變成當前、刪不掉了。
            ForEach(model.snapshot.packs.filter(\.isRemovable), id: \.id) { pack in
                HStack {
                    Text(pack.id).font(.caption)
                    Spacer()
                    Button("移除") { model.removePack(pack.id) }
                        .controlSize(.small)
                }
            }

            ForEach(model.snapshot.packs.filter { !$0.isUsable }, id: \.id) { pack in
                Text("\(pack.id)：\(pack.problems.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let notice = model.snapshot.packNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }

            Text("把 .fmpack 或 pack 資料夾拖到這裡")
                .font(.caption)
                .foregroundStyle(packDropTargeted ? AnyShapeStyle(.primary)
                                                  : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity)
                .padding(8)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(packDropTargeted ? Color.accentColor : Color.secondary,
                                      style: StrokeStyle(lineWidth: 1, dash: [4]))
                }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importPacks(urls)
            // **一律回 true。** `false` 會讓 Finder 播「彈回去」的動畫，而我們
            // 已經收下了它——失敗的原因寫在上面那一行提示，不是用動畫表達。
            return true
        } isTargeted: { packDropTargeted = $0 }
        .alert("要取代嗎？", isPresented: Binding(
            get: { model.snapshot.packConfirmation != nil },
            // 使用者用 Esc 或點外面關掉時走這裡，與按「取消」同一條路。
            set: { if !$0 { model.cancelPendingImport() } }
        ), presenting: model.snapshot.packConfirmation) { _ in
            Button("取代", role: .destructive) { model.confirmPendingImport() }
            Button("取消", role: .cancel) { model.cancelPendingImport() }
        } message: { pending in
            Text(pending.prompt)
        }
    }

    private func label(for pack: PackChoice) -> String {
        var text = pack.id
        if pack.isBuiltIn { text += "（內建）" }
        if !pack.isUsable { text += "　不合格" }
        return text
    }

    // MARK: - 數值

    /// 滑軌 ＋ 欄位。標題欄寬與兩個控制項的組合是**主視窗的**版面；
    /// 進階視窗的列要多畫 key 與 ↺，所以它自己組一次，共用的是
    /// `SettingSlider` 與 `SettingField` 這兩塊控制項本體。
    private func sliderRow(_ key: String, title: String,
                           slider: AdvancedPresentation.SliderSpec,
                           width: CGFloat = 64) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).frame(width: 150, alignment: .leading)
            SettingSlider(model: model, key: key, slider: slider)
            SettingField(model: model, key: key, width: width, focused: $focused)
        }
    }

    private var scaleRow: some View {
        sliderRow("cat.scale", title: "貓的大小",
                  slider: AdvancedPresentation.SliderSpec(step: 0.05))
    }

    /// 用 `onIncrement`／`onDecrement` 而不是 `Stepper(value:in:)`：後者的加減
    /// 以**畫面上那個值**為基準，而畫面可能落後於 CLI 剛改過的值
    /// （見 `SettingsFormStore.step`）。
    private func stepperRow(_ key: String, title: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).frame(width: 150, alignment: .leading)
            SettingField(model: model, key: key, width: 64, focused: $focused)
            Stepper {
                Text(unit)
            } onIncrement: {
                model.step(key, by: 1)
            } onDecrement: {
                model.step(key, by: -1)
            }
            Spacer()
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

    /// 標題欄 ＋ `SettingChoice`。與 `sliderRow` 同一個分工：
    /// 這一層是主視窗的版面，控制項本體共用。
    private func choiceRow(_ key: String, title: String,
                           labels: [String: String]) -> some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            SettingChoice(model: model, key: key, labels: labels)
            Spacer()
        }
    }

    private var triggerRow: some View {
        choiceRow("spotlight.trigger", title: "聚光燈時機", labels: Self.triggerLabels)
    }

    private static let triggerLabels = [
        "onSummonOnly": "只有叫出來的那一次",
        "everyHunt": "每次重新找鼠標都亮",
    ]

    // MARK: - 快捷鍵

    /// 最小版的錄製欄位：文字欄 ＋ 失焦／Enter 時驗證，與兩個數值欄同一塊
    /// （`SettingField`）。
    ///
    /// **不在這裡呼叫 `HotkeySpec(text)` 判一次再決定要不要送**：值域住在
    /// `SettingsUseCase`（spec 第 9 節），UI 再驗一次就是第二份。
    private func hotkeyRow(_ key: String, title: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).frame(width: 150, alignment: .leading)
            SettingField(model: model, key: key, focused: $focused)
        }
    }

    // MARK: - 進階

    /// 其餘那些設定搬去自己的視窗（`AdvancedSettingsRootView`）。
    ///
    /// **不再是原地展開的清單**：那份清單只給得出 `config set …` 的命令字串，
    /// 而它們是調手感用的——調手感要看著貓拉滑桿，而不是抄命令去終端機打。
    /// 換成獨立視窗還有一個原地展開給不了的好處：它可以與主視窗**同時開著**，
    /// 兩邊都不必為了看另一邊而關掉。
    private var advancedSection: some View {
        HStack {
            Button("進階設定…") { openAdvanced() }
            Spacer()
        }
    }

    // MARK: - 建置身分

    /// 右下角一行。**這裡沒有任何判斷**——`FindMouseApp` 沒有測試 target，
    /// 所以「要不要標 (dev)」「缺值怎麼降級」全在 `BuildStamp`（Domain，有測試），
    /// 讀 plist 在 `BuildInfo`（Adapters，有測試）。與 `loginItemRow` 同一個做法。
    ///
    /// `status --json` 的 `appVersion` 走同一支 `BuildInfo.stamp()`，所以 e2e 驗
    /// 那個欄位時，連帶驗到了這一列的內容。
    private var buildStampRow: some View {
        let stamp = BuildInfo.stamp()
        return HStack {
            Spacer()
            Text(copiedStamp ? "已複製 ✓" : stamp)
                .font(.caption)
                .foregroundStyle(.secondary)
                // 沒有這個提示，「可以點」這件事沒有任何線索——而回報問題時
                // 不用手抄 sha 正是這一列存在的主要用途。
                .help("點一下複製")
                .onTapGesture {
                    // 複製的與顯示的是**同一個值**，不各自組一次：回報問題時貼上的
                    // 東西必須與畫面一致，而共用一個值是唯一不需要測試就成立的做法。
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(stamp, forType: .string)
                    copiedStamp = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedStamp = false }
                }
        }
    }
}

// MARK: - 兩個視窗共用的控制項

// 這三塊是**控制項本體**，不含標題欄。兩個視窗的列長得不一樣（主視窗是
// 「標題 ＋ 控制項」，進階視窗多了 key、單位與 ↺），共用整列的話其中一邊
// 一定要靠參數去關掉另一邊的東西；共用到控制項為止就沒有這個問題，
// 而會漂掉的東西（紅框、量化公式、選項來源）剛好都在控制項裡。
//
// 它們是 internal 而不是 private：`AdvancedSettingsWindow.swift` 要用。

/// 文字欄 ＋ 下面一行（有錯誤是紅字，沒有是值域提示）。
///
/// **共用的是欄位不是整列**——滑軌列有滑軌、stepper 列有加減鈕、hotkey 列
/// 兩者都沒有，外層本來就不一樣；而紅框、錯誤字、提示這三件事三種列一模一樣，
/// 各寫一份的話改一邊會忘另外兩邊。
///
/// **不在這裡 parse 也不比範圍**：值域住在 `SettingsUseCase`（spec 第 9 節），
/// UI 再驗一次就是第二份。特別是不用 `TextField(value:format:)`——它會自己
/// 解析並**夾值**，與 spec 第 8 節「超出範圍一律拒絕、不 clamp」相反，
/// 而默默改掉使用者給的值比明確失敗更難查。
///
/// **焦點收 `FocusState<String?>.Binding` 而不是自己開一個 `@FocusState`。**
/// 提交時機掛在根 view 的單一 `onChange(of: focused)` 上（理由寫在那裡），
/// 每個欄位自帶焦點狀態的話那條就看不到欄位之間的切換了。
struct SettingField: View {

    @ObservedObject var model: SettingsViewModel
    let key: String
    let width: CGFloat?
    @FocusState.Binding var focused: String?

    init(model: SettingsViewModel, key: String, width: CGFloat? = nil,
         focused: FocusState<String?>.Binding) {
        self.model = model
        self.key = key
        self.width = width
        self._focused = focused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("", text: Binding(get: { model.snapshot.text(key) },
                                        set: { model.draft(key, $0) }))
                .monospacedDigit()
                .frame(width: width)
                .focused($focused, equals: key)
                .onSubmit { model.commitDraft(key) }
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.red, lineWidth: model.snapshot.errors[key] == nil ? 0 : 2))
            if let problem = model.snapshot.errors[key] {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if let kind = model.kind(of: key) {
                Text(SettingsForm.text(for: kind)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 滑軌本體。範圍取自 `SettingKind`，不在這裡寫第二份（spec 第 9 節：值域只有一份）。
///
/// **收 `SliderSpec` 而不是 `step` 與位數兩個參數**：兩個各自填的旋鈕可以互相
/// 矛盾，而那個矛盾沒有任何測試看得見（症狀寫在 `AdvancedPresentation.SliderSpec`
/// 的註解）。`SliderSpec` 的位數是從 step 推導的，所以傳不進不一致的一組。
/// 註冊表的 `AdvancedPresentation.slider` 解開之後就是這個型別；
/// `cat.scale` 是主視窗的，沒有 presentation，就地從它的 step 生一個。
struct SettingSlider: View {

    @ObservedObject var model: SettingsViewModel
    let key: String
    let slider: AdvancedPresentation.SliderSpec

    var body: some View {
        if case .number(let range)? = model.kind(of: key) {
            let factor = pow(10.0, Double(slider.fractionDigits))
            Slider(value: Binding(
                get: { model.snapshot.number(key) ?? range.lowerBound },
                // 量化到 `fractionDigits` 位：slider 給的是 1.2999999999，
                // 那個字串會原封不動出現在 `config get` 裡。
                // 公式與 `everySliderStopIsAValueTheValidatorAccepts` 同一條，
                // **但那條不是這一支的測試**：它只掃 `advancedKeys`，所以
                // `cat.scale` 走這一支時完全不在它的涵蓋內；而即使是它掃得到的
                // 那些 key，它釘的也是註冊表的 step 與值域相容，
                // 不是這一支真的照這個公式量化。
                set: { model.submit(key, number: ($0 * factor).rounded() / factor) }
            ), in: range, step: slider.step)
        }
    }
}

/// 兩選一以上的選項。選項來自 `SettingKind.choice`——寫死在這裡的話，
/// spec 哪天多一個選項，這裡會靜默少一個。
struct SettingChoice: View {

    @ObservedObject var model: SettingsViewModel
    let key: String
    /// rawValue → 中文標籤。
    let labels: [String: String]

    var body: some View {
        if case .choice(let options)? = model.kind(of: key) {
            Picker("", selection: Binding(
                get: { model.snapshot.text(key) },
                set: { model.submit(key, $0) }
            )) {
                ForEach(options, id: \.self) { option in
                    // 沒有對應中文標籤時退回 rawValue，而不是漏掉這個選項
                    Text(labels[option] ?? option).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}
