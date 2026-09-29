import Foundation

public struct MetadataError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Derived from PR #217 by foobisdweik. Schema corrections are grounded in
/// Xcode-generated OTodo and LeadTrack metadata (see provenance.json). Reference
/// archives are diagnostic evidence only; all values come from scanned source.
public struct Emitter: Sendable {
    public static let actionsDataVersion = 1
    public static let versionJSONVersion = "3.0"

    public struct Inputs: Sendable {
        public let bundleIdentifier: String
        public let moduleName: String
        public let toolchainVersion: String
        public let deploymentTarget: String
        public let platformFamily: String
        public let isAppExtension: Bool
        public let displayName: String
        public init(bundleIdentifier: String, moduleName: String, toolchainVersion: String,
                    deploymentTarget: String, platformFamily: String = "iOS",
                    isAppExtension: Bool = false, displayName: String = "") {
            self.bundleIdentifier = bundleIdentifier
            self.moduleName = moduleName
            self.toolchainVersion = toolchainVersion
            self.deploymentTarget = deploymentTarget
            self.platformFamily = platformFamily
            self.isAppExtension = isAppExtension
            self.displayName = displayName
        }
    }

    public init() {}

    public func emit(module: ScannedModule, inputs: Inputs, outputDir: URL) throws {
        guard module.diagnostics.isEmpty else { throw MetadataError(module.diagnostics.joined(separator: "\n")) }
        guard module.shortcutsProviders.count <= 1 else { throw MetadataError("Multiple AppShortcutsProvider declarations in one bundle") }
        var actions: [String: Any] = [:]
        for intent in module.intents {
            guard actions[intent.typeName] == nil else { throw MetadataError("Duplicate intent \(intent.typeName)") }
            actions[intent.typeName] = try action(intent, module: module, inputs: inputs)
        }
        var entities: [String: Any] = [:]
        for entity in module.entities {
            guard entities[entity.typeName] == nil else { throw MetadataError("Duplicate entity \(entity.typeName)") }
            guard let queryName = entity.defaultQuery,
                  module.queries.contains(where: { $0.typeName == queryName && $0.entityType == entity.typeName }) else {
                throw MetadataError("\(entity.typeName): default query is missing from source inputs")
            }
            entities[entity.typeName] = entityDictionary(entity, inputs: inputs)
        }
        var queries: [String: Any] = [:]
        for query in module.queries {
            guard queries[query.typeName] == nil else { throw MetadataError("Duplicate query \(query.typeName)") }
            guard query.protocolNames == ["EntityQuery"], query.hasSuggestedEntities else {
                throw MetadataError("\(query.typeName): only EntityQuery with suggestedEntities is supported")
            }
            guard module.entities.contains(where: { $0.typeName == query.entityType && $0.defaultQuery == query.typeName }) else {
                throw MetadataError("\(query.typeName): query must be the default query of a scanned entity")
            }
            queries[query.typeName] = queryDictionary(query, inputs: inputs)
        }
        guard Set(module.enums.map(\.typeName)).count == module.enums.count else { throw MetadataError("Duplicate AppEnum declaration") }
        let provider = module.shortcutsProviders.first
        for shortcut in provider?.shortcuts ?? [] {
            guard actions[shortcut.intentTypeName] != nil else { throw MetadataError("Shortcut references unknown intent \(shortcut.intentTypeName)") }
        }
        var payload: [String: Any] = [
            "version": Self.actionsDataVersion,
            "generator": ["name": "xtool-appintents-gen", "version": inputs.toolchainVersion],
            "shortcutTileColor": 14, "actions": actions, "entities": entities,
            "enums": try module.enums.map { try enumDictionary($0, inputs: inputs) }, "queries": queries,
            "autoShortcuts": (provider?.shortcuts ?? []).map(shortcutDictionary),
            "negativePhrases": [Any](), "assistantEntities": [Any](), "assistantIntents": [Any](),
            "assistantIntentNegativePhrases": [Any](),
        ]
        if let provider { payload["autoShortcutProviderMangledName"] = mangled(provider.typeName, provider.module, provider.kind, inputs) }
        if !module.packages.isEmpty { throw MetadataError("AppIntentsPackage aggregation is unsupported; pass declarations for the actual bundle") }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let version = try JSONSerialization.data(withJSONObject: ["version": Self.versionJSONVersion, "toolsVersion": inputs.toolchainVersion], options: [.sortedKeys])
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try data.write(to: outputDir.appendingPathComponent("extract.actionsdata"), options: .atomic)
        try version.write(to: outputDir.appendingPathComponent("version.json"), options: .atomic)
    }

    private func action(_ intent: ScannedIntent, module: ScannedModule, inputs: Inputs) throws -> [String: Any] {
        guard let title = intent.title else { throw MetadataError("\(intent.typeName): missing literal title") }
        guard !intent.returnsValue else { throw MetadataError("\(intent.typeName): ReturnsValue output type metadata is not supported") }
        guard intent.categoryName == nil else { throw MetadataError("\(intent.typeName): categoryName metadata is unsupported") }
        let configuration = intent.protocolNames.contains("WidgetConfigurationIntent") || intent.protocolNames.contains("ControlConfigurationIntent")
        let visibility = intent.isDiscoverable ?? true
        let name = mangled(intent.typeName, intent.module, intent.kind, inputs)
        let protocols = try SystemProtocols.resolve(for: intent.protocolNames)
        let protocolMetadata: [Any] = protocols.flatMap { [$0, ["empty": [String: Any]()]] as [Any] }
        var value: [String: Any] = [
            "identifier": intent.typeName, "fullyQualifiedTypeName": qualified(intent.typeName, intent.module, inputs),
            "mangledTypeName": name, "mangledTypeNameV2": name,
            "mangledTypeNameByBundleIdentifier": [String: Any](), "mangledTypeNameByBundleIdentifierV2": [String: Any](),
            "title": localizable(title), "visibilityMetadata": visibilityMetadata(visibility),
            "availabilityAnnotations": availability, "isDiscoverable": configuration ? false : visibility,
            "isAuthPolExplicit": false, "authenticationPolicy": 0, "openAppWhenRun": intent.openAppWhenRun ?? false,
            "outputFlags": configuration ? 8 : (intent.providesDialog ? 4 : 0), "presentationStyle": 0, "supportedModes": 1,
            "requiredCapabilities": [Any](), "effectiveBundleIdentifiers": [Any](),
            "systemProtocols": protocols, "systemProtocolMetadata": protocolMetadata, "systemProtocolMetadataV2": protocolMetadata,
            "typeSpecificMetadata": [Any](), "assistantDefinedSchemas": [Any](), "assistantDefinedSchemaTraits": [Any](),
            "parameters": try intent.parameters.map { try parameter($0, module: module) },
        ]
        if let description = intent.descriptionText {
            value["descriptionMetadata"] = ["descriptionText": localizable(description), "searchKeywords": [Any]()] as [String: Any]
        }
        if let summary = intent.summary {
            let known = Set(intent.parameters.map(\.propertyName))
            guard Set(summary.parameters + summary.otherParameters).isSubset(of: known) else { throw MetadataError("\(intent.typeName): summary references an unknown parameter") }
            value["actionConfiguration"] = ["actionSummary": ["wrapper": [
                "otherParameterIdentifiers": summary.otherParameters,
                "summaryString": ["formatString": summary.formatString, "parameterIdentifiers": summary.parameters] as [String: Any],
            ] as [String: Any]]]
        }
        return value
    }

    private func parameter(_ parameter: ScannedParameter, module: ScannedModule) throws -> [String: Any] {
        var type = parameter.typeName
        if type.hasSuffix("?") { type.removeLast() }
        for prefix in ["Optional<", "Swift.Optional<"] where type.hasPrefix(prefix) && type.hasSuffix(">") {
            type = String(type.dropFirst(prefix.count).dropLast())
        }
        type = type.split(separator: ".").last.map(String.init) ?? type
        let enumeration = module.enums.first { $0.typeName == type }
        let entity = module.entities.first { $0.typeName == type }
        let valueType: [String: Any]
        var inputs: [[String: Any]] = []
        if entity != nil {
            valueType = entityValueType(type)
        } else if enumeration != nil {
            valueType = ["linkEnumeration": ["wrapper": ["identifier": type]]]
        } else if type == "String" {
            valueType = primitive(0)
            inputs = [primitive(2), primitive(0), ["array": ["wrapper": ["capabilities": 3, "memberValueType": primitive(2)] as [String: Any]]]]
        } else if type == "URL" {
            valueType = primitive(11)
            inputs = [primitive(0), primitive(11)]
        } else { throw MetadataError("\(parameter.propertyName): unsupported parameter type \(parameter.typeName)") }
        var specific: [Any] = []
        if let expression = parameter.defaultValueExpression {
            let literal: String
            if let enumeration {
                let name = expression.split(separator: ".").last.map(String.init) ?? expression
                guard expression.contains("."), enumeration.cases.contains(name) else { throw MetadataError("\(parameter.propertyName): unknown enum default \(expression)") }
                literal = enumeration.rawValues[name] ?? name
            } else if type == "String", let decoded = try? JSONDecoder().decode(String.self, from: Data(expression.utf8)) {
                literal = decoded
            } else { throw MetadataError("\(parameter.propertyName): unsupported default \(expression)") }
            specific = ["LNValueTypeSpecificMetadataKeyDefaultValue", ["string": ["wrapper": literal]]]
        }
        var value: [String: Any] = [
            "name": parameter.propertyName, "isOptional": parameter.isOptional, "isInput": false,
            "capabilities": enumeration == nil ? 0 : 1, "dynamicOptionsSupport": entity == nil ? 0 : 1,
            "inputConnectionBehavior": 0, "title": localizable(parameter.title ?? parameter.propertyName),
            "valueType": valueType, "resolvableInputTypes": inputs.map { ["kindValue": 0, "valueType": $0] as [String: Any] },
            "typeSpecificMetadata": specific,
        ]
        if let description = parameter.descriptionText { value["parameterDescription"] = localizable(description) }
        // requestValueDialog is a runtime IntentParameter value; Xcode's metadata
        // does not serialize it. It remains in the compiled application code.
        return value
    }

    private func entityDictionary(_ entity: ScannedEntity, inputs: Inputs) -> [String: Any] {
        [
            "typeName": entity.typeName, "fullyQualifiedTypeName": qualified(entity.typeName, entity.module, inputs),
            "mangledTypeName": mangled(entity.typeName, entity.module, entity.kind, inputs),
            "mangledTypeNameByBundleIdentifier": [String: Any](),
            "displayTypeName": localizable(entity.title!),
            "defaultQueryIdentifier": qualified(entity.defaultQuery!, entity.module, inputs),
            "assistantDefinedSchemas": [Any](), "availabilityAnnotations": availability,
            "effectiveBundleIdentifiers": [Any](), "properties": [Any](), "requiredCapabilities": [Any](),
            "systemProtocolMetadata": [Any](), "systemProtocolMetadataV2": [Any](), "transient": false,
            "visibilityMetadata": visibilityMetadata(true),
        ]
    }

    private func queryDictionary(_ query: ScannedQuery, inputs: Inputs) -> [String: Any] {
        [
            "identifier": query.typeName, "queryType": query.typeName, "entityType": query.entityType,
            "fullyQualifiedIdentifier": qualified(query.typeName, query.module, inputs),
            "mangledTypeName": mangled(query.typeName, query.module, query.kind, inputs),
            "mangledTypeNameByBundleIdentifier": [String: Any](), "availabilityAnnotations": availability,
            "capabilities": 66, "defaultQueryForEntity": true, "effectiveBundleIdentifiers": [Any](),
            "parameters": [Any](), "resultValueType": entityValueType(query.entityType), "sortingOptions": [Any](),
            "visibilityMetadata": visibilityMetadata(true),
        ]
    }

    private func enumDictionary(_ enumeration: ScannedEnum, inputs: Inputs) throws -> [String: Any] {
        guard let title = enumeration.title else { throw MetadataError("\(enumeration.typeName): missing enum type title") }
        for (name, raw) in enumeration.rawValues where name != raw {
            throw MetadataError("\(enumeration.typeName): custom raw value for \(name) is unsupported")
        }
        return [
            "identifier": enumeration.typeName, "fullyQualifiedTypeName": qualified(enumeration.typeName, enumeration.module, inputs),
            "mangledTypeName": mangled(enumeration.typeName, enumeration.module, .enum, inputs),
            "mangledTypeNameByBundleIdentifier": [String: Any](), "displayTypeName": localizable(title),
            "availabilityAnnotations": availability, "assistantDefinedSchemas": [Any](),
            "effectiveBundleIdentifiers": [Any](), "isSystem": false, "visibilityMetadata": visibilityMetadata(true),
            "cases": enumeration.cases.map { name in
                ["identifier": name, "displayRepresentation": ["title": localizable(enumeration.caseTitles[name]!)]] as [String: Any]
            },
        ]
    }

    private func shortcutDictionary(_ shortcut: ScannedShortcut) -> [String: Any] {
        [
            "actionIdentifier": shortcut.intentTypeName, "availabilityAnnotations": availability,
            "phraseTemplates": shortcut.phrases.map { localizable($0.replacingOccurrences(of: "\\(.applicationName)", with: "${applicationName}")) },
            "shortTitle": localizable(shortcut.shortTitle!), "systemImageName": shortcut.systemImageName!,
        ]
    }

    private var availability: [String: Any] { ["LNPlatformNameWildcard": ["introducedVersion": "*"]] }
    private func visibilityMetadata(_ discoverable: Bool) -> [String: Any] { ["assistantOnly": false, "isDiscoverable": discoverable] }
    private func localizable(_ text: String) -> [String: Any] { ["key": text, "alternatives": [Any]()] }
    private func primitive(_ identifier: Int) -> [String: Any] { ["primitive": ["wrapper": ["typeIdentifier": identifier]]] }
    private func entityValueType(_ name: String) -> [String: Any] { ["entity": ["wrapper": ["typeName": name]]] }
    private func qualified(_ name: String, _ module: String, _ inputs: Inputs) -> String { "\(module.isEmpty ? inputs.moduleName : module).\(name)" }
    private func mangled(_ name: String, _ module: String, _ kind: ScannedDeclKind, _ inputs: Inputs) -> String {
        MangledName.encode(module: module.isEmpty ? inputs.moduleName : module, typeName: name, kind: kind)
    }
}
