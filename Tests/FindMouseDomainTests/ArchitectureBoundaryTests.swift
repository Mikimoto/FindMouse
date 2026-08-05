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
/// 允許清單讓「模組名」這一層由構造上完整：凡是被辨識出來、又不在清單上的模組一律紅燈。
///
/// 這個測試**保證**：被辨識為 import 宣告的行，其模組必須在該 target 的允許清單內；
/// 被掃描的目錄裡沒有符號連結；`Package.swift` 維持慣例佈局。
///
/// 這個測試**不保證**，寫出來以免綠燈被過度解讀：
///
/// - **不保證 Domain 沒有 I/O。** 允許清單的粒度是模組而不是符號。`CoreGraphics` 是
///   spec 第 7.1 節允許的，但它同時給了 `CGDisplayBounds`、`CGWarpMouseCursorPosition`
///   與 `CGEvent.post`——實測這些在 Domain 裡編得過而本測試維持綠。在這個專案裡這是
///   最可能發生的真實洩漏，因為整個 App 的主題就是列舉螢幕與移動鼠標，而那些操作
///   應該住在 Core 的 port 後面。**綠燈不等於 Domain 是純的。**
/// - **不保證擋得住刻意規避。** 一行寫兩個 import、`import` 與模組名跨行、
///   `import /* 註解 */ AppKit` 都能編過而本測試看不到（pattern 是 `^` 錨定的單行比對）。
///   這些不會有人不小心寫出來，所以刻意不為它們增加誤報風險。
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

    /// 被掃描目錄裡的符號連結。SPM 會編譯符號連結目錄底下的檔案，
    /// 但 `FileManager.enumerator` 不會遞迴進去——那是一條掃不到的路徑。
    /// 與其複製 SPM 的來源解析邏輯，不如在符號連結出現的當下就紅燈。
    private static func symlinks(inTarget target: String) -> [String] {
        let dir = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent(target)
        let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey])
        return (walker?.compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true }
            .map { "\(target)/\($0.lastPathComponent)" }
            .sorted()
    }

    /// 掃描假設「`Sources/<target>/` 就是該 target 的實際內容」。
    /// 這些 manifest 設定會讓那個假設失效：實測 `path:` 重導向並留下誘餌目錄、
    /// 或 `unsafeFlags` 掛 `-import-objc-header`，都能讓 AppKit 進到 Domain
    /// 而本測試維持綠。與其讓假設默默失效，不如在它被引入的當下就紅燈。
    /// 後續里程碑若真的需要其中之一，必須連同這個測試一起改——那才是有意識的決定。
    private static let manifestKeysThatBreakTheScan = [
        "path:", "sources:", "exclude:", "unsafeFlags",
        "linkerSettings", "cSettings", "-import-objc-header",
    ]

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
            // 先正規化 CRLF：.newlines 會把 \r 與 \n 各算一個分隔符，
            // 讓 \r\n 檔案的每一行多出一個空元素，回報的行號約為實際的兩倍
            let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
            for (lineNumber, line) in normalized.components(separatedBy: "\n").enumerated() {
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

    @Test func manifestKeepsTheLayoutTheScanAssumes() throws {
        let manifest = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8)
        let present = Self.manifestKeysThatBreakTheScan.filter { manifest.contains($0) }
        #expect(present.isEmpty, "Package.swift 出現會讓掃描假設失效的設定，掃到的檔案可能不是真正被編譯的檔案：\(present)")
    }

    @Test func innerTargetsImportOnlyAllowedModules() throws {
        var audited: [String] = []
        for target in Self.sourceTargets {
            guard let allowed = Self.allowedImports[target] else { continue }
            audited.append(target)

            let dangling = Self.symlinks(inTarget: target)
            #expect(dangling.isEmpty, "\(target) 裡有符號連結，SPM 會編譯它但掃描不會進去：\(dangling)")

            let result = try Self.audit(target: target, allowed: allowed)
            #expect(result.fileCount > 0, "\(target) 掃不到任何 .swift，這一層等於沒檢查")
            #expect(result.offences.isEmpty,
                    "\(target) 只允許 import \(allowed.sorted().joined(separator: "、"))：\(result.offences)")
        }
        #expect(audited.contains("FindMouseDomain"),
                "沒有審到 FindMouseDomain，這個測試的綠燈單獨看沒有意義：audited=\(audited)")
    }
}
