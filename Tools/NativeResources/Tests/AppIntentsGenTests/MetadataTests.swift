import Foundation
import XCTest
@testable import AppIntentsGen

final class MetadataTests: XCTestCase {
    private func emit(_ source: String) throws -> [String: Any] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let module = Scanner().scan(source: source, module: "Example")
        try Emitter().emit(module: module, inputs: .init(
            bundleIdentifier: "org.example.app", moduleName: "Example", toolchainVersion: "test",
            deploymentTarget: "17.0", displayName: "Example"
        ), outputDir: directory)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("extract.actionsdata"))) as? [String: Any])
    }

    func testEveryBuilderShortcutAndLiteralPhraseSurvives() throws {
        let data = try emit(#"""
        struct Capture: AppIntent {
            static let title = "Capture"
            @Parameter(title: "Text") var text: String
            @Parameter(title: "URL") var url: URL?
            static var parameterSummary: some ParameterSummary {
                Summary("Save \(\.$text)") { \.$url }
            }
            func perform() async throws -> some IntentResult & ProvidesDialog { .result(dialog: "Saved") }
        }
        struct Shortcuts: AppShortcutsProvider {
            static var appShortcuts: [AppShortcut] {
                AppShortcut(intent: Capture(), phrases: ["Save in \(.applicationName)", "Capture with \(.applicationName)"], shortTitle: "Save", systemImageName: "plus")
                AppShortcut(intent: Capture(), phrases: ["Remember in \(.applicationName)"], shortTitle: "Remember", systemImageName: "bookmark")
            }
        }
        """#)
        let shortcuts = try XCTUnwrap(data["autoShortcuts"] as? [[String: Any]])
        let phrases = shortcuts.flatMap { $0["phraseTemplates"] as? [[String: Any]] ?? [] }.compactMap { $0["key"] as? String }
        XCTAssertEqual(phrases, ["Save in ${applicationName}", "Capture with ${applicationName}", "Remember in ${applicationName}"])
        let actions = try XCTUnwrap(data["actions"] as? [String: [String: Any]])
        let action = try XCTUnwrap(actions["Capture"])
        XCTAssertEqual(action["outputFlags"] as? Int, 4)
        let configuration = try XCTUnwrap(action["actionConfiguration"] as? [String: [String: [String: Any]]])
        let summary = try XCTUnwrap(configuration["actionSummary"]?["wrapper"])
        XCTAssertEqual(summary["otherParameterIdentifiers"] as? [String], ["url"])
        XCTAssertEqual((summary["summaryString"] as? [String: Any])?["formatString"] as? String, "Save ${text}")
        let parameters = try XCTUnwrap(action["parameters"] as? [[String: Any]])
        let urlType = try XCTUnwrap(parameters.last?["valueType"] as? [String: [String: [String: Int]]])
        XCTAssertEqual(urlType["primitive"]?["wrapper"]?["typeIdentifier"], 11)
    }

    func testEntityQueryAndEnumDefaultRetainPickerSemantics() throws {
        let data = try emit(#"""
        struct Item: AppEntity {
            let id: UUID
            static let typeDisplayRepresentation = "Item"
            static let defaultQuery = Items()
        }
        struct Items: EntityQuery {
            func entities(for identifiers: [UUID]) async throws -> [Item] { [] }
            func suggestedEntities() async throws -> [Item] { [] }
        }
        enum Style: String, AppEnum {
            case compact, expanded
            static let typeDisplayRepresentation = "Style"
            static let caseDisplayRepresentations: [Style: DisplayRepresentation] = [.compact: "Compact View", .expanded: "Expanded View"]
        }
        struct Select: WidgetConfigurationIntent {
            static let title = "Select Item"
            @Parameter(title: "Item") var item: Item?
            @Parameter(title: "Style", default: .expanded) var style: Style
        }
        """#)
        let actions = try XCTUnwrap(data["actions"] as? [String: [String: Any]])
        let action = try XCTUnwrap(actions["Select"])
        XCTAssertEqual(action["isDiscoverable"] as? Bool, false)
        XCTAssertEqual((action["visibilityMetadata"] as? [String: Bool])?["isDiscoverable"], true)
        XCTAssertEqual(action["outputFlags"] as? Int, 8)
        let parameters = try XCTUnwrap(action["parameters"] as? [[String: Any]])
        XCTAssertEqual(parameters.first?["dynamicOptionsSupport"] as? Int, 1)
        let specific = try XCTUnwrap(parameters.last?["typeSpecificMetadata"] as? [Any])
        XCTAssertEqual(specific.first as? String, "LNValueTypeSpecificMetadataKeyDefaultValue")
        XCTAssertEqual((specific.last as? [String: [String: String]])?["string"]?["wrapper"], "expanded")
        let entities = try XCTUnwrap(data["entities"] as? [String: [String: Any]])
        XCTAssertEqual(entities["Item"]?["defaultQueryIdentifier"] as? String, "Example.Items")
        let queries = try XCTUnwrap(data["queries"] as? [String: [String: Any]])
        XCTAssertEqual(queries["Items"]?["entityType"] as? String, "Item")
        XCTAssertEqual(queries["Items"]?["capabilities"] as? Int, 66)
        let enums = try XCTUnwrap(data["enums"] as? [[String: Any]])
        let cases = try XCTUnwrap(enums.first?["cases"] as? [[String: Any]])
        let titles = cases.compactMap { ($0["displayRepresentation"] as? [String: [String: Any]])?["title"]?["key"] as? String }
        XCTAssertEqual(titles, ["Compact View", "Expanded View"])
    }

    func testDynamicPhraseFailsInsteadOfPublishingPartialShortcuts() {
        XCTAssertThrowsError(try emit(#"""
        struct Capture: AppIntent { static let title = "Capture" }
        struct Shortcuts: AppShortcutsProvider {
            static var appShortcuts: [AppShortcut] {
                AppShortcut(intent: Capture(), phrases: ["Valid in \(.applicationName)", phraseFromRuntime], shortTitle: "Save", systemImageName: "plus")
            }
        }
        """#))
    }

    func testUnknownParameterTypeFailsInsteadOfBecomingString() {
        XCTAssertThrowsError(try emit("""
        struct Capture: AppIntent {
            static let title = "Capture"
            @Parameter(title: "Value") var value: UnknownEntity
        }
        """))
    }

    func testPlatformGuardsExcludeUnavailableIntents() {
        let source = """
        #if canImport(ActivityKit) && os(iOS)
        struct Timer: LiveActivityIntent { static let title = "Timer" }
        #elseif os(watchOS)
        struct Select: WidgetConfigurationIntent { static let title = "Select" }
        #endif
        """
        XCTAssertEqual(Scanner(platform: "ios").scan(source: source).intents.map(\.typeName), ["Timer"])
        XCTAssertEqual(Scanner(platform: "watchos").scan(source: source).intents.map(\.typeName), ["Select"])
    }

    func testUnknownBuildFlagCannotSilentlyChooseIntentBranch() {
        XCTAssertThrowsError(try emit("""
        #if CUSTOM_INTENT_FEATURE
        struct Capture: AppIntent { static let title = "Capture" }
        #endif
        """))
    }
}
