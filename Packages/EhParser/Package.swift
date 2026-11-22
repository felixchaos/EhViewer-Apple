// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EhParser",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "EhParser", targets: ["EhParser"]),
    ],
    dependencies: [
        .package(path: "../EhCore"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "EhParser",
            dependencies: [
                .product(name: "EhModels", package: "EhCore"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "EhParserTests",
            dependencies: [
                "EhParser",
                .product(name: "EhModels", package: "EhCore"),
            ],
            path: "Tests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
