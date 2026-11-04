#!/bin/bash
# Build a genuine iPhoneOS Release binary. The output still requires local Apple ID signing.
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd -P)"
OUTPUT_DIR="$PROJECT_DIR/.build/device-ipa"
mkdir -p "$OUTPUT_DIR"
BUILD_DIR="$(mktemp -d "$PROJECT_DIR/.build/device-archive.XXXXXX")"
ARCHIVE_PATH="$BUILD_DIR/GZUCMPocket.xcarchive"
IPA_PATH="$OUTPUT_DIR/GZUCMPocket-for-local-signing.ipa"
PHASE=preflight
mkdir -p "$OUTPUT_DIR"

finish() {
  local result=$?
  trap - EXIT
  python3 - "$OUTPUT_DIR/build-status.json" "$result" "$PHASE" <<'PY'
from pathlib import Path
import json, sys
Path(sys.argv[1]).write_text(json.dumps({
    'status': 'passed' if sys.argv[2] == '0' and sys.argv[3] == 'complete' else 'failed',
    'exit_status': int(sys.argv[2]), 'phase': sys.argv[3],
    'configuration': 'Release', 'platform': 'iPhoneOS',
    'signing': 'unsigned_requires_local_signing',
    'installable_without_signing': False,
}, indent=2) + '\n', encoding='utf-8')
PY
  exit "$result"
}
trap finish EXIT
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' 'This build requires macOS and Xcode.' >&2; exit 1; }
xcodebuild -version | tee "$OUTPUT_DIR/xcode-version.log"
python3 tools/verify_project.py
python3 -m unittest discover -s tools/tests -p 'test_inspect_ipa.py' -v
PHASE=device_archive
xcodebuild archive \
  -project GZUCMPocket.xcodeproj -scheme GZUCMPocket -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  2>&1 | tee "$OUTPUT_DIR/release-device-build.log"

PHASE=ipa_package
APP_PATH="$ARCHIVE_PATH/Products/Applications/GZUCMPocket.app"
[[ -d "$APP_PATH" ]] || { printf '%s\n' 'iPhoneOS archive did not contain the App.' >&2; exit 1; }
mkdir -p "$BUILD_DIR/stage/Payload"
ditto "$APP_PATH" "$BUILD_DIR/stage/Payload/GZUCMPocket.app"
# Replace only this script's prior output; zip otherwise updates a stale archive in place.
python3 - "$IPA_PATH" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
PY
(cd "$BUILD_DIR/stage" && /usr/bin/zip -q -r -y "$IPA_PATH" Payload)
PHASE=ipa_validation
python3 tools/inspect_ipa.py "$IPA_PATH" --output "$OUTPUT_DIR/package-status.json"
python3 - "$OUTPUT_DIR/package-status.json" <<'PY'
from pathlib import Path
import json, sys
assert json.loads(Path(sys.argv[1]).read_text())['signing'] == 'unsigned_requires_local_signing'
PY
(cd "$OUTPUT_DIR" && shasum -a 256 GZUCMPocket-for-local-signing.ipa > GZUCMPocket-for-local-signing.ipa.sha256)
PHASE=complete
printf '%s\n' 'iPhoneOS Release IPA prepared. Apple ID signing is still required before installation.'
