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
/// 被掃描的目錄裡沒有符號連結；`Package.swift` 是根目錄唯一的 manifest，
/// 且不含會讓掃描假設失效的關鍵字。
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
/// - **不保證 manifest 檢查是解析式的。** 它是對單一檔名的文字關鍵字掃描，
///   `path : "x"`（冒號前有空格）這種寫法躲得過。與 import 行同屬「刻意規避
///   擋不住」那一類。
/// - **這三個測試是一道閘門，不是三個獨立結論。** 任何單獨一個的綠燈都沒有意義：
///   例如 manifest 被 `path:` 重導向時，`innerTargetsImportOnlyAllowedModules`
///   會忠實地稽核那個誘餌目錄然後通過。
struct ArchitectureBoundaryTests {

    /// 每個內層 target 允許 import 的模組。來源：spec 第 7.1 節。
    /// `Sources/` 底下出現沒列在這裡的 target 會讓測試失敗，
    /// 逼作者明確宣告它的政策，而不是讓它靜默地不受檢查。
    private static let allowedImports: [String: Set<String>] = [
        "FindMouseDomain": ["Foundation", "CoreGraphics"],
        // Wire：Foundation 與 Darwin。這是 CLI 與 App 的共同契約，
        // 碰到 Domain 就等於把 domain 型別洩漏進對外 JSON。
        //
        // Darwin 是為了 `WireClient`：CLI 只依賴 Wire（spec 第 8.5 節），
        // 所以講這個協定的 socket client 也只能住在這裡。禁令針對的是
        // **本專案的內層模組**，不是系統的 C 介面——放行它不會讓 domain
        // 型別有任何新的路徑洩漏進來。
        "FindMouseWire": ["Foundation", "Darwin"],
        // Core 只依賴 Domain
        "FindMouseCore": ["Foundation", "CoreGraphics", "FindMouseDomain"],
        // Adapters：允許碰系統框架與 UI，但依賴方向仍然只能往內（Core、Domain）
        // FindMouseWire 在這裡而不在 Core：把 domain 型別翻譯成對外 JSON 契約
        // 是 adapter 的工作。Core 若能 import Wire，狀態機就會開始為了
        // 「JSON 好看」而長出欄位，而那正是 Wire 單獨存在要防的事。
        "FindMouseAdapters": ["Foundation", "CoreGraphics", "AppKit", "QuartzCore",
                              "ImageIO", "UniformTypeIdentifiers", "OSLog",
                              "FindMouseCore", "FindMouseDomain", "FindMouseWire"],
        // app（驅動層）：可以碰 UI 與系統框架，這是依賴方向的最外層
        "FindMouseApp": ["Foundation", "CoreGraphics", "AppKit", "QuartzCore",
                         "Carbon", "OSLog",
                         "FindMouseCore", "FindMouseDomain", "FindMouseAdapters",
                         "FindMouseWire"],
        // CLI：只有 Wire 與 Foundation／Darwin。碰得到 Domain 的話，
        // 對外 JSON 契約與內部型別就又綁在一起了（spec 第 7.1 節）。
        "FindMouseCLICore": ["Foundation", "FindMouseWire"],
        "FindMouseCLI": ["Foundation", "Darwin", "FindMouseCLICore", "FindMouseWire"],
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
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return (entries ?? [])
            .filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                // 指向目錄的符號連結，isDirectory 是 false。不把它收進來的話，
                // 一個 symlink 當 target 目錄會同時躲過「未宣告政策」與「內容稽核」。
                return values?.isDirectory == true || values?.isSymbolicLink == true
            }
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
            .map { $0.path.replacingOccurrences(
                of: packageRoot.appendingPathComponent("Sources").path + "/", with: "") }
            .sorted()
    }

    /// 掃描假設「`Sources/<target>/` 就是該 target 的實際內容」。
    /// 這些 manifest 設定會讓那個假設失效：實測 `path:` 重導向並留下誘餌目錄、
    /// 或 `unsafeFlags` 掛 `-import-objc-header`，都能讓 AppKit 進到 Domain
    /// 而本測試維持綠。與其讓假設默默失效，不如在它被引入的當下就紅燈。
    /// 後續里程碑若真的需要其中之一，必須連同這個測試一起改——那才是有意識的決定。
    ///
    /// 不列 `sources:`——它是 `resources:` 的子字串，而本專案之後要用 resources 出貨
    /// 內建 sprite pack。而且用 `sources:` 縮小編譯範圍只會讓掃描看到「超集」，
    /// 那是 fail-closed 的方向（可能誤報，不會漏放）。
    private static let manifestKeysThatBreakTheScan = [
        "path:", "exclude:", "unsafeFlags",
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
            // 單獨的 \r 也是 Swift lexer 認的換行，不正規化的話整個檔案會塌成一行
            let normalized = body
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
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
        let root = Self.packageRoot
        let manifests = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix("Package") && $0.hasSuffix(".swift") }
            .sorted()
        // SwiftPM 會優先採用 Package@swift-<版本>.swift。只讀 Package.swift 的檢查
        // 在那種檔案存在時，檢查的是一份不再權威的 manifest，而且會回報綠燈。
        #expect(manifests == ["Package.swift"],
                "根目錄應該只有一份 Package.swift，否則本測試檢查的可能不是 SwiftPM 實際採用的那一份：\(manifests)")

        let manifest = try String(
            contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
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
        let declared = Set(Self.allowedImports.keys)
        let missing = declared.subtracting(audited).sorted()
        #expect(missing.isEmpty,
                "allowedImports 宣告了這些內層 target，但掃描時找不到它們的目錄，這個測試的綠燈單獨看沒有意義：\(missing)")
    }
}
