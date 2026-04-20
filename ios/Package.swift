// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GhostCrypto",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GhostCrypto", targets: ["GhostCrypto"])
    ],
    targets: [
        .target(
            name: "GhostCrypto",
            path: "Sources/GhostCrypto",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "GhostCryptoTests",
            dependencies: ["GhostCrypto"],
            path: "Tests/GhostCryptoTests",
            resources: [.copy("test-vectors.json")],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        )
    ]
)
