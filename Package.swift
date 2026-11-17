// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChaosKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "ChaosKit", targets: ["ChaosKit"]),
    ],
    targets: [
        .target(
            name: "ChaosKit",
            path: "Sources/ChaosKit",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "ChaosKitTests",
            dependencies: ["ChaosKit"],
            path: "Tests/ChaosKitTests"
        ),
    ]
)
