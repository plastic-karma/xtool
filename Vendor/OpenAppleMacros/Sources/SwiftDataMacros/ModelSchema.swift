import OpenAppleMacrosBase

/// Macro plugins do not receive the compiler's conditional-compilation evaluation.
/// The SwiftData import guard is known true whenever @Model can expand. Reject
/// other wrappers rather than merge metadata from mutually exclusive branches.
func swiftDataModelConditionalClause(_ conditional: IfConfigDeclSyntax) throws -> IfConfigClauseSyntax {
    guard conditional.clauses.count == 1, let clause = conditional.clauses.first,
          clause.condition?.tokens(viewMode: .sourceAccurate).map(\.text).joined() == "canImport(SwiftData)" else {
        throw MacroError("@Model supports conditional schema declarations only under #if canImport(SwiftData); other conditions require an explicit model declaration")
    }
    return clause
}

func swiftDataModelMembers(_ members: MemberBlockItemListSyntax) throws -> [DeclSyntax] {
    var result: [DeclSyntax] = []
    for member in members {
        if let conditional = member.decl.as(IfConfigDeclSyntax.self) {
            let clause = try swiftDataModelConditionalClause(conditional)
            guard case .decls(let nested) = clause.elements else {
                throw MacroError("Unsupported conditional member syntax in @Model")
            }
            result += try swiftDataModelMembers(nested)
        } else {
            result.append(member.decl)
        }
    }
    return result
}

private func validateAttributeConditions(_ attributes: AttributeListSyntax) throws {
    for element in attributes {
        guard case .ifConfigDecl(let conditional) = element else { continue }
        let clause = try swiftDataModelConditionalClause(conditional)
        guard case .attributes(let nested) = clause.elements else {
            throw MacroError("Unsupported conditional attribute syntax in @Model")
        }
        try validateAttributeConditions(nested)
    }
}

struct SwiftDataModelProperty {
    let identifier: TokenSyntax
    let binding: PatternBindingSyntax
    let isTransient: Bool
    let metadataAttribute: AttributeSyntax?

    init?(_ variable: VariableDeclSyntax) throws {
        if variable.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) {
            return nil
        }
        guard variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else {
            throw MacroError("@Model requires one named property per declaration")
        }
        if let accessors = binding.accessorBlock {
            switch accessors.accessors {
            case .getter:
                return nil
            case .accessors(let list):
                if list.contains(where: { ["get", "set", "_read", "_modify"].contains($0.accessorSpecifier.text) }) {
                    return nil
                }
                throw MacroError("Stored property observers in @Model are not supported by this implementation")
            }
        }
        try validateAttributeConditions(variable.attributes)
        let attributes = swiftDataPropertyAttributes(variable.attributes)
        let schemaAttributes = attributes.filter {
            ["Attribute", "Relationship", "Transient"].contains(swiftDataPropertyAttributeName($0))
        }
        guard schemaAttributes.count <= 1 else {
            throw MacroError("A model property cannot combine @Attribute, @Relationship, or @Transient")
        }
        let marker = schemaAttributes.first
        let isTransient = marker.map { swiftDataPropertyAttributeName($0) == "Transient" } ?? false
        if !isTransient {
            guard variable.bindingSpecifier.tokenKind == .keyword(.var) else {
                throw MacroError("Persisted @Model properties must be declared with var; use @Transient for constants")
            }
            guard !variable.modifiers.contains(where: { ["lazy", "weak", "unowned"].contains($0.name.text) }) else {
                throw MacroError("Persisted @Model properties cannot be lazy, weak, or unowned")
            }
            if let marker, swiftDataPropertyAttributeName(marker) == "Attribute",
               case .argumentList(let arguments) = marker.arguments,
               arguments.contains(where: { argument in
                   argument.expression.tokens(viewMode: .sourceAccurate).contains { $0.text == "transformable" }
               }) {
                throw MacroError("Transformable @Attribute storage is not supported by this implementation")
            }
        }
        self.identifier = identifier
        self.binding = binding
        self.isTransient = isTransient
        self.metadataAttribute = isTransient ? nil : marker
    }

    func metadata(model: String) throws -> String {
        let defaultValue: String
        if let initializer = binding.initializer?.value, !initializer.is(NilLiteralExprSyntax.self) {
            if let type = binding.typeAnnotation?.type {
                // Supplying the original contextual type preserves [], .case and
                // optional defaults when PropertyMetadata erases the value to Any.
                defaultValue = "(\(initializer.trimmedDescription) as \(type.trimmedDescription))"
            } else {
                defaultValue = initializer.trimmedDescription
            }
        } else {
            defaultValue = "nil"
        }
        let metadata: String
        if let attribute = metadataAttribute {
            let arguments: String
            switch attribute.arguments {
            case .argumentList(let list): arguments = list.trimmedDescription
            case nil: arguments = ""
            default: throw MacroError("Unsupported SwiftData schema attribute arguments")
            }
            metadata = "SwiftData.Schema.\(swiftDataPropertyAttributeName(attribute))(\(arguments))"
        } else {
            metadata = "nil"
        }
        let name = identifier.text.filter { $0 != "`" }
        return "SwiftData.Schema.PropertyMetadata(name: \"\(name)\", keypath: \\\(model).\(identifier.trimmedDescription), defaultValue: \(defaultValue), metadata: \(metadata))"
    }
}
