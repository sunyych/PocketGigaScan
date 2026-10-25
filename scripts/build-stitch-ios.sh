#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: build-stitch-ios.sh [--cache-dir DIR] [--output-dir DIR] [--include-intel-simulator]

Builds the native Rust/OpenCV/JPEG XL core and unsigned Flutter iOS device and
simulator apps. Device arm64 and Apple Silicon simulator arm64 are included by
default. Intel simulator archives are optional. Run on macOS with Xcode.
USAGE
}

cache_arg=""
output_arg=""
include_intel=false
while (($#)); do
  case "$1" in
    --cache-dir) (($# >= 2)) || { usage; exit 64; }; cache_arg="$2"; shift 2 ;;
    --output-dir) (($# >= 2)) || { usage; exit 64; }; output_arg="$2"; shift 2 ;;
    --include-intel-simulator) include_intel=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || {
  echo "The iOS application must be built on macOS with Xcode; Windows cannot produce an iOS executable." >&2
  exit 69
}

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$repo/Apps/Flutter/stitch_app"
lock="$repo/scripts/ios-dependencies.lock.json"
helper="$app/tool/native/apple/build_ios_native.sh"
[[ -f "$lock" && -f "$helper" && -f "$app/pubspec.lock" ]] || {
  echo "The iOS dependency lock, native builder, or locked Flutter dependency file is missing." >&2
  exit 66
}

if [[ -n "$cache_arg" ]]; then
  [[ "$cache_arg" == /* ]] || cache_arg="$PWD/$cache_arg"
  mkdir -p "$cache_arg"
  cache="$(cd "$cache_arg" && pwd)"
else
  cache="$repo/.build/ios-native-cache"
  mkdir -p "$cache"
  cache="$(cd "$cache" && pwd)"
fi
if [[ -n "$output_arg" ]]; then
  [[ "$output_arg" == /* ]] || output_arg="$PWD/$output_arg"
  mkdir -p "$output_arg"
  output="$(cd "$output_arg" && pwd)"
else
  output="$repo/.build/stitch-ios"
  mkdir -p "$output"
  output="$(cd "$output" && pwd)"
fi

for command in bash cargo rustc xcodebuild xcode-select xcrun cmake python3; do
  command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 69; }
done
xcode-select -p >/dev/null

if [[ -n "${FLUTTER_ROOT:-}" && -x "$FLUTTER_ROOT/bin/flutter" ]]; then
  flutter="$FLUTTER_ROOT/bin/flutter"
elif command -v flutter >/dev/null; then
  flutter="$(command -v flutter)"
else
  echo "Flutter 3.44.2 is required; add its bin directory to PATH or set FLUTTER_ROOT." >&2
  exit 69
fi

flutter_info="$("$flutter" --version --machine)"
read -r flutter_version flutter_revision < <(python3 -c 'import json,sys; value=json.loads(sys.stdin.read()); print(value["frameworkVersion"], value["frameworkRevision"])' <<<"$flutter_info")
expected_flutter_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["flutter"]["version"])' "$lock")"
expected_flutter_revision="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["flutter"]["revision"])' "$lock")"
[[ "$flutter_version" == "$expected_flutter_version" && "$flutter_revision" == "$expected_flutter_revision" ]] || {
  echo "Flutter SDK pin mismatch: found $flutter_version ($flutter_revision); expected $expected_flutter_version ($expected_flutter_revision)." >&2
  exit 65
}
xcodebuild -version >/dev/null
xcrun --sdk iphoneos --show-sdk-path >/dev/null
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null

source_revision="${LUMIA_SOURCE_REVISION:-}"
if [[ -z "$source_revision" && -f "$repo/SOURCE-REVISION" ]]; then
  source_revision="$(tr -d '\r\n' < "$repo/SOURCE-REVISION")"
fi
if [[ -z "$source_revision" ]] && command -v git >/dev/null; then
  source_revision="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
fi
[[ "$source_revision" =~ ^[0-9a-fA-F]{40}$ ]] || {
  echo "Set LUMIA_SOURCE_REVISION or provide SOURCE-REVISION with the 40-character source Git SHA." >&2
  exit 65
}
export LUMIA_SOURCE_REVISION="$source_revision"
build_native=("$helper" "$repo" "$cache")
if [[ "$include_intel" == true ]]; then build_native+=(--include-intel-simulator); fi
bash "${build_native[@]}"
native_manifest="$app/ios/Native/build-manifest.json"
linker_config="$app/ios/Flutter/NativeCore.generated.xcconfig"
[[ -s "$native_manifest" && -s "$linker_config" ]] || {
  echo "Native iOS build did not produce its manifest and linker configuration." >&2
  exit 66
}

export LUMIA_NATIVE_APPLE_ENABLED=YES
cd "$app"
"$flutter" pub get --enforce-lockfile
"$flutter" build ios --release --no-codesign
"$flutter" build ios --debug --simulator --no-codesign

cd "$repo"
python3 "$repo/scripts/package_ios_build.py" \
  --app "$app/build/ios/iphoneos/Runner.app" \
  --kind device --configuration Release --output-dir "$output" \
  --source-revision "$source_revision" --flutter-version "$flutter_version" \
  --native-manifest "$native_manifest"
python3 "$repo/scripts/package_ios_build.py" \
  --app "$app/build/ios/iphonesimulator/Runner.app" \
  --kind simulator --configuration Debug --output-dir "$output" \
  --source-revision "$source_revision" --flutter-version "$flutter_version" \
  --native-manifest "$native_manifest"

echo "Built native-linked unsigned iOS device and simulator packages in $output"
