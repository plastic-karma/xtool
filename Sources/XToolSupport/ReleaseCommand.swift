import Foundation
import ArgumentParser
import Subprocess
import XUtils

struct ReleaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Build, verify, and optionally upload an iOS/watchOS release from an app manifest",
        discussion: "Install tools with scripts/build-native-release-tools.sh. See xtool release --help.",
        helpNames: []
    )

    @Argument(parsing: .captureForPassthrough)
    var arguments: [String] = []

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executableName = CommandLine.arguments[0]
        let executable: Executable = executableName.contains("/")
            ? .path(FilePath(executableName)) : .name(executableName)
        let currentExecutable = try await executable.resolveExecutablePath(in: .inherit)
        let executableURL = URL(filePath: String(describing: currentExecutable)).resolvingSymlinksInPath()
        let installedPrefix = executableURL.deletingLastPathComponent().deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataHome = environment["XDG_DATA_HOME"] ?? home.appending(path: ".local/share").path
        let hasInstalledRuntime = FileManager.default.fileExists(
            atPath: installedPrefix.appending(path: "libexec/xtool_release/__main__.py").path
        )
        let nativePath = environment["XTOOL_NATIVE_HOME"]
            ?? (hasInstalledRuntime ? installedPrefix.path : "\(dataHome)/xtool/native")
        guard nativePath.hasPrefix("/") else {
            throw Console.Error("XTOOL_NATIVE_HOME and XDG_DATA_HOME must be absolute paths")
        }
        let native = URL(fileURLWithPath: nativePath, isDirectory: true)
        let python = native.appending(path: "venv/bin/python3")
        let modules = native.appending(path: "libexec")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: modules.appending(path: "xtool_release/__main__.py").path) else {
            throw Console.Error("""
            Native release tools are not installed at \(native.path).
            Run scripts/build-native-release-tools.sh.
            """)
        }
        let overrides: [Environment.Key: String?] = [
            "PYTHONPATH": modules.path,
            "XTOOL_NATIVE_HOME": native.path,
            "XTOOL": executableURL.path,
        ]
        let result = try await Subprocess.run(
            .path(FilePath(python.path)),
            arguments: .init(["-m", "xtool_release"] + arguments),
            environment: .inherit.updating(overrides),
            output: .currentStandardOutput,
            error: .currentStandardError
        )
        switch result.terminationStatus {
        case .exited(let code) where code != 0:
            throw ExitCode(code)
        default:
            try result.checkSuccess()
        }
    }
}
