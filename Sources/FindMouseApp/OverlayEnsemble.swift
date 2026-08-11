// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import AppKit
import FindMouseAdapters
import FindMouseDomain

/// **每片螢幕一個 overlay 視窗。**
///
/// spec 第 7.4 節寫的是「單一 borderless 視窗，frame 為所有螢幕的聯集矩形」，
/// 實測那個設計在這台三螢幕的機器上不成立：視窗的 frame 確實涵蓋聯集
/// （AppKit 回報 `touching = 3`，window server 也回報同樣的 bounds、`onscreen = 1`），
/// 但**只有它所屬的那一片螢幕會真的被畫出來**。用「每片螢幕塗不同顏色」的探針
/// 確認過：三塊色塊只有一塊出現。`screensHaveSeparateSpaces` 是 false，
/// 所以不是「顯示器使用獨立空間」那個設定造成的。
///
/// 所以改成每片螢幕各一個視窗，各自把同一份 `CatFrameState` 換算到自己的
/// 座標系。貓在別片螢幕上時，它的圖層會落在本視窗的範圍外而被自然裁掉；
/// 暗幕則因為光圈也在範圍外，`DimMask.layout` 會回「整片都暗」——
/// 那正是 `holeCompletelyOutsideMakesEverythingDim` 釘住的行為。
@MainActor
final class OverlayEnsemble {

    private struct Pane {
        let window: OverlayWindow
        let view: OverlayView
    }

    private var panes: [Pane] = []
    private var sprites: SpriteRepository
    private let feather: CGFloat
    private let level: CGWindowLevelKey

    init(sprites: SpriteRepository, feather: CGFloat, level: CGWindowLevelKey) {
        self.sprites = sprites
        self.feather = feather
        self.level = level
    }

    /// display link 需要一個 view 來取得畫面刷新節奏。任何一個都可以——
    /// 它只是時鐘，不決定畫什麼。
    var anyView: NSView? { panes.first?.view }

    var screenCount: Int { panes.count }

    /// 依當前螢幕組態重建所有視窗。螢幕插拔時整批重來，
    /// 因為連「有幾片」都可能變。
    func rebuild(screens: [CGRect]) {
        for pane in panes {
            pane.window.orderOut(nil)
        }
        panes = screens.map { frame in
            let window = OverlayWindow(union: frame, level: level)
            let view = OverlayView(sprites: sprites, feather: feather)
            view.frame = CGRect(origin: .zero, size: frame.size)
            window.contentView = view
            window.orderFrontRegardless()
            return Pane(window: window, view: view)
        }
    }

    /// 換 pack 的圖，但**不重建視窗**：重建會讓每一片 overlay 閃一下，
    /// 而換 pack 已經有「貓走掉再跑回來」的動畫在演了。
    ///
    /// 自己的 `sprites` 也要換，不是只更新現有的 view——`rebuild(screens:)`
    /// 用它建新 view，漏了的話換 pack 之後插拔一次螢幕就悄悄退回舊圖，
    /// 而那時離換 pack 已經很遠了，沒有人會把兩件事連起來。
    func replace(sprites: SpriteRepository) {
        self.sprites = sprites
        for pane in panes { pane.view.replace(sprites: sprites) }
    }

    /// 把同一份狀態畫到每一片螢幕上。
    func apply(_ state: CatFrameState, presenter: OverlayPresenter) {
        for pane in panes {
            pane.view.apply(presenter.viewModel(for: state, in: pane.window.frame))
        }
    }

    func hideAll() {
        for pane in panes { pane.window.orderOut(nil) }
    }
}
