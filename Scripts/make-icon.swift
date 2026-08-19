#!/usr/bin/env swift
// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

// 把 Scripts/icon.svg 產成一份自我驗證過的 .icns。
//
// 用法：
//   swift Scripts/make-icon.swift <輸出的.icns路徑> [<來源.svg>]
//
// 產物**不進版控**，由 make-app.sh 在組裝 .app 時現產（來源進版控、產物不進，
// 與 tools/build-mycat.py 同一個形狀）。這支不進 Package.swift：它是一次性
// 工具而不是產品程式碼，與 make-test-blocks.swift 同一個理由。
//
// 為什麼用 NSImage 而不是外部 rasterizer：mise.toml 刻意沒有 [tools] 區段，
// 加一個 brew 相依是有代價的。實測（2026-08-19）NSImage 原生讀得了 SVG，
// 而且是**向量重繪**不是點陣放大——量法是圓弧邊緣的過渡寬度：
// SVG 直接畫 1024 是 0 px（抗鋸齒在門檻下），128 放大到 1024 是 6 px。
import AppKit

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ m: String) { description = m }
}

/// iconutil 要的 10 個檔名 → 實際像素邊長。
///
/// 六個不同的像素尺寸、十個檔名：`icon_32x32@2x` 與 `icon_16x16@2x` 都是 32px，
/// 但兩個檔名都必須在，少一個 iconutil 就不收。
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func render(_ image: NSImage, px: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw Failure("開不出 \(px)×\(px) 的 bitmap") }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // **先清成全透明再畫。** 實測這個 buffer 本來就是零填的（2026-08-20：抽樣 19268
    // 個全透明像素，RGB 非零的 0 個；連跑四次 icns 的 sha256 逐字相同），但那是
    // AppKit 沒有保證的行為——`bitmapDataPlanes: nil` 只說「由物件配置記憶體」。
    // 它若哪天不成立，症狀是出貨的圖示在透明處帶隨機雜點，而下面那段反向拆解
    // **只數 rep 與尺寸、抓不到顏色**。實測種了雜點再 draw，19268 個透明像素會
    // 全部帶著髒 RGB 活下來（`.sourceOver` 不覆寫 alpha=0 的底色）。
    // 代價是一個 fill；用 `.copy` 而不是預設的 `.sourceOver`，後者對透明色是 no-op。
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: px, height: px).fill(using: .copy)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw Failure("\(px)×\(px) 編不出 PNG")
    }
    try png.write(to: url)
}

/// 跑一個外部命令，非零就拋。**不接管線**：`cmd | tail` 的 exit code 來自 tail。
@discardableResult
func run(_ launchPath: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard p.terminationStatus == 0 else {
        throw Failure("\(launchPath) \(args.joined(separator: " ")) 回 \(p.terminationStatus)：\(text)")
    }
    return text
}

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    print("用法：swift Scripts/make-icon.swift <輸出的.icns路徑> [<來源.svg>]")
    exit(1)
}
let outICNS = URL(fileURLWithPath: argv[1])
let svg = URL(fileURLWithPath: argv.count > 2
    ? argv[2]
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("icon.svg").path)

do {
    guard FileManager.default.fileExists(atPath: svg.path) else {
        throw Failure("找不到來源 \(svg.path)")
    }
    guard let image = NSImage(contentsOf: svg) else {
        throw Failure("NSImage 讀不了 \(svg.path)。它不是合法的 SVG，或這個 macOS 不支援。")
    }

    let staging = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fm-icon-\(ProcessInfo.processInfo.processIdentifier).iconset")
    try? FileManager.default.removeItem(at: staging)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    for (name, px) in sizes {
        try render(image, px: px, to: staging.appendingPathComponent("\(name).png"))
    }

    try? FileManager.default.removeItem(at: outICNS)
    try FileManager.default.createDirectory(
        at: outICNS.deletingLastPathComponent(), withIntermediateDirectories: true)
    try run("/usr/bin/iconutil", ["-c", "icns", "-o", outICNS.path, staging.path])

    // **反向拆解自我驗證。** `iconutil -c icns` **不檢查尺寸齊不齊**——只有
    // `icon_16x16.png` 一張的 iconset 照樣回 exit 0 並產出一份合法的 icns
    // （2026-08-19 實測 1136 bytes；`test-release.sh` 第 7 段的負向對照組正是
    // 這樣做出來的）。而「圖示在小尺寸變成放大的大圖」這種退化從外面看不出來。
    // 拆回來數，才是驗產物而不是驗意圖。
    let back = staging.deletingLastPathComponent()
        .appendingPathComponent("fm-icon-back-\(ProcessInfo.processInfo.processIdentifier).iconset")
    try? FileManager.default.removeItem(at: back)
    defer { try? FileManager.default.removeItem(at: back) }
    try run("/usr/bin/iconutil", ["-c", "iconset", "-o", back.path, outICNS.path])
    let got = try FileManager.default.contentsOfDirectory(atPath: back.path)
        .filter { $0.hasSuffix(".png") }.sorted()
    let want = sizes.map { "\($0.name).png" }.sorted()
    guard got == want else {
        throw Failure("拆回來的 iconset 少了東西。期望 \(want.count) 個、實際 \(got.count) 個：\(got)")
    }
    guard let big = NSImage(contentsOf: back.appendingPathComponent("icon_512x512@2x.png")),
          let bigRep = big.representations.first,
          bigRep.pixelsWide == 1024, bigRep.pixelsHigh == 1024 else {
        throw Failure("最大那張不是 1024×1024。App Store 要 1024，而縮圖出來的假 1024 從檔名看不出來。")
    }

    let bytes = (try? FileManager.default.attributesOfItem(atPath: outICNS.path)[.size] as? Int) ?? nil
    print("已產出 \(outICNS.path)（\(sizes.count) 個尺寸，\(bytes ?? 0) bytes，反向拆解通過）")
} catch {
    FileHandle.standardError.write(Data("make-icon 失敗：\(error)\n".utf8))
    exit(1)
}
