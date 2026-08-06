// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FindMouse",
    platforms: [.macOS("14.0")],
    products: [
        .library(name: "FindMouseDomain", targets: ["FindMouseDomain"]),
        .library(name: "FindMouseCore", targets: ["FindMouseCore"]),
        .library(name: "FindMouseAdapters", targets: ["FindMouseAdapters"]),
        .library(name: "FindMouseWire", targets: ["FindMouseWire"]),
        // App target 叫 FindMouseApp 而不是 FindMouse：CLI 的產品名是 `findmouse`，
        // 而建置系統對名稱不分大小寫——`findmouse` 產品會去抓 `FindMouse` target 的
        // 原始碼（實測：findmouse 的編譯輸入變成 AppDelegate.swift）。
        .executable(name: "FindMouseApp", targets: ["FindMouseApp"]),
        .executable(name: "findmouse", targets: ["FindMouseCLI"]),
    ],
    targets: [
        .target(name: "FindMouseDomain"),
        .target(name: "FindMouseWire"),
        .target(name: "FindMouseCore", dependencies: ["FindMouseDomain"]),
        // 用 .copy 不用 .process：pack 的目錄結構就是契約（spec 第 6.1 節），
        // .process 會對 PNG 做最佳化並可能改寫結構。
        .target(
            name: "FindMouseAdapters",
            dependencies: ["FindMouseCore", "FindMouseDomain", "FindMouseWire"],
            resources: [.copy("Resources/Packs")]),
        .executableTarget(
            name: "FindMouseApp",
            dependencies: ["FindMouseAdapters", "FindMouseCore", "FindMouseDomain",
                           "FindMouseWire"]),
        .testTarget(
            name: "FindMouseAdaptersTests",
            dependencies: ["FindMouseAdapters", "FindMouseCore", "FindMouseDomain",
                           "FindMouseWire"],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "FindMouseDomainTests", dependencies: ["FindMouseDomain"]),
        .testTarget(name: "FindMouseCoreTests", dependencies: ["FindMouseCore", "FindMouseDomain"]),
        // CLI 只能碰 Wire（spec 第 7.1 節）：碰得到 Domain 的話，
        // 對外 JSON 契約與內部型別就又綁在一起了。
        //
        // 拆成 Core（純函式）＋ 執行檔（只有 I/O 與 exit code）：executable target
        // 一旦被測試 target 依賴，main.swift 的 top-level code 就連不到自己模組的
        // 符號（實測 Undefined symbols）。而參數解析正是最需要單元測試的部分。
        .target(name: "FindMouseCLICore", dependencies: ["FindMouseWire"]),
        .executableTarget(name: "FindMouseCLI",
                          dependencies: ["FindMouseCLICore", "FindMouseWire"]),
        .testTarget(name: "FindMouseWireTests", dependencies: ["FindMouseWire"]),
        .testTarget(name: "FindMouseCLICoreTests",
                    dependencies: ["FindMouseCLICore", "FindMouseWire"]),
    ]
)
