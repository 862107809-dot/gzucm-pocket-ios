"""Synthetic device/simulator Mach-O IPA fixtures; no school or signing data."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "inspect_ipa.py"
SPEC = importlib.util.spec_from_file_location("pocket_ipa_inspector", SCRIPT)
INSPECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSPECTOR)
APP_ROOT = "Payload/GZUCMPocket.app"


def info() -> dict:
    return {
        "CFBundleIdentifier": "com.example.gzucm.pocket",
        "CFBundleExecutable": "GZUCMPocket",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "DTPlatformName": "iphoneos",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "MinimumOSVersion": "18.0",
    }


def build_command(platform: int = 2, minimum: int = 18 << 16, tools: int = 0) -> bytes:
    return struct.pack("<6I", 0x32, 24, platform, minimum, 26 << 16, tools)


def macho(platform: int = 2, cpu: int = 0x0100000C, filetype: int = 2, commands: bytes | None = None, count: int = 1, size: int | None = None) -> bytes:
    commands = build_command(platform) if commands is None else commands
    return struct.pack("<8I", 0xFEEDFACF, cpu, 0, filetype, count, len(commands) if size is None else size, 0, 0) + commands


def entry(name: str, data: bytes, mode: int = stat.S_IFREG | 0o644) -> tuple[zipfile.ZipInfo, bytes]:
    record = zipfile.ZipInfo(name)
    # ZipInfo's Windows constructor otherwise normalizes the malicious backslash fixture.
    record.filename = name
    record.orig_filename = name
    record.create_system = 3
    record.external_attr = mode << 16
    return record, data


class IPAInspectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix=".ipa-test-", dir=str(SCRIPT.parent))
        self.root = Path(self.temporary.name).resolve()
        # The only recursive cleanup target is verified inside this task's tools directory.
        self.assertTrue(self.root.is_relative_to(SCRIPT.parent.resolve()))
        self.addCleanup(self.temporary.cleanup)

    def make_ipa(self, metadata: dict | None = None, binary: bytes | None = None, mode: int = stat.S_IFREG | 0o755, extras: list[tuple[zipfile.ZipInfo, bytes]] | None = None, app_root: str = APP_ROOT) -> Path:
        path = self.root / "fixture.ipa"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)  # Duplicate-entry fixtures are deliberate.
            with zipfile.ZipFile(path, "w") as archive:
                records = [
                    entry(app_root + "/Info.plist", plistlib.dumps(info() if metadata is None else metadata)),
                    entry(app_root + "/GZUCMPocket", macho() if binary is None else binary, mode),
                ]
                for record, data in records + (extras or []):
                    archive.writestr(record, data)
        return path

    def test_device_ipa_reports_unsigned_and_exact_safe_metadata(self) -> None:
        path = self.make_ipa()
        result = INSPECTOR.inspect_ipa(path)
        self.assertEqual(set(result), {"sha256", "bundle", "version", "minimum_os", "architecture", "platform", "signing"})
        self.assertEqual(result["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(result["bundle"], "com.example.gzucm.pocket")
        self.assertEqual(result["version"], "0.1.0")
        self.assertEqual(result["minimum_os"], "18.0")
        self.assertEqual(result["architecture"], "arm64")
        self.assertEqual(result["platform"], "iphoneos")
        self.assertEqual(result["signing"], "unsigned_requires_local_signing")

    def test_simulator_metadata_wrong_cpu_endian_and_filetype_are_rejected(self) -> None:
        simulator = info(); simulator["DTPlatformName"] = "iphonesimulator"
        wrong_platforms = info(); wrong_platforms["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
        wrong_endian = struct.pack(">8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0) + build_command()
        cases = [(simulator, macho()), (wrong_platforms, macho()), (info(), macho(platform=7)), (info(), macho(cpu=0x01000007)), (info(), wrong_endian), (info(), macho(filetype=6))]
        for index, (metadata, binary) in enumerate(cases):
            with self.subTest(index=index), self.assertRaises(INSPECTOR.IPAInspectionError):
                INSPECTOR.inspect_ipa(self.make_ipa(metadata=metadata, binary=binary))

    def test_single_expected_app_and_safe_executable_are_required(self) -> None:
        with self.assertRaises(INSPECTOR.IPAInspectionError):
            INSPECTOR.inspect_ipa(self.make_ipa(app_root="Payload/Another.app"))
        with self.assertRaises(INSPECTOR.IPAInspectionError):
            INSPECTOR.inspect_ipa(self.make_ipa(extras=[entry("Payload/Extra.app/Info.plist", plistlib.dumps(info()))]))
        for name in ("../GZUCMPocket", "/bin/GZUCMPocket", "sub/app", "sub\\app", "..", "", "MissingExecutable"):
            metadata = info(); metadata["CFBundleExecutable"] = name
            with self.subTest(name=name), self.assertRaises(INSPECTOR.IPAInspectionError):
                INSPECTOR.inspect_ipa(self.make_ipa(metadata=metadata))

    def test_unsafe_or_duplicate_zip_entries_are_rejected(self) -> None:
        for name in ("../outside", "/absolute", "C:/absolute", "Payload\\outside", "Payload/../outside", "Payload//alias", "Payload/./alias"):
            with self.subTest(name=name), self.assertRaises(INSPECTOR.IPAInspectionError):
                INSPECTOR.inspect_ipa(self.make_ipa(extras=[entry(name, b"not extracted")]))
        with self.assertRaisesRegex(INSPECTOR.IPAInspectionError, "duplicate"):
            INSPECTOR.inspect_ipa(self.make_ipa(extras=[entry(APP_ROOT + "/Info.plist", plistlib.dumps(info()))]))
        self.assertEqual(set(path.name for path in self.root.iterdir()), {"fixture.ipa"})

    def test_macho_header_command_region_and_tool_record_bounds_are_checked(self) -> None:
        cases = [
            b"\xcf\xfa\xed\xfe",
            macho(size=4096),
            macho(count=1000),
            macho(commands=struct.pack("<2I", 0x32, 0)),
            macho(commands=struct.pack("<2I", 0x32, 7)),
            macho(commands=struct.pack("<2I", 0x32, 32)),
            macho(commands=struct.pack("<4I", 0x32, 16, 2, 18 << 16)),
            macho(commands=build_command(tools=1)),
            macho(commands=struct.pack("<2I", 0x1, 8)),
            macho(commands=build_command() * 2, count=2),
            macho(commands=build_command() + b"\0" * 8, count=1),
        ]
        for index, binary in enumerate(cases):
            with self.subTest(index=index), self.assertRaises(INSPECTOR.IPAInspectionError):
                INSPECTOR.inspect_ipa(self.make_ipa(binary=binary))

    def test_minimum_os_and_real_executable_permission_bits_are_required(self) -> None:
        for value in ("17.6", "latest", "18.invalid"):
            metadata = info(); metadata["MinimumOSVersion"] = value
            with self.subTest(value=value), self.assertRaises(INSPECTOR.IPAInspectionError):
                INSPECTOR.inspect_ipa(self.make_ipa(metadata=metadata))
        with self.assertRaises(INSPECTOR.IPAInspectionError):
            INSPECTOR.inspect_ipa(self.make_ipa(binary=macho(commands=build_command(minimum=26 << 16))))
        for mode in (stat.S_IFREG | 0o644, stat.S_IFLNK | 0o777):
            with self.subTest(mode=mode), self.assertRaises(INSPECTOR.IPAInspectionError):
                INSPECTOR.inspect_ipa(self.make_ipa(mode=mode))

    def test_any_main_app_signing_marker_is_not_misreported_unsigned(self) -> None:
        for marker in ("_CodeSignature/", "_CodeSignature/CodeResources", "embedded.mobileprovision"):
            with self.subTest(marker=marker):
                result = INSPECTOR.inspect_ipa(self.make_ipa(extras=[entry(APP_ROOT + "/" + marker, b"synthetic marker, not a signature")]))
                self.assertEqual(result["signing"], "signing_present_not_verified")
        self.assertEqual(INSPECTOR.inspect_ipa(self.make_ipa())["signing"], "unsigned_requires_local_signing")

    def test_cli_writes_only_safe_json_and_cannot_overwrite_the_ipa(self) -> None:
        path = self.make_ipa()
        output = self.root / "metadata" / "inspection.json"
        completed = subprocess.run([sys.executable, str(SCRIPT), str(path), "--output", str(output)], capture_output=True, text=True, check=False)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout), json.loads(output.read_text(encoding="utf-8")))
        self.assertEqual(json.loads(completed.stdout)["signing"], "unsigned_requires_local_signing")
        original = path.read_bytes()
        failed = subprocess.run([sys.executable, str(SCRIPT), str(path), "--output", str(path)], capture_output=True, text=True, check=False)
        self.assertEqual(failed.returncode, 2)
        self.assertEqual(failed.stdout, "")
        self.assertEqual(path.read_bytes(), original)
        malformed = self.root / "invalid.ipa"; malformed.write_bytes(b"not a zip archive")
        failed = subprocess.run([sys.executable, str(SCRIPT), str(malformed)], capture_output=True, text=True, check=False)
        self.assertEqual(failed.returncode, 2)
        self.assertEqual(failed.stdout, "")
        self.assertNotIn("Traceback", failed.stderr)


if __name__ == "__main__":
    unittest.main()
