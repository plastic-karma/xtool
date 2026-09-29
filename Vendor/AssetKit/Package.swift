// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "AssetKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "AssetKit",
            targets: ["AssetKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/tayloraswift/swift-png", exact: "4.5.1"),
    ],
    targets: [
        .target(
            name: "CLZFSE",
            path: "Sources/CLZFSE",
            exclude: ["LICENSE", "UPSTREAM.md"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "AssetKit",
            dependencies: [
                .product(name: "PNG", package: "swift-png"),
                "CLZFSE",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
