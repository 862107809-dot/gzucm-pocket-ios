#!/bin/bash
# Requires macOS and an already-selected Xcode. Does not change xcode-select,
# install runtimes, erase simulators, or substitute a different OS/device kind.
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd -P)"
OS_MAJOR=26
DEVICE_KIND=iphone

usage() {
  printf '%s\n' 'Usage: bash tools/verify-mac.sh [--os-major 18|26|27] [--device-kind iphone|ipad|duo]'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --os-major)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      OS_MAJOR="$2"; shift 2 ;;
    --device-kind)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      DEVICE_KIND="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; printf 'Unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done
case "$OS_MAJOR" in ''|0*|*[!0-9]*) usage >&2; exit 64 ;; esac
[[ ${#OS_MAJOR} -le 3 ]] || { usage >&2; exit 64; }
case "$DEVICE_KIND" in iphone|ipad|duo) ;; *) usage >&2; exit 64 ;; esac

ARTIFACT_DIR="$PROJECT_DIR/.build/verification-${OS_MAJOR}-${DEVICE_KIND}"
mkdir -p "$ARTIFACT_DIR"
STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
RUN_STAMP="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
RESULT_BUNDLE="$ARTIFACT_DIR/native-ui-tests-${RUN_STAMP}.xcresult"
SELECTED_FILE="$ARTIFACT_DIR/selected.json"
INVENTORY_FILE="$ARTIFACT_DIR/inventory.json"
SELECTED_UDID=''
BOOTED_BY_SCRIPT=0
SDK_VERSION=''
XCODE_VERSION=''
PHASE=preflight
CONFIG_STATUS=not_run
PROJECT_STATUS=not_run
PYTHON_STATUS=not_run
CORE_STATUS=not_run
BRIDGE_STATUS=not_run
NATIVE_STATUS=not_run

log() {
  printf '[verification] %s\n' "$*" | tee -a "$ARTIFACT_DIR/verification.log"
}

# pipefail preserves a failed compiler/test command even when tee succeeds.
run_logged() {
  local filename="$1"
  shift
  "$@" 2>&1 | tee "$ARTIFACT_DIR/$filename"
}

finish() {
  local exit_status=$?
  local shutdown_status='not_needed'
  local attachments_status='not_available'
  trap - EXIT INT TERM
  set +e
  if [[ -d "$RESULT_BUNDLE" ]]; then
    xcrun xcresulttool export attachments --path "$RESULT_BUNDLE" \
      --output-path "$ARTIFACT_DIR/attachments-${RUN_STAMP}" \
      > "$ARTIFACT_DIR/attachments-export.log" 2>&1
    attachments_status=$?
    if [[ "$attachments_status" -ne 0 ]]; then
      log 'Attachment export failed; the original .xcresult remains available.'
    fi
  fi
  if [[ "$BOOTED_BY_SCRIPT" -eq 1 && -n "$SELECTED_UDID" ]]; then
    # Leave preexisting Booted/Booting simulators alone.
    xcrun simctl shutdown "$SELECTED_UDID" > "$ARTIFACT_DIR/simulator-shutdown.log" 2>&1
    shutdown_status=$?
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$ARTIFACT_DIR/status.json" "$exit_status" "$OS_MAJOR" "$DEVICE_KIND" \
      "$PHASE" "$SELECTED_UDID" "$BOOTED_BY_SCRIPT" "$SDK_VERSION" "$XCODE_VERSION" \
      "$STARTED_AT" "$RESULT_BUNDLE" "$shutdown_status" "$attachments_status" \
      "$CONFIG_STATUS" "$PROJECT_STATUS" "$PYTHON_STATUS" "$CORE_STATUS" \
      "$BRIDGE_STATUS" "$NATIVE_STATUS" <<'PY'
import datetime
import json
import os
from pathlib import Path
import sys

values = sys.argv[1:]
destination = Path(values[0])
names = ("configuration_lint", "project_checks", "python_tests", "core_tests", "bridge_tests", "native_ui_tests")
checks = {name: ("failed" if state == "running" else state) for name, state in zip(names, values[13:])}
result = {
    "status": "passed" if int(values[1]) == 0 and values[4] == "complete" else "failed",
    "exit_status": int(values[1]),
    "requested_os_major": int(values[2]),
    "device_kind": values[3],
    "phase": values[4],
    "selected_udid": values[5] or None,
    "booted_by_script": values[6] == "1",
    "sdk_version": values[7] or None,
    "xcode_version": values[8] or None,
    "started_at": values[9],
    "finished_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "native_result_bundle": Path(values[10]).name if Path(values[10]).is_dir() else None,
    "simulator_shutdown_exit_status": values[11],
    "attachments_export_exit_status": values[12],
    "checks": checks,
}
temporary = destination.with_suffix(".json.tmp")
temporary.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
os.replace(temporary, destination)
PY
  else
    # Even a missing Python installation must not leave a false success marker.
    printf '{"status":"failed","exit_status":%s,"phase":"%s","requested_os_major":%s,"device_kind":"%s","status_writer":"python3 unavailable"}\n' \
      "$exit_status" "$PHASE" "$OS_MAJOR" "$DEVICE_KIND" > "$ARTIFACT_DIR/status.json"
  fi
  log "Finished with exit status ${exit_status}; evidence: ${ARTIFACT_DIR}"
  exit "$exit_status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "Requested iOS ${OS_MAJOR}, device kind ${DEVICE_KIND}."
if [[ "$(uname -s)" != Darwin ]]; then
  log 'This verification requires macOS. No native tests were run.'
  exit 1
fi
for required in python3 node xcodebuild xcrun plutil; do
  if ! command -v "$required" >/dev/null 2>&1; then
    log "Missing required tool: ${required}"
    exit 1
  fi
done
run_logged xcode-version.log xcodebuild -version
XCODE_VERSION="$(python3 - "$ARTIFACT_DIR/xcode-version.log" <<'PY'
from pathlib import Path
import re
import sys
match = re.search(r"(?m)^Xcode\s+(\d+(?:\.\d+)*)", Path(sys.argv[1]).read_text(encoding="utf-8"))
if not match:
    raise SystemExit("Could not read the selected Xcode version")
print(match.group(1))
PY
)"
SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
printf '%s\n' "$SDK_VERSION" | tee "$ARTIFACT_DIR/sdk-version.log"
python3 - "$SDK_VERSION" "$XCODE_VERSION" "$DEVICE_KIND" <<'PY'
import re
import sys
def version(raw):
    if not re.fullmatch(r"\d+(?:\.\d+)*", raw):
        raise SystemExit("Unexpected toolchain version: " + raw)
    return tuple(int(part) for part in raw.split("."))
sdk, xcode = version(sys.argv[1]), version(sys.argv[2])
if sdk[0] < 26:
    raise SystemExit("An iOS Simulator SDK 26+ is required to compile Liquid Glass. Select an installed Xcode 26+ using DEVELOPER_DIR.")
if sys.argv[3] == "duo" and (xcode + (0, 0))[:2] < (27, 1):
    raise SystemExit("Duo verification requires the selected Xcode to be 27.1 or newer.")
PY

PHASE=configuration_lint
CONFIG_STATUS=running
run_logged configuration-lint.log plutil -lint App/Info.plist App/Resources/PrivacyInfo.xcprivacy GZUCMPocket.xcodeproj/project.pbxproj
CONFIG_STATUS=passed
PHASE=project_checks
PROJECT_STATUS=running
run_logged project-checks.log python3 tools/verify_project.py
PROJECT_STATUS=passed
PHASE=python_tests
PYTHON_STATUS=running
run_logged python-tests.log python3 -m unittest discover -s tools/tests -p 'test_*.py' -v
PYTHON_STATUS=passed
PHASE=core_tests
CORE_STATUS=running
run_logged core-tests.log xcrun swift test --package-path Packages/PocketCore
CORE_STATUS=passed
PHASE=bridge_tests
BRIDGE_STATUS=running
run_logged bridge-tests.log node --test App/Web/Tests/EcardBridge.test.cjs
BRIDGE_STATUS=passed

PHASE=simulator_selection
log 'Capturing simulator inventory; a missing requested OS/device kind is a failure.'
xcrun simctl list --json > "$INVENTORY_FILE" 2> "$ARTIFACT_DIR/inventory.stderr.log"
run_logged simulator-selection.log python3 tools/select_simulator.py \
  --inventory "$INVENTORY_FILE" --os-major "$OS_MAJOR" --device-kind "$DEVICE_KIND" --output "$SELECTED_FILE"
SELECTED_UDID="$(python3 - "$SELECTED_FILE" <<'PY'
import json
import sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["udid"])
PY
)"
DEVICE_STATE="$(python3 - "$INVENTORY_FILE" "$SELECTED_FILE" <<'PY'
import json
import sys
from pathlib import Path
inventory = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
selected = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
matches = [device for device in inventory["devices"].get(selected["runtime"], []) if device.get("udid") == selected["udid"]]
if len(matches) != 1:
    raise SystemExit("Selected device was not uniquely present in the captured inventory")
state = matches[0].get("state")
if state not in ("Shutdown", "Booted", "Booting"):
    raise SystemExit("Selected simulator is not bootable from state: " + str(state))
print(state)
PY
)"
PHASE=simulator_boot
if [[ "$DEVICE_STATE" == Shutdown ]]; then
  run_logged simulator-boot.log xcrun simctl boot "$SELECTED_UDID"
  BOOTED_BY_SCRIPT=1
else
  log "Selected simulator is already ${DEVICE_STATE}; its lifecycle remains caller-owned."
fi
run_logged simulator-bootstatus.log xcrun simctl bootstatus "$SELECTED_UDID" -b

PHASE=native_ui_tests
NATIVE_STATUS=running
run_logged native-ui-tests.log xcodebuild test \
  -project GZUCMPocket.xcodeproj -scheme GZUCMPocket -configuration Debug \
  -destination "platform=iOS Simulator,id=${SELECTED_UDID}" \
  -parallel-testing-enabled NO \
  -derivedDataPath "$PROJECT_DIR/.build/DerivedData-${OS_MAJOR}-${DEVICE_KIND}" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -only-testing:GZUCMPocketUITests CODE_SIGNING_ALLOWED=NO
NATIVE_STATUS=passed
PHASE=complete
log 'Core, bridge, tool and native UI tests passed on the selected simulator.'
log 'Screenshots and .xcresult require review; these checks do not certify real-device fold poses or school-account access.'
