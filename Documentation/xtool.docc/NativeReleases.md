# Native iOS and watchOS releases

Build an existing Swift application and its companion Watch app from Linux, with release tooling shared between projects.

## Install the source-built tools

Use Swift 6.4 for the host tools. Install Clang, CMake, Ninja, Make, Git, pkg-config, Python 3.11 or newer with venv/pip, ImageMagick, OpenSSL, and development headers for OpenSSL, zlib, libbsd, and libuuid. SVG asset inputs also require `rsvg-convert`. App Store Connect upload additionally requires an authenticated [asc CLI](https://github.com/rudrankriyam/App-Store-Connect-CLI).

The installed tools need the same working Swift runtime environment used to build them. On distributions requiring a Swift compatibility-library path, preserve that environment when launching `xtool`; an external workstation launcher can source it without putting machine-specific paths in application repositories.

From the xtool checkout:

```bash
scripts/build-linux-toolset.sh "$HOME/.cache/xtool-native"
scripts/build-native-release-tools.sh
export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/xtool/native/bin:$PATH"
```

Both scripts accept an optional absolute installation prefix; the default is `${XDG_DATA_HOME:-$HOME/.local/share}/xtool/native`. Set `XTOOL_NATIVE_HOME` when using a different prefix. `JOBS` controls build parallelism. `XTOOL_NATIVE_BUILD_DIR` selects the resource/signing build directory.

The work directories contain rebuildable intermediates. Runtime helpers, Python environment, toolset, and macro server are installed outside caches. Repaired AssetKit, zsign, and OpenAppleMacros sources and their licenses live in `Vendor`; the resource package pins its remaining Swift dependencies. No editable SwiftPM dependency points into an application cache.

Install the Darwin SDK from your own Xcode download as described in <doc:Installation-Linux>, selecting these tools:

```bash
native="${XTOOL_NATIVE_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/xtool/native}"
xtool sdk install /path/to/Xcode.xip \
  --toolset "$native/toolset" \
  --macros-server "$native/bin/OpenAppleMacrosServer"
```

For an existing normal SDK, use `xtool sdk update` with the same two options instead. Release assembly and compilation use the same SDK selected by xtool's SwiftPM configuration directory (`XDG_CONFIG_HOME/swiftpm`, or `~/.swiftpm`). Choose an application compiler compatible with the imported SDK; the manifest's `swiftVersion` selects an installed Swiftly toolchain without changing the global Swift selection. `--toolchain` accepts an explicit toolchain directory.

Normal builds automatically upgrade an obsolete normal SDK and retain its saved custom toolset and macro-server selections. SDK epoch 5 invalidates installations predating native Foundation/SwiftData plugin routing. Replacing an installed custom macro-server executable does not replace the copy inside an otherwise current SDK: run `xtool sdk update` after rebuilding that server, without repeating the tooling options.

## Keep only application configuration in the application repository

Create `xtool-release.yml` beside the canonical project:

```yaml
version: 1
project: project.yml             # XcodeGen YAML, or Example.xcodeproj
target: Example
swiftVersion: 6.3.3
appStoreConnect:
  appID: "1234567890"             # Public identifier, required only for upload
  locale: en-US
  testNotes: Verify the iPhone app, Watch app, widgets and extensions.
```

The importer follows the project's embedded-product graph rather than a second target list: application, iOS extensions, companion Watch application, and Watch extensions. Swift package dependencies, source membership, resources, Info.plist values, requested entitlements, deployment targets, and supported compiler settings come from the original project. Application sources are not rewritten.

A launcher can be shared unchanged between applications:

```bash
#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${XTOOL:-xtool}" release --config "$repo/xtool-release.yml" "$@"
```

Save it as `scripts/build-release.sh` and make it executable. Add `.xtool/` to the application's `.gitignore`.

```bash
scripts/build-release.sh --prepare-only
scripts/build-release.sh --unsigned       # Complete ad-hoc smoke IPA; not TestFlight-installable
scripts/build-release.sh                  # Distribution signing with external identity
scripts/build-release.sh --upload         # Explicit Apple upload and processing/access checks
```

`--build-number` selects a decimal build number; otherwise the current Unix timestamp is used. Output is `.xtool/releases/<build-number>/` by default, or `<directory>/<build-number>/` with `--output <directory>`. Existing release directories are never replaced. Each release contains `Payload`, an IPA, `release.json`, and `verification.json`.

`--prepare-only` creates `.xtool/workspace/project.json` and a disposable SwiftPM/xtool wrapper. It does not sign or upload, but declared resource-generation scripts do execute. Treat imported projects and their scripts as executable code. Build caches remain reusable when the generated wrapper is refreshed.

## Keep signing and API credentials outside repositories

Default signing configuration:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/xtool/signing/<root-bundle-id>.yml
```

Use `--signing /private/location/signing.yml` or `XTOOL_SIGNING_CONFIG` to override it. A signing file contains paths, never inline credentials:

```yaml
certificate: /private/location/distribution.cer
privateKey: /private/location/distribution.key
profiles:
  com.example.app: /private/location/App.mobileprovision
  com.example.app.widget: /private/location/Widget.mobileprovision
  com.example.app.watchkitapp: /private/location/Watch.mobileprovision
  com.example.app.watchkitapp.widget: /private/location/WatchWidget.mobileprovision
```

Use a DER distribution certificate, its matching unencrypted PEM private key, and an App Store distribution profile for every bundle. Relative paths are resolved beside the signing file. Protect the directory with mode `0700` and the configuration/private files with mode `0600`. The CLI rejects signing configurations and signing inputs inside the application project. Do not put them in the xtool checkout either.

The pipeline validates certificate validity/key matching, profile expiry, bundle identity, distribution mode, and each requested entitlement against its profile. It does not provision or revoke identities. It preserves requested capabilities instead of copying all profile entitlements. Signing keys and configuration files are not copied into workspaces or artifacts; the signed app necessarily contains its public certificate signature and embedded provisioning profiles.

Authenticate `asc` separately using its protected credential store. Upload happens only with `--upload`, never as part of installation, preparation, or ordinary builds. `appStoreConnect.appID`, optional `groupIDs`, locale and test notes are public release metadata. Upload checks the exact version/build for `VALID`, unexpired status, beta-testing availability, and related TestFlight groups; it does not silently publish a public App Store release or enroll testers.

Manifest `settings` and `requiredEnvironment` are **public build configuration**. Their values may be embedded in the application or generated workspace. An OAuth client identifier can go there; an OAuth client secret, API private key, password, or access token cannot.

## Reuse boundaries

Supported inputs include direct XcodeGen target specifications and Xcode project Release configurations with ordinary or synchronized source groups, system frameworks, and Swift package products. Unsupported project constructs fail explicitly: xcconfig indirection, XcodeGen includes/templates, custom build rules, non-embedded project dependencies, unsupported per-file settings, or non-Swift application sources. Expand such configuration or extend the importer rather than dropping a target.

The generated Swift package has one deployment target per platform. iOS and watchOS may differ; products on the same platform must share a deployment target. Mixed per-product versions fail before building instead of silently lowering an extension's minimum OS.

Resource scripts must declare output files inside the staged bundle-resource directory. Validation-only shell phases may be named in `skippedBuildScripts` with a reason; run those projects' lint/format gates separately. Never skip a phase that generates required app data.

Native asset compilation preserves supported colors, images and app-icon appearances, including modern Watch icon metadata. Native SwiftSyntax extraction supplies AppIntents actions, entity/query/enum metadata and shortcut phrases; unsupported metadata forms fail rather than receiving placeholder records. The source-built macro server handles the supported SwiftData model/property/relationship/uniqueness forms, SwiftUI `@Query` backed by SwiftData's real `DynamicProperty`, and pinned upstream Foundation predicates/expressions configured for Darwin rather than the Linux host. This is not a general replacement for every Xcode build phase, asset-catalog feature, or proprietary compiler macro.

Applications using `@Query` with synthesized memberwise view initializers need Swift 6.4 or newer. Its [SE-0502 initialization rules](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0502-exclude-private-from-memberwise-init.md) exclude initialized private macro storage; older Linux compilers otherwise make the view initializer private. Select that compiler in the application's `swiftVersion` rather than exposing backing storage or rewriting views.

SwiftData property markers require a property directly inside an `@Model` class; a nested non-model class does not inherit that permission. Generated private backing-data, observation-registrar and initialization-marker storage does not invoke `@Transient`, so the compiler's missing lexical context for generated peers needs no validation exception. User-written storage lookalikes still receive the same strict marker validation. Inheritance, generic models and `#Index` remain explicit errors rather than silently losing schema semantics.

A compiler smoke using the installed SDK verified model initialization, relationships, external-storage attributes, uniqueness, Foundation predicates, real `Query` storage, `@Bindable` editing and cross-file synthesized view initializers for iOS `arm64` and both watchOS device architectures. Emitted SwiftData/Observation calls and rejection of transient properties outside a directly enclosing model were checked. These are compiler/binding-path checks, not execution of Apple's persistence or SwiftUI runtime.

Release verification checks the complete expected bundle and architecture inventory, Mach-O platform/deployment/SDK records, host-only load paths, code-page and signed-resource hashes, requested entitlements, signing certificates, CMS signatures, and strict universal-binary extents. Watch device bundles contain `arm64_32` and `arm64` slices, with the watchOS 26 deployment floor applied only to `arm64`. Allocation slack after a signature SuperBlob is distinct from forbidden bytes after the final universal slice; [Apple's parser](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_utilities/lib/superblob.h) bounds indexed signature data by the blob's own length.

Both SwiftPM build backends retain archived application and extension code whose entry points are resolved by the system. The SDK wrapper implements Swift Build's relocatable-object link (`-r`) as a static archive; both product wrappers therefore use `-all_load` to extract runtime-only members before normal `-dead_strip` processing. Public visibility and `N_NO_DEAD_STRIP` metadata cannot retain a member that was never extracted from its archive.

For AppIntents, inspect the final application executable as well as its extensions: source-generated metadata JSON does not prove that callable implementations, type descriptors, and protocol-conformance records survived compilation and linking. In Swift 6.4, explicitly declare `AppIntent` alongside `LiveActivityIntent` rather than relying on the inherited protocol to propagate metadata retention.

Both backends pass the selected SDK version to the Linux linker explicitly. The native signer supports executables without a `__text` section and refuses to insert a signature load command unless the entire command fits before the first file-backed section.

A successful build and local verification do not prove device behavior or Apple acceptance. Exercise SwiftData persistence/migrations, Watch installation/sync, widgets, AppIntents and protected capabilities on devices. `--unsigned` specifically does not establish distribution signing or TestFlight readiness.

### Additional application checks

The installed native CLI was also exercised with the XcodeGen projects in `plastic-karma/obsidian-git-mobile` (VaultLink) and `plastic-karma/weight-track` (Still), using Swift 6.4 and the iPhoneOS 26.5 SDK. Both retained their iOS 17 minimum, iPhone/iPad families, original local Swift package dependencies, app source membership, artwork, and privacy manifests without app-source or xtool implementation changes. VaultLink also compiled its transitive Yams/CYaml dependency and retained its public OAuth client ID and third-party licenses.

VaultLink 1.3.0 (1790710501) produced an ad-hoc IPA; Still 1.1.0 (1790710501) produced a distribution-signed IPA using its existing external identity/profile, preserving HealthKit and background delivery without adding profile-only Health Records access. Both passed local release verification and archive-to-Payload byte checks. These runs did not upload to Apple or execute on a device.

The builds still emit Swift Build's language-mode override warning. VaultLink's canonical Swift 5 language mode also permits existing `Sendable` diagnostics in `BaseDocument`; a move to Swift 6 language mode requires addressing those app diagnostics rather than suppressing them or silently changing the project's language mode.

## Development checks

```bash
swift test
swift test --package-path Vendor/OpenAppleMacros
swift test --package-path Tools/NativeResources
PYTHONPATH=Tools/Release python3 -m unittest discover -s Tools/Release/tests
make lint
```

Run the Python checks in an environment with `Tools/Release/requirements.txt` installed. Build and exercise an actual app release as well; unit tests alone do not verify the imported SDK, native resources, signer, or complete bundle graph.

On Linux, SwiftLint needs the active toolchain's SourceKit library. If it is outside the system library search path, set `LINUX_SOURCEKIT_LIB_PATH` to that toolchain's `usr/lib` directory when running `make lint`.
