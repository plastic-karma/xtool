import Foundation
import Subprocess
import XUtils
import Superutils

public struct BuildSettings: Sendable {
    private static let customBinDir =
        // this is the same option used by SwiftPM itself for dev builds
        ProcessInfo.processInfo.environment["SWIFTPM_CUSTOM_BIN_DIR"].map { FilePath($0) }

    public var packagePath: String
    public let configuration: BuildConfiguration
    public let triple: String
    public let buildSystem: BuildSystem
    public let platform: BuildPlatform
    public let watchTriple: String?
    public let customOptions: [String]

    public var sdkOptions: [String]
    public var sdkEnvironment: [Environment.Key: String?]

    private var configOptions: [String] {
        return [
            "--configuration", configuration.rawValue,
            "--build-system", buildSystem.pmName,
            "--package-path", packagePath,
        ]
    }

    private var resolvedBaseOptions: [String] {
        configOptions + sdkOptions + customOptions
    }

    public init(
        configuration: BuildConfiguration,
        triple: String,
        buildSystem: BuildSystem? = nil,
        watchTriple: String? = nil,
        packagePath: String = ".",
        options: [String] = []
    ) async throws {
        self.packagePath = packagePath
        self.configuration = configuration
        self.customOptions = options
        self.triple = triple
        self.platform = try BuildPlatform(triple: triple)
        self.watchTriple = watchTriple
        if let watchTriple, try BuildPlatform(triple: watchTriple) != .watchOS {
            throw StringError("The companion watch triple must target watchOS: \(watchTriple)")
        }
        self.buildSystem = if let buildSystem { buildSystem } else { try await .default() }

        self.sdkEnvironment = [
            // xcrun passes an SDKROOT that messes with our sdk configuration
            "SDKROOT": nil,
        ]

        switch self.buildSystem {
        case .swiftPM:
            // on macOS we don't explicitly install a Swift SDK but
            // SwiftPM vends "implicit" Darwin SDKs as of Swift 6.1,
            // i.e. we can pass `--swift-sdk arm64-apple-ios` and it
            // just works. See:
            // https://github.com/swiftlang/swift-package-manager/pull/6828
            self.sdkOptions = ["--swift-sdk", triple]
        case .swiftBuild:
            self.sdkOptions = ["--triple", triple]
            #if !os(macOS)
            let darwinSDK = try DarwinSDK.current()
                .orThrow(StringError("No Darwin SDK configured. Please run `xtool setup`."))
            self.sdkOptions += [
                "--toolset", "\(darwinSDK.bundle.path)/toolset-swb.json",
            ]
            self.sdkEnvironment.merge([
                "XCODE_EXTRA_PLATFORM_FOLDERS": "\(darwinSDK.bundle.path)/Developer/Platforms",
                // SWB looks for dsymutil in the PATH. Other stuff (lld, libtool) is handled by toolset-swb.json.
                "PATH": "\(darwinSDK.bundle.path)/toolset/bin:\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
            ]) { $1 }
            #endif
        }
    }

    #if os(macOS)
    private static func xcrun(_ arguments: [String]) async throws -> String {
        let result = try await Subprocess.run(
            .path("/usr/bin/xcrun"),
            arguments: .init(arguments),
            output: .string(limit: .max)
        ).checkSuccess()
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let _swiftURL = Task {
        try await FilePath(xcrun(["-f", "swift"]))
    }

    public static func swiftURL() async throws -> FilePath {
        try await _swiftURL.value
    }

    private static let _swiftcURL = Task {
        try await FilePath(xcrun(["-f", "swiftc"]))
    }

    public static func swiftcURL() async throws -> FilePath {
        try await _swiftcURL.value
    }
    #else
    public static func swiftURL() async throws -> FilePath {
        try await FilePath(ToolRegistry.locate("swift")).orThrow(StringError("Got bad path for swift executable"))
    }

    public static func swiftcURL() async throws -> FilePath {
        try await FilePath(ToolRegistry.locate("swiftc")).orThrow(StringError("Got bad path for swiftc executable"))
    }
    #endif

    public func withPackagePath(_ path: String) -> Self {
        var copy = self
        copy.packagePath = path
        return copy
    }

    public func forPlatform(_ platform: BuildPlatform) async throws -> Self {
        if platform == self.platform { return self }
        guard platform == .watchOS, self.platform == .iOS else {
            throw StringError("Cannot build \(platform.rawValue) products using \(triple)")
        }
        let companionTriple = watchTriple ?? (
            triple.contains("simulator")
                ? "\(triple.split(separator: "-")[0])-apple-watchos-simulator"
                : "arm64_32-apple-watchos"
        )
        guard companionTriple.contains("simulator") == triple.contains("simulator") else {
            throw StringError("The app and companion watch app must both target devices or both target simulators")
        }
        return try await Self(
            configuration: configuration,
            triple: companionTriple,
            buildSystem: buildSystem,
            packagePath: packagePath,
            options: customOptions
        )
    }

    func companionWatchBuildSettings() async throws -> [Self] {
        let primary = try await forPlatform(.watchOS)
        guard watchTriple == nil, !triple.contains("simulator") else {
            return [primary]
        }
        let arm64 = try await Self(
            configuration: configuration,
            triple: "arm64-apple-watchos",
            buildSystem: buildSystem,
            packagePath: packagePath,
            options: customOptions
        )
        return [primary, arm64]
    }

    var architecture: String {
        String(triple.prefix { $0 != "-" })
    }

    func deploymentTarget(for requested: String) -> String {
        // Device arm64 uses the watchOS 26 ABI. arm64_32 retains the app's
        // older deployment target; arm64 simulators do not use this ABI floor.
        if platform == .watchOS, architecture == "arm64", !triple.contains("simulator"),
           requested.compare("26.0", options: .numeric) == .orderedAscending {
            return "26.0"
        }
        return requested
    }

    public var scratchPath: String {
        platform == .watchOS ? ".build/xtool-watchos/\(architecture)" : ".build"
    }

    public var binaryDirectory: URL {
        let path: String
        switch buildSystem {
        case .swiftPM:
            path = "\(triple)/\(configuration.rawValue)"
        case .swiftBuild:
            let platformName = platform.sdkName(simulator: triple.contains("simulator"))
            path = "out/Products/\(configuration.swiftBuildValue)-\(platformName)"
        }
        return URL(fileURLWithPath: "\(scratchPath)/\(path)", isDirectory: true)
    }

    public func swiftPMInvocation(
        forTool tool: String,
        arguments: [String],
    ) async throws -> Subprocess.Configuration {
        let executable: Executable
        let baseArguments: [String]
        if let customBinDir = Self.customBinDir {
            executable = .path(customBinDir.appending("swift-\(tool)"))
            baseArguments = []
        } else {
            #if os(macOS)
            // xcrun/libxcrun (via the /usr/bin/swift trampoline) is very trigger-happy
            // to add SDKROOT=.../MacOSX.sdk to our invocations. We avoid this by
            // 1) invoking the real swift executable (located with `xcrun -f`) and
            // 2) explicitly removing SDKROOT from the env, as it may be inherited
            // through a parent process (e.g. `swift run xtool`).
            executable = .path(try await Self.swiftURL())
            #else
            executable = .name("swift")
            #endif
            baseArguments = [tool]
        }

        return Configuration(
            executable: executable,
            arguments: .init(baseArguments + resolvedBaseOptions + arguments),
            environment: .inherit.updating(sdkEnvironment),
            platformOptions: .withGracefulShutDown,
        )
    }

    // loosely based on
    // https://github.com/swiftlang/sourcekit-lsp/blob/c55899a/Sources/BuildServerIntegration/ExternalBuildServerAdapter.swift#L92
    private var baseBuildServerArguments: [String] {
        return [
            "experimental-build-server",
            "--disable-automatic-resolution",
            "--scratch-path", ".build/index-build",
            // this requires Swift 6.4 but we need 6.4 on Linux anyway, for the platform toolset fixes
            "--experimental-skip-acquiring-lock",
        ]
    }

    public var buildServerArguments: [String] {
        ["package"] + baseBuildServerArguments + resolvedBaseOptions
    }

    public func buildServerInvocation() async throws -> Subprocess.Configuration {
        try await swiftPMInvocation(forTool: "package", arguments: baseBuildServerArguments)
    }
}

public enum BuildConfiguration: String, CaseIterable, Sendable {
    case debug
    case release

    var swiftBuildValue: String {
        switch self {
        case .debug: "Debug"
        case .release: "Release"
        }
    }
}

public enum BuildSystem: Sendable {
    case swiftPM
    case swiftBuild

    public static func `default`() async throws -> Self {
        if try await SwiftVersion.current.supportsSwiftBuild {
            return .swiftBuild
        } else {
            return .swiftPM
        }
    }

    var pmName: String {
        switch self {
        case .swiftPM: "native"
        case .swiftBuild: "swiftbuild"
        }
    }
}

public enum BuildPlatform: String, Sendable {
    case iOS = "ios"
    case watchOS = "watchos"

    public init(triple: String) throws {
        let components = triple.split(separator: "-")
        guard components.count >= 3, components[1] == "apple" else {
            throw StringError("Expected an Apple iOS or watchOS target triple, got '\(triple)'")
        }
        if components[2].hasPrefix("watchos") {
            self = .watchOS
        } else if components[2].hasPrefix("ios") {
            self = .iOS
        } else {
            throw StringError("Unsupported app platform in target triple '\(triple)'; use iOS or watchOS")
        }
    }

    var packagePlatform: String {
        switch self {
        case .iOS: "iOS"
        case .watchOS: "watchOS"
        }
    }

    var minimumDeploymentTarget: String {
        switch self {
        case .iOS: "13.0"
        case .watchOS: "6.0"
        }
    }

    func sdkName(simulator: Bool) -> String {
        switch self {
        case .iOS: simulator ? "iphonesimulator" : "iphoneos"
        case .watchOS: simulator ? "watchsimulator" : "watchos"
        }
    }

    func supportedPlatform(simulator: Bool) -> String {
        switch self {
        case .iOS: simulator ? "iPhoneSimulator" : "iPhoneOS"
        case .watchOS: simulator ? "WatchSimulator" : "WatchOS"
        }
    }

    func applyBundleMetadata(to info: inout [String: any Sendable], simulator: Bool, application: Bool) {
        info["CFBundleSupportedPlatforms"] = [supportedPlatform(simulator: simulator)]
        switch self {
        case .iOS:
            info["UIRequiredDeviceCapabilities"] = info["UIRequiredDeviceCapabilities"] ?? ["arm64"]
            if application {
                info["LSRequiresIPhoneOS"] = true
            }
        case .watchOS:
            info["UIDeviceFamily"] = [4]
            info.removeValue(forKey: "LSRequiresIPhoneOS")
            info.removeValue(forKey: "UISupportedInterfaceOrientations")
            info.removeValue(forKey: "UISupportedInterfaceOrientations~ipad")
            info.removeValue(forKey: "UILaunchScreen")
        }
    }
}
