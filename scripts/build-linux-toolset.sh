#!/usr/bin/env bash
# Build Linux-hosted Darwin tools, including the arm64_32 linker required by watchOS.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 WORK_DIRECTORY [INSTALL_PREFIX]" >&2
    exit 2
fi
mkdir -p "$1"
work=$(realpath "$1")
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
install_prefix=${2:-${XTOOL_NATIVE_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/xtool/native}}
[[ "$install_prefix" = /* ]] || { echo 'Install prefix must be absolute' >&2; exit 2; }
jobs=${JOBS:-8}
cc=${CC:-clang}
cxx=${CXX:-clang++}
for tool in git cmake ninja make swift python3 "$cc" "$cxx" pkg-config; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
cc=$(command -v "$cc")
cxx=$(command -v "$cxx")
swift_lib=$(swift -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])')

source_at() {
    local url=$1 directory=$2 revision=$3
    if [[ ! -e "$directory/.git" ]]; then
        git clone --filter=blob:none --no-checkout "$url" "$directory"
        git -C "$directory" fetch --depth 1 origin "$revision"
        git -C "$directory" checkout --detach "$revision"
    fi
    if [[ $(git -C "$directory" rev-parse HEAD) != "$revision" ]]; then
        echo "Unexpected source revision in $directory; expected $revision" >&2
        exit 1
    fi
}

source_at https://github.com/xtool-org/darwin-tools-linux-llvm.git \
    "$work/darwin-tools-linux-llvm" 4a2fbb018370ccd7455947a91de263107baa6031
source_at https://github.com/kabiroberai/llvm-project.git \
    "$work/darwin-tools-linux-llvm/llvm-project" 7ae80f745b07d2c99733b09dccf27bf68a1b271c
source_at https://github.com/tpoechtrager/apple-libtapi.git \
    "$work/apple-libtapi" fa9443738c1a18accef4244732ec6d6ee97a8133
source_at https://github.com/tpoechtrager/cctools-port.git \
    "$work/cctools-port" 904de2a71d4da6a9b30d2efaf912a10ddc7d9ddb

llvm="$work/darwin-tools-linux-llvm"
cmake -S "$llvm/llvm-project/llvm" -B "$llvm/build/cmake" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_TARGETS_TO_BUILD='AArch64;X86' -DLLVM_ENABLE_PROJECTS=lld \
    -DCMAKE_C_COMPILER="$cc" -DCMAKE_CXX_COMPILER="$cxx"
cmake --build "$llvm/build/cmake" -j "$jobs" --target \
    dsymutil lld llvm-libtool-darwin llvm-lipo llvm-install-name-tool

prefix="$work/native-tools"
cmake -S "$work/apple-libtapi/src/llvm" -B "$work/apple-libtapi/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=RELEASE -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_ENABLE_PROJECTS='tapi;clang' -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_C_COMPILER="$cc" -DCMAKE_CXX_COMPILER="$cxx" \
    -DTAPI_REPOSITORY_STRING=1600.0.11.8 -DTAPI_FULL_VERSION=1600.0.11.8
cmake --build "$work/apple-libtapi/build" -j "$jobs" --target clangBasic vt_gen libtapi
(cd "$work/apple-libtapi" && ./install.sh)
(
    cd "$work/cctools-port/cctools"
    CC="$cc" CXX="$cxx" \
        CPPFLAGS="-I$swift_lib -I$swift_lib/Block" \
        LDFLAGS="-L$swift_lib/linux -Wl,-rpath,$swift_lib/linux" \
        ./configure --prefix="$prefix" --with-libtapi="$prefix" --disable-xar-support
    make -j "$jobs"
    make install
)

macro_build="${XTOOL_NATIVE_BUILD_DIR:-$root/.build/native-release}/macros"
swift build --package-path "$root/Vendor/OpenAppleMacros" --scratch-path "$macro_build" \
    -c release --product OpenAppleMacrosServer --force-resolved-versions -j "$jobs"
macro_bin=$(swift build --package-path "$root/Vendor/OpenAppleMacros" --scratch-path "$macro_build" -c release --show-bin-path)

stage="$work/toolset"
mkdir -p "$stage/bin" "$stage/lib"
cp "$llvm/build/cmake/bin/lld" "$stage/bin/lld-native"
cp "$llvm/build/cmake/bin/llvm-libtool-darwin" "$stage/bin/libtool"
for binary in dsymutil llvm-lipo llvm-install-name-tool; do
    cp -L "$llvm/build/cmake/bin/$binary" "$stage/bin/$binary"
done
cp "$prefix/bin/ld" "$stage/bin/ld64"
cp -L "$prefix/lib/libtapi.so.17" "$stage/lib/"
cp -L "$swift_lib/linux/libBlocksRuntime.so" "$swift_lib/linux/libdispatch.so" "$stage/lib/"
cat > "$stage/bin/ld64.lld" <<'LINKER'
#!/bin/sh
# xtool moves this entrypoint into bin/orig during SDK installation.
set -eu
bin_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if [ "${bin_dir##*/}" = orig ]; then bin_dir=${bin_dir%/*}; fi
arch=
previous=
for argument do
    if [ "$previous" = -arch ]; then arch=$argument; fi
    previous=$argument
done
export LD_LIBRARY_PATH="$bin_dir/../lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if [ "$arch" = arm64_32 ]; then exec "$bin_dir/ld64" "$@"; fi
exec "$bin_dir/lld-native" -flavor darwin "$@"
LINKER
chmod +x "$stage/bin/ld64.lld"
swift build --package-path "$root" --product xtool -j "$jobs"
mkdir -p "$install_prefix/toolset" "$install_prefix/bin"
cp -R "$stage/." "$install_prefix/toolset/"
install -m 755 "$macro_bin/OpenAppleMacrosServer" "$install_prefix/bin/OpenAppleMacrosServer"
printf 'Toolset: %s/toolset\nMacro server: %s/bin/OpenAppleMacrosServer\n' "$install_prefix" "$install_prefix"
