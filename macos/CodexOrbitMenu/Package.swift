// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexOrbitMenu",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "CodexOrbitMenu", targets: ["CodexOrbitMenu"]),
    ],
    targets: [
        .executableTarget(
            name: "CodexOrbitMenu",
            path: "Sources"
        ),
    ]
)
