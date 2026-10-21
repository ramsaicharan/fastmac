// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FastMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FastMac",
            path: "Sources/FastMac",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
