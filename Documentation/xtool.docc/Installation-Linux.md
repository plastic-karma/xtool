# Installation (Linux/Windows)

Set up xtool for iOS app development on Linux or Windows.

## Overview

This article outlines the steps to install `xtool` and begin developing iOS apps on Linux (or Windows via WSL).

## Prerequisites

### WSL (for Windows users)

If you're on Windows, you can use xtool via [Windows Subsystem for Linux](https://learn.microsoft.com/en-us/windows/wsl/install) (WSL).

Once you install WSL, you'll also need to set up USB passthrough. See Microsoft's instructions on [installing USBIPD](https://learn.microsoft.com/en-us/windows/wsl/connect-usb). Make sure you're able to bind your iOS device to WSL via USB.

> Note:
>
> If you encounter `Error: AFCClient.Error.muxError`, follow the steps described in [this issue comment](https://github.com/xtool-org/xtool/issues/19#issuecomment-2898986718) from user rena2019.
>
> This relays the device connection from iTunes on Windows, instead of relying on USBIPD.

### Swift

Install the Swift 6.4 toolchain for your Linux distribution from <https://swift.org/install/linux>.

After following the steps there, confirm that Swift is installed correctly:

```bash
swift --version
# should say something like:
# Swift version 6.4 (swift-6.4-RELEASE)
```

### usbmuxd

xtool relies on [usbmuxd](https://github.com/libimobiledevice/usbmuxd) to talk to your iOS device from Linux.

Your Linux distro probably offers this package, and it may be preinstalled. To check if it is, run

```bash
usbmuxd --help
# Usage: usbmuxd [OPTIONS]
# ...
```

If instead you get "command not found", you need to install `usbmuxd` yourself. On Ubuntu/Debian, for example, you can do this with

```bash
sudo apt-get install usbmuxd
```

> Other useful tools:
>
> `usbmuxd` is part of the [libimobiledevice](https://libimobiledevice.org) project. You may want to install other libimobiledevice tools, such as `ideviceinfo`, that offer many ways to interact with your iOS device from the command line. On Ubuntu/Debian, you can run
>
> ```bash
> sudo apt-get install libimobiledevice-utils
> # The following NEW packages will be installed:
> #   libimobiledevice-utils
> # 0 upgraded, 1 newly installed
> ideviceinfo
> # DeviceName: Kabir's iPhone
> # SerialNumber: ...
> # UniqueDeviceID: ...
> # ...
> ```

### Xcode.xip

Download **Xcode 27** from <https://developer.apple.com/download/all/?q=Xcode>. Note the path where `Xcode.xip` is saved.

> Note:
>
> The URL above requires authentication, so make sure to visit it in your browser rather than running `curl`. You'll be asked to log in with your Apple ID and accept the license agreement to download Xcode.

## Installation

### 1. Download xtool

Once you have the prerequisites, download the [latest GitHub Release](https://github.com/xtool-org/xtool/releases/latest) of `xtool.AppImage` for your architecture. Rename it to `xtool` and add it to a location in your `PATH`.

```bash
curl -fL \
  "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" \
  -o xtool
chmod +x xtool
sudo mv xtool /usr/local/bin/
```

Confirm that xtool is installed correctly:

```bash
xtool --help
# OVERVIEW: Cross-platform Xcode replacement
# ...
```

### 2. Configure xtool: log in

Perform one-time setup with

```bash
xtool setup
```

You'll be asked to log in:

```
Select login mode
0: API Key (requires paid Apple Developer Program membership)
1: Password (works with any Apple ID but uses private APIs)
Choice (0-1):
```

> Choosing a login mode:
>
> **API Key:** If you have a paid [Apple Developer Program](https://developer.apple.com/programs/enroll/) membership, this is the recommended option. It relies on the public App Store Connect API. You'll want to follow the [instructions](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api) to generate a **Team Key** with the **App Manager** role.
>
> **Password:** If you aren't enrolled in the paid developer program, you'll want to use password-based authentication. This relies on private Apple APIs to authenticate, so you may want to create a throwaway Apple ID to be extra cautious.

Once you select a login mode, you'll be asked to provide the corresponding credentials (API key or email+password+2FA). Needless to say, *your credentials are only sent to Apple* and nobody else (feel free to build xtool from source and check!)

### 3. Configure xtool: SDK

After you're logged in, you'll be asked to provide the path to the `Xcode.xip` file you downloaded earlier.

```
Choice (0-1): 0
...
Path to Xcode.xip:
```

Enter the path (for example `~/Downloads/Xcode_27.0.xip`) and hit enter. xtool will extract the Xcode XIP to generate and install an iOS Swift SDK for you.

Confirm that it worked:

```bash
swift sdk list
# darwin
```

### Building the toolset locally

The SDK includes WatchOS and WatchSimulator when supplied by Xcode. Device Watch apps need an `arm64_32` linker in addition to the normal `arm64` linker; the released LLVM toolset does not provide that architecture.

From an xtool source checkout, build the pinned LLVM tools, Apple ld64/TAPI port, OpenAppleMacros server, and local xtool executable:

```bash
# Requires Swift 6.4, Clang, CMake, Ninja, Make, Git, pkg-config,
# and development headers for OpenSSL, zlib, libbsd, and libuuid.
scripts/build-linux-toolset.sh "$HOME/.cache/xtool-native"
```

The Watch-capable signer is vendored in `Vendor/zsign`, with its upstream revision and repairs recorded in `UPSTREAM.json`. It fixes universal-container padding, per-slice executable bounds, ARM64 page/segment alignment, and dual-hash CMS attributes. Apple's [strict universal-binary validation](https://github.com/apple-oss-distributions/Security/blob/main/OSX/include/security_utilities/macho%2B%2B.cpp) rejects any bytes after the final slice, even when every CodeDirectory hash verifies. There is no editable dependency on a cache directory.

The script installs the toolset and source-built macro server under `${XDG_DATA_HOME:-$HOME/.local/share}/xtool/native`, or the absolute prefix supplied as its second argument. Pass these durable locations to `xtool sdk install`, or replace the tooling of an existing normal SDK with `xtool sdk update`:

```bash
XTOOL_BIN="$(swift build --show-bin-path)/xtool"
NATIVE="${XTOOL_NATIVE_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/xtool/native}"
"$XTOOL_BIN" sdk update \
  --toolset "$NATIVE/toolset" \
  --macros-server "$NATIVE/bin/OpenAppleMacrosServer"
```

`--toolset` expects `bin/ld64.lld`, `bin/libtool`, `bin/dsymutil`, `bin/llvm-lipo`, and `bin/llvm-install-name-tool`. The entire directory is copied, including supporting libraries. `--macros-server` is copied separately. Both options are also available on `xtool sdk build` and `xtool sdk install` with Xcode input.

Normal SDK updates retain the custom source locations in `sdk-tooling.json`; keep those locations available or supply replacement paths when updating. An unavailable custom source is an error, not a fallback to downloaded tools.

Use a Swift compiler compatible with the imported SDK and your app's source. xtool selects Swift Build with Swift 6.4 or newer, and the native SwiftPM backend with older supported compilers. Installing or updating the SDK copies the selected host compiler's Clang headers while retaining Apple's runtime libraries.

## Next steps

You're now ready to use xtool! See <doc:First-app>.

For reusable Xcode/XcodeGen app builds, native resources, external distribution signing, and explicit TestFlight upload, see <doc:NativeReleases>.
