// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Slotkeeper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Slotkeeper",
            path: "Sources/Slotkeeper",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
    ]
)
