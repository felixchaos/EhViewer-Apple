// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EhNetwork",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "EhNetwork", targets: ["EhAPI", "EhCookie", "EhDNS"]),
        .library(name: "EhAPI", targets: ["EhAPI"]),
        .library(name: "EhCookie", targets: ["EhCookie"]),
        .library(name: "EhDNS", targets: ["EhDNS"]),
    ],
    dependencies: [
        .package(path: "../EhCore"),
        .package(path: "../EhParser"),
    ],
    targets: [
        .target(
            name: "EhAPI",
            dependencies: [
                .product(name: "EhModels", package: "EhCore"),
                .product(name: "EhSettings", package: "EhCore"),
                .product(name: "EhParser", package: "EhParser"),
                "EhCookie",
                "EhDNS",
            ],
            path: "Sources/EhAPI"
        ),
        .testTarget(
            name: "EhAPITests",
            dependencies: ["EhAPI", .product(name: "EhModels", package: "EhCore")]
        ),
        .target(
            name: "EhCookie",
            dependencies: [
                .product(name: "EhSettings", package: "EhCore"),
            ],
            path: "Sources/EhCookie"
        ),
        .target(
            name: "EhDNS",
            dependencies: [
                .product(name: "EhSettings", package: "EhCore"),
            ],
            path: "Sources/EhDNS"
        ),
    ]
)
