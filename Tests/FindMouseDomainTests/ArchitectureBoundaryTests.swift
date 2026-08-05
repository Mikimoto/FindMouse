import Foundation
import Testing

/// 掃原始碼強制分層規則。SPM 無法阻止內層 import 系統框架，只能靠這個測試。
///
/// 被擋的模組分兩類：直接的展示層框架（AppKit / Cocoa / SwiftUI / UIKit），
/// 以及會 re-export AppKit 的框架（QuartzCore / Carbon / Quartz / WebKit / AVKit）——
/// 後者一樣會把 NSScreen、NSEvent 帶進來，所以同樣要擋。
struct ArchitectureBoundaryTests {

    /// 往上找到含 Package.swift 的目錄。
    /// 刻意不數層數：數層數的話，本檔搬到子目錄就會讓掃描範圍變成空的，
    /// 而空的掃描範圍會讓這個測試靜默通過——對偵測器來說那是最危險的方向。
    private static var packageRoot: URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            let parent = dir.deletingLastPathComponent()
            precondition(parent != dir, "從 \(#filePath) 往上找不到 Package.swift")
            dir = parent
        }
        return dir
    }

    private static let forbiddenModules: Set<String> = [
        // 直接的展示層框架
        "AppKit", "Cocoa", "SwiftUI", "UIKit",
        // 會 re-export AppKit：實測 NSScreen / NSEvent 都解析得到
        "QuartzCore", "Carbon", "Quartz", "WebKit", "AVKit",
    ]

    /// 容許 attribute 與 access modifier 前綴，只擷取模組路徑的第一段。
    /// 因此以下全部會被抓到：
    ///   @preconcurrency import AppKit
    ///   public import AppKit
    ///   import AppKit.NSColor
    ///   import AppKit // 註解
    ///   import AppKit;
    ///   import Carbon.HIToolbox
    /// 而註解行（`// … import AppKit …`）不會誤觸，因為 `//` 擋住了 `^\s*` 之後的比對。
    /// 計算屬性而非 `static let`：`Regex<AnyRegexOutput>` 不是 Sendable，
    /// Swift 6 語言模式下 `static let` 會被判為非併發安全而編譯失敗。
    private static var importPattern: Regex<AnyRegexOutput> {
        try! Regex(
            #"^\s*(?:@\w+\s+)*(?:public|package|internal|fileprivate|private)?\s*import\s+([A-Za-z_]\w*)"#
        )
    }

    private static func swiftFiles(in relativePath: String) -> [URL] {
        let dir = packageRoot.appendingPathComponent(relativePath)
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (walker?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
    }

    private static func offendingImports(in relativePath: String) throws -> [String] {
        var offences: [String] = []
        let importPattern = Self.importPattern
        for file in swiftFiles(in: relativePath) {
            let text = try String(contentsOf: file, encoding: .utf8)
            // 外部編輯器可能留下 BOM，U+FEFF 屬 Cf 類、不會被 whitespace trim 掉
            let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            for (lineNumber, line) in body.components(separatedBy: .newlines).enumerated() {
                guard let match = try? importPattern.firstMatch(in: line),
                      let range = match[1].range else { continue }
                let module = String(line[range])
                if forbiddenModules.contains(module) {
                    offences.append("\(file.lastPathComponent):\(lineNumber + 1) import \(module)")
                }
            }
        }
        return offences
    }

    @Test func domainImportsNoPresentationFramework() throws {
        let files = Self.swiftFiles(in: "Sources/FindMouseDomain")
        #expect(!files.isEmpty, "掃不到 Sources/FindMouseDomain 的 .swift，這個邊界測試等於沒跑")
        let offences = try Self.offendingImports(in: "Sources/FindMouseDomain")
        #expect(offences.isEmpty, "FindMouseDomain 不得 import 展示層框架：\(offences)")
    }

    /// `Sources/FindMouseCore` 要到 Task 10 才誕生，所以這裡還不能斷言掃到檔案——
    /// 現在加非空斷言會讓這個測試在 Task 10 之前一直是紅的。
    /// 那個非空斷言與對應的 mutation 檢查排在 Task 10 的 Step 5b，
    /// 也就是第一個 Core 檔案出現的當下。
    @Test func coreImportsNoPresentationFramework() throws {
        let offences = try Self.offendingImports(in: "Sources/FindMouseCore")
        #expect(offences.isEmpty, "FindMouseCore 不得 import 展示層框架：\(offences)")
    }
}
