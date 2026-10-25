#!/usr/bin/env bash
# Build the existing iOS integration test as an app, launch it normally, then
# attach flutter drive to the Dart VM service URI reported by that Runner.
set -uo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'The iOS native smoke must run on macOS with Xcode.' >&2
  exit 69
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
if [[ ! -f "$repo_root/scripts/build-stitch-ios.sh" || \
      ! -f "$repo_root/Apps/Flutter/stitch_app/pubspec.yaml" || \
      ! -f "$repo_root/.github/workflows/ios-build.yml" ]]; then
  echo 'Run this helper from a PocketGigaScan source checkout.' >&2
  exit 2
fi
if [[ -z "${SIMULATOR_ID:-}" ]]; then
  echo 'Set SIMULATOR_ID to an already-booted iOS Simulator UDID.' >&2
  exit 2
fi

app_dir="$repo_root/Apps/Flutter/stitch_app"
build_app="$app_dir/build/ios/iphonesimulator/Runner.app"
work_dir="$repo_root/.build/ios-direct-smoke"
app_copy="$work_dir/Runner.app"
log_file="$repo_root/.build/ios-smoke.log"
private_dir="$work_dir/private"
bundle_id='com.lumiaiq.pocketgigascan'
target='integration_test/ios_native_smoke_test.dart'
driver='test_driver/ios_native_smoke_driver.dart'

build_timeout_seconds=480
vm_timeout_seconds=90
drive_timeout_seconds=240
result=0
build_succeeded_this_run=0
copy_succeeded_this_run=0
launched_pid=''
vm_uri=''

mkdir -p "$repo_root/.build" "$work_dir" "$private_dir"
chmod 700 "$work_dir" "$private_dir"
rm -f "$work_dir/failed-test-app.zip"
: > "$log_file"
chmod 600 "$log_file"

sanitize_append() {
  local input="$1"
  [[ -s "$input" ]] || return 0
  python3 - "$input" "$log_file" <<'PY'
import re
import sys

source, destination = sys.argv[1:]
with open(source, "r", errors="replace") as stream:
    text = stream.read()
text = re.sub(r"(?i)(?:https?|wss?)://[^\s\"'<>]+", "<redacted-vm-service-uri>", text)
with open(destination, "a") as stream:
    stream.write(text)
    if text and not text.endswith("\n"):
        stream.write("\n")
PY
}

run_bounded() {
  local seconds="$1"
  local phase="$2"
  local output="$private_dir/$phase.raw.log"
  shift 2
  : > "$output"
  chmod 600 "$output"
  python3 - "$seconds" "$output" "$@" <<'PY'
import os
import signal
import subprocess
import sys

limit = int(sys.argv[1])
output = sys.argv[2]
command = sys.argv[3:]
with open(output, "ab") as log:
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        status = process.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        log.write(f"\nTimed out after {limit} seconds.\n".encode())
        status = 124
if status < 0:
    status = 128 - status
sys.exit(status)
PY
  local status=$?
  sanitize_append "$output"
  return "$status"
}

on_exit() {
  local status=$?
  if [[ "$result" -ne 0 && "$status" -eq 0 ]]; then
    status="$result"
  fi
  if [[ "$status" -ne 0 || "$result" -ne 0 ]]; then
    if [[ "$copy_succeeded_this_run" -eq 1 && -d "$app_copy" ]]; then
      if ! ditto -c -k --sequesterRsrc --keepParent "$app_copy" "$work_dir/failed-test-app.zip" \
        >> "$log_file" 2>&1; then
        echo 'Could not archive the failed test app copy.' >> "$log_file"
        status=1
      fi
    elif [[ "$build_succeeded_this_run" -eq 1 && -d "$build_app" ]]; then
      if ! ditto -c -k --sequesterRsrc --keepParent "$build_app" "$work_dir/failed-test-app.zip" \
        >> "$log_file" 2>&1; then
        echo 'Could not archive the failed build app.' >> "$log_file"
        status=1
      fi
    fi
    echo "Direct smoke failed (status $status); failed app, if built this run, is at $work_dir/failed-test-app.zip." >&2
  fi
  rm -f "$private_dir"/*.raw.log
  exit "$status"
}
trap on_exit EXIT

python3 - "$SIMULATOR_ID" <<'PY' || exit 2
import json
import subprocess
import sys

devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
matches = [d for group in devices["devices"].values() for d in group if d.get("udid") == sys.argv[1]]
if not matches or matches[0].get("state") != "Booted":
    raise SystemExit("SIMULATOR_ID must identify an already-booted available simulator.")
PY

echo 'Phase 1/4: build the existing integration test as the simulator app entrypoint.'
run_bounded "$build_timeout_seconds" build \
  bash -c 'cd "$1" && flutter build ios --simulator --debug --target="$2" --no-codesign --no-pub' \
  _ "$app_dir" "$target"
build_status=$?
if (( build_status != 0 )); then
  result=1
  exit "$result"
fi
if [[ ! -d "$build_app" ]]; then
  echo "Build succeeded but expected app is missing: $build_app" | tee -a "$log_file" >&2
  result=1
  exit "$result"
fi
build_succeeded_this_run=1

echo 'Phase 2/4: copy, verify/sign the simulator app, and launch normally.'
rm -rf "$app_copy"
if ! ditto "$build_app" "$app_copy"; then
  echo 'Could not copy the built Runner.app into the isolated test directory.' | tee -a "$log_file" >&2
  result=1
  exit "$result"
fi
copy_succeeded_this_run=1
if ! codesign --verify --deep --strict "$app_copy" > "$private_dir/codesign.raw.log" 2>&1; then
  codesign --force --deep --sign - "$app_copy" >> "$private_dir/codesign.raw.log" 2>&1 || {
    sanitize_append "$private_dir/codesign.raw.log"
    result=1
    exit "$result"
  }
fi
codesign --verify --deep --strict --verbose=2 "$app_copy" >> "$private_dir/codesign.raw.log" 2>&1 || {
  sanitize_append "$private_dir/codesign.raw.log"
  result=1
  exit "$result"
}
sanitize_append "$private_dir/codesign.raw.log"

bundle_from_plist=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_copy/Info.plist") || exit 1
if [[ "$bundle_from_plist" != "$bundle_id" ]]; then
  echo "Unexpected bundle identifier: $bundle_from_plist" | tee -a "$log_file" >&2
  result=1
  exit "$result"
fi

xcrun simctl install "$SIMULATOR_ID" "$app_copy" > "$private_dir/install.raw.log" 2>&1 || {
  sanitize_append "$private_dir/install.raw.log"
  result=1
  exit "$result"
}
sanitize_append "$private_dir/install.raw.log"
xcrun simctl terminate "$SIMULATOR_ID" "$bundle_id" >/dev/null 2>&1 || true

if ! xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$bundle_id" \
  --enable-checked-mode --verify-entry-points --disable-vm-service-publication \
  > "$private_dir/launch.raw.log" 2>&1; then
  sanitize_append "$private_dir/launch.raw.log"
  result=1
  exit "$result"
fi
sanitize_append "$private_dir/launch.raw.log"
launched_pid="$(python3 - "$private_dir/launch.raw.log" <<'PY'
import re
import sys

text = open(sys.argv[1], errors="replace").read()
match = re.search(r":\s*(?:pid\s+)?(\d+)\s*$", text, re.MULTILINE)
if match:
    print(match.group(1))
PY
)"
if [[ ! "$launched_pid" =~ ^[0-9]+$ ]]; then
  echo 'Could not identify the launched Runner PID from simctl launch output.' | tee -a "$log_file" >&2
  result=1
  exit "$result"
fi

echo "Phase 3/4: find this Runner process VM service URI (maximum ${vm_timeout_seconds} seconds)."
deadline=$((SECONDS + vm_timeout_seconds))
while (( SECONDS < deadline )); do
  xcrun simctl spawn "$SIMULATOR_ID" log show --last 2m --style compact --debug \
    --predicate "processIdentifier == $launched_pid" > "$private_dir/vm-query.raw.log" 2>&1 || true
  vm_uri="$(python3 - "$private_dir/vm-query.raw.log" <<'PY'
import re
import sys

text = open(sys.argv[1], errors="replace").read()
match = re.search(
    r"Dart VM Service is listening on\s+((?:https?|wss?)://[^\s\"'<>]+)",
    text,
    re.IGNORECASE,
)
if match:
    print(match.group(1).rstrip(".,);"))
PY
)"
  if [[ -n "$vm_uri" ]]; then
    break
  fi
  sleep 2
done
if [[ -z "$vm_uri" ]]; then
  sanitize_append "$private_dir/vm-query.raw.log"
  echo "No VM service URI found for Runner PID $launched_pid within ${vm_timeout_seconds}s." | tee -a "$log_file" >&2
  result=1
  exit "$result"
fi

echo 'Phase 4/4: attach the existing host driver and collect its test result.'
run_bounded "$drive_timeout_seconds" drive \
  bash -c 'cd "$1" && flutter drive --verbose --no-pub --device-id "$2" --use-existing-app "$3" --driver="$4" --target="$5" --timeout="$6"' \
  _ "$app_dir" "$SIMULATOR_ID" "$vm_uri" "$driver" "$target" "$drive_timeout_seconds"
drive_status=$?
xcrun simctl spawn "$SIMULATOR_ID" log show --last 20m --style compact --debug \
  --predicate "processIdentifier == $launched_pid" \
  > "$private_dir/runner-final.raw.log" 2>&1 || true
sanitize_append "$private_dir/runner-final.raw.log"
if (( drive_status != 0 )); then
  result=1
  exit "$result"
fi

echo 'Direct iOS simulator integration smoke passed. Test log: .build/ios-smoke.log'
exit 0
