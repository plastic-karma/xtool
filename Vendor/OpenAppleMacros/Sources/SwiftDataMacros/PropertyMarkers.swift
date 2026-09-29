import OpenAppleMacrosBase

struct AttributePropertyMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try validateSchemaProperty(declaration, macro: "Attribute", in: context)
        // @Model turns the annotation's options into Schema.Attribute metadata.
        return []
    }
}

struct RelationshipPropertyMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try validateSchemaProperty(declaration, macro: "Relationship", in: context)
        // @Model preserves inverses, cardinality, options and deletion rules in
        // Schema.Relationship; _PersistedProperty invokes relationship-aware APIs.
        return []
    }
}

struct TransientPropertyMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let variable = try swiftDataValidateProperty(declaration, macro: "Transient", in: context)
        let binding = variable.bindings.first!
        let annotations = swiftDataPropertyAttributes(variable.attributes).map(swiftDataPropertyAttributeName)
        guard !annotations.contains("Attribute"), !annotations.contains("Relationship"),
              !annotations.contains("_PersistedProperty") else {
            throw MacroError("@Transient cannot be combined with persistence annotations")
        }
        if let accessors = binding.accessorBlock {
            guard case .accessors(let list) = accessors.accessors,
                  list.allSatisfy({ ["willSet", "didSet"].contains($0.accessorSpecifier.text) }) else {
                throw MacroError("@Transient requires a stored property, not a computed property")
            }
        }
        let type = binding.typeAnnotation?.type
        guard binding.initializer != nil || swiftDataPropertyIsOptional(type) else {
            throw MacroError("@Transient requires a default value so @Model can initialize it when loading backing data")
        }
        // This property intentionally remains ordinary stored state. @Model omits
        // it from schema metadata and does not attach persistence accessors.
        return []
    }
}

private func validateSchemaProperty(
    _ declaration: some DeclSyntaxProtocol,
    macro: String,
    in context: some MacroExpansionContext
) throws {
    let variable = try swiftDataValidateProperty(declaration, macro: macro, in: context)
    guard variable.bindingSpecifier.tokenKind == .keyword(.var),
          variable.bindings.first?.accessorBlock == nil else {
        throw MacroError("@\(macro) requires a mutable stored property without property observers")
    }
    let annotations = swiftDataPropertyAttributes(variable.attributes).map(swiftDataPropertyAttributeName)
    let conflicting = macro == "Attribute" ? "Relationship" : "Attribute"
    guard !annotations.contains("Transient"), !annotations.contains(conflicting) else {
        throw MacroError("@\(macro) cannot be combined with @Transient or @\(conflicting)")
    }
    guard annotations.filter({ $0 == macro }).count <= 1 else {
        throw MacroError("A property cannot have multiple @\(macro) annotations")
    }
}
