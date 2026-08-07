#!/usr/bin/env swift
// 產生 spec 第 6.6 節的 test-blocks pack 與三個刻意壞掉的 fixture。
//
// 用法：
//   swift Scripts/make-test-blocks.swift Sources/FindMouseAdapters/Resources/Packs
//   swift Scripts/make-test-blocks.swift Tests/FindMouseAdaptersTests/Fixtures
//   swift Scripts/make-test-blocks.swift <根目錄> <id> [<體高> [<色相偏移> [<略過的動作...>]]]
//
// 輸出是要 commit 的：`Bundle.module` 的資源必須在建置時就存在，
// 執行期才產生的檔案進不了 resource bundle。這支腳本不進 Package.swift，
// 它是一次性工具而不是產品程式碼。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 14 個動作與各自的色相（度）。順序與 spec 第 6.1 節的目錄列表相同。
/// 每個動作一個不同色相，是為了讓 M2 的手動驗收能用眼睛分辨「現在播的是哪個動作」。
let actions: [(name: String, hue: Double)] = [
    ("run", 0), ("brake", 25), ("sit", 50), ("sitIdle", 75),
    ("stretch", 100), ("yawn", 125), ("scratch", 150), ("lieDown", 175),
    ("sleep", 200), ("stalk", 225), ("windup", 250), ("pounce", 275),
    ("tumble", 300), ("retreat", 325),
]

/// 循環播放的動作。與 M1 的 StubCatalog 用同一份清單，
/// 這樣 test-blocks 與既有單元測試的行為一致。
let loopingActions: Set<String> = ["run", "sitIdle", "sleep", "stalk", "windup"]

/// HSV → RGB，只為了讓 14 個動作的顏色分得開。
func rgb(hue: Double, value: Double) -> (Double, Double, Double) {
    let h = hue / 60
    let c = value
    let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
    switch Int(h) % 6 {
    case 0: return (c, x, 0)
    case 1: return (x, c, 0)
    case 2: return (0, c, x)
    case 3: return (0, x, c)
    case 4: return (x, 0, c)
    default: return (c, 0, x)
    }
}

func writeBlock(to url: URL, side: Int, hue: Double, value: Double) throws {
    guard let ctx = CGContext(data: nil, width: side, height: side,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure("建不出 CGContext") }

    // 整張透明，只在中間畫一個方塊：留白邊才看得出 anchor 有沒有算對。
    // 滿版的圖在 anchor 錯誤時看起來完全正常。
    ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
    let (r, g, b) = rgb(hue: hue, value: value)
    ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
    let inset = Double(side) * 0.1
    ctx.fill(CGRect(x: inset, y: inset,
                    width: Double(side) - inset * 2, height: Double(side) - inset * 2))

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(
              url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure("建不出 PNG destination：\(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw Failure("PNG 寫入失敗：\(url.path)")
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// 產一套 pack。
/// - `drop`：這些動作不產目錄、也不在 manifest 宣告（＝該動作整個不存在）
/// - `frameCountLie`：這個動作的 manifest 宣告 8 格，但目錄裡只有 2 張
/// - `logicalHeight`：宣告用的體高。用 Int 而不是 Double，是為了讓
///   JSONSerialization 對預設值寫出的位元組與既有的 test-blocks/pack.json 完全相同——
///   Double 可能被寫成 `96.0`，那會讓「預設行為不變」這條變成假的。
/// - `hueShift`：整套色相一起偏移幾度。動作之間的相對色差不變，
///   所以「哪個動作在播」仍分得出來，但兩套 pack 之間一眼就看得出不同。
func writePack(root: URL, id: String, side: Int = 64,
               logicalHeight: Int = 96, hueShift: Double = 0,
               drop: Set<String> = [], frameCountLie: String? = nil) throws {
    let dir = root.appendingPathComponent(id)
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var declared: [String: [String: Any]] = [:]
    for (name, hue) in actions where !drop.contains(name) {
        let actionDir = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: actionDir, withIntermediateDirectories: true)
        // 色相是環狀量：偏移後繞回 0–360，不要仰賴 `rgb` 對超界輸入碰巧算得對
        let shifted = (hue + hueShift).truncatingRemainder(dividingBy: 360)
        for frame in 0..<2 {
            let url = actionDir.appendingPathComponent(String(format: "%03d.png", frame))
            // 第 0 格亮、第 1 格暗：眼睛才看得出逐格播放真的在動
            try writeBlock(to: url, side: side, hue: shifted, value: frame == 0 ? 0.95 : 0.55)
        }
        declared[name] = [
            "frames": name == frameCountLie ? 8 : 2,
            "fps": 10,
            "loop": loopingActions.contains(name),
        ]
    }

    let manifest: [String: Any] = [
        "schemaVersion": 1,
        "id": id,
        "name": "測試方塊",
        "author": "FindMouse",
        "license": "CC0",
        "logicalHeight": logicalHeight,
        "anchor": ["x": 0.5, "y": 0.9],
        "facing": "right",
        "mirrorForOpposite": true,
        "actions": declared,
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest,
                                          options: [.prettyPrinted, .sortedKeys])
    try data.write(to: dir.appendingPathComponent("pack.json"))
    print("寫出 \(id)：\(declared.count) 個動作、\(declared.count * 2) 張 PNG")
}

// ── 進入點 ──────────────────────────────────────────────
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法：swift Scripts/make-test-blocks.swift <輸出根目錄> [<id> [<體高> [<色相偏移> [<略過的動作...>]]]]")
    print("  只給根目錄，名為 Packs → 產出合格的 test-blocks")
    print("  只給根目錄，其他名稱   → 產出三個壞掉的 fixture")
    print("  再給 id                → 只產指名的那一套")
    exit(1)
}
let root = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

/// 給了就必須解得開。靜默退回預設值會產出一套「體高其實還是 96」的 pack，
/// 而寫檔成功本身不會有任何警訊——錯要等到有人去比對 pack.json 才發現。
func parsed<T>(_ index: Int, _ fallback: T, _ convert: (String) -> T?) throws -> T {
    guard args.count > index else { return fallback }
    guard let value = convert(args[index]) else {
        throw Failure("第 \(index) 個參數解不開：\(args[index])")
    }
    return value
}

if args.count > 2 {
    // 指名 id 的模式。M4 的第二套 pack（test-blocks-tall）走這條，
    // 而它與 test-blocks 的差異全部由參數表達，產生器本身只有一份。
    try writePack(root: root, id: args[2],
                  logicalHeight: try parsed(3, 96) { Int($0) },
                  hueShift: try parsed(4, 0) { Double($0) },
                  drop: Set(args.dropFirst(5)))
} else if root.lastPathComponent == "Packs" {
    try writePack(root: root, id: "test-blocks")
} else {
    // 三種壞法，對應 spec 第 6.4 節的錯誤規則。
    // bad-missing-core 拿掉 sit（core 級）→ 整套無效
    // bad-frame-count 讓 run 宣告 8 格但只有 2 張 → error
    // bad-missing-teaser 拿掉 pounce（teaser 級）→ 仍有效但逗貓棒不可用
    try writePack(root: root, id: "bad-missing-core", drop: ["sit"])
    try writePack(root: root, id: "bad-frame-count", frameCountLie: "run")
    try writePack(root: root, id: "bad-missing-teaser", drop: ["pounce"])
}
