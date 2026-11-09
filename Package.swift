// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BackgroundMemo",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "BackgroundMemoCore", path: "Sources/BackgroundMemoCore"),
        .executableTarget(
            name: "BackgroundMemo",
            dependencies: ["BackgroundMemoCore"],
            path: "Sources/BackgroundMemo"
        ),
        // Run with `swift run CoreChecks`. `swift test` needs a full Xcode install.
        .executableTarget(
            name: "CoreChecks",
            dependencies: ["BackgroundMemoCore"],
            path: "Sources/CoreChecks"
        ),
    ]
)
