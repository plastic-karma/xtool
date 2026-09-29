import Foundation
import SwiftParser
import SwiftSyntax

/// Walks a list of source roots and harvests every AppIntents-related
/// declaration into a `ScannedModule`. The scanner is purely lexical:
/// it does not execute any Swift code and does not resolve types across
/// modules, so it sees only what the source itself spells out.
///
/// Recognised conformance markers (matched by trailing identifier on the
/// inheritance clause; module-qualified spellings such as
/// `AppIntents.AppIntent` also match):
///   * `AppIntent`, `AudioRecordingIntent`, `OpenIntent`,
///     `ForegroundContinuableIntent`, `LiveActivityIntent` (treated as
///     intents).
///   * `AppShortcutsProvider` (treated as a shortcuts provider).
///   * `AppEntity` (entity).
///   * `AppEnum` (enum).
///
/// Unsupported metadata is diagnosed, never silently discarded. The emitter
/// refuses to publish a module with any diagnostics.
public struct Scanner: Sendable {

    /// A source root paired with the SwiftPM module that owns it. Used to
    /// stamp scanned declarations with their declaring module so the emitter
    /// can produce correct cross-module mangled names.
    public struct ScanRoot: Sendable, Equatable {
        public var module: String
        public var url: URL

        public init(module: String, url: URL) {
            self.module = module
            self.url = url
        }
    }

    public let platform: String
    public init(platform: String = "ios") { self.platform = platform }

    /// Scan every `.swift` file under each root, recursively. Symlinks are
    /// not followed. Hidden files are skipped. All decls are stamped with
    /// the empty string for `module` (legacy single-module callers).
    public func scan(roots: [URL]) throws -> ScannedModule {
        try scan(roots: roots.map { ScanRoot(module: "", url: $0) })
    }

    /// Scan a list of `(module, root)` pairs. Each scanned declaration is
    /// stamped with its declaring module name, which the emitter uses to
    /// generate correct mangled names for cross-module types.
    public func scan(roots: [ScanRoot]) throws -> ScannedModule {
        var module = ScannedModule()
        for root in roots {
            for url in try Self.swiftFiles(under: root.url) {
                let source = try String(contentsOf: url, encoding: .utf8)
                module.merge(scan(source: source, module: root.module))
            }
        }
        return module
    }

    /// Scan a single Swift source string. Useful in tests and for the
    /// `xtool-appintents-gen` CLI.
    public func scan(source: String) -> ScannedModule {
        scan(source: source, module: "")
    }

    public func scan(source: String, module: String) -> ScannedModule {
        let tree = Parser.parse(source: source)
        let visitor = AppIntentsVisitor(module: module, platform: platform, viewMode: .sourceAccurate)
        visitor.walk(tree)
        if tree.hasError { visitor.module.diagnostics.append("Swift parser errors in input source") }
        return visitor.module
    }

    static func swiftFiles(under root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }
}

private final class AppIntentsVisitor: SyntaxVisitor {
    var module = ScannedModule()
    let moduleName: String
    let platform: String

    init(module: String, platform: String, viewMode: SyntaxTreeViewMode) {
        self.moduleName = module
        self.platform = platform
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        for clause in node.clauses {
            let matches = clause.condition.map { condition($0.trimmedDescription) } ?? true
            guard let matches else {
                // An unknown build flag in unrelated application code must not
                // block metadata. It must block conditional intent declarations.
                let probe = AppIntentsVisitor(module: moduleName, platform: platform, viewMode: .sourceAccurate)
                for candidate in node.clauses {
                    if let elements = candidate.elements { probe.walk(Syntax(elements)) }
                }
                if !probe.module.isEmpty || !probe.module.queries.isEmpty || !probe.module.diagnostics.isEmpty {
                    fail("Unresolved conditional compilation around AppIntents: \(clause.condition?.trimmedDescription ?? "")")
                }
                return .skipChildren
            }
            if matches {
                if let elements = clause.elements { walk(Syntax(elements)) }
                return .skipChildren
            }
        }
        return .skipChildren
    }

    private func condition(_ raw: String) -> Bool? {
        let text = raw.filter { !$0.isWhitespace }
        let characters = Array(text)
        for operation in ["||", "&&"] {
            var depth = 0
            for index in characters.indices {
                let character = characters[index]
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if depth == 0, index + 1 < characters.count,
                   String(characters[index...index + 1]) == operation {
                    let left = condition(String(characters[..<index]))
                    let right = condition(String(characters[(index + 2)...]))
                    if operation == "&&" {
                        if left == false || right == false { return false }
                        if left == true && right == true { return true }
                    } else {
                        if left == true || right == true { return true }
                        if left == false && right == false { return false }
                    }
                    return nil
                }
            }
        }
        if text.hasPrefix("!") { return condition(String(text.dropFirst())).map { !$0 } }
        if text.hasPrefix("("), text.hasSuffix(")") { return condition(String(text.dropFirst().dropLast())) }
        if text == "true" { return true }
        if text == "false" { return false }
        if text.hasPrefix("os("), text.hasSuffix(")") {
            return String(text.dropFirst(3).dropLast()).lowercased() == platform
        }
        if text.hasPrefix("canImport("), text.hasSuffix(")") {
            let name = String(text.dropFirst(10).dropLast())
            if ["Foundation", "Swift", "SwiftUI", "AppIntents", "WidgetKit", "SwiftData"].contains(name) { return true }
            if ["ActivityKit", "UIKit"].contains(name) { return platform == "ios" }
            if name == "WatchKit" { return platform == "watchos" }
        }
        return nil
    }

    private static let intentProtocols: Set<String> = [
        "AppIntent",
        "AudioRecordingIntent",
        "ForegroundContinuableIntent",
        "LiveActivityIntent",
        "OpenIntent",
        "WidgetConfigurationIntent",
        "ControlConfigurationIntent",
        "AppIntentsPackage",
    ]

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.name.text
        let protocols = inheritanceNames(node.inheritanceClause)
        validateType(node, protocols: protocols, generic: node.genericParameterClause != nil)
        classify(
            typeName: typeName,
            kind: .struct,
            protocols: protocols,
            members: node.memberBlock.members
        )
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.name.text
        let protocols = inheritanceNames(node.inheritanceClause)
        validateType(node, protocols: protocols, generic: node.genericParameterClause != nil)
        classify(
            typeName: typeName,
            kind: .class,
            protocols: protocols,
            members: node.memberBlock.members
        )
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.name.text
        let protocols = inheritanceNames(node.inheritanceClause)
        validateType(node, protocols: protocols, generic: node.genericParameterClause != nil)
        let isAppEnum = protocols.contains { $0 == "AppEnum" }
        if isAppEnum {
            var enumeration = ScannedEnum(typeName: typeName, module: moduleName, protocolNames: protocols)
            for member in node.memberBlock.members {
                if let declaration = member.decl.as(EnumCaseDeclSyntax.self) {
                    for element in declaration.elements {
                        if element.parameterClause != nil { fail("\(typeName): associated-value enum case") }
                        enumeration.cases.append(element.name.text)
                        if let value = element.rawValue?.value {
                            if let raw = stringLiteralValue(from: value) { enumeration.rawValues[element.name.text] = raw }
                            else { fail("\(typeName): nonliteral enum raw value") }
                        }
                    }
                }
                guard let declaration = member.decl.as(VariableDeclSyntax.self),
                      declaration.modifiers.contains(where: { $0.name.text == "static" }),
                      let binding = declaration.bindings.first else { continue }
                let name = binding.pattern.trimmedDescription
                if name == "typeDisplayRepresentation" {
                    enumeration.title = stringLiteralValue(from: propertyExpression(binding))
                    if enumeration.title == nil { fail("\(typeName): nonliteral type display representation") }
                } else if name == "caseDisplayRepresentations" {
                    guard let dictionary = propertyExpression(binding)?.as(DictionaryExprSyntax.self),
                          case .elements(let entries) = dictionary.content else {
                        fail("\(typeName): case display representations must be a dictionary literal")
                        continue
                    }
                    for entry in entries {
                        guard let key = entry.key.as(MemberAccessExprSyntax.self)?.declName.baseName.text,
                              let title = stringLiteralValue(from: entry.value) else {
                            fail("\(typeName): unsupported enum display representation")
                            continue
                        }
                        enumeration.caseTitles[key] = title
                    }
                } else {
                    fail("\(typeName): unsupported static enum property \(name)")
                }
            }
            if Set(enumeration.cases) != Set(enumeration.caseTitles.keys) {
                fail("\(typeName): missing or unknown enum case display representations")
            }
            module.enums.append(enumeration)
        }
        return .visitChildren
    }

    private func classify(
        typeName: String,
        kind: ScannedDeclKind,
        protocols: [String],
        members: MemberBlockItemListSyntax
    ) {
        let protocolSet = Set(protocols)
        let isIntent = !protocolSet.isDisjoint(with: Self.intentProtocols.subtracting(["AppIntentsPackage"]))
        let isProvider = protocols.contains("AppShortcutsProvider")
        let isEntity = protocols.contains("AppEntity")
        let isPackage = protocols.contains("AppIntentsPackage")

        if isIntent {
            var intent = makeIntent(
                typeName: typeName,
                kind: kind,
                protocols: protocols,
                members: members
            )
            intent.module = moduleName
            module.intents.append(intent)
        }
        if isProvider {
            var provider = makeShortcutsProvider(typeName: typeName, kind: kind, members: members)
            provider.module = moduleName
            module.shortcutsProviders.append(provider)
        }
        if isEntity {
            var entity = ScannedEntity(typeName: typeName, kind: kind, module: moduleName, protocolNames: protocols)
            for member in members {
                guard let declaration = member.decl.as(VariableDeclSyntax.self),
                      let binding = declaration.bindings.first else { continue }
                switch binding.pattern.trimmedDescription {
                case "typeDisplayRepresentation": entity.title = stringLiteralValue(from: propertyExpression(binding))
                case "defaultQuery":
                    if let call = propertyExpression(binding)?.as(FunctionCallExprSyntax.self), call.arguments.isEmpty {
                        entity.defaultQuery = call.calledExpression.trimmedDescription.split(separator: ".").last.map(String.init)
                    }
                case "id": entity.identifierType = binding.typeAnnotation?.type.trimmedDescription
                default:
                    if !declaration.attributes.isEmpty { fail("\(typeName): unsupported entity property attribute") }
                    if declaration.modifiers.contains(where: { $0.name.text == "static" }) {
                        fail("\(typeName): unsupported static entity property \(binding.pattern.trimmedDescription)")
                    }
                }
            }
            if entity.title == nil || entity.defaultQuery == nil || entity.identifierType == nil {
                fail("\(typeName): entity requires a literal type title, default query constructor, and typed id")
            }
            module.entities.append(entity)
        }
        if protocols.contains(where: { ["EntityQuery", "EntityStringQuery", "EntityPropertyQuery"].contains($0) }) {
            var entityType: String?
            var suggested = false
            for member in members {
                if let declaration = member.decl.as(VariableDeclSyntax.self),
                   !declaration.attributes.isEmpty || declaration.modifiers.contains(where: { $0.name.text == "static" }) {
                    fail("\(typeName): query properties and parameters are unsupported")
                }
                guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
                if function.name.text == "suggestedEntities" { suggested = true }
                if function.name.text == "entities", let array = function.signature.returnClause?.type.as(ArrayTypeSyntax.self) {
                    entityType = array.element.trimmedDescription
                }
            }
            if let entityType {
                module.queries.append(ScannedQuery(typeName: typeName, module: moduleName, kind: kind, entityType: entityType, protocolNames: protocols, hasSuggestedEntities: suggested))
            } else { fail("\(typeName): cannot resolve query entity type") }
        }
        if isPackage {
            module.packages.append(ScannedPackage(typeName: typeName, kind: kind, module: moduleName))
        }
    }

    private func makeIntent(
        typeName: String,
        kind: ScannedDeclKind,
        protocols: [String],
        members: MemberBlockItemListSyntax
    ) -> ScannedIntent {
        var intent = ScannedIntent(typeName: typeName, kind: kind, protocolNames: protocols)
        for member in members {
            if let varDecl = member.decl.as(VariableDeclSyntax.self) {
                handleIntentProperty(varDecl, into: &intent)
            }
            if let funcDecl = member.decl.as(FunctionDeclSyntax.self),
               funcDecl.name.text == "perform" {
                if let returnType = funcDecl.signature.returnClause?.type {
                    intent.returnsValue = Self.typeMentions(returnType, name: "ReturnsValue")
                    intent.providesDialog = Self.typeMentions(returnType, name: "ProvidesDialog")
                } else {
                    intent.returnsValue = false
                }
            }
        }
        return intent
    }

    private func handleIntentProperty(
        _ varDecl: VariableDeclSyntax,
        into intent: inout ScannedIntent
    ) {
        let isStatic = varDecl.modifiers.contains { $0.name.text == "static" }
        let bindings = varDecl.bindings
        guard let binding = bindings.first,
              let identPattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return }
        let propertyName = identPattern.identifier.text

        if isStatic {
            switch propertyName {
            case "title":
                intent.title = stringLiteralValue(from: propertyExpression(binding))
                if intent.title == nil { fail("\(intent.typeName): nonliteral title") }
            case "description":
                intent.descriptionText = intentDescriptionText(from: propertyExpression(binding))
                intent.categoryName = intentDescriptionCategory(from: propertyExpression(binding))
                if intent.descriptionText == nil { fail("\(intent.typeName): nonliteral description") }
            case "openAppWhenRun":
                intent.openAppWhenRun = booleanValue(from: propertyExpression(binding))
                if intent.openAppWhenRun == nil { fail("\(intent.typeName): nonliteral openAppWhenRun") }
            case "isDiscoverable":
                intent.isDiscoverable = booleanValue(from: propertyExpression(binding))
                if intent.isDiscoverable == nil { fail("\(intent.typeName): nonliteral isDiscoverable") }
            case "parameterSummary":
                intent.summary = scanSummary(propertyExpression(binding))
            default:
                fail("\(intent.typeName): unsupported static property \(propertyName)")
            }
            return
        }

        // Instance property: candidate for `@Parameter`.
        let isParameter = varDecl.attributes.contains { attr in
            guard let attrSyntax = attr.as(AttributeSyntax.self) else { return false }
            return attrSyntax.attributeName.trimmedDescription.split(separator: ".").last == "Parameter"
        }
        guard isParameter else { return }
        if bindings.count != 1 { fail("\(intent.typeName): multiple bindings in one @Parameter declaration") }
        guard let typeAnnotation = binding.typeAnnotation else {
            fail("\(intent.typeName).\(propertyName): parameter must have an explicit type")
            return
        }
        let typeText = typeAnnotation.type.trimmedDescription
        let isOptional = typeText.hasSuffix("?") || typeText.hasPrefix("Optional<") || typeText.hasPrefix("Swift.Optional<")

        var parameter = ScannedParameter(
            propertyName: propertyName,
            typeName: typeText,
            isOptional: isOptional
        )

        if let attr = varDecl.attributes.compactMap({ $0.as(AttributeSyntax.self) }).first(where: {
            $0.attributeName.trimmedDescription.split(separator: ".").last == "Parameter"
        }), case let .argumentList(args)? = attr.arguments {
            for arg in args {
                guard let label = arg.label?.text else { continue }
                if label == "title" {
                    parameter.title = stringLiteralValue(from: arg.expression)
                } else if label == "description" {
                    parameter.descriptionText = stringLiteralValue(from: arg.expression)
                    if parameter.descriptionText == nil { fail("\(propertyName): nonliteral parameter description") }
                } else if label == "default" {
                    parameter.defaultValueExpression = arg.expression.trimmedDescription
                } else if label == "requestValueDialog" {
                    parameter.requestValueDialog = stringLiteralValue(from: arg.expression)
                    if parameter.requestValueDialog == nil { fail("\(propertyName): nonliteral request dialog") }
                } else {
                    fail("\(propertyName): unsupported @Parameter argument \(label)")
                }
            }
        }
        if let initializer = binding.initializer?.value {
            parameter.defaultValueExpression = initializer.trimmedDescription
        }
        if parameter.title == nil { fail("\(propertyName): parameter requires a literal title") }
        intent.parameters.append(parameter)
    }

    private func makeShortcutsProvider(
        typeName: String,
        kind: ScannedDeclKind,
        members: MemberBlockItemListSyntax
    ) -> ScannedShortcutsProvider {
        var provider = ScannedShortcutsProvider(typeName: typeName, kind: kind)
        for member in members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  varDecl.modifiers.contains(where: { $0.name.text == "static" }),
                  let binding = varDecl.bindings.first,
                  let identPattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            guard identPattern.identifier.text == "appShortcuts" else {
                fail("\(typeName): unsupported shortcut provider property \(identPattern.identifier.text)")
                continue
            }

            if let expression = binding.initializer?.value {
                provider.shortcuts = parseAppShortcutsExpression(expression)
            } else if let accessor = binding.accessorBlock, case .getter(let statements) = accessor.accessors {
                for statement in statements {
                    if let expression = statement.item.as(ExprSyntax.self) ?? statement.item.as(ReturnStmtSyntax.self)?.expression {
                        provider.shortcuts += parseAppShortcutsExpression(expression)
                    } else { fail("\(typeName): unsupported shortcut builder statement") }
                }
            } else { fail("\(typeName): unsupported appShortcuts accessor") }
            if provider.shortcuts.isEmpty { fail("\(typeName): no statically resolvable shortcuts") }
        }
        return provider
    }

    /// Walk a result builder body that produces `[AppShortcut]`. The body
    /// is typically a sequence of `AppShortcut(intent:phrases:shortTitle:systemImageName:)`
    /// calls. We accept either an array literal or a `@AppShortcutsBuilder`
    /// block.
    private func parseAppShortcutsExpression(_ expr: ExprSyntax) -> [ScannedShortcut] {
        if let array = expr.as(ArrayExprSyntax.self) {
            return array.elements.flatMap { parseAppShortcutsExpression($0.expression) }
        }
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let shortcut = scanAppShortcutCall(call) else {
            fail("Unsupported AppShortcut builder expression: \(expr.trimmedDescription)")
            return []
        }
        return [shortcut]
    }

    private func scanAppShortcutCall(_ call: FunctionCallExprSyntax) -> ScannedShortcut? {
        // Match `AppShortcut(...)` or `AppIntents.AppShortcut(...)`.
        let calleeText = call.calledExpression.trimmedDescription
        let calleeTail = calleeText.split(separator: ".").last.map(String.init) ?? calleeText
        guard calleeTail == "AppShortcut" else { return nil }

        var intentTypeName: String?
        var shortTitle: String?
        var systemImageName: String?
        var phrases: [String] = []

        for arg in call.arguments {
            guard let label = arg.label?.text else { continue }
            switch label {
            case "intent":
                intentTypeName = intentTypeFromExpression(arg.expression)
            case "phrases":
                phrases = stringArrayLiteralValue(arg.expression)
            case "shortTitle":
                shortTitle = stringLiteralValue(from: arg.expression)
            case "systemImageName":
                systemImageName = stringLiteralValue(from: arg.expression)
            default:
                fail("Unsupported AppShortcut argument: \(label)")
            }
        }

        guard let intentTypeName, shortTitle != nil, systemImageName != nil, !phrases.isEmpty else {
            fail("AppShortcut requires literal phrases, shortTitle, image, and an intent constructor")
            return nil
        }
        return ScannedShortcut(
            intentTypeName: intentTypeName,
            phrases: phrases,
            shortTitle: shortTitle,
            systemImageName: systemImageName
        )
    }

    /// Extract a type name from `MyIntent()` / `MyIntent.self` /
    /// `Module.MyIntent()` style expressions. Returns the trailing
    /// identifier so module qualification is stripped.
    private func intentTypeFromExpression(_ expr: ExprSyntax) -> String? {
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if !call.arguments.isEmpty {
                fail("Preconfigured shortcut intent arguments are not supported")
                return nil
            }
            return call.calledExpression.trimmedDescription
                .split(separator: ".").last.map(String.init)
        }
        if let memberAccess = expr.as(MemberAccessExprSyntax.self),
           memberAccess.declName.baseName.text == "self" {
            return memberAccess.base?.trimmedDescription
                .split(separator: ".").last.map(String.init)
        }
        fail("Unsupported shortcut intent expression")
        return nil
    }

    private func inheritanceNames(_ clause: InheritanceClauseSyntax?) -> [String] {
        guard let clause else { return [] }
        return clause.inheritedTypes.map { inherited in
            let text = inherited.type.trimmedDescription
            return text.split(separator: ".").last.map(String.init) ?? text
        }
    }

    private func stringLiteralValue(from expr: ExprSyntax?) -> String? {
        guard let expr else { return nil }
        // Plain string literal: `"foo"`.
        if let lit = expr.as(StringLiteralExprSyntax.self) {
            return concatStringLiteralSegments(lit)
        }
        // `LocalizedStringResource("foo")` / `IntentDescription("foo", ...)`.
        if let call = expr.as(FunctionCallExprSyntax.self),
           ["LocalizedStringResource", "TypeDisplayRepresentation", "DisplayRepresentation"].contains(call.calledExpression.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""),
           call.arguments.count == 1,
           let firstArg = call.arguments.first,
           firstArg.label == nil,
           let lit = firstArg.expression.as(StringLiteralExprSyntax.self) {
            return concatStringLiteralSegments(lit)
        }
        return nil
    }

    /// Specifically handles `IntentDescription("foo", categoryName: "bar")`.
    private func intentDescriptionText(from expr: ExprSyntax?) -> String? {
        guard let expr else { return nil }
        if let lit = expr.as(StringLiteralExprSyntax.self) {
            return concatStringLiteralSegments(lit)
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           call.calledExpression.trimmedDescription.split(separator: ".").last == "IntentDescription",
           call.arguments.count == 1,
           let firstArg = call.arguments.first,
           firstArg.label == nil,
           let lit = firstArg.expression.as(StringLiteralExprSyntax.self) {
            return concatStringLiteralSegments(lit)
        }
        return nil
    }

    private func intentDescriptionCategory(from expr: ExprSyntax?) -> String? {
        guard let call = expr?.as(FunctionCallExprSyntax.self) else { return nil }
        for arg in call.arguments where arg.label?.text == "categoryName" {
            return stringLiteralValue(from: arg.expression)
        }
        return nil
    }

    private func booleanValue(from expr: ExprSyntax?) -> Bool? {
        guard let booleanLiteral = expr?.as(BooleanLiteralExprSyntax.self) else { return nil }
        return booleanLiteral.literal.text == "true"
    }

    private func stringArrayLiteralValue(_ expr: ExprSyntax) -> [String] {
        guard let array = expr.as(ArrayExprSyntax.self) else {
            fail("Shortcut phrases must be an array literal")
            return []
        }
        var values: [String] = []
        for element in array.elements {
            if let lit = element.expression.as(StringLiteralExprSyntax.self),
               let s = concatStringLiteralSegments(lit) {
                if s.contains("\\(\\.$") { fail("Parameterized shortcut phrases require unsupported NLU parameter slots") }
                values.append(s)
            } else {
                fail("Every shortcut phrase must be a literal")
            }
        }
        return values
    }

    /// Retain only supported AppIntents interpolation tokens. Literal Swift
    /// escaping is decoded, not copied verbatim into the emitted JSON.
    private func concatStringLiteralSegments(_ lit: StringLiteralExprSyntax) -> String? {
        var out = ""
        guard lit.openingPounds == nil, lit.openingQuote.text == "\"" else {
            fail("Raw and multiline metadata strings are unsupported")
            return nil
        }
        for segment in lit.segments {
            if let str = segment.as(StringSegmentSyntax.self) {
                let quoted = "\"" + str.content.text + "\""
                guard let decoded = try? JSONDecoder().decode(String.self, from: Data(quoted.utf8)) else {
                    fail("Unsupported Swift escape in metadata string")
                    return nil
                }
                out.append(decoded)
            } else if let interp = segment.as(ExpressionSegmentSyntax.self) {
                let expression = interp.expressions.trimmedDescription
                guard expression == ".applicationName" || expression.hasPrefix("\\.$") else {
                    fail("Unsupported metadata interpolation: \(expression)")
                    return nil
                }
                out.append("\\(\(expression))")
            }
        }
        return out
    }

    private func fail(_ message: String) { module.diagnostics.append(message) }

    private static let metadataProtocols = intentProtocols.union([
        "AppEntity", "AppEnum", "AppShortcutsProvider", "EntityQuery", "EntityStringQuery", "EntityPropertyQuery",
    ])

    private func validateType(_ node: some SyntaxProtocol, protocols: [String], generic: Bool) {
        guard !Self.metadataProtocols.isDisjoint(with: protocols) else { return }
        if generic { fail("Generic AppIntents declarations are unsupported") }
        let syntax = Syntax(node)
        let name = syntax.as(StructDeclSyntax.self)?.name.text
            ?? syntax.as(ClassDeclSyntax.self)?.name.text
            ?? syntax.as(EnumDeclSyntax.self)?.name.text ?? ""
        if !name.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 }) {
            fail("Non-ASCII AppIntents type identifiers require unsupported Swift mangling")
        }
        let attributes = syntax.as(StructDeclSyntax.self)?.attributes
            ?? syntax.as(ClassDeclSyntax.self)?.attributes
            ?? syntax.as(EnumDeclSyntax.self)?.attributes
        if let attributes {
            for attribute in attributes {
                guard let value = attribute.as(AttributeSyntax.self) else { continue }
                if !["MainActor", "preconcurrency"].contains(value.attributeName.trimmedDescription) {
                    fail("Unsupported AppIntents declaration attribute: \(value.attributeName.trimmedDescription)")
                }
            }
        }
        var parent = Syntax(node).parent
        while let ancestor = parent {
            if ancestor.is(StructDeclSyntax.self) || ancestor.is(ClassDeclSyntax.self)
                || ancestor.is(EnumDeclSyntax.self) || ancestor.is(ExtensionDeclSyntax.self)
                || ancestor.is(FunctionDeclSyntax.self) {
                fail("Nested AppIntents declarations are unsupported")
                break
            }
            parent = ancestor.parent
        }
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        if !Self.metadataProtocols.isDisjoint(with: inheritanceNames(node.inheritanceClause)) {
            fail("AppIntents conformances declared in extensions are unsupported")
        }
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        if !Self.metadataProtocols.isDisjoint(with: inheritanceNames(node.inheritanceClause)) {
            fail("Custom protocols inheriting AppIntents metadata protocols are unsupported")
        }
        return .visitChildren
    }

    private func propertyExpression(_ binding: PatternBindingSyntax) -> ExprSyntax? {
        if let expression = binding.initializer?.value { return expression }
        guard let accessor = binding.accessorBlock, case .getter(let statements) = accessor.accessors,
              statements.count == 1, let statement = statements.first else { return nil }
        return statement.item.as(ExprSyntax.self) ?? statement.item.as(ReturnStmtSyntax.self)?.expression
    }

    private func scanSummary(_ expression: ExprSyntax?) -> ScannedSummary? {
        guard let call = expression?.as(FunctionCallExprSyntax.self),
              call.calledExpression.trimmedDescription.split(separator: ".").last == "Summary",
              call.arguments.count == 1, let argument = call.arguments.first,
              let literal = argument.expression.as(StringLiteralExprSyntax.self),
              let text = concatStringLiteralSegments(literal) else {
            fail("Only a literal Summary with parameter key paths is supported")
            return nil
        }
        var parameters: [String] = []
        var format = text
        for segment in literal.segments {
            guard let interpolation = segment.as(ExpressionSegmentSyntax.self) else { continue }
            let key = interpolation.expressions.trimmedDescription
            guard let name = parameterKeyPath(key) else { return nil }
            parameters.append(name)
            format = format.replacingOccurrences(of: "\\(\(key))", with: "${\(name)}")
        }
        var others: [String] = []
        if let closure = call.trailingClosure {
            for statement in closure.statements {
                guard let name = parameterKeyPath(statement.item.trimmedDescription) else { return nil }
                others.append(name)
            }
        }
        return ScannedSummary(formatString: format, parameters: parameters, otherParameters: others)
    }

    private func parameterKeyPath(_ expression: String) -> String? {
        guard expression.hasPrefix("\\.$") else {
            fail("Unsupported summary key path: \(expression)")
            return nil
        }
        let name = String(expression.dropFirst(3))
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            fail("Unsupported summary key path: \(expression)")
            return nil
        }
        return name
    }

    /// Returns true when `type` is, or contains as a nested component, an
    /// identifier whose trailing name matches `name`. Used to detect
    /// `ReturnsValue<...>` inside opaque/composition return types like
    /// `some IntentResult & ReturnsValue<String>`. Walks
    /// `IdentifierTypeSyntax`, `MemberTypeSyntax`, `CompositionTypeSyntax`,
    /// `SomeOrAnyTypeSyntax`, and any generic argument lists.
    static func typeMentions(_ type: TypeSyntax, name: String) -> Bool {
        if let ident = type.as(IdentifierTypeSyntax.self) {
            if ident.name.text == name { return true }
            if let args = ident.genericArgumentClause?.arguments {
                for arg in args {
                    if case .type(let argument) = arg.argument, typeMentions(argument, name: name) {
                        return true
                    }
                }
            }
            return false
        }
        if let member = type.as(MemberTypeSyntax.self) {
            if member.name.text == name { return true }
            if let args = member.genericArgumentClause?.arguments {
                for arg in args {
                    if case .type(let argument) = arg.argument, typeMentions(argument, name: name) {
                        return true
                    }
                }
            }
            return typeMentions(TypeSyntax(member.baseType), name: name)
        }
        if let composition = type.as(CompositionTypeSyntax.self) {
            for element in composition.elements {
                if typeMentions(element.type, name: name) { return true }
            }
            return false
        }
        if let some = type.as(SomeOrAnyTypeSyntax.self) {
            return typeMentions(some.constraint, name: name)
        }
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return typeMentions(attributed.baseType, name: name)
        }
        return false
    }
}

