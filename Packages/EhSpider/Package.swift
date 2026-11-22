// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EhSpider",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "EhSpider", targets: ["EhSpider"]),
    ],
    dependencies: [
        .package(path: "../EhCore"),
        .package(path: "../EhNetwork"),
        .package(path: "../EhParser"),
    ],
    targets: [
        .target(
            name: "EhSpider",
            dependencies: [
                .product(name: "EhModels", package: "EhCore"),
                .product(name: "EhSettings", package: "EhCore"),
                .product(name: "EhAPI", package: "EhNetwork"),
                .product(name: "EhParser", package: "EhParser"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "EhSpiderTests",
            dependencies: [
                "EhSpider",
                .product(name: "EhModels", package: "EhCore"),
            ]
        ),
    ]
)
