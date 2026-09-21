// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TWhisper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TWhisper", targets: ["TWhisperApp"])
    ],
    targets: [
        .target(
            name: "TWhisperKit",
            path: "Sources/TWhisperKit"
        ),
        .executableTarget(
            name: "TWhisperApp",
            dependencies: ["TWhisperKit"],
            path: "Sources/TWhisperApp"
        ),
        .testTarget(
            name: "TWhisperTests",
            dependencies: ["TWhisperKit"],
            path: "Tests/TWhisperTests"
        )
    ]
)
