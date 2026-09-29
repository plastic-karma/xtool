import Foundation

/// Protocol metadata observed in Xcode-generated metadata. LiveActivityIntent
/// is SessionStarting (not the guessed LiveActivity string in PR #217).
public enum SystemProtocols {
    private static let mappings: [String: [String]] = [
        "AppIntent": [],
        "LiveActivityIntent": ["com.apple.link.systemProtocol.SessionStarting"],
        "WidgetConfigurationIntent": ["com.apple.link.systemProtocol.WidgetConfiguration"],
        "ControlConfigurationIntent": ["com.apple.link.systemProtocol.ControlConfiguration"],
        "AudioRecordingIntent": [
            "com.apple.link.systemProtocol.SessionStarting",
            "com.apple.link.systemProtocol.AudioRecording",
        ],
        "Sendable": [],
    ]

    public static func resolve(for protocols: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in protocols {
            guard let entries = mappings[name] else {
                throw MetadataError("Unsupported AppIntent conformance \(name); no verified metadata mapping")
            }
            for entry in entries where seen.insert(entry).inserted { result.append(entry) }
        }
        return result
    }
}
