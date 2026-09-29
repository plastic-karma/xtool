import OpenAppleMacrosBase

/// #Unique has no independent storage: @Model incorporates its complete argument
/// list as Schema.Unique metadata, preserving compound and separate constraints.
struct UniqueConstraintsMacro: DeclarationMacro {
    static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let model = context.lexicalContext.first?.as(ClassDeclSyntax.self),
              swiftDataPropertyAttributes(model.attributes).contains(where: {
                  swiftDataPropertyAttributeName($0) == "Model"
              }) else {
            throw MacroError("#Unique must be declared directly inside an @Model class")
        }
        try swiftDataValidateUnique(node, model: model.name.trimmedDescription)
        // The member macro sees the original declaration, including import guards.
        // Emitting a second property here would introduce an unrelated model field.
        return []
    }
}

func swiftDataValidateUnique(
    _ node: some FreestandingMacroExpansionSyntax,
    model: String,
    properties: [SwiftDataModelProperty]? = nil
) throws {
    guard let generic = node.genericArgumentClause, generic.arguments.count == 1,
          generic.arguments.first?.argument.trimmedDescription == model else {
        throw MacroError("#Unique must specify its enclosing model type")
    }
    guard !node.arguments.isEmpty, node.trailingClosure == nil, node.additionalTrailingClosures.isEmpty else {
        throw MacroError("#Unique requires one or more nonempty arrays of stored-property key paths")
    }
    for argument in node.arguments {
        guard argument.label == nil,
              let array = argument.expression.as(ArrayExprSyntax.self), !array.elements.isEmpty else {
            throw MacroError("#Unique requires literal nonempty arrays of stored-property key paths")
        }
        for element in array.elements {
            guard let keyPath = element.expression.as(KeyPathExprSyntax.self),
                  keyPath.root == nil || keyPath.root?.trimmedDescription == model,
                  keyPath.components.count == 1,
                  let component = keyPath.components.first,
                  case .property(let property) = component.component,
                  property.genericArgumentClause == nil,
                  property.declName.argumentNames == nil else {
                throw MacroError("#Unique supports direct stored-property key paths of its enclosing model only")
            }
            if let properties {
                let name = property.declName.baseName.text.filter { $0 != "`" }
                guard let stored = properties.first(where: {
                    $0.identifier.text.filter { $0 != "`" } == name && !$0.isTransient
                }) else {
                    throw MacroError("#Unique cannot reference computed, transient, or unknown property '\(name)'")
                }
                var type = stored.binding.typeAnnotation?.type
                if let optional = type?.as(OptionalTypeSyntax.self) { type = optional.wrappedType }
                if type?.is(ArrayTypeSyntax.self) == true {
                    throw MacroError("#Unique collection constraints are not supported; uniqueness on relationships requires a to-one relationship")
                }
            }
        }
    }
}
