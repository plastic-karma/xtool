import Foundation
import Testing
@testable import PackLib
@testable import XToolSupport

@Test func swiftPMDirectoryUsesXDGConfigHome() throws {
    let directory = try DarwinSDK.swiftPMDirectory(
        environment: ["XDG_CONFIG_HOME": "/xdg/config"],
        homeDirectory: URL(fileURLWithPath: "/home/test")
    )

    #expect(directory.path == "/xdg/config/swiftpm")
}

@Test func swiftPMDirectoryFallsBackToHomeDirectory() throws {
    let directory = try DarwinSDK.swiftPMDirectory(
        environment: [:],
        homeDirectory: URL(fileURLWithPath: "/home/test")
    )

    #expect(directory.path == "/home/test/.swiftpm")
}

@Test func swiftPMDirectoryRejectsRelativeXDGConfigHome() {
    #expect(throws: StringError.self) {
        try DarwinSDK.swiftPMDirectory(
            environment: ["XDG_CONFIG_HOME": "relative/config"],
            homeDirectory: URL(fileURLWithPath: "/home/test")
        )
    }
}

@Test func temporaryDarwinSDKBundleUsesSwiftSDKsDirectory() throws {
    let configDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DarwinSDKTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: configDirectory) }

    let environment = ["XDG_CONFIG_HOME": configDirectory.path]
    let sdksDirectory = configDirectory.appending(path: "swiftpm/swift-sdks")
    let temporaryURL = sdksDirectory.appendingPathComponent("darwin.artifactbundle.tmp", isDirectory: true)
    let installedBundle = sdksDirectory.appending(path: "darwin.artifactbundle")
    try FileManager.default.createDirectory(at: installedBundle, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: false)

    do {
        let temporaryBundle = try DarwinSDK.prepareTemporaryBundle(environment: environment)
        #expect(temporaryBundle.url == temporaryURL)
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))

        try FileManager.default.createDirectory(at: temporaryBundle.url, withIntermediateDirectories: false)
        #expect(DarwinSDK(bundle: temporaryBundle.url)?.version == "develop")
    }

    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    #expect(FileManager.default.fileExists(atPath: installedBundle.path))
}

@Test func nativeMacroRoutingRequiresSDKUpgrade() throws {
    let bundle = FileManager.default.temporaryDirectory
        .appendingPathComponent("SDKUpgrade-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    try FileManager.default.createDirectory(
        at: bundle.appendingPathComponent("Xcode.app"),
        withIntermediateDirectories: true
    )
    let versionFile = bundle.appendingPathComponent("darwin-sdk-version.txt")
    // Epoch 4 predates native Foundation/SwiftData plugin routing.
    try Data("epoch=4,darwinTools=1.1.0,oam=1.3.0\n".utf8).write(to: versionFile)
    let oldSDK = try #require(DarwinSDK(bundle: bundle))
    #expect(oldSDK.flavor == .normal)
    #expect(!oldSDK.isUpToDate())

    try Data("\(SDKBuilder.currentSDKVersion)\n".utf8).write(to: versionFile)
    let updatedSDK = try #require(DarwinSDK(bundle: bundle))
    #expect(updatedSDK.isUpToDate())
}

@Test func watchSDKRetainsHeadersRuntimeAndTestingLibraries() {
    for path in [
        "Contents/Developer/Platforms/WatchOS.platform/Info.plist",
        "Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.5.sdk/usr/include/watch.h",
        "Contents/Developer/Platforms/WatchSimulator.platform/Developer/SDKs/WatchSimulator26.5.sdk/usr/lib/libSystem.tbd",
        "Contents/Developer/Platforms/WatchOS.platform/Developer/Library/Frameworks/Testing.framework/Testing",
        "Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/watchos/libswift_Concurrency.dylib",
        "Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/17/lib/darwin/libclang_rt.watchos.a",
    ] {
        #expect(SDKEntry.wanted.matches(path.split(separator: "/")[...]), "\(path)")
    }
    #expect(!SDKEntry.wanted.matches(
        "Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS.sdk".split(separator: "/")[...]
    ))
}

@Test func watchSDKArchitecturesComeFromSelectedSDKTarget() throws {
    let settings = Data("""
    {
        "SupportedTargets": {
            "watchos": {"Archs": ["arm64_32"]},
            "watchsimulator": {"Archs": ["arm64", "x86_64"]}
        }
    }
    """.utf8)
    #expect(try SDKBuilder.supportedArchitectures(in: settings, target: "watchos") == ["arm64_32"])
    #expect(try SDKBuilder.supportedArchitectures(in: settings, target: "watchsimulator") == ["arm64", "x86_64"])
    #expect(throws: (any Error).self) {
        try SDKBuilder.supportedArchitectures(in: settings, target: "unknown")
    }
}

@Test(arguments: ["llvm-lipo", "llvm-install-name-tool"])
func customToolsetRequiresUniversalPackagingTools(missing: String) throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolsetValidation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let toolset = temporary.appending(path: "toolset")
    let binaries = toolset.appending(path: "bin")
    try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
    for name in ["ld64.lld", "libtool", "dsymutil", "llvm-lipo", "llvm-install-name-tool"] where name != missing {
        let executable = binaries.appending(path: name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    do {
        try SDKBuilder.ToolingSources(toolset: toolset).validate(output: temporary.appending(path: "sdk"))
        Issue.record("Accepted a toolset missing \(missing)")
    } catch {
        #expect(String(describing: error).contains(missing))
    }
}
