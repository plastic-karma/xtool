import AppIntentsGen
import Foundation

@main
struct AppIntentsCLI {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("xtool-appintents-gen: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var options: [String: String] = [:]
        var sources: [String] = []
        var isExtension = false
        var index = 0
        let accepted: Set<String> = ["--module", "--bundle-id", "--display-name", "--output", "--source", "--deployment-target", "--platform"]
        while index < arguments.count {
            let option = arguments[index]
            if option == "--app-extension" {
                isExtension = true
                index += 1
                continue
            }
            guard accepted.contains(option), index + 1 < arguments.count else {
                throw MetadataError("Usage: xtool-appintents-gen --module NAME --bundle-id ID --display-name NAME --output DIR --source FILE... [--deployment-target VERSION] [--platform ios|watchos] [--app-extension]")
            }
            if option == "--source" { sources.append(arguments[index + 1]) }
            else {
                guard options[option] == nil else { throw MetadataError("Duplicate option \(option)") }
                options[option] = arguments[index + 1]
            }
            index += 2
        }
        func required(_ name: String) throws -> String {
            guard let value = options[name], !value.isEmpty else { throw MetadataError("\(name) is required") }
            return value
        }
        let moduleName = try required("--module")
        guard moduleName.first?.isLetter == true || moduleName.first == "_",
              moduleName.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 }) else {
            throw MetadataError("Module must be an ASCII Swift identifier")
        }
        guard !sources.isEmpty else { throw MetadataError("At least one --source FILE is required") }
        let platform = options["--platform"] ?? "ios"
        guard ["ios", "watchos"].contains(platform) else { throw MetadataError("Unsupported platform \(platform)") }
        let inputs = Emitter.Inputs(
            bundleIdentifier: try required("--bundle-id"), moduleName: moduleName,
            toolchainVersion: "xtool-native-appintents-1", deploymentTarget: options["--deployment-target"] ?? "",
            platformFamily: platform, isAppExtension: isExtension, displayName: try required("--display-name")
        )
        let output = URL(fileURLWithPath: try required("--output"))
        var module = ScannedModule()
        let scanner = Scanner(platform: platform)
        for source in Set(sources).sorted() {
            let text = try String(contentsOfFile: source, encoding: .utf8)
            var scanned = scanner.scan(source: text, module: moduleName)
            scanned.diagnostics = scanned.diagnostics.map { "\(source): \($0)" }
            module.merge(scanned)
        }
        try Emitter().emit(module: module, inputs: inputs, outputDir: output)
        let result: [String: Any] = [
            "actions": module.intents.map(\.typeName).sorted(), "entities": module.entities.map(\.typeName).sorted(),
            "enums": module.enums.map(\.typeName).sorted(), "queries": module.queries.map(\.typeName).sorted(),
            "shortcuts": module.shortcutsProviders.flatMap(\.shortcuts).count,
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
