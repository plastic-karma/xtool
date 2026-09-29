import Foundation
import Testing
@testable import PackLib

@Test func watchBundleMetadataRemovesIncompatiblePhoneSettings() {
    var info: [String: any Sendable] = [
        "UIDeviceFamily": [1, 2],
        "LSRequiresIPhoneOS": true,
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
        "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationLandscapeLeft"],
        "UILaunchScreen": [:] as [String: String],
        "WKCompanionAppBundleIdentifier": "com.example.Phone",
        "NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"],
    ]
    BuildPlatform.watchOS.applyBundleMetadata(to: &info, simulator: false, application: false)

    #expect(info["UIDeviceFamily"] as? [Int] == [4])
    #expect(info["CFBundleSupportedPlatforms"] as? [String] == ["WatchOS"])
    #expect(info["LSRequiresIPhoneOS"] == nil)
    #expect(info["UISupportedInterfaceOrientations"] == nil)
    #expect(info["UISupportedInterfaceOrientations~ipad"] == nil)
    #expect(info["UILaunchScreen"] == nil)
    #expect(info["WKCompanionAppBundleIdentifier"] as? String == "com.example.Phone")
    #expect(info["NSExtension"] as? [String: String] == [
        "NSExtensionPointIdentifier": "com.apple.widgetkit-extension",
    ])
}

@Test func phoneBundleMetadataPreservesRequestedCapabilitiesAndFamilies() {
    var info: [String: any Sendable] = [
        "UIRequiredDeviceCapabilities": ["arm64", "gps"],
        "UIDeviceFamily": [1],
    ]
    BuildPlatform.iOS.applyBundleMetadata(to: &info, simulator: true, application: true)

    #expect(info["UIRequiredDeviceCapabilities"] as? [String] == ["arm64", "gps"])
    #expect(info["UIDeviceFamily"] as? [Int] == [1])
    #expect(info["LSRequiresIPhoneOS"] as? Bool == true)
    #expect(info["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneSimulator"])
}

@Test func iOSExtensionsDeclareRequiredArchitectureForAppStoreValidation() {
    var info: [String: any Sendable] = [
        "NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"],
    ]
    BuildPlatform.iOS.applyBundleMetadata(to: &info, simulator: false, application: false)

    #expect(info["UIRequiredDeviceCapabilities"] as? [String] == ["arm64"])
    #expect(info["LSRequiresIPhoneOS"] == nil)
}

@Test func companionBundlesNestWithinWatchAppWhileStandaloneBundlesStayAtRoot() {
    func product(_ name: String, platform: BuildPlatform, type: Plan.ProductType) -> Plan.Product {
        Plan.Product(
            type: type,
            platform: platform,
            product: name,
            deploymentTarget: platform == .iOS ? "17.0" : "10.0",
            bundleID: "com.example.\(name)",
            infoPlist: [:],
            resources: []
        )
    }
    let phone = product("Phone", platform: .iOS, type: .application)
    let widget = product("Widget", platform: .iOS, type: .appExtension)
    var watch = product("Watch", platform: .watchOS, type: .application)
    var watchWidget = product("WatchWidget", platform: .watchOS, type: .appExtension)
    let root = URL(fileURLWithPath: "/Payload/Phone.app", isDirectory: true)

    #expect(watch.directory(inApp: root).standardizedFileURL.path == root.path)
    #expect(watchWidget.directory(inApp: root).path == "/Payload/Phone.app/PlugIns/WatchWidget.appex")

    watch.watchAppProduct = "Watch"
    watchWidget.watchAppProduct = "Watch"
    let plan = Plan(app: phone, extensions: [widget], watchApp: watch, watchExtensions: [watchWidget])
    let paths = plan.allProducts.map { $0.directory(inApp: root).standardizedFileURL.path }
    #expect(paths == [
        "/Payload/Phone.app",
        "/Payload/Phone.app/PlugIns/Widget.appex",
        "/Payload/Phone.app/Watch/Watch.app",
        "/Payload/Phone.app/Watch/Watch.app/PlugIns/WatchWidget.appex",
    ])
}

@Test func companionBuildSeparatesPlatformAndPreservesRequestedArchitecture() async throws {
    let phone = try await BuildSettings(
        configuration: .release,
        triple: "arm64-apple-ios",
        buildSystem: .swiftPM,
        watchTriple: "arm64-apple-watchos"
    )
    let watch = try await phone.forPlatform(.watchOS)
    let companionBuilds = try await phone.companionWatchBuildSettings()

    #expect(phone.platform == .iOS)
    #expect(watch.platform == .watchOS)
    #expect(watch.triple == "arm64-apple-watchos")
    #expect(watch.configuration == .release)
    #expect(phone.scratchPath != watch.scratchPath)
    #expect(watch.binaryDirectory.path.hasSuffix("/xtool-watchos/arm64/arm64-apple-watchos/release"))
    #expect(companionBuilds.map(\.triple) == ["arm64-apple-watchos"])

    let invalid = try await BuildSettings(
        configuration: .debug,
        triple: "arm64-apple-ios",
        buildSystem: .swiftPM,
        watchTriple: "arm64-apple-watchos-simulator"
    )
    await #expect(throws: (any Error).self) {
        try await invalid.forPlatform(.watchOS)
    }
}

@Test func defaultCompanionBuildIncludesBothDeviceArchitecturesButOnlyOneSimulatorArchitecture() async throws {
    let device = try await BuildSettings(
        configuration: .release,
        triple: "arm64-apple-ios",
        buildSystem: .swiftPM
    )
    let deviceBuilds = try await device.companionWatchBuildSettings()
    #expect(deviceBuilds.map(\.triple) == ["arm64_32-apple-watchos", "arm64-apple-watchos"])
    #expect(Set(deviceBuilds.map(\.scratchPath)).count == 2)
    #expect(Set(deviceBuilds.map(\.binaryDirectory)).count == 2)

    let simulator = try await BuildSettings(
        configuration: .debug,
        triple: "arm64-apple-ios-simulator",
        buildSystem: .swiftPM
    )
    let simulatorBuilds = try await simulator.companionWatchBuildSettings()
    #expect(simulatorBuilds.map(\.triple) == ["arm64-apple-watchos-simulator"])
}

@Test func watchArm64DeploymentFloorDoesNotRaiseOtherArchitectures() async throws {
    let arm64 = try await BuildSettings(
        configuration: .release, triple: "arm64-apple-watchos", buildSystem: .swiftPM
    )
    #expect(arm64.deploymentTarget(for: "10.0") == "26.0")
    #expect(arm64.deploymentTarget(for: "26.5") == "26.5")
    for triple in ["arm64_32-apple-watchos", "arm64-apple-watchos-simulator", "arm64-apple-ios"] {
        let settings = try await BuildSettings(configuration: .release, triple: triple, buildSystem: .swiftPM)
        #expect(settings.deploymentTarget(for: "10.0") == "10.0")
    }
}
