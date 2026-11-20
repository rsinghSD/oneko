// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Oneko",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Oneko",
            path: "Sources/Oneko"
        )
    ]
)
