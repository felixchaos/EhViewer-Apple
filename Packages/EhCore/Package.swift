// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EhCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "EhModels", targets: ["EhModels"]),
        .library(name: "EhDatabase", targets: ["EhDatabase"]),
        .library(name: "EhSettings", targets: ["EhSettings"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "EhModels",
            path: "Sources/EhModels"
        ),
        .target(
            name: "EhDatabase",
            dependencies: [
                "EhModels",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/EhDatabase"
        ),
        .testTarget(
            name: "EhDatabaseTests",
            dependencies: ["EhDatabase", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "EhSettings",
            dependencies: ["EhModels"],
            path: "Sources/EhSettings"
        ),
        .testTarget(
            name: "EhSettingsTests",
            dependencies: ["EhSettings"]
        ),
    ]
)
