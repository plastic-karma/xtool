import OpenAppleMacrosBase

/// Attribute lists can contain conditional-compilation nodes, including the
/// canImport(SwiftData) guards used by shared iOS/Linux model sources.
func swiftDataPropertyAttributes(_ attributes: AttributeListSyntax) -> [AttributeSyntax] {
    var result: [AttributeSyntax] = []
    func collect(_ syntax: Syntax) {
        if let attribute = syntax.as(AttributeSyntax.self) {
            result.append(attribute)
            return
        }
        for child in syntax.children(viewMode: .sourceAccurate) {
            collect(child)
        }
    }
    collect(Syntax(attributes))
    return result
}

func swiftDataPropertyAttributeName(_ attribute: AttributeSyntax) -> String {
    if let name = attribute.attributeName.as(IdentifierTypeSyntax.self) {
        return name.name.text
    }
    if let name = attribute.attributeName.as(MemberTypeSyntax.self) {
        return name.name.text
    }
    return attribute.attributeName.trimmedDescription
}

func swiftDataPropertyIsOptional(_ type: TypeSyntax?) -> Bool {
    guard let type else { return false }
    if type.is(OptionalTypeSyntax.self) { return true }
    if let identifier = type.as(IdentifierTypeSyntax.self) {
        return identifier.name.text == "Optional" && identifier.genericArgumentClause?.arguments.count == 1
    }
    if let member = type.as(MemberTypeSyntax.self) {
        return member.baseType.trimmedDescription == "Swift" && member.name.text == "Optional"
            && member.genericArgumentClause?.arguments.count == 1
    }
    return false
}

/// Marker macros must never silently accept declarations that @Model cannot
/// incorporate into its schema or instantiate from an existing backing store.
func swiftDataValidateProperty(
    _ declaration: some DeclSyntaxProtocol,
    macro: String,
    in context: some MacroExpansionContext
) throws -> VariableDeclSyntax {
    guard let model = context.lexicalContext.first?.as(ClassDeclSyntax.self),
          swiftDataPropertyAttributes(model.attributes).contains(where: {
              swiftDataPropertyAttributeName($0) == "Model"
          }) else {
        throw MacroError("@\(macro) requires a property declared directly in an @Model class")
    }
    return try swiftDataStoredProperty(declaration, macro: macro)
}

func swiftDataStoredProperty(
    _ declaration: some DeclSyntaxProtocol,
    macro: String
) throws -> VariableDeclSyntax {
    guard let variable = declaration.as(VariableDeclSyntax.self),
          variable.bindings.count == 1,
          let binding = variable.bindings.first,
          binding.pattern.is(IdentifierPatternSyntax.self) else {
        throw MacroError("@\(macro) requires a single named stored property")
    }
    let unsupported = ["static", "class", "lazy", "weak", "unowned"]
    if let modifier = variable.modifiers.first(where: { unsupported.contains($0.name.text) }) {
        throw MacroError("@\(macro) does not support '\(modifier.name.text)' properties")
    }
    if binding.typeAnnotation?.type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) == true {
        throw MacroError("@\(macro) does not support implicitly unwrapped optional properties; use an optional instead")
    }
    return variable
}

/// Generated storage is already absent from the source model's schema. Avoid
/// recursively attaching persistence accessors without invoking @Transient on
/// generated peers, whose enclosing-type context the compiler can omit.
func swiftDataIsInternalStorage(_ declaration: some DeclSyntaxProtocol) -> Bool {
    guard let variable = declaration.as(VariableDeclSyntax.self),
          variable.bindings.count == 1, let binding = variable.bindings.first,
          binding.accessorBlock == nil,
          let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
          variable.modifiers.count == 1,
          variable.modifiers.first?.name.tokenKind == .keyword(.private),
          variable.modifiers.first?.detail == nil,
          variable.attributes.isEmpty else {
        return false
    }
    let initializer = binding.initializer?.value
    let type = binding.typeAnnotation?.type.trimmedDescription
    if name == "_$observationRegistrar" {
        return variable.bindingSpecifier.tokenKind == .keyword(.let)
            && type == nil && initializer?.trimmedDescription == "Observation.ObservationRegistrar()"
    }
    guard variable.bindingSpecifier.tokenKind == .keyword(.var) else { return false }
    if name == "_$backingData" {
        guard let call = initializer?.as(FunctionCallExprSyntax.self),
              call.arguments.isEmpty, call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty,
              let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
              callee.declName.baseName.text == "createBackingData", callee.declName.argumentNames == nil,
              let model = callee.base?.as(DeclReferenceExprSyntax.self),
              model.argumentNames == nil else {
            return false
        }
        return type == "any SwiftData.BackingData<\(model.trimmedDescription)>"
    }
    return name.hasPrefix("_") && name.count > 1 && !name.hasPrefix("_$")
        && (type == "_SwiftDataNoType" || type == "_SwiftDataNoType?")
        && (initializer == nil || initializer?.trimmedDescription == ".init()")
}

