"""Attach a forwarded Apple debugserver before handing its connection to LLDB."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import select
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading


def packet(payload: str) -> bytes:
    data = payload.encode("ascii")
    return b"$" + data + b"#" + f"{sum(data) & 255:02x}".encode("ascii")


def receive_exact(connection: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            raise EOFError("debugserver disconnected during attach")
        data.extend(chunk)
    return bytes(data)


def attach(connection: socket.socket, pid: int) -> None:
    connection.sendall(packet(f"vAttach;{pid:x}"))
    while True:
        marker = receive_exact(connection, 1)
        if marker == b"$":
            break
        if marker == b"-":
            raise RuntimeError("debugserver rejected the attach packet checksum")
        if marker != b"+":
            raise RuntimeError(f"Unexpected debugserver packet marker: {marker!r}")
    response = bytearray()
    while (character := receive_exact(connection, 1)) != b"#":
        response.extend(character)
        if len(response) > 1024 * 1024:
            raise RuntimeError("debugserver attach response exceeds 1 MiB")
    checksum = receive_exact(connection, 2)
    if int(checksum, 16) != sum(response) & 255:
        raise RuntimeError("Invalid debugserver attach response checksum")
    connection.sendall(b"+")
    if response[:1] not in (b"T", b"S"):
        raise RuntimeError(
            f"Device refused attach ({response.decode('ascii', errors='replace')}). "
            "Use a development-signed app with get-task-allow=true, unlock the phone, "
            "and enable Developer Mode. TestFlight builds cannot be attached."
        )


def relay(listener: socket.socket, upstream: socket.socket) -> None:
    downstream, _ = listener.accept()
    upstream.settimeout(None)
    with downstream:
        while True:
            ready, _, _ = select.select([upstream, downstream], [], [])
            for source in ready:
                data = source.recv(65536)
                if not data:
                    return
                (downstream if source is upstream else upstream).sendall(data)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path, help="Matching local Mach-O executable")
    parser.add_argument("--pid", type=int, required=True, help="Running iPhone application PID")
    parser.add_argument("--port", type=int, default=62078, help="Loopback debugserver forwarding port")
    parser.add_argument("--lldb", default="lldb", help="Swift LLDB executable or launcher")
    parser.add_argument("--symbols", type=Path, help="Raw dSYM Contents/Resources/DWARF executable")
    parser.add_argument("--remote-executable", help="Installed executable path reported by the phone")
    parser.add_argument("--sysroot", type=Path, help="Extracted device OS symbols root (not the compiler SDK)")
    parser.add_argument("--sdk", type=Path, help="Matching iPhoneOS compiler SDK for Swift expressions")
    parser.add_argument("-o", "--command", action="append", default=[], help="LLDB command before connecting")
    args = parser.parse_args()
    if args.pid <= 0 or not 1 <= args.port <= 65535:
        parser.error("--pid must be positive and --port must be between 1 and 65535")
    for path in (args.executable, args.symbols):
        if path is not None and not path.is_file():
            parser.error(f"Not a file: {path}")
    if args.sysroot is not None and not args.sysroot.is_dir():
        parser.error(f"Not a symbol root directory: {args.sysroot}")
    if args.sdk is not None and not (args.sdk / "usr/lib/swift/shims").is_dir():
        parser.error(f"iPhoneOS SDK has no Darwin Swift shims: {args.sdk}")
    if args.sdk:
        core_foundation = args.sdk.resolve() / "System/Library/Frameworks/CoreFoundation.framework/Modules/module.modulemap"
        if not core_foundation.is_file():
            parser.error(f"iPhoneOS SDK has no CoreFoundation module map: {args.sdk}")
    lldb = shutil.which(args.lldb)
    if not lldb:
        parser.error(f"LLDB executable not found: {args.lldb}")
    target_options = f" --sysroot {shlex.quote(str(args.sysroot.resolve()))}" if args.sysroot else ""
    commands = [
        "platform select remote-ios",
        "settings set target.preload-symbols false",
        "settings set target.memory-module-load-level partial",
        f"target create{target_options} {shlex.quote(str(args.executable.resolve()))}",
    ]
    if args.symbols:
        commands.append(f"target symbols add {shlex.quote(str(args.symbols.resolve()))}")
    if args.remote_executable:
        commands.append(
            "script lldb.target.module[0].SetPlatformFileSpec(lldb.SBFileSpec("
            + json.dumps(args.remote_executable) + "))"
        )
    if args.sysroot:
        commands.append("target modules search-paths add / " + shlex.quote(str(args.sysroot.resolve()) + "/"))
    if args.sdk:
        commands.extend([
            "settings set target.sdk-path " + shlex.quote(str(args.sdk.resolve())),
            "settings append target.swift-module-search-paths "
            + shlex.quote(str(args.sdk.resolve() / "usr/lib/swift/shims")),
            # Otherwise Linux's CoreFoundation module relocates Darwin PCMs into
            # the host toolchain and prevents app-local Swift expressions.
            "settings append target.swift-extra-clang-flags "
            + shlex.quote(f"-fmodule-map-file={core_foundation}"),
        ])
    commands.extend(args.command)
    with socket.socket() as listener, socket.create_connection(("127.0.0.1", args.port), timeout=30) as upstream:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(30)
        local_port = listener.getsockname()[1]
        # iOS 26 debugproxy answers qfThreadInfo with OK before a process is attached.
        # Swift 6.4 LLDB stalls on that handshake. Bootstrap the real attachment;
        # subsequent traffic is forwarded unchanged, including compression negotiation.
        attach(upstream, args.pid)
        print(f"Attached to device PID {args.pid}. Starting LLDB; detach with 'process detach'.", flush=True)
        commands.append(f"process connect connect://127.0.0.1:{local_port}")
        failures: list[Exception] = []
        closing = threading.Event()

        def forward() -> None:
            try:
                relay(listener, upstream)
            except (OSError, EOFError) as error:
                if not closing.is_set():
                    failures.append(error)
                    print(f"Debug transport failed: {error}", file=sys.stderr, flush=True)

        threading.Thread(target=forward, daemon=True).start()
        command = [lldb, "--no-lldbinit"]
        for item in commands:
            command.extend(["-o", item])
        try:
            child = subprocess.Popen(command)
            # Ctrl-C belongs to interactive LLDB, not this transport supervisor.
            previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
            try:
                result = child.wait()
            finally:
                signal.signal(signal.SIGINT, previous)
        finally:
            closing.set()
            # Also release a successful attachment if LLDB fails to start/connect.
            # RSP requests remain uncompressed after LLDB enables response compression.
            try:
                upstream.settimeout(2)
                upstream.sendall(packet("D"))
            except OSError:
                pass  # A normal LLDB detach already closes the remote connection.
        return result or bool(failures)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, EOFError, ValueError, RuntimeError) as error:
        print(f"xtool-debug: {error}", file=sys.stderr)
        raise SystemExit(1) from error
