// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import FindMouseDomain

/// `CatFrameState`（全域座標）→ `OverlayViewModel`（視窗座標）。
///
/// 這裡集中三個容易靜默算錯的轉換。三個都有一個共同性質：**在單螢幕、
/// 朝右站著的貓身上完全看不出來**，所以它們必須靠測試而不是靠眼睛。
///
/// 1. **全域 → 視窗**：overlay 視窗的 frame 是所有螢幕的聯集，而聯集的原點
///    在副螢幕位於主螢幕左方或下方時是**負的**。直接把全域座標當視窗座標，
///    單螢幕看起來完全正常，接上第二個螢幕才壞。
/// 2. **anchor 的 y 軸方向**：manifest 的 `anchor.y` 由上往下（spec 第 6.2 節），
///    CALayer 的 `anchorPoint.y` 由下往上。漏掉這個翻轉，貓會陷進桌面或浮空。
/// 3. **鏡像**：素材只畫一側（manifest 的 `facing`），朝反向時水平鏡像產生，
///    但 `mirrorForOpposite == false` 的 pack（單邊花色、缺耳）不准鏡像。
public struct OverlayPresenter: Sendable {

    private let logicalHeight: CGFloat
    private let catScale: CGFloat
    private let anchor: CGPoint
    private let spriteFacing: Facing
    private let mirrorForOpposite: Bool
    /// 素材的寬高比（寬 ÷ 高）
    private let spriteAspect: CGFloat
    private let feather: CGFloat

    public init(logicalHeight: CGFloat, catScale: CGFloat, anchor: CGPoint,
                spriteFacing: Facing, mirrorForOpposite: Bool,
                spriteAspect: CGFloat, feather: CGFloat) {
        self.logicalHeight = logicalHeight
        self.catScale = catScale
        self.anchor = anchor
        self.spriteFacing = spriteFacing
        self.mirrorForOpposite = mirrorForOpposite
        self.spriteAspect = spriteAspect
        self.feather = feather
    }

    /// 「一套 pack ＋ 一份設定」就決定了整個 presenter。
    ///
    /// 為什麼要這個便利建構子：`cat.scale` 是**建構時吃進去**的，而
    /// `CatSessionUseCase` 每帧重讀設定。改了 `cat.scale` 卻不重建 presenter 的話，
    /// 貓的移動幾何立刻變、畫出來的大小沒變，兩者對不上。所以設定一改就要重建，
    /// 而重建的地方（App 啟動、換 pack、設定變更）有三處——把「哪些欄位來自 pack、
    /// 哪些來自設定」寫成一份，漏掉其中一個欄位才會是編譯錯誤而不是視覺 bug。
    ///
    /// presenter 是無狀態的純轉換，所以重建很便宜，也不會打斷正在演的動畫。
    public init(sprites: SpriteRepository, config: BehaviorConfig) {
        self.init(logicalHeight: sprites.logicalHeight,
                  catScale: config.catScale,
                  anchor: sprites.anchor,
                  spriteFacing: sprites.spriteFacing,
                  mirrorForOpposite: sprites.mirrorForOpposite,
                  spriteAspect: sprites.spriteAspect,
                  feather: config.spotlightFeather)
    }

    public func viewModel(for state: CatFrameState, in windowFrame: CGRect) -> OverlayViewModel {
        let height = logicalHeight * catScale
        let cat = OverlayViewModel.Cat(
            position: toWindow(state.body.position, in: windowFrame),
            size: CGSize(width: height * spriteAspect, height: height),
            // manifest 的 anchor.y 由上往下，CALayer 的 anchorPoint.y 由下往上
            anchorPoint: CGPoint(x: anchor.x, y: 1 - anchor.y),
            action: state.action,
            frameIndex: state.frameIndex,
            // 面向的判定用 CatBody.facing（Domain 既有、M1 的
            // bodyFacingFollowsHeading 釘著），不在這裡重寫一份 cos(heading) < 0——
            // 同一條規則放兩個地方遲早會漂移，而漂移的那一刻沒有訊號。
            mirrored: mirrorForOpposite && state.body.facing != spriteFacing,
            alpha: state.alpha)

        let dim: OverlayViewModel.Dim? = state.spotlight.isActive
            ? OverlayViewModel.Dim(center: toWindow(state.spotlight.center, in: windowFrame),
                                   radius: state.spotlight.radius,
                                   opacity: state.spotlight.opacity,
                                   feather: feather)
            : nil

        return OverlayViewModel(visible: state.isVisible, cat: cat, dim: dim)
    }

    /// 全域座標 -> **這一個視窗**的座標。
    ///
    /// 參數是視窗自己的 frame，不是所有螢幕的聯集：實測發現單一視窗只會在它
    /// 「所屬」的那片螢幕上渲染，所以每片螢幕各有一個視窗（見 AppDelegate）。
    /// 傳聯集進來正好是那個 bug 的形狀，所以參數名不叫 union。
    private func toWindow(_ point: CGPoint, in windowFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - windowFrame.minX, y: point.y - windowFrame.minY)
    }
}
