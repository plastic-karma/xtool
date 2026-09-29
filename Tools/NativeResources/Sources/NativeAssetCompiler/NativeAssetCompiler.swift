import AssetKit
import Foundation

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private enum Platform: String { case ios, watchos }

private struct IconSlot {
    let name: String
    let idiom: String
    let points: String
    let scale: Int
    let inCAR: Bool
    var pixels: Int { Int(Double(points)! * Double(scale)) }
    var base: String { "\(name)\(points)x\(points)" }
    func filename(_ appearance: String) -> String {
        base + (appearance.isEmpty ? "" : "-\(appearance)") + (scale == 1 ? "" : "@\(scale)x") + ".png"
    }
    func entry(_ appearance: String) -> [String: Any] {
        var value: [String: Any] = ["idiom": idiom, "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename(appearance)]
        if !appearance.isEmpty { value["appearances"] = [["appearance": "luminosity", "value": appearance]] }
        return value
    }
}

@main
private struct NativeAssetCompiler {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 5, let platform = Platform(rawValue: args[1]) else {
            throw Failure("Usage: xtool-native-assets CATALOG ios|watchos OUTPUT --deployment-target VERSION [--app-icon NAME] [--catalog CATALOG]...")
        }
        var catalogs = [URL(fileURLWithPath: args[0]).standardizedFileURL.resolvingSymlinksInPath()]
        let output = URL(fileURLWithPath: args[2]).standardizedFileURL.resolvingSymlinksInPath()
        var deployment: String?
        var requestedIcon: String?
        var index = 3
        while index < args.count {
            guard index + 1 < args.count else { throw Failure("Missing value for \(args[index])") }
            switch args[index] {
            case "--deployment-target": deployment = args[index + 1]
            case "--app-icon": requestedIcon = args[index + 1]
            case "--catalog": catalogs.append(URL(fileURLWithPath: args[index + 1]).standardizedFileURL.resolvingSymlinksInPath())
            default: throw Failure("Unknown option \(args[index])")
            }
            index += 2
        }
        guard let deployment, !deployment.isEmpty else { throw Failure("--deployment-target is required") }
        let fm = FileManager.default
        for catalog in catalogs where output == catalog || output.path.hasPrefix(catalog.path + "/") {
            throw Failure("Output must not be inside a source catalog")
        }
        if fm.fileExists(atPath: output.path), !(try fm.contentsOfDirectory(atPath: output.path)).isEmpty {
            throw Failure("Output must be empty; refusing to overwrite existing files")
        }
        let scratch = fm.temporaryDirectory.appendingPathComponent("xtool-assets-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let staged = scratch.appendingPathComponent("Assets.xcassets")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        var assetNames = Set<String>()
        var icons: [URL] = []
        for catalog in catalogs {
            try stage(catalog, into: staged, names: &assetNames, icons: &icons)
        }
        guard icons.count <= 1 else { throw Failure("Multiple appiconsets are not supported; refusing to discard alternate icons") }
        if let requestedIcon, icons.first?.deletingPathExtension().lastPathComponent != requestedIcon {
            throw Failure("Requested app icon \(requestedIcon) is not the catalog's unique appiconset")
        }
        var looseFiles: [URL] = []
        var slots: [IconSlot] = []
        var iconName: String?
        var appearances: [String] = []
        if let icon = icons.first {
            iconName = icon.deletingPathExtension().lastPathComponent
            slots = iconSlots(name: iconName!, platform: platform)
            var contents = try jsonObject(icon.appendingPathComponent("Contents.json"))
            guard let images = contents["images"] as? [[String: Any]], !images.isEmpty else { throw Failure("App icon has no images") }
            var generated: [[String: Any]] = []
            for image in images {
                let appearanceValues = image["appearances"] as? [[String: String]] ?? []
                guard appearanceValues.count <= 1,
                      appearanceValues.allSatisfy({ $0["appearance"] == "luminosity" && ["dark", "tinted"].contains($0["value"] ?? "") }) else {
                    throw Failure("Unsupported app icon appearance: \(appearanceValues)")
                }
                let appearance = appearanceValues.first?["value"] ?? ""
                guard !appearances.contains(appearance),
                      image["idiom"] as? String == "universal",
                      image["platform"] as? String == platform.rawValue,
                      image["size"] as? String == "1024x1024",
                      let filename = image["filename"] as? String,
                      !filename.contains("/"), filename.lowercased().hasSuffix(".png") else {
                    throw Failure("Expected unique universal \(platform.rawValue) 1024x1024 PNG masters; refusing to discard variants")
                }
                appearances.append(appearance)
                let source = icon.appendingPathComponent(filename)
                let metadata = try magick(["identify", "-format", "%w|%h|%[opaque]|%[colorspace]", source.path])
                guard metadata == "1024|1024|True|sRGB" || metadata == "1024|1024|True|Gray" else {
                    throw Failure("Icon must be opaque 1024x1024 sRGB or grayscale; found \(metadata)")
                }
                let sourceBytes = try Data(contentsOf: source)
                var written = Set<String>()
                for slot in slots where written.insert(slot.filename(appearance)).inserted {
                    let destination = icon.appendingPathComponent(slot.filename(appearance))
                    if slot.pixels == 1024 {
                        try sourceBytes.write(to: destination)
                    } else {
                        _ = try magick([source.path, "-filter", "Lanczos", "-resize", "\(slot.pixels)x\(slot.pixels)", "-alpha", "off", "-define", "png:color-type=2", "-depth", "8", destination.path])
                    }
                    if platform == .ios { looseFiles.append(destination) }
                }
                generated += slots.filter(\.inCAR).map { $0.entry(appearance) }
            }
            guard appearances.contains("") else { throw Failure("App icon requires an unqualified default master") }
            contents["images"] = generated
            try JSONSerialization.data(withJSONObject: contents, options: [.sortedKeys]).write(to: icon.appendingPathComponent("Contents.json"))
        }
        let result = try await XCAssetCompiler(deploymentTarget: deployment).compile(catalog: staged)
        var additions: [String: Any] = result.appIconBundle?.infoPlistAdditions.mapValues { $0 as Any } ?? [:]
        if let iconName, platform == .ios {
            func names(_ idiom: String) -> [String] { Array(Set(slots.filter { $0.idiom == idiom }.map(\.base))).sorted() }
            additions["CFBundleIcons"] = ["CFBundlePrimaryIcon": ["CFBundleIconName": iconName, "CFBundleIconFiles": names("iphone")]]
            additions["CFBundleIcons~ipad"] = ["CFBundlePrimaryIcon": ["CFBundleIconName": iconName, "CFBundleIconFiles": names("ipad")]]
            additions["CFBundleIconFiles"] = Array(Set(names("iphone") + names("ipad"))).sorted()
        }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        try result.carData.write(to: output.appendingPathComponent("Assets.car"))
        try PropertyListSerialization.data(fromPropertyList: additions, format: .xml, options: 0).write(to: output.appendingPathComponent("asset-info.plist"))
        for file in looseFiles { try fm.copyItem(at: file, to: output.appendingPathComponent(file.lastPathComponent)) }
        let manifest: [String: Any] = ["schemaVersion": 1, "platform": platform.rawValue, "deploymentTarget": deployment, "assets": assetNames.sorted(), "iconAppearances": appearances, "looseFiles": looseFiles.map(\.lastPathComponent).sorted()]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: output.appendingPathComponent("asset-manifest.json"))
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    private static func stage(_ directory: URL, into destination: URL, names: inout Set<String>, icons: inout [URL]) throws {
        let fm = FileManager.default
        let metadata = directory.appendingPathComponent("Contents.json")
        if fm.fileExists(atPath: metadata.path) {
            let json = try jsonObject(metadata)
            if let properties = json["properties"] as? [String: Any], !properties.isEmpty {
                throw Failure("Unsupported catalog folder properties at \(directory.path); refusing to lose namespace or resource tags")
            }
        }
        for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]).sorted(by: { $0.path < $1.path }) {
            guard try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                guard child.lastPathComponent == "Contents.json" || child.lastPathComponent == ".DS_Store" else { throw Failure("Unexpected catalog file \(child.path)") }
                continue
            }
            if child.pathExtension.isEmpty {
                try stage(child, into: destination, names: &names, icons: &icons)
                continue
            }
            guard ["imageset", "colorset", "appiconset"].contains(child.pathExtension) else { throw Failure("Unsupported asset type: \(child.pathExtension)") }
            let name = child.deletingPathExtension().lastPathComponent
            guard names.insert(name).inserted else { throw Failure("Duplicate catalog asset \(name)") }
            try validateAsset(child)
            let stagedChild = destination.appendingPathComponent(child.lastPathComponent)
            try fm.copyItem(at: child, to: stagedChild)
            if child.pathExtension == "appiconset" { icons.append(stagedChild) }
        }
    }

    private static func validateAsset(_ directory: URL) throws {
        let contents = try jsonObject(directory.appendingPathComponent("Contents.json"))
        let color = directory.pathExtension == "colorset"
        let icon = directory.pathExtension == "appiconset"
        let member = color ? "colors" : "images"
        guard Set(contents.keys).isSubset(of: ["info", member]),
              let variants = contents[member] as? [[String: Any]] else {
            throw Failure("Unsupported asset properties in \(directory.path)")
        }
        let allowed: Set<String>
        if color {
            allowed = ["idiom", "appearances", "display-gamut", "color"]
        } else if icon {
            allowed = ["idiom", "appearances", "filename", "platform", "size"]
        } else {
            allowed = ["idiom", "appearances", "display-gamut", "filename", "scale"]
        }
        for variant in variants {
            guard Set(variant.keys).isSubset(of: allowed) else {
                throw Failure("Unsupported asset variant properties in \(directory.path)")
            }
            if let appearances = variant["appearances"] {
                guard let values = appearances as? [[String: String]], values.count == 1,
                      let value = values.first, Set(value.keys) == ["appearance", "value"],
                      value["appearance"] == "luminosity",
                      (icon ? ["dark", "tinted"] : ["dark"]).contains(value["value"] ?? "") else {
                    throw Failure("Unsupported appearance in \(directory.path)")
                }
            }
            if let filename = variant["filename"] as? String,
               filename.contains("/") || filename == ".." {
                throw Failure("Asset filenames must be local to their asset set")
            }
            if color, let value = variant["color"] as? [String: Any] {
                guard Set(value.keys) == ["color-space", "components"],
                      ["srgb", "display-p3"].contains(value["color-space"] as? String ?? ""),
                      let components = value["components"] as? [String: Any],
                      Set(components.keys) == ["red", "green", "blue", "alpha"] else {
                    throw Failure("Unsupported color representation in \(directory.path)")
                }
            }
        }
    }

    private static func iconSlots(name: String, platform: Platform) -> [IconSlot] {
        func slot(_ idiom: String, _ points: String, _ scale: Int, _ inCAR: Bool) -> IconSlot { IconSlot(name: name, idiom: idiom, points: points, scale: scale, inCAR: inCAR) }
        if platform == .watchos { return [slot("watch", "1024", 1, true)] }
        var slots: [IconSlot] = []
        for points in ["20", "29", "40", "60"] {
            for scale in [2, 3] { slots.append(slot("iphone", points, scale, points == "60")) }
        }
        for points in ["20", "29", "40", "76"] {
            for scale in [1, 2] { slots.append(slot("ipad", points, scale, points == "76")) }
        }
        return slots + [slot("ipad", "83.5", 2, false), slot("ios-marketing", "1024", 1, true)]
    }

    private static func jsonObject(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw Failure("Expected JSON object at \(url.path)") }
        return value
    }

    private static func magick(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["magick"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw Failure("ImageMagick failed with status \(process.terminationStatus)") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
