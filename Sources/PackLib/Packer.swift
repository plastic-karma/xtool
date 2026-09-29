import Foundation
import XUtils
import Subprocess

public struct Packer: Sendable {
    public let buildSettings: BuildSettings
    public let plan: Plan

    public init(buildSettings: BuildSettings, plan: Plan) {
        self.plan = plan
        self.buildSettings = buildSettings
    }

    private func build(settings: BuildSettings, products: [Plan.Product]) async throws {
        let xtoolDir = URL(fileURLWithPath: "xtool")
        let packageDir = xtoolDir.appendingPathComponent(".xtool-tmp/\(settings.platform.rawValue)")
        try? FileManager.default.removeItem(at: packageDir)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

        let deploymentTarget = settings.deploymentTarget(for: products[0].deploymentTarget)
        let packageSwift = packageDir.appendingPathComponent("Package.swift")
        let contents = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "\(plan.app.product)-Builder",
            platforms: [
                .\(settings.platform.packagePlatform)("\(deploymentTarget)"),
            ],
            dependencies: [
                .package(name: "RootPackage", path: "../../.."),
            ],
            targets: [
                \(
                    products.map {
                        """
                        .executableTarget(
                            name: "\($0.targetName)",
                            dependencies: [
                                .product(name: "\($0.product)", package: "RootPackage"),
                            ],
                            linkerSettings: \($0.linkerSettings)
                        )
                        """
                    }
                    .joined(separator: ",\n")
                )
            ]
        )\n
        """
        try Data(contents.utf8).write(to: packageSwift)
        let resolved = URL(fileURLWithPath: buildSettings.packagePath).appendingPathComponent("Package.resolved")
        if FileManager.default.fileExists(atPath: resolved.path) {
            try FileManager.default.copyItem(
                at: resolved,
                to: packageDir.appendingPathComponent("Package.resolved")
            )
        }

        for product in products {
            let sources: URL = packageDir.appendingPathComponent("Sources/\(product.targetName)", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data().write(to: sources.appendingPathComponent("stub.c", isDirectory: false))
        }

        var linkerOptions: [String] = []
        #if !os(macOS)
        // Linux Clang otherwise records the deployment target as the SDK
        // version, including when Swift Build drives it. Set both explicitly.
        struct SDKSettings: Decodable {
            let Version: String
        }
        let sdk = try DarwinSDK.current()
            .orThrow(StringError("No Darwin SDK configured. Please run `xtool setup`."))
        let simulator = settings.triple.contains("simulator")
        let platform = settings.platform.supportedPlatform(simulator: simulator)
        let sdkSettings = sdk.bundle.appendingPathComponent(
            "Developer/Platforms/\(platform).platform/Developer/SDKs/\(platform).sdk/SDKSettings.json"
        )
        let version = try JSONDecoder().decode(SDKSettings.self, from: Data(contentsOf: sdkSettings)).Version
        let linkerPlatform = settings.platform.rawValue + (simulator ? "-simulator" : "")
        linkerOptions = ["-platform_version", linkerPlatform, deploymentTarget, version]
            .flatMap { ["-Xlinker", $0] }
        #endif
        let buildConfig = try await settings
            .withPackagePath(packageDir.path)
            .swiftPMInvocation(
                forTool: "build",
                arguments: [
                    "--scratch-path", settings.scratchPath,
                    // resolving can cause SwiftPM to overwrite the root package deps
                    // with just the deps needed for the builder package (which is to
                    // say, any "dev dependencies" of the root package may be removed.)
                    // fortunately we've already resolved the root package by this point
                    // in order to dump the plan, so we can skip resolution here to skirt
                    // the issue.
                    "--disable-automatic-resolution",
                ] + linkerOptions,
            )
        try await Subprocess.run(
            buildConfig,
            output: .currentStandardOutput,
            error: .currentStandardError,
        )
        .checkSuccess()
    }

    public func pack() async throws -> URL {
        let products = plan.allProducts
        var settingsByPlatform = [buildSettings.platform: [buildSettings]]
        if plan.watchApp != nil {
            settingsByPlatform[.watchOS] = try await buildSettings.companionWatchBuildSettings()
        }
        let lipo = settingsByPlatform.values.contains { $0.count > 1 } ? try await Self.lipoExecutable() : nil
        for (platform, settings) in settingsByPlatform {
            let platformProducts = products.filter { $0.platform == platform }
            for architectureSettings in settings {
                try await build(settings: architectureSettings, products: platformProducts)
            }
        }

        let output = try TemporaryDirectory(name: "\(plan.app.product).app")

        let outputURL = output.url

        try await withThrowingTaskGroup(of: Void.self) { group in
            for product in products {
                guard let settings = settingsByPlatform[product.platform] else {
                    throw StringError("No build settings for \(product.platform.rawValue) product \(product.product)")
                }
                try pack(
                    product: product,
                    settings: settings,
                    lipo: lipo,
                    outputURL: product.directory(inApp: outputURL),
                    &group
                )
            }

            while !group.isEmpty {
                do {
                    try await group.next()
                } catch is CancellationError {
                    // continue
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        }

        let dest = URL(fileURLWithPath: "xtool").appendingPathComponent(outputURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try output.persist(at: dest)
        return dest
    }

    @Sendable private func pack(
        product: Plan.Product,
        settings: [BuildSettings],
        lipo: Executable?,
        outputURL: URL,
        _ group: inout ThrowingTaskGroup<Void, Error>
    ) throws {
        let binDir = settings[0].binaryDirectory
        @Sendable func packFileToRoot(srcName: String) async throws {
            let srcURL = URL(fileURLWithPath: srcName)
            let destURL = outputURL.appendingPathComponent(srcURL.lastPathComponent)
            try FileManager.default.copyItem(at: srcURL, to: destURL)

            try Task.checkCancellation()
        }

        @Sendable func packFile(
            srcName: String,
            dstName: String? = nil,
            executablePath: String? = nil
        ) async throws {
            let srcURL = URL(fileURLWithPath: srcName, relativeTo: binDir)
            let dstURL = URL(fileURLWithPath: dstName ?? srcURL.lastPathComponent, relativeTo: outputURL)
            try? FileManager.default.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
            if let executablePath, let lipo, settings.count > 1 {
                let sources = settings.map { settings in
                    let source = settings.binaryDirectory.appendingPathComponent(srcName)
                    return (
                        settings.architecture,
                        executablePath.isEmpty ? source : source.appendingPathComponent(executablePath)
                    )
                }
                let destination = executablePath.isEmpty ? dstURL : dstURL.appendingPathComponent(executablePath)
                try await Self.mergeWatchBinary(sources: sources, destination: destination, lipo: lipo)
            }

            try Task.checkCancellation()
        }

        // Ensure output directory is available
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        for command in product.resources {
            group.addTask {
                switch command {
                case .bundle(let package, let target):
                    try await packFile(srcName: "\(package)_\(target).bundle")
                case .binaryTarget(let name):
                    let src = URL(fileURLWithPath: "\(name).framework/\(name)", relativeTo: binDir)
                    let magic = Data("!<arch>\n".utf8)
                    let thinMagic = Data("!<thin>\n".utf8)
                    guard let bytes = try? FileHandle(forReadingFrom: src).read(upToCount: magic.count) else {
                        // if we can't find the binary, it might be a static framework that SwiftPM
                        // did not copy into the .build directory. we don't need to pack it anyway.
                        break
                    }
                    // if the magic matches one of these it's a static archive; don't embed it.
                    // https://github.com/apple/llvm-project/blob/e716ff14c46490d2da6b240806c04e2beef01f40/llvm/include/llvm/Object/Archive.h#L33
                    // swiftlint:disable:previous line_length
                    if bytes != magic && bytes != thinMagic {
                        try await packFile(
                            srcName: "\(name).framework",
                            dstName: "Frameworks/\(name).framework",
                            executablePath: name
                        )
                    }
                case .library(let name):
                    try await packFile(
                        srcName: "lib\(name).dylib",
                        dstName: "Frameworks/lib\(name).dylib",
                        executablePath: ""
                    )
                case .root(let source):
                    try await packFileToRoot(srcName: source)
                }
            }
        }
        if let iconPath = product.iconPath {
            group.addTask {
                try await packFileToRoot(srcName: iconPath)
            }
        }
        group.addTask {
            try await packFile(srcName: product.targetName, dstName: product.product, executablePath: "")
        }
        group.addTask {
            var info = product.infoPlist

            if let iconPath = product.iconPath {
                let iconName = URL(fileURLWithPath: iconPath).deletingPathExtension().lastPathComponent
                info["CFBundleIconFile"] = iconName
            }

            let infoPath = outputURL.appendingPathComponent("Info.plist")
            let encodedPlist = try PropertyListSerialization.data(
                fromPropertyList: info,
                format: .xml,
                options: 0
            )
            try encodedPlist.write(to: infoPath)
        }
    }

    private static func lipoExecutable() async throws -> Executable {
        if let sdk = try DarwinSDK.current() {
            let tool = sdk.bundle.appendingPathComponent("toolset/bin/llvm-lipo")
            if FileManager.default.isExecutableFile(atPath: tool.path) {
                return .path(FilePath(tool.path))
            }
        }
        #if os(macOS)
        return .path("/usr/bin/lipo")
        #else
        return .path(FilePath(try await ToolRegistry.locate("llvm-lipo").path))
        #endif
    }

    private static func mergeWatchBinary(
        sources: [(architecture: String, url: URL)],
        destination: URL,
        lipo: Executable
    ) async throws {
        let temporary = try TemporaryDirectory(name: "xtool-watch-universal")
        var inputs: [String] = []
        for source in sources {
            let result = try await Subprocess.run(
                lipo,
                arguments: .init(["-archs", source.url.path]),
                output: .string(limit: .max),
                error: .currentStandardError
            ).checkSuccess()
            let architectures = result.standardOutput.split(whereSeparator: \.isWhitespace)
            guard architectures.contains(Substring(source.architecture)) else {
                throw StringError("Watch binary '\(source.url.path)' does not contain \(source.architecture)")
            }
            if architectures.count == 1 {
                inputs.append(source.url.path)
            } else {
                // Binary dependencies may already be universal; take only the matching
                // slice from each build rather than passing duplicate slices to -create.
                let thin = temporary.url.appendingPathComponent(source.architecture)
                try await Subprocess.run(
                    lipo,
                    arguments: .init([
                        source.url.path, "-thin", source.architecture, "-output", thin.path,
                    ]),
                    output: .currentStandardOutput,
                    error: .currentStandardError
                ).checkSuccess()
                inputs.append(thin.path)
            }
        }
        try await Subprocess.run(
            lipo,
            arguments: .init(["-create"] + inputs + ["-output", destination.path]),
            output: .currentStandardOutput,
            error: .currentStandardError
        ).checkSuccess()
    }
}

extension Plan.Product {
    fileprivate var linkerSettings: String {
        switch self.type {
        case .application: """
        [
            .unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            ]),
        ]
        """
        case .appExtension: """
        [
            // Link to Foundation framework which implements the _NSExtensionMain entrypoint
            .linkedFramework("Foundation"),
            .unsafeFlags([
                // Extension entry points are resolved by the system at runtime.
                // Swift Build archives their modules; retain those unreferenced objects.
                "-Xlinker", "-all_load",
                // Set the entry point to Foundation`_NSExtensionMain
                "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                // Include frameworks that the host app may use
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../Frameworks",
                // ...as well as our own
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            ]),
        ]
        """
        }
    }
}
