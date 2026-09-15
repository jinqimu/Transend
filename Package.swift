// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Transend",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Transend",
            path: "Sources/Transend"
        )
    ]
)
