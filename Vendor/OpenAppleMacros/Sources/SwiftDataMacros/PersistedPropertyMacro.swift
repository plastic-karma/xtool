import OpenAppleMacrosBase

/// Uses SwiftData's backing store during initialization and its PersistentModel
/// accessors thereafter, so relationship fixups and change tracking remain in SwiftData.
struct PersistedPropertyMacro: AccessorMacro, PeerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let property = try SwiftDataPersistedProperty(declaration, in: context)
        let name = property.reference
        let marker = property.marker
        return [
            """
            @storageRestrictions(accesses: _$backingData, initializes: \(raw: marker))
            init(initialValue) {
                _$backingData.setValue(forKey: \\.\(raw: name), to: initialValue)
                \(raw: marker) = _SwiftDataNoType()
            }
            """,
            """
            get {
                _$observationRegistrar.access(self, keyPath: \\.\(raw: name))
                return self.getValue(forKey: \\.\(raw: name))
            }
            """,
            """
            set {
                _$observationRegistrar.withMutation(of: self, keyPath: \\.\(raw: name)) {
                    self.setValue(forKey: \\.\(raw: name), to: newValue)
                }
            }
            """,
        ]
    }

    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let property = try SwiftDataPersistedProperty(declaration, in: context)
        // Optional markers preserve Swift's implicit nil initialization. Explicit
        // defaults stay on the original property and run through its init accessor;
        // the marker contains no persisted value and must not evaluate that default.
        let optional = swiftDataPropertyIsOptional(property.binding.typeAnnotation?.type)
        let type = optional ? "_SwiftDataNoType?" : "_SwiftDataNoType"
        let initializer = property.binding.initializer == nil ? "" : " = .init()"
        return [
            "@SwiftData.Transient private var \(raw: property.marker): \(raw: type)\(raw: initializer)"
        ]
    }
}

private struct SwiftDataPersistedProperty {
    let binding: PatternBindingSyntax
    let reference: String
    let marker: String

    init(_ declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) throws {
        let variable = try swiftDataValidateProperty(declaration, macro: "_PersistedProperty", in: context)
        guard variable.bindingSpecifier.tokenKind == .keyword(.var) else {
            throw MacroError("@_PersistedProperty requires a mutable stored property")
        }
        let binding = variable.bindings.first!
        guard binding.accessorBlock == nil else {
            throw MacroError("@_PersistedProperty does not support computed properties or property observers")
        }
        let annotations = swiftDataPropertyAttributes(variable.attributes).map(swiftDataPropertyAttributeName)
        guard !annotations.contains("Transient") else {
            throw MacroError("A transient property cannot also be persisted")
        }
        let identifier = binding.pattern.as(IdentifierPatternSyntax.self)!.identifier.text
        let name = identifier.first == "`" && identifier.last == "`"
            ? String(identifier.dropFirst().dropLast()) : identifier
        self.binding = binding
        self.reference = "`\(name)`"
        self.marker = "_\(name)"
    }
}
