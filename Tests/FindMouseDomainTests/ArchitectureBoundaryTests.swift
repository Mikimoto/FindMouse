import Foundation
import Testing

/// 掃原始碼強制分層規則。SPM 無法阻止內層 import 系統框架，只能靠這個測試。
struct ArchitectureBoundaryTests {

    /// 由測試檔位置推出套件根目錄：Tests/FindMouseDomainTests/x.swift → 往上三層
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static let forbidden = ["AppKit", "Cocoa", "SwiftUI", "QuartzCore", "CoreAnimation", "Carbon"]

    private static func swiftFiles(in relativePath: String) throws -> [URL] {
        let dir = packageRoot.appendingPathComponent(relativePath)
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private static func offendingImports(in relativePath: String) throws -> [String] {
        var offences: [String] = []
        for file in try swiftFiles(in: relativePath) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (lineNumber, line) in text.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = trimmed.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                if forbidden.contains(module) {
                    offences.append("\(file.lastPathComponent):\(lineNumber + 1) import \(module)")
                }
            }
        }
        return offences
    }

    @Test func domainImportsNoUIFramework() throws {
        let offences = try Self.offendingImports(in: "Sources/FindMouseDomain")
        #expect(offences.isEmpty, "FindMouseDomain 不得 import UI 框架：\(offences)")
    }

    @Test func coreImportsNoUIFramework() throws {
        let offences = try Self.offendingImports(in: "Sources/FindMouseCore")
        #expect(offences.isEmpty, "FindMouseCore 不得 import UI 框架：\(offences)")
    }
}
