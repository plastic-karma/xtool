import OpenAppleMacrosBase
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import Testing
@testable import SwiftDataMacros

private func expandMarker(_ source: String, lexicalContext: [Syntax]) throws {
    let declaration = DeclSyntax(stringLiteral: source)
    let variable = try #require(declaration.as(VariableDeclSyntax.self))
    let attribute = try #require(swiftDataPropertyAttributes(variable.attributes).first)
    let context = BasicMacroExpansionContext(lexicalContext: lexicalContext)
    switch swiftDataPropertyAttributeName(attribute) {
    case "Transient":
        _ = try TransientPropertyMacro.expansion(of: attribute, providingPeersOf: variable, in: context)
    case "Attribute":
        _ = try AttributePropertyMacro.expansion(of: attribute, providingPeersOf: variable, in: context)
    case "Relationship":
        _ = try RelationshipPropertyMacro.expansion(of: attribute, providingPeersOf: variable, in: context)
    case "_PersistedProperty":
        _ = try PersistedPropertyMacro.expansion(of: attribute, providingPeersOf: variable, in: context)
    default:
        Issue.record("Unexpected fixture marker")
    }
}

@Test(arguments: ["Transient", "Attribute", "Relationship", "_PersistedProperty"])
func markersRejectPropertiesOutsideDirectModel(marker: String) throws {
    let model = Syntax(try #require(DeclSyntax("@Model final class Outer {}").as(ClassDeclSyntax.self)))
    let plain = Syntax(try #require(DeclSyntax("final class Plain {}").as(ClassDeclSyntax.self)))
    let source = "@\(marker) var value: Int = 0"
    for scope: [Syntax] in [[], [plain], [plain, model]] {
        #expect(throws: MacroError.self) {
            try expandMarker(source, lexicalContext: scope)
        }
    }
}

@Test(arguments: [
    "@Transient private var _value: Int = 0",
    "@SwiftData.Transient var _value: _SwiftDataNoType",
    "@SwiftData.Transient private var _value: _SwiftDataNoType = .init()",
    "@SwiftData.Transient private var _value: _SwiftDataNoType?",
    "@SwiftData.Transient private let _value: _SwiftDataNoType = .init()",
    "@SwiftData.Transient private var _value: _SwiftDataNoType = makeValue()",
    "@SwiftData.Transient private var _value: _SwiftDataNoType { .init() }",
    "@SwiftData.Transient private var _$backingData: any SwiftData.BackingData<A> = B.createBackingData()",
    "@SwiftData.Transient private var _$backingData: any SwiftData.BackingData<A> = A.createBackingData(1)",
    "@SwiftData.Transient private var _$observationRegistrar = Observation.ObservationRegistrar()",
    "@SwiftData.Transient private let _$observationRegistrar = makeRegistrar()",
])
func contextFreeStorageLookalikesAreRejected(source: String) {
    #expect(throws: MacroError.self) {
        try expandMarker(source, lexicalContext: [])
    }
}

@Test(arguments: [
    "@Transient var value: Int",
    "@Transient private var _value: _SwiftDataNoType",
    "@Transient var value: Int { 0 }",
    "@Transient @Attribute var value = 0",
    "@Transient @Relationship var value = 0",
    "@Transient @_PersistedProperty var value = 0",
])
func invalidTransientStorageInModelIsRejected(source: String) throws {
    let model = Syntax(try #require(DeclSyntax("@Model final class Item {}").as(ClassDeclSyntax.self)))
    #expect(throws: MacroError.self) {
        try expandMarker(source, lexicalContext: [model])
    }
}
