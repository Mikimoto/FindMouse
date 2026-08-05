// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FindMouse",
    platforms: [.macOS("14.0")],
    products: [
        .library(name: "FindMouseDomain", targets: ["FindMouseDomain"]),
    ],
    targets: [
        .target(name: "FindMouseDomain"),
        .testTarget(name: "FindMouseDomainTests", dependencies: ["FindMouseDomain"]),
    ]
)
