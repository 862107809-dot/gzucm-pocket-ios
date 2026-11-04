#!/usr/bin/env python3
"""Inspect this app's device IPA without extracting any archive member.

This checks bundle/platform metadata and the arm64 Mach-O header/load commands.
It does not verify code signatures, attest that every executable byte is valid,
or make an unsigned IPA installable. A device must receive a locally signed IPA.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import sys
import tempfile
from typing import Any
from xml.parsers.expat import ExpatError
import zipfile


APP_ROOT = "Payload/GZUCMPocket.app"
INFO_PATH = APP_ROOT + "/Info.plist"
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2


class IPAInspectionError(ValueError):
    """The archive cannot prove the required device-build properties."""


def _safe_member_name(member: zipfile.ZipInfo) -> str:
    name = member.filename
    original = member.orig_filename
    if not name or name != original or "\x00" in original or "\\" in name or name.startswith("/"):
        raise IPAInspectionError("Archive contains an unsafe ZIP member name.")
    parts = name[:-1].split("/") if name.endswith("/") else name.split("/")
    if any(part in ("", ".", "..") or re.match(r"^[A-Za-z]:", part) for part in parts):
        raise IPAInspectionError("Archive contains an unsafe ZIP member path.")
    return name


def _required_text(info: dict[str, Any], key: str) -> str:
    value = info.get(key)
    if not isinstance(value, str) or not value.strip():
        raise IPAInspectionError("Info.plist is missing a required text field: " + key + ".")
    return value


def _version(value: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise IPAInspectionError("MinimumOSVersion must be a numeric iOS version.")
    parts = [int(part) for part in value.split(".")]
    return tuple((parts + [0, 0])[:3])


def _regular_entry(member: zipfile.ZipInfo, label: str) -> int:
    mode = (member.external_attr >> 16) & 0xFFFF
    kind = stat.S_IFMT(mode)
    if member.is_dir() or kind not in (0, stat.S_IFREG):
        raise IPAInspectionError(label + " must be a regular ZIP file entry.")
    return mode


def _inspect_macho(binary: bytes, minimum_os: tuple[int, int, int]) -> None:
    if len(binary) < 32:
        raise IPAInspectionError("Main executable has a truncated Mach-O 64-bit header.")
    magic, cpu, _subtype, filetype, count, command_bytes, _flags, _reserved = struct.unpack_from("<8I", binary)
    if magic != MH_MAGIC_64 or cpu != CPU_TYPE_ARM64:
        raise IPAInspectionError("Main executable must be a little-endian arm64 64-bit Mach-O.")
    if filetype != MH_EXECUTE:
        raise IPAInspectionError("Main Mach-O file type is not MH_EXECUTE.")
    if count < 1 or count > command_bytes // 8 or command_bytes > len(binary) - 32:
        raise IPAInspectionError("Mach-O load-command count or region is out of bounds.")
    end = 32 + command_bytes
    cursor = 32
    build_version_seen = False
    for _ in range(count):
        if cursor + 8 > end:
            raise IPAInspectionError("Mach-O load-command header is out of bounds.")
        command, size = struct.unpack_from("<2I", binary, cursor)
        if size < 8 or size % 8 or size > end - cursor:
            raise IPAInspectionError("Mach-O load-command size is invalid or out of bounds.")
        if command == LC_BUILD_VERSION:
            if build_version_seen or size < 24:
                raise IPAInspectionError("Mach-O has a duplicate or truncated LC_BUILD_VERSION.")
            build_version_seen = True
            platform, binary_minimum, _sdk, tools = struct.unpack_from("<4I", binary, cursor + 8)
            if size != 24 + tools * 8:
                raise IPAInspectionError("LC_BUILD_VERSION tool records exceed its declared command size.")
            if platform != PLATFORM_IOS:
                raise IPAInspectionError("LC_BUILD_VERSION must target iOS devices, not a simulator or another platform.")
            required = (binary_minimum >> 16, (binary_minimum >> 8) & 0xFF, binary_minimum & 0xFF)
            if required > minimum_os:
                raise IPAInspectionError("Mach-O requires a newer iOS version than Info.plist declares.")
        cursor += size
    if cursor != end:
        raise IPAInspectionError("Mach-O load-command sizes do not match sizeofcmds.")
    if not build_version_seen:
        raise IPAInspectionError("Main executable has no LC_BUILD_VERSION proving an iOS device target.")


def inspect_ipa(path: Path) -> dict[str, str]:
    """Return seven non-secret inspection fields; read ZIP entries only in memory."""
    try:
        with Path(path).open("rb") as source:
            checksum = hashlib.sha256()
            for block in iter(lambda: source.read(1024 * 1024), b""):
                checksum.update(block)
            digest = checksum.hexdigest()
            source.seek(0)
            with zipfile.ZipFile(source) as archive:
                entries: dict[str, zipfile.ZipInfo] = {}
                apps: set[str] = set()
                for member in archive.infolist():
                    name = _safe_member_name(member)
                    if name in entries:
                        raise IPAInspectionError("Archive contains a duplicate ZIP entry.")
                    entries[name] = member
                    parts = name.rstrip("/").split("/")
                    if len(parts) >= 2 and parts[0] == "Payload" and parts[1].endswith(".app"):
                        apps.add(parts[1])
                if apps != {"GZUCMPocket.app"} or INFO_PATH not in entries:
                    raise IPAInspectionError("IPA must contain one Payload/GZUCMPocket.app/Info.plist and no other top-level app.")
                _regular_entry(entries[INFO_PATH], "Info.plist")
                try:
                    info = plistlib.loads(archive.read(entries[INFO_PATH]))
                except (plistlib.InvalidFileException, ExpatError, ValueError, TypeError) as error:
                    raise IPAInspectionError("App Info.plist is not a readable property list.") from error
                if not isinstance(info, dict):
                    raise IPAInspectionError("App Info.plist must contain a dictionary.")
                if info.get("DTPlatformName") != "iphoneos":
                    raise IPAInspectionError("Info.plist DTPlatformName must be iphoneos.")
                platforms = info.get("CFBundleSupportedPlatforms")
                if not isinstance(platforms, list) or "iPhoneOS" not in platforms:
                    raise IPAInspectionError("Info.plist must list iPhoneOS as a supported platform.")
                minimum = _required_text(info, "MinimumOSVersion")
                minimum_parts = _version(minimum)
                if minimum_parts < (18, 0, 0):
                    raise IPAInspectionError("IPA minimum iOS version must be 18.0 or newer.")
                executable = _required_text(info, "CFBundleExecutable")
                if executable in (".", "..") or any(value in executable for value in ("/", "\\", "\x00", ":")):
                    raise IPAInspectionError("CFBundleExecutable must be a single safe filename.")
                binary_path = APP_ROOT + "/" + executable
                if binary_path not in entries:
                    raise IPAInspectionError("Main app executable is missing from the archive.")
                mode = _regular_entry(entries[binary_path], "Main executable")
                if not mode & 0o111:
                    raise IPAInspectionError("Main executable lacks executable permission bits in ZIP external attributes.")
                _inspect_macho(archive.read(entries[binary_path]), minimum_parts)
                signing_present = any(
                    name == APP_ROOT + "/" + marker or name.startswith(APP_ROOT + "/" + marker + "/")
                    for name in entries
                    for marker in ("_CodeSignature", "embedded.mobileprovision")
                )
                return {
                    "sha256": digest,
                    "bundle": _required_text(info, "CFBundleIdentifier"),
                    "version": _required_text(info, "CFBundleShortVersionString"),
                    "minimum_os": minimum,
                    "architecture": "arm64",
                    "platform": "iphoneos",
                    "signing": "signing_present_not_verified" if signing_present else "unsigned_requires_local_signing",
                }
    except IPAInspectionError:
        raise
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile, RuntimeError, NotImplementedError, UnicodeError, struct.error) as error:
        raise IPAInspectionError("IPA archive could not be read completely for inspection.") from error


def _write_json(destination: Path, content: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n", dir=str(destination.parent), prefix=".ipa-inspection-", suffix=".json", delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(content)
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path, help="device Release IPA to inspect without extraction")
    parser.add_argument("--output", type=Path, help="also atomically write the safe JSON result")
    args = parser.parse_args(argv)
    try:
        if args.output and args.output.resolve() == args.ipa.resolve():
            raise IPAInspectionError("JSON output must not overwrite the IPA being inspected.")
        result = inspect_ipa(args.ipa)
        content = json.dumps(result, ensure_ascii=True, indent=2) + "\n"
        if args.output:
            _write_json(args.output, content)
    except (IPAInspectionError, OSError) as error:
        parser.error(str(error))
    sys.stdout.write(content)
    return 0


if __name__ == "__main__":
    sys.exit(main())
