// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import FindMouseDomain

/// presenter 的輸出：畫面要畫什麼，全部已換算成視窗座標。
///
/// **全部是 struct**——spec 第 7.4 節的硬性約束：60fps 下跨層載體不配置堆積物件。
public struct OverlayViewModel: Sendable, Equatable {

    public struct Cat: Sendable, Equatable {
        /// 視窗座標（原點在 union 的左下角）
        public let position: CGPoint
        /// 繪製尺寸（pt）
        public let size: CGSize
        /// CALayer 的 anchorPoint（y 由**下**往上，與 manifest 相反）
        public let anchorPoint: CGPoint
        public let action: CatAction
        public let frameIndex: Int
        /// 素材的原始面向與貓當前面向相反，且 pack 允許鏡像
        public let mirrored: Bool
        public let alpha: CGFloat
    }

    public struct Dim: Sendable, Equatable {
        /// 視窗座標的光圈圓心
        public let center: CGPoint
        public let radius: CGFloat
        public let opacity: CGFloat
        /// 內側全透明的比例（spec 第 5.3 節，預設 0.65）
        public let feather: CGFloat
    }

    public let visible: Bool
    public let cat: Cat
    /// nil 表示完全不變暗
    public let dim: Dim?
}
