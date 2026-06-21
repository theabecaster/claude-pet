// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ClaudePet",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "ClaudePet", path: "Sources/ClaudePet")
    ]
)
