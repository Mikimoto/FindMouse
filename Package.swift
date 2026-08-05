// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FindMouse",
    platforms: [.macOS("14.0")],
    products: [
        .library(name: "FindMouseDomain", targets: ["FindMouseDomain"]),
        .library(name: "FindMouseCore", targets: ["FindMouseCore"]),
    ],
    targets: [
        .target(name: "FindMouseDomain"),
        .target(name: "FindMouseCore", dependencies: ["FindMouseDomain"]),
        .testTarget(name: "FindMouseDomainTests", dependencies: ["FindMouseDomain"]),
        .testTarget(name: "FindMouseCoreTests", dependencies: ["FindMouseCore", "FindMouseDomain"]),
    ]
)
