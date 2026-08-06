import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 唯一碰 ImageIO 的地方。
///
/// 分層的意義在這裡很具體：`PackValidator` 要判斷「PNG 能不能解碼」與
/// 「同一動作內尺寸是否一致」，但它是 Domain 的純函式、不能碰 ImageIO，
/// 所以由這一層先把檔案系統的事實讀出來再餵給它。
public enum SpriteFileStore {

    public static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 只讀 header 取尺寸，不解碼像素。
    /// 驗證整套 pack 的尺寸一致性不需要把所有圖解進記憶體。
    public static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
