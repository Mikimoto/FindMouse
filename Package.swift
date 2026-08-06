// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FindMouse",
    platforms: [.macOS("14.0")],
    products: [
        .library(name: "FindMouseDomain", targets: ["FindMouseDomain"]),
        .library(name: "FindMouseCore", targets: ["FindMouseCore"]),
        .executable(name: "FindMouse", targets: ["FindMouse"]),
    ],
    targets: [
        .target(name: "FindMouseDomain"),
        .target(name: "FindMouseCore", dependencies: ["FindMouseDomain"]),
        .executableTarget(name: "FindMouse", dependencies: ["FindMouseCore", "FindMouseDomain"]),
        .testTarget(name: "FindMouseDomainTests", dependencies: ["FindMouseDomain"]),
        .testTarget(name: "FindMouseCoreTests", dependencies: ["FindMouseCore", "FindMouseDomain"]),
    ]
)
