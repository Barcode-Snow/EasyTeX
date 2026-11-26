// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EasyTeX",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "EasyTeX", path: "Sources/EasyTeX")
    ]
)
