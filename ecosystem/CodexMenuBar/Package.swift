// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexMenuBar",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "CodexMenuBar", targets: ["CodexMenuBar"]),
    ],
    targets: [
        .executableTarget(
            name: "CodexMenuBar",
            path: "Sources/CodexMenuBar"
        ),
    ]
)
