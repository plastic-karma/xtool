import OpenAppleMacrosBase

/// Preserve SwiftData's DynamicProperty storage and fetch semantics. The macro
/// only exposes its wrapped result; SwiftData still owns filtering and updates.
struct QueryMacro: PeerMacro, AccessorMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let property = try QueryProperty(declaration)
        let arguments: String
        switch node.arguments {
        case .argumentList(let list): arguments = list.trimmedDescription
        case nil: arguments = ""
        default: throw MacroError("Unsupported @Query arguments")
        }
        return [
            "private var \(raw: property.storage): _SwiftData_SwiftUI.Query<\(property.element), [\(property.element)]> = .init(\(raw: arguments))"
        ]
    }

    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let property = try QueryProperty(declaration)
        return ["get { \(raw: property.storage).wrappedValue }"]
    }
}

private struct QueryProperty {
    let storage: String
    let element: TypeSyntax

    init(_ declaration: some DeclSyntaxProtocol) throws {
        let variable = try swiftDataStoredProperty(declaration, macro: "Query")
        let binding = variable.bindings.first!
        guard variable.bindingSpecifier.tokenKind == .keyword(.var),
              binding.accessorBlock == nil, binding.initializer == nil else {
            throw MacroError("@Query requires a mutable stored declaration without an initializer; configure its backing Query in init instead")
        }
        guard let type = binding.typeAnnotation?.type else {
            throw MacroError("@Query requires an explicit array result type")
        }
        if let array = type.as(ArrayTypeSyntax.self) {
            element = array.element
        } else if let array = type.as(IdentifierTypeSyntax.self), array.name.text == "Array",
                  let arguments = array.genericArgumentClause?.arguments, arguments.count == 1,
                  case .type(let item) = arguments.first!.argument {
            element = item
        } else if let array = type.as(MemberTypeSyntax.self), array.baseType.trimmedDescription == "Swift",
                  array.name.text == "Array", let arguments = array.genericArgumentClause?.arguments,
                  arguments.count == 1, case .type(let item) = arguments.first!.argument {
            element = item
        } else {
            throw MacroError("@Query supports [Model] or Array<Model> results; type aliases and other result forms require explicit Query storage")
        }
        let identifier = binding.pattern.as(IdentifierPatternSyntax.self)!.identifier.text
        storage = "_" + identifier.filter { $0 != "`" }
    }
}
