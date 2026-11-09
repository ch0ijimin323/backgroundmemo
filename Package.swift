// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BackgroundMemo",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "BackgroundMemo", path: "Sources/BackgroundMemo")
    ]
)
