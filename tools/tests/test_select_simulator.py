"""Synthetic inventories model simctl's runtimes/devicetypes/devices JSON layout."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "select_simulator.py"
SPEC = importlib.util.spec_from_file_location("pocket_simulator_selector", SCRIPT)
SELECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SELECTOR)

TYPE_PREFIX = "com.apple.CoreSimulator.SimDeviceType."
RUNTIME_PREFIX = "com.apple.CoreSimulator.SimRuntime.iOS-"


def runtime(version, available=True):
    return {
        "bundlePath": "/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime",
        "buildversion": "23A000", "name": "iOS " + version,
        "identifier": RUNTIME_PREFIX + version.replace(".", "-"),
        "version": version, "isAvailable": available
    }


def device(name, model, number, available=True):
    return {
        "dataPath": "/Users/runner/Library/Developer/CoreSimulator/Devices/fixture/data",
        "logPath": "/Users/runner/Library/Logs/CoreSimulator/fixture",
        "udid": "00000000-0000-4000-8000-{:012d}".format(number),
        "name": name, "state": "Shutdown", "isAvailable": available,
        "deviceTypeIdentifier": TYPE_PREFIX + model
    }


def inventory():
    models = [
        ("iPhone 16 Pro", "iPhone-16-Pro", "iPhone"),
        ("iPhone 17 Pro Max", "iPhone-17-Pro-Max", "iPhone"),
        ("iPad Pro 13-inch (M4)", "iPad-Pro-13-inch-M4", "iPad"),
        ("iPhone Duo", "iPhone-Duo", "iPhone")
    ]
    versions = ["18.6", "26.0", "27.0"]
    return {
        "devicetypes": [{"name": name, "identifier": TYPE_PREFIX + model, "productFamily": family} for name, model, family in models],
        "runtimes": [runtime(version) for version in versions],
        "devices": {
            RUNTIME_PREFIX + "18-6": [device("iPhone 16 Pro", "iPhone-16-Pro", 18)],
            RUNTIME_PREFIX + "26-0": [device("iPhone 17 Pro Max", "iPhone-17-Pro-Max", 26), device("iPad Pro 13-inch (M4)", "iPad-Pro-13-inch-M4", 126)],
            RUNTIME_PREFIX + "27-0": [device("iPhone 17 Pro Max", "iPhone-17-Pro-Max", 27), device("iPhone Duo", "iPhone-Duo", 227)]
        },
        "pairs": {}
    }


class SelectionTests(unittest.TestCase):
    def test_exact_major_selects_18_26_and_27_without_crossing(self):
        for major, version in [(18, "18.6"), (26, "26.0"), (27, "27.0")]:
            with self.subTest(major=major):
                result = SELECTOR.select_simulator(inventory(), major, "iphone")
                self.assertEqual(result["os_version"], version)
                self.assertEqual(result["runtime"], RUNTIME_PREFIX + version.replace(".", "-"))
                self.assertEqual(set(result), {"udid", "name", "runtime", "os_version", "device_type"})

    def test_default_is_latest_available_ios_major(self):
        self.assertEqual(SELECTOR.select_simulator(inventory())["os_version"], "27.0")

    def test_exact_major_missing_is_actionable_and_not_substituted(self):
        with self.assertRaisesRegex(SELECTOR.SelectionError, "No available iOS 19 runtime.*different major"):
            SELECTOR.select_simulator(inventory(), 19)

    def test_unavailable_runtime_is_not_selected_even_with_an_available_device(self):
        value = inventory()
        value["runtimes"][-1]["isAvailable"] = False
        self.assertEqual(SELECTOR.select_simulator(value)["os_version"], "26.0")
        with self.assertRaisesRegex(SELECTOR.SelectionError, "No available iOS 27 runtime"):
            SELECTOR.select_simulator(value, 27)

    def test_unavailable_device_cannot_satisfy_the_kind(self):
        value = inventory()
        value["devices"][RUNTIME_PREFIX + "18-6"][0]["isAvailable"] = False
        with self.assertRaisesRegex(SELECTOR.SelectionError, "No available iphone simulator on iOS 18"):
            SELECTOR.select_simulator(value, 18)

    def test_duo_is_never_a_regular_iphone(self):
        value = inventory()
        self.assertEqual(SELECTOR.select_simulator(value, 27, "duo")["name"], "iPhone Duo")
        self.assertEqual(SELECTOR.select_simulator(value, 27, "iphone")["name"], "iPhone 17 Pro Max")
        value["devices"][RUNTIME_PREFIX + "27-0"] = [device("iPhone Duo", "iPhone-Duo", 227)]
        with self.assertRaisesRegex(SELECTOR.SelectionError, "No available iphone simulator on iOS 27"):
            SELECTOR.select_simulator(value, 27, "iphone")

    def test_duo_identifier_is_recognized_after_custom_rename(self):
        value = inventory()
        value["devices"][RUNTIME_PREFIX + "27-0"][1]["name"] = "Folded device test"
        result = SELECTOR.select_simulator(value, 27, "duo")
        self.assertEqual(result["device_type"], TYPE_PREFIX + "iPhone-Duo")

    def test_duo_name_is_recognized_when_identifier_does_not_say_duo(self):
        value = inventory()
        value["devices"][RUNTIME_PREFIX + "27-0"] = [device("iPhone Duo", "iPhone-Future-Device", 229)]
        self.assertEqual(SELECTOR.select_simulator(value, 27, "duo")["name"], "iPhone Duo")
        with self.assertRaises(SELECTOR.SelectionError):
            SELECTOR.select_simulator(value, 27, "iphone")

    def test_ipad_is_exact_family_and_not_substituted(self):
        result = SELECTOR.select_simulator(inventory(), 26, "ipad")
        self.assertEqual(result["device_type"], TYPE_PREFIX + "iPad-Pro-13-inch-M4")
        with self.assertRaisesRegex(SELECTOR.SelectionError, "No available ipad simulator on iOS 27"):
            SELECTOR.select_simulator(inventory(), 27, "ipad")

    def test_default_latest_major_without_requested_kind_does_not_fall_back_to_older_major(self):
        with self.assertRaisesRegex(SELECTOR.SelectionError, "No available ipad simulator on iOS 27"):
            SELECTOR.select_simulator(inventory(), device_kind="ipad")

    def test_version_order_is_numeric_not_lexical(self):
        value = inventory()
        for index, version in enumerate(["26.9", "26.10", "26.10.1"]):
            row = runtime(version)
            value["runtimes"].append(row)
            value["devices"][row["identifier"]] = [device("iPhone 17 Pro Max", "iPhone-17-Pro-Max", 300 + index)]
        self.assertEqual(SELECTOR.select_simulator(value, 26)["os_version"], "26.10.1")

    def test_newest_patch_with_the_requested_family_is_used_within_same_major(self):
        value = inventory()
        value["runtimes"].append(runtime("26.2"))
        value["devices"][RUNTIME_PREFIX + "26-2"] = [device("iPhone 17 Pro Max", "iPhone-17-Pro-Max", 262)]
        self.assertEqual(SELECTOR.select_simulator(value, 26, "ipad")["os_version"], "26.0")

    def test_non_ios_runtimes_are_ignored(self):
        value = inventory()
        value["runtimes"].append({"identifier": "com.apple.CoreSimulator.SimRuntime.visionOS-99-0", "version": "99.0", "isAvailable": True})
        self.assertEqual(SELECTOR.select_simulator(value)["os_version"], "27.0")

    def test_known_iphone_identifier_is_preferred_to_name_only_fallback(self):
        value = inventory()
        value["devices"][RUNTIME_PREFIX + "26-0"].append({"name": "iPhone 999", "udid": "00000000-0000-4000-8000-000000000999", "isAvailable": True})
        self.assertEqual(SELECTOR.select_simulator(value, 26)["name"], "iPhone 17 Pro Max")

    def test_known_ipad_type_cannot_be_renamed_into_an_iphone(self):
        value = inventory()
        value["devices"][RUNTIME_PREFIX + "26-0"] = [device("iPhone renamed test", "iPad-Pro-13-inch-M4", 126)]
        with self.assertRaises(SELECTOR.SelectionError):
            SELECTOR.select_simulator(value, 26, "iphone")

    def test_missing_device_type_identifier_can_use_exact_type_name(self):
        value = inventory()
        del value["devices"][RUNTIME_PREFIX + "18-6"][0]["deviceTypeIdentifier"]
        self.assertEqual(SELECTOR.select_simulator(value, 18)["device_type"], TYPE_PREFIX + "iPhone-16-Pro")

    def test_runtime_version_can_be_derived_from_identifier(self):
        value = inventory()
        del value["runtimes"][0]["version"]
        self.assertEqual(SELECTOR.select_simulator(value, 18)["os_version"], "18.6")

    def test_real_apple_identifier_can_omit_patch_without_blocking_ios_18(self):
        value = inventory()
        value["runtimes"][1]["version"] = "26.0.1"
        self.assertEqual(SELECTOR.select_simulator(value, 18)["os_version"], "18.6")
        selected = SELECTOR.select_simulator(value, 26)
        self.assertEqual(selected["runtime"], RUNTIME_PREFIX + "26-0")
        self.assertEqual(selected["os_version"], "26.0.1")

    def test_identifier_prefix_still_rejects_conflicting_major_minor_or_patch(self):
        for identifier, version in [
            ("26-0", "27.0.1"), ("26-0", "26.1.0"),
            ("26-0-1", "26.0.2"), ("26-0-1", "26.0")
        ]:
            with self.subTest(identifier=identifier, version=version):
                value = inventory()
                value["runtimes"][1]["identifier"] = RUNTIME_PREFIX + identifier
                value["runtimes"][1]["version"] = version
                with self.assertRaisesRegex(SELECTOR.SelectionError, "disagrees with its version"):
                    SELECTOR.select_simulator(value, 18)

    def test_no_available_runtime_has_clear_install_instruction(self):
        value = inventory()
        for row in value["runtimes"]:
            row["isAvailable"] = False
        with self.assertRaisesRegex(SELECTOR.SelectionError, "No available iOS runtime.*Install"):
            SELECTOR.select_simulator(value)

    def test_legacy_availability_field_is_supported_without_assuming_missing_states(self):
        value = inventory()
        runtime_row = value["runtimes"][0]
        del runtime_row["isAvailable"]
        runtime_row["availability"] = "(available)"
        device_row = value["devices"][RUNTIME_PREFIX + "18-6"][0]
        del device_row["isAvailable"]
        device_row["availability"] = "(available)"
        self.assertEqual(SELECTOR.select_simulator(value, 18)["os_version"], "18.6")
        del device_row["availability"]
        with self.assertRaises(SELECTOR.SelectionError):
            SELECTOR.select_simulator(value, 18)

    def test_malformed_inventory_types_and_versions_do_not_silently_disappear(self):
        malformed = []
        malformed.append([])
        malformed.append({"runtimes": {}, "devices": {}})
        value = inventory(); value["runtimes"][0]["version"] = "latest"; malformed.append(value)
        value = inventory(); value["runtimes"][0]["version"] = "19.0"; malformed.append(value)
        value = inventory(); value["devices"][RUNTIME_PREFIX + "18-6"][0]["isAvailable"] = "true"; malformed.append(value)
        value = inventory(); value["devices"][RUNTIME_PREFIX + "18-6"][0]["udid"] = "not-a-uuid"; malformed.append(value)
        value = inventory(); value["runtimes"].append(copy.deepcopy(value["runtimes"][0])); malformed.append(value)
        for value in malformed:
            with self.subTest(value=value):
                with self.assertRaises(SELECTOR.SelectionError):
                    SELECTOR.select_simulator(value, 18)


class CLITests(unittest.TestCase):
    def run_cli(self, *arguments):
        return subprocess.run([sys.executable, str(SCRIPT)] + list(arguments), capture_output=True, text=True, check=False)

    def test_cli_outputs_matching_json_to_stdout_and_file(self):
        with tempfile.TemporaryDirectory(dir=str(SCRIPT.parent)) as directory:
            root = Path(directory)
            captured = root / "inventory.json"
            captured.write_text(json.dumps(inventory()), encoding="utf-8")
            destination = root / "artifacts" / "selected.json"
            result = self.run_cli("--inventory", str(captured), "--os-major", "18", "--device-kind", "iphone", "--output", str(destination))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), json.loads(destination.read_text(encoding="utf-8")))
            self.assertEqual(json.loads(result.stdout)["os_version"], "18.6")

    def test_cli_missing_environment_exits_two_with_actionable_error(self):
        with tempfile.TemporaryDirectory(dir=str(SCRIPT.parent)) as directory:
            captured = Path(directory) / "inventory.json"
            captured.write_text(json.dumps(inventory()), encoding="utf-8")
            result = self.run_cli("--inventory", str(captured), "--os-major", "18", "--device-kind", "duo")
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertIn("No available duo simulator on iOS 18", result.stderr)

    def test_cli_invalid_json_reports_parse_location_and_does_not_write_output(self):
        with tempfile.TemporaryDirectory(dir=str(SCRIPT.parent)) as directory:
            root = Path(directory)
            captured = root / "inventory.json"
            captured.write_text('{"runtimes": [}', encoding="utf-8")
            destination = root / "selected.json"
            result = self.run_cli("--inventory", str(captured), "--output", str(destination))
            self.assertEqual(result.returncode, 2)
            self.assertIn("line 1 column", result.stderr)
            self.assertFalse(destination.exists())

    def test_cli_missing_file_and_invalid_major_exit_two(self):
        with tempfile.TemporaryDirectory(dir=str(SCRIPT.parent)) as directory:
            missing = Path(directory) / "missing.json"
            self.assertEqual(self.run_cli("--inventory", str(missing)).returncode, 2)
            for invalid in ("0", "-1", "latest", "18.0"):
                with self.subTest(value=invalid):
                    result = self.run_cli("--inventory", str(missing), "--os-major", invalid)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("positive integer", result.stderr)


if __name__ == "__main__":
    unittest.main()
