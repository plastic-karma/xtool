// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "NativeResources",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "xtool-native-assets", targets: ["NativeAssetCompiler"]),
        .executable(name: "xtool-appintents-gen", targets: ["AppIntentsCLI"]),
    ],
    dependencies: [
        .package(path: "../../Vendor/AssetKit"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
    ],
    targets: [
        .executableTarget(name: "NativeAssetCompiler", dependencies: ["AssetKit"]),
        .target(name: "AppIntentsGen", dependencies: [
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftParser", package: "swift-syntax"),
        ]),
        .executableTarget(name: "AppIntentsCLI", dependencies: ["AppIntentsGen"]),
        .testTarget(name: "AppIntentsGenTests", dependencies: ["AppIntentsGen"]),
    ]
)
