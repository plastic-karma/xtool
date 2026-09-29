import OpenAppleMacrosBase

/// Implements the public SwiftData model ABI, rather than a separate storage layer.
struct PersistentModelMacro: MemberMacro, MemberAttributeMacro, ExtensionMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let model = declaration.as(ClassDeclSyntax.self) else {
            throw MacroError("@Model requires a class")
        }
        guard model.genericParameterClause == nil, model.inheritanceClause == nil else {
            throw MacroError("@Model inheritance and generic models are not supported by this implementation")
        }
        let members = try swiftDataModelMembers(model.memberBlock.members)
        let properties = try members.compactMap { member -> SwiftDataModelProperty? in
            guard let variable = member.as(VariableDeclSyntax.self) else { return nil }
            return try SwiftDataModelProperty(variable)
        }
        let name = model.name.trimmedDescription
        let access = model.modifiers.contains { $0.name.text == "public" || $0.name.text == "open" }
            ? "public " : ""
        let required = model.modifiers.contains { $0.name.text == "final" } ? "" : "required "
        let metadata = try properties.filter { !$0.isTransient }.map { try $0.metadata(model: name) }
        var uniqueness: String?
        for member in members {
            guard let macro = member.as(MacroExpansionDeclSyntax.self) else { continue }
            switch macro.macroName.text {
            case "Unique":
                guard uniqueness == nil else {
                    throw MacroError("#Unique may appear only once in a model; combine constraints in one declaration")
                }
                try swiftDataValidateUnique(macro, model: name, properties: properties)
                uniqueness = "SwiftData.Schema.PropertyMetadata(name: \"SwiftData.Schema.Unique\", keypath: \\SwiftData.Schema.encodingVersion, defaultValue: nil, metadata: SwiftData.Schema.Unique<\(name)>(\(macro.arguments.trimmedDescription)))"
            case "Index":
                throw MacroError("#Index is not supported by this implementation; its schema semantics cannot be omitted")
            default:
                throw MacroError("Declaration macros inside @Model are not supported by this implementation")
            }
        }
        let initializeMarkers = properties.filter { !$0.isTransient }.map {
            "self._\($0.identifier.text.filter { $0 != "`" }) = _SwiftDataNoType()"
        }.joined(separator: "\n")
        var schemaBody = "return [\(metadata.joined(separator: ",\n"))]"
        if let uniqueness {
            schemaBody = """
            var properties: [SwiftData.Schema.PropertyMetadata] = [\(metadata.joined(separator: ",\n"))]
            if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
                properties.append(\(uniqueness))
            }
            return properties
            """
        }
        return [
            """
            private var _$backingData: any SwiftData.BackingData<\(raw: name)> = \(raw: name).createBackingData()
            """,
            """
            \(raw: access)var persistentBackingData: any SwiftData.BackingData<\(raw: name)> {
                get { self._$backingData }
                set { self._$backingData = newValue }
            }
            """,
            """
            \(raw: access)static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
                \(raw: schemaBody)
            }
            """,
            """
            \(raw: access)\(raw: required)init(backingData: any SwiftData.BackingData<\(raw: name)>) {
                \(raw: initializeMarkers)
                self._$backingData = backingData
            }
            """,
            """
            private let _$observationRegistrar = Observation.ObservationRegistrar()
            """,
            "struct _SwiftDataNoType {}",
        ]
    }

    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard let variable = member.as(VariableDeclSyntax.self),
              !swiftDataIsInternalStorage(variable),
              let property = try SwiftDataModelProperty(variable), !property.isTransient else {
            return []
        }
        if swiftDataPropertyAttributes(variable.attributes).contains(where: {
            swiftDataPropertyAttributeName($0) == "_PersistedProperty"
        }) {
            return []
        }
        return ["@SwiftData._PersistedProperty"]
    }

    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(ClassDeclSyntax.self) else { return [] }
        return [try ExtensionDeclSyntax("extension \(type): nonisolated SwiftData.PersistentModel, nonisolated Observation.Observable {}")]
    }
}
