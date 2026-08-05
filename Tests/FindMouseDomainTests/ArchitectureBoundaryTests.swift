import Foundation
import Testing

/// 掃原始碼強制分層規則。
///
/// SPM 無法阻止內層 import 系統框架——macOS 的系統框架不需宣告依賴就能 import——
/// 所以這個測試是整個專案唯一的分層強制點。
///
/// **規則是允許清單，不是禁止清單。** 禁止清單無法窮舉：實測 macOS SDK 裡至少有 14 個
/// 框架會 re-export AppKit（PDFKit、SceneKit、MapKit、ScreenCaptureKit、StoreKit…），
/// 而 Swift 的 import 文法還有 `import class AppKit.NSScreen` 這種逐符號形式。
/// 允許清單由 spec 第 7.1 節直接給定、小而穩定，而且對沒想到的寫法是往失敗的方向倒
/// （大聲誤報，看 檔案:行號 幾秒就能判斷），不是往通過的方向倒（靜默漏放）。
struct ArchitectureBoundaryTests {

    /// 每個內層 target 允許 import 的模組。來源：spec 第 7.1 節。
    /// `Sources/` 底下出現沒列在這裡的 target 會讓測試失敗，
    /// 逼作者明確宣告它的政策，而不是讓它靜默地不受檢查。
    private static let allowedImports: [String: Set<String>] = [
        "FindMouseDomain": ["Foundation", "CoreGraphics"],
        // Core 只依賴 Domain
        "FindMouseCore": ["Foundation", "CoreGraphics", "FindMouseDomain"],
    ]

    /// 往上找到含 Package.swift 的目錄。
    ///
    /// 終止條件用 `dir.path != "/"`，不用 `parent != dir`：URL 在根目錄的相等性
    /// 不可靠，拿它當終止條件會在找不到 Package.swift 時變成無窮迴圈而不是錯誤訊息。
    private static var packageRoot: URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("從 \(#filePath) 往上找不到 Package.swift")
    }

    /// 容許 attribute（含參數列）與 access modifier 前綴，跳過 import kind 關鍵字，
    /// 只擷取模組路徑的第一段。因此以下全部正確歸類：
    ///   @preconcurrency import AppKit          → AppKit
    ///   @_spi(Private) import AppKit           → AppKit
    ///   public import AppKit                   → AppKit
    ///   import AppKit.NSColor                  → AppKit
    ///   import class AppKit.NSScreen           → AppKit
    ///   import struct Foundation.Data          → Foundation
    ///   import AppKit // 註解                   → AppKit
    /// 註解行（`// … import AppKit`）不會誤觸，因為 `//` 擋住了 `^\s*` 之後的比對。
    private static var importPattern: Regex<AnyRegexOutput> {
        try! Regex(
            #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public|package|internal|fileprivate|private)?\s*import\s+(?:(?:struct|class|enum|protocol|typealias|func|var|let|actor|macro)\s+)?([A-Za-z_]\w*)"#
        )
    }

    /// `Sources/` 底下的所有 target 目錄名
    private static var sourceTargets: [String] {
        let dir = packageRoot.appendingPathComponent("Sources")
        let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        return (entries ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    private static func swiftFiles(inTarget target: String) -> [URL] {
        let dir = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent(target)
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (walker?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
    }

    private static func audit(target: String,
                              allowed: Set<String>) throws -> (fileCount: Int, offences: [String]) {
        // importPattern 是計算屬性（見下），所以在迴圈外取一份
        let pattern = importPattern
        let files = swiftFiles(inTarget: target)
        var offences: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            // 外部編輯器可能留下 BOM；U+FEFF 屬 Cf 類，不會被 whitespace trim 掉
            let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            for (lineNumber, line) in body.components(separatedBy: .newlines).enumerated() {
                guard let match = try? pattern.firstMatch(in: line),
                      let range = match[1].range else { continue }
                let module = String(line[range])
                if !allowed.contains(module) {
                    offences.append("\(target)/\(file.lastPathComponent):\(lineNumber + 1) import \(module)")
                }
            }
        }
        return (files.count, offences)
    }

    @Test func everySourceTargetHasADeclaredImportPolicy() {
        let targets = Self.sourceTargets
        #expect(targets.contains("FindMouseDomain"),
                "掃不到 Sources/FindMouseDomain，這個邊界測試等於沒跑：\(targets)")
        let undeclared = targets.filter { Self.allowedImports[$0] == nil }
        #expect(undeclared.isEmpty,
                "這些 target 沒有宣告 import 政策，請在 allowedImports 明確宣告，不要讓它靜默地不受檢查：\(undeclared)")
    }

    @Test func innerTargetsImportOnlyAllowedModules() throws {
        for target in Self.sourceTargets {
            guard let allowed = Self.allowedImports[target] else { continue }
            let result = try Self.audit(target: target, allowed: allowed)
            #expect(result.fileCount > 0, "\(target) 掃不到任何 .swift，這一層等於沒檢查")
            #expect(result.offences.isEmpty,
                    "\(target) 只允許 import \(allowed.sorted().joined(separator: "、"))：\(result.offences)")
        }
    }
}
