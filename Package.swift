// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Saccade",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Saccade",
            path: "Sources/Saccade"
        )
    ]
)
