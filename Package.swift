// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftCD",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swiftcd-server", targets: ["swiftcd-server"]),
        .executable(name: "swiftcd", targets: ["swiftcd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SwiftCDCore",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .executableTarget(
            name: "swiftcd-server",
            dependencies: [
                "SwiftCDCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [.copy("Public")]
        ),
        .executableTarget(
            name: "swiftcd",
            dependencies: [
                "SwiftCDCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SwiftCDCoreTests",
            dependencies: ["SwiftCDCore"]
        ),
    ]
)
