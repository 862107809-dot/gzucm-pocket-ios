#!/usr/bin/env python3
"""Select an available iOS simulator from a captured ``simctl list --json``.

This module never launches simctl or modifies simulators. A missing requested
major version or device family is an error, rather than a fallback to another
test environment. With no --os-major, the newest available iOS major is used.
Within that major, prefer the newest runtime that has the requested device.
"""

import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any, Dict, List, Mapping, Optional, Tuple
import uuid


class SelectionError(ValueError):
    """The inventory is malformed or cannot satisfy the requested environment."""


_IOS_RUNTIME = re.compile(r"^com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+(?:-\d+)*)$", re.IGNORECASE)
_DEVICE_PREFIX = "com.apple.CoreSimulator.SimDeviceType."


def _object(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise SelectionError("{} must be a JSON object.".format(label))
    return value


def _text(value: Any, label: str, allow_empty: bool = False) -> str:
    if not isinstance(value, str) or (not allow_empty and not value.strip()):
        raise SelectionError("{} must be a{} string.".format(label, " nonempty" if not allow_empty else ""))
    return value.strip()


def _available(item: Mapping[str, Any], label: str) -> bool:
    if "isAvailable" in item:
        if not isinstance(item["isAvailable"], bool):
            raise SelectionError("{}.isAvailable must be a JSON boolean.".format(label))
        return item["isAvailable"]
    # Legacy simctl inventories used a printable availability field.
    if "availability" in item:
        value = _text(item["availability"], label + ".availability")
        return value.lower() in ("available", "(available)")
    # An unspecified state cannot prove that a simulator is bootable.
    return False


def _version(raw: str, label: str) -> Tuple[int, ...]:
    if not re.fullmatch(r"\d+(?:\.\d+)*", raw):
        raise SelectionError("{} must be a numeric version such as 18.6 or 26.0.1; got {!r}.".format(label, raw))
    parts = tuple(int(part) for part in raw.split("."))
    if parts[0] < 1:
        raise SelectionError("{} must have a positive major version.".format(label))
    # 26, 26.0 and 26.0.0 are the same version for comparison.
    while len(parts) > 1 and parts[-1] == 0:
        parts = parts[:-1]
    return parts


def _device_kind(device: Mapping[str, Any], device_types: Mapping[str, Mapping[str, Any]]) -> Tuple[Optional[str], int, str]:
    """Return family, metadata confidence (lower is better), and type descriptor."""
    name = device["name"]
    type_id = device.get("deviceTypeIdentifier", "")
    metadata = device_types.get(type_id, {})
    if not type_id:
        # Older inventories may have only a device name. Resolve an exact type
        # name first; a renamed simulator still needs its explicit identifier.
        matches = [item for item in device_types.values() if item.get("name") == name]
        if len(matches) == 1:
            metadata = matches[0]
            type_id = metadata["identifier"]
    type_name = metadata.get("name", "")
    family = metadata.get("productFamily", "").lower()
    combined = " ".join((name, type_id, type_name)).lower()
    if "duo" in combined:
        return "duo", 0 if "duo" in type_id.lower() else 1, type_id or name

    short_id = type_id[len(_DEVICE_PREFIX):] if type_id.startswith(_DEVICE_PREFIX) else ""
    for kind in ("iphone", "ipad"):
        if re.match(r"^" + kind + r"(?:-|$)", short_id, re.IGNORECASE):
            return kind, 0, type_id
    for kind in ("iphone", "ipad"):
        if family == kind:
            return kind, 1, type_id or type_name or name
    for kind in ("iphone", "ipad"):
        if re.match(r"^" + kind + r"(?:\s|$)", type_name, re.IGNORECASE):
            return kind, 2, type_id or type_name
    # Name fallback is useful for older output but never overrides known type
    # metadata (e.g. an iPad renamed to 'iPhone test').
    if family or type_name or short_id:
        return None, 9, type_id or name
    for kind in ("iphone", "ipad"):
        if re.match(r"^" + kind + r"(?:\s|$)", name, re.IGNORECASE):
            return kind, 3, type_id or name
    return None, 9, type_id or name


def _model_order(candidate: Mapping[str, Any]) -> Tuple[Any, ...]:
    descriptor = candidate["device_type"]
    numbers = tuple(int(value) for value in re.findall(r"\d+", descriptor))
    return numbers, descriptor.lower(), candidate["name"].lower(), candidate["udid"].lower()


def select_simulator(inventory: Any, os_major: Optional[int] = None, device_kind: str = "iphone") -> Dict[str, str]:
    """Return udid/name/runtime/os_version/device_type without crossing families."""
    if os_major is not None and (not isinstance(os_major, int) or isinstance(os_major, bool) or os_major < 1):
        raise SelectionError("The requested iOS major must be a positive integer.")
    if device_kind not in ("iphone", "ipad", "duo"):
        raise SelectionError("The requested device kind must be iphone, ipad or duo.")
    root = _object(inventory, "Inventory")
    runtimes = root.get("runtimes")
    devices = root.get("devices")
    types = root.get("devicetypes", [])
    if not isinstance(runtimes, list) or not isinstance(devices, dict) or not isinstance(types, list):
        raise SelectionError("Inventory requires runtimes (array), devices (object), and optional devicetypes (array). Capture xcrun simctl list --json available.")

    device_types = {}  # type: Dict[str, Mapping[str, Any]]
    for index, raw_type in enumerate(types):
        label = "devicetypes[{}]".format(index)
        item = dict(_object(raw_type, label))
        identifier = _text(item.get("identifier"), label + ".identifier")
        item["name"] = _text(item.get("name", ""), label + ".name", allow_empty=True)
        item["productFamily"] = _text(item.get("productFamily", ""), label + ".productFamily", allow_empty=True)
        if identifier in device_types:
            raise SelectionError("Duplicate device type identifier {!r}.".format(identifier))
        device_types[identifier] = item

    available_runtimes = []  # type: List[Dict[str, Any]]
    seen_runtime_ids = set()
    for index, raw_runtime in enumerate(runtimes):
        label = "runtimes[{}]".format(index)
        runtime = _object(raw_runtime, label)
        identifier = _text(runtime.get("identifier"), label + ".identifier")
        if identifier in seen_runtime_ids:
            raise SelectionError("Duplicate runtime identifier {!r}.".format(identifier))
        seen_runtime_ids.add(identifier)
        is_available = _available(runtime, label)
        match = _IOS_RUNTIME.fullmatch(identifier)
        if not match:
            continue
        raw_version = runtime.get("version", match.group(1).replace("-", "."))
        version = _text(raw_version, label + ".version")
        parts = _version(version, label + ".version")
        # Apple's identifier may omit a patch: iOS-26-0 can report 26.0.1.
        # Compare the untrimmed identifier components as a prefix, preserving
        # the minor zero so iOS-26-0 cannot accidentally accept version 26.1.
        id_parts = tuple(int(part) for part in match.group(1).split("-"))
        reported_parts = tuple(int(part) for part in version.split("."))
        if len(id_parts) < 2 or reported_parts[:len(id_parts)] != id_parts:
            raise SelectionError("Runtime {!r} disagrees with its version {!r}.".format(identifier, version))
        if is_available:
            available_runtimes.append({"identifier": identifier, "version": version, "parts": parts})

    available_devices = {}  # type: Dict[str, List[Dict[str, Any]]]
    for runtime_id, raw_devices in devices.items():
        _text(runtime_id, "devices runtime key")
        if not isinstance(raw_devices, list):
            raise SelectionError("devices[{!r}] must be an array.".format(runtime_id))
        selected = []
        for index, raw_device in enumerate(raw_devices):
            label = "devices[{!r}][{}]".format(runtime_id, index)
            device = dict(_object(raw_device, label))
            is_available = _available(device, label)
            device["name"] = _text(device.get("name"), label + ".name")
            device["udid"] = _text(device.get("udid"), label + ".udid")
            try:
                uuid.UUID(device["udid"])
            except ValueError as error:
                raise SelectionError("{}.udid is not a UUID: {!r}.".format(label, device["udid"])) from error
            if "deviceTypeIdentifier" in device:
                device["deviceTypeIdentifier"] = _text(device["deviceTypeIdentifier"], label + ".deviceTypeIdentifier", allow_empty=True)
            if is_available:
                selected.append(device)
        available_devices[runtime_id] = selected

    if not available_runtimes:
        raise SelectionError("No available iOS runtime exists in this inventory. Install an iOS Simulator runtime with Xcode and capture xcrun simctl list --json available again.")
    versions = ", ".join(runtime["version"] for runtime in sorted(available_runtimes, key=lambda item: item["parts"], reverse=True))
    target_major = os_major if os_major is not None else max(runtime["parts"][0] for runtime in available_runtimes)
    target_runtimes = [runtime for runtime in available_runtimes if runtime["parts"][0] == target_major]
    if not target_runtimes:
        raise SelectionError("No available iOS {} runtime. Available iOS versions: {}. Install the requested runtime in Xcode; a different major version will not be substituted.".format(target_major, versions))

    available_names = []
    for runtime in sorted(target_runtimes, key=lambda item: item["parts"], reverse=True):
        candidates = []
        for device in available_devices.get(runtime["identifier"], []):
            kind, confidence, descriptor = _device_kind(device, device_types)
            available_names.append("{} ({}, iOS {})".format(device["name"], kind or "unrecognized family", runtime["version"]))
            if kind == device_kind:
                candidates.append({
                    "udid": device["udid"], "name": device["name"], "runtime": runtime["identifier"],
                    "os_version": runtime["version"], "device_type": descriptor, "confidence": confidence
                })
        if candidates:
            best_confidence = min(candidate["confidence"] for candidate in candidates)
            best = max((candidate for candidate in candidates if candidate["confidence"] == best_confidence), key=_model_order)
            return {key: best[key] for key in ("udid", "name", "runtime", "os_version", "device_type")}

    alternatives = "; ".join(available_names) if available_names else "none"
    raise SelectionError("No available {} simulator on iOS {}. Available devices on that major: {}. Create an available device of the requested kind in Xcode, then regenerate the inventory. Other OS majors and device kinds will not be substituted.".format(device_kind, target_major, alternatives))


def _positive_major(raw: str) -> int:
    try:
        value = int(raw)
    except ValueError as error:
        raise argparse.ArgumentTypeError("iOS major must be a positive integer") from error
    if value < 1:
        raise argparse.ArgumentTypeError("iOS major must be a positive integer")
    return value


def _write_output(destination: Path, content: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n", dir=str(destination.parent), prefix=".simulator-", suffix=".json", delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(content)
        os.replace(str(temporary), str(destination))
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink()


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, required=True, help="JSON file captured with xcrun simctl list --json available")
    parser.add_argument("--os-major", type=_positive_major, help="exact iOS major version; defaults to latest available iOS major")
    parser.add_argument("--device-kind", choices=("iphone", "ipad", "duo"), default="iphone")
    parser.add_argument("--output", type=Path, help="also atomically write the selected simulator JSON to this path")
    args = parser.parse_args(argv)
    try:
        inventory = json.loads(args.inventory.read_text(encoding="utf-8-sig"))
        result = select_simulator(inventory, args.os_major, args.device_kind)
        # Escaped JSON is portable even when a Windows console cannot encode a
        # simulator's custom Unicode name. Decoding retains the original name.
        content = json.dumps(result, ensure_ascii=True, indent=2) + "\n"
        if args.output:
            _write_output(args.output, content)
    except (OSError, UnicodeError, json.JSONDecodeError, SelectionError) as error:
        parser.error(str(error))
    sys.stdout.write(content)
    return 0


if __name__ == "__main__":
    sys.exit(main())
