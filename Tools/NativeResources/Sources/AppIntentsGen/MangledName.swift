import Foundation

/// Computes the lightweight Apple "mangled type name" string used inside
/// `Metadata.appintents/extract.actionsdata`.
///
/// The format observed in shipping iOS apps (e.g. Wispr Flow 1.55) is a
/// stripped-down form of Swift symbol mangling, not the full Swift ABI
/// mangled symbol that nm/dyld would emit. Concretely:
///
///     <moduleLength><moduleName><typeLength><typeName><kindSuffix>
///
/// where `kindSuffix` is `V` for `struct`, `C` for `class`, `O` for `enum`.
/// Examples from Wispr:
///   * `Flow.StartStopRecordingAppIntent` (struct)
///       → `4Flow27StartStopRecordingAppIntentV`
///   * `Widgets.NoteAppIntent` (struct in widget extension)
///       → `7Widgets13NoteAppIntentV`
///   * `Flow.ShortcutsProvider` (autoShortcutProviderMangledName)
///       → `4Flow17ShortcutsProviderV`
///
/// We deliberately do NOT prefix `$s` (the Swift 5 mangling marker) — Apple's
/// AppIntents pipeline uses the bare `<len><name>` grammar internally and the
/// daemon recognises it without the Swift prefix.
///
/// The scanner rejects nested and generic metadata declarations. Expanded
/// identifiers are valid Swift manglings; compiler output may compress repeated
/// words with substitutions, but the runtime resolves either spelling.
public enum MangledName {

    /// Module and type identifiers are ASCII; byte lengths are the ABI units.
    public static func encode(
        module: String,
        typeName: String,
        kind: ScannedDeclKind
    ) -> String {
        "\(module.utf8.count)\(module)\(typeName.utf8.count)\(typeName)\(kind.mangledSuffix)"
    }
}
