// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SlotstreamBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SlotstreamBar",
            path: "Sources/SlotstreamBar",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
    ]
)
