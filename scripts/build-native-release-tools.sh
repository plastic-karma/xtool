#!/usr/bin/env bash
# Build reusable resource/signing tools and install the release runtime outside caches.
set -euo pipefail
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [INSTALL_PREFIX]" >&2
    exit 2
fi
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
prefix=${1:-${XTOOL_NATIVE_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/xtool/native}}
[[ "$prefix" = /* ]] || { echo 'Install prefix must be absolute' >&2; exit 2; }
build=${XTOOL_NATIVE_BUILD_DIR:-$root/.build/native-release}
jobs=${JOBS:-8}
for tool in swift python3 cmake ninja cc c++ magick openssl; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
mkdir -p "$prefix/bin" "$prefix/lib" "$prefix/libexec/xtool_release"
python3 -m venv "$prefix/venv"
"$prefix/venv/bin/python3" -m pip install --disable-pip-version-check -r "$root/Tools/Release/requirements.txt"

swift build --package-path "$root/Tools/NativeResources" --scratch-path "$build/resources" -c release --force-resolved-versions -j "$jobs"
resources_bin=$(swift build --package-path "$root/Tools/NativeResources" --scratch-path "$build/resources" -c release --show-bin-path)
for tool in xtool-native-assets xtool-appintents-gen; do
    install -m 755 "$resources_bin/$tool" "$prefix/bin/$tool"
done
cmake -S "$root/Tools/Signing" -B "$build/signing" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix"
cmake --build "$build/signing" -j "$jobs"
cmake --install "$build/signing"

# Only versioned Python sources are runtime inputs; no app config, keys or caches.
install -m 644 "$root"/Tools/Release/xtool_release/*.py "$prefix/libexec/xtool_release/"
install -m 755 "$root/scripts/xtool-debug" "$prefix/bin/xtool-debug"
swift build --package-path "$root" --product xtool -j "$jobs"
xtool_bin=$(swift build --package-path "$root" --show-bin-path)
install -m 755 "$xtool_bin/xtool" "$prefix/bin/xtool"
shopt -s nullglob
for resource in "$xtool_bin"/*.resources "$xtool_bin"/*.bundle "$resources_bin"/*.resources "$resources_bin"/*.bundle; do
    cp -R "$resource" "$prefix/bin/"
done
# SwiftPM products can contain package-owned shared libraries (notably XADI).
# Preserve their $ORIGIN lookup when the CLI is moved out of the build tree.
for library in "$xtool_bin"/*.so*; do
    install -m 755 "$library" "$prefix/bin/"
done
printf 'Installed native release tools: %s\nCLI: %s/bin/xtool\n' "$prefix" "$prefix"
printf 'Add that bin directory to PATH, or set XTOOL in the app release wrapper.\n'
