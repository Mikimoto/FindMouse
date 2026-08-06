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
        .executable(name: "FindMouse", targets: ["FindMouse"]),
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
            name: "FindMouse",
            dependencies: ["FindMouseAdapters", "FindMouseCore", "FindMouseDomain",
                           "FindMouseWire"]),
        .testTarget(
            name: "FindMouseAdaptersTests",
            dependencies: ["FindMouseAdapters", "FindMouseCore", "FindMouseDomain",
                           "FindMouseWire"],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "FindMouseDomainTests", dependencies: ["FindMouseDomain"]),
        .testTarget(name: "FindMouseCoreTests", dependencies: ["FindMouseCore", "FindMouseDomain"]),
        .testTarget(name: "FindMouseWireTests", dependencies: ["FindMouseWire"]),
    ]
)
