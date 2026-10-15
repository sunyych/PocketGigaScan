#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: build-stitch-macos.sh --scene-model <scene-model-v1.onnx> [--output-dir <directory>]

Builds the non-sandboxed Apple Silicon macOS client and an ad-hoc-signed ZIP.
The model, exporter manifest, upstream README model card, and model notice must be in the same directory.
USAGE
  exit 64
}

scene_model=""
output_dir=""
while (($#)); do
  case "$1" in
    --scene-model) (($# >= 2)) || usage; scene_model="$2"; shift 2 ;;
    --output-dir) (($# >= 2)) || usage; output_dir="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done
[[ -n "$scene_model" ]] || usage
[[ "$(uname -s)" == Darwin ]] || { echo 'The macOS client can only be built on macOS with Xcode.' >&2; exit 69; }
[[ "$(uname -m)" == arm64 ]] || { echo 'This first macOS package targets Apple Silicon arm64.' >&2; exit 69; }

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$repo/Apps/Flutter/stitch_app"
cache="$repo/.build/macos"
[[ "$scene_model" = /* ]] || scene_model="$PWD/$scene_model"
scene_model="$(cd "$(dirname "$scene_model")" && pwd)/$(basename "$scene_model")"
scene_manifest="$(dirname "$scene_model")/scene-model-v1.manifest.json"
if [[ -z "$output_dir" ]]; then output_dir="$repo/.build/stitch-macos"; fi
[[ "$output_dir" = /* ]] || output_dir="$PWD/$output_dir"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

command -v xcodebuild >/dev/null || { echo 'Xcode command-line tools are required.' >&2; exit 69; }
command -v python3 >/dev/null || { echo 'Python 3 is required for package validation.' >&2; exit 69; }
command -v cmake >/dev/null || { echo 'CMake is required to build OpenCV and libjxl from source.' >&2; exit 69; }
xcode-select -p >/dev/null

if [[ -n "${FLUTTER_ROOT:-}" && -x "$FLUTTER_ROOT/bin/flutter" ]]; then
  flutter="$FLUTTER_ROOT/bin/flutter"
elif command -v flutter >/dev/null; then
  flutter="$(command -v flutter)"
else
  flutter_root="$cache/flutter-3.44.2"
  flutter_archive="$cache/downloads/flutter_macos_arm64_3.44.2-stable.zip"
  expected='57fbfdc7032678ab30ad577872bbfc4114a25d3cba94fbfa14a050ec61381a23'
  mkdir -p "$cache/downloads"
  if [[ ! -f "$flutter_archive" ]] || [[ "$(shasum -a 256 "$flutter_archive" | awk '{print $1}')" != "$expected" ]]; then
    rm -f "$flutter_archive" "$flutter_archive.partial"
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
      'https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_3.44.2-stable.zip' \
      --output "$flutter_archive.partial"
    [[ "$(shasum -a 256 "$flutter_archive.partial" | awk '{print $1}')" == "$expected" ]] || { echo 'Flutter 3.44.2 archive SHA-256 mismatch.' >&2; exit 65; }
    mv "$flutter_archive.partial" "$flutter_archive"
  fi
  if [[ ! -x "$flutter_root/bin/flutter" ]]; then
    flutter_extract="$cache/flutter-extract-3.44.2"
    mkdir -p "$flutter_extract"
    ditto -x -k "$flutter_archive" "$flutter_extract"
    [[ -x "$flutter_extract/flutter/bin/flutter" ]] || { echo 'Flutter archive did not contain the expected arm64 SDK layout.' >&2; exit 66; }
    mv "$flutter_extract/flutter" "$flutter_root"
  fi
  flutter="$flutter_root/bin/flutter"
fi
flutter_version="$("$flutter" --version --machine | python3 -c 'import json,sys; v=json.load(sys.stdin); print(v["frameworkVersion"] + " " + v["frameworkRevision"])')"
[[ "$flutter_version" == '3.44.2 c9a6c484230f8b5e408ec57be1ef71dee1e77020' ]] || { echo "Flutter SDK pin mismatch: $flutter_version" >&2; exit 65; }
flutter_sdk_root="$(cd "$(dirname "$flutter")/.." && pwd)"
dart_binary="$(cd "$(dirname "$flutter")/cache/dart-sdk/bin" && pwd)/dart"
file "$dart_binary" | grep -q 'arm64' || { echo 'Flutter Dart SDK must be native arm64; Rosetta-based SDKs are unsupported.' >&2; exit 65; }

python3 "$repo/scripts/verify-macos-package.py" --model "$scene_model" --manifest "$scene_manifest"
export LUMIA_NATIVE_APPLE_ENABLED=YES

cd "$app"
"$flutter" pub get
"$flutter" analyze --no-pub
"$flutter" test --no-pub --reporter expanded
cd "$repo"
bash "$repo/Apps/Flutter/stitch_app/tool/native/apple/build_macos_native.sh" "$repo" "$cache/dependencies"
cd "$app"
"$flutter" build macos --release

bundle="$app/build/macos/Build/Products/Release/PocketGigaScan.app"
[[ -d "$bundle" ]] || { echo "Flutter did not produce the expected app bundle: $bundle" >&2; exit 66; }
resources="$bundle/Contents/Resources"
mkdir -p "$resources/models"
cp "$scene_model" "$resources/models/scene-model-v1.onnx"
cp "$scene_manifest" "$resources/models/scene-model-v1.manifest.json"
model_readme="$(dirname "$scene_model")/scene-model-README.md"
model_notice="$(dirname "$scene_model")/scene-model-NOTICE.txt"
[[ -f "$model_readme" && -f "$model_notice" ]] || { echo 'Pinned scene model README and license notice are required beside the ONNX model.' >&2; exit 66; }
cp "$model_readme" "$resources/models/scene-model-README.md"
cp "$model_notice" "$resources/models/scene-model-NOTICE.txt"
model_license="$(dirname "$scene_model")/scene-model-LICENSE.txt"
if [[ -f "$model_license" ]]; then cp "$model_license" "$resources/models/scene-model-LICENSE.txt"; fi

codesign --force --deep --sign - --timestamp=none "$bundle"
codesign --verify --strict --deep "$bundle"

mkdir -p "$cache/package-staging"
package_stage="$(mktemp -d "$cache/package-staging/PocketGigaScan.XXXXXX")"
package="$package_stage/PocketGigaScan-macos-arm64"
mkdir -p "$package/licenses"
ditto "$bundle" "$package/PocketGigaScan.app"
cp "$repo/LICENSE" "$package/licenses/PocketGigaScan-LICENSE.txt"
cp "$repo/NOTICE" "$package/licenses/PocketGigaScan-NOTICE.txt"
cp "$repo/THIRD-PARTY-NOTICES.md" "$package/licenses/THIRD-PARTY-NOTICES.md"
ort_root="$cache/dependencies/sdk/onnxruntime/onnxruntime-osx-arm64-1.31.0"
cp "$ort_root/LICENSE" "$package/licenses/ONNX-Runtime-LICENSE.txt"
cp "$ort_root/ThirdPartyNotices.txt" "$package/licenses/ONNX-Runtime-ThirdPartyNotices.txt"
cp "$model_readme" "$package/licenses/Scene-Model-README.md"
cp "$model_notice" "$package/licenses/Scene-Model-NOTICE.txt"
if [[ -f "$model_license" ]]; then cp "$model_license" "$package/licenses/Scene-Model-LICENSE.txt"; fi
for entry in 'OpenCV:opencv-4.13.0' 'libjxl:libjxl-0.12.0' 'Brotli:brotli-028fb5a23661f123017c060daa546b55cf4bde29' 'Highway:highway-457c891775a7397bdb0376bb1031e6e027af1c48' 'skcms:skcms-96d9171c94b937a1b5f0293de7309ac16311b722'; do
  IFS=: read -r label folder <<< "$entry"
  source_dir="$cache/dependencies/sources/$folder"
  license_count=0
  while IFS= read -r source; do
    [[ -f "$source" ]] || continue
    cp "$source" "$package/licenses/$label-$(basename "$source")"
    license_count=$((license_count + 1))
  done < <(find "$source_dir" -maxdepth 1 -type f \( -iname 'LICENSE' -o -iname 'LICENSE-*' -o -iname 'LICENSE_*' -o -iname 'LICENSE.*' -o -iname 'COPYING' -o -iname 'COPYING-*' -o -iname 'NOTICE' -o -iname 'NOTICE-*' -o -iname 'PATENTS*' \) -print)
  ((license_count > 0)) || { echo "Dependency license missing in pinned source: $source_dir" >&2; exit 66; }
done
for codec in libjpeg-turbo libpng zlib; do
  codec_root="$cache/dependencies/sources/opencv-4.13.0/3rdparty/$codec"
  [[ -d "$codec_root" ]] || { echo "OpenCV bundled codec source is missing: $codec_root" >&2; exit 66; }
  codec_text_count=0
  while IFS= read -r source; do
    [[ -f "$source" ]] || continue
    cp "$source" "$package/licenses/OpenCV-$codec-$(basename "$source")"
    codec_text_count=$((codec_text_count + 1))
  done < <(find "$codec_root" -type f \( \
    -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' -o -iname 'PATENTS*' -o -iname 'README*' \
  \) -print)
  ((codec_text_count > 0)) || { echo "OpenCV bundled codec license texts are missing: $codec" >&2; exit 66; }
done
cp "$flutter_sdk_root/packages/flutter/LICENSE" "$package/licenses/Flutter-LICENSE.txt"
python3 - "$app/.dart_tool/package_config.json" "$package/licenses/flutter-packages" <<'PY'
import json
import shutil
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

config_path, target_arg = map(Path, sys.argv[1:])
target_arg.mkdir(parents=True, exist_ok=True)
config = json.loads(config_path.read_text(encoding="utf-8"))
copied = 0
for item in config.get("packages", []):
    uri = item.get("rootUri", "")
    parsed = urlparse(uri)
    root = Path(unquote(parsed.path)) if parsed.scheme == "file" else (config_path.parent / uri).resolve()
    package_root = (root / item.get("packageUri", "lib")).resolve()
    package_root = package_root.parent if package_root.name == "lib" else package_root
    for name in ("LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "NOTICE"):
        candidate = package_root / name
        if candidate.is_file():
            shutil.copy2(candidate, target_arg / f"{item['name']}-{name}")
            copied += 1
            break
if copied == 0:
    raise SystemExit("Flutter package license notices were not found in the resolved package graph")
PY

metadata="$cache/cargo-metadata.json"
(cd "$repo/native/core" && cargo +1.88.0 metadata --format-version 1 --locked > "$metadata")
python3 - "$metadata" "$package/licenses/cargo" <<'PY'
import json
import re
import shutil
import sys
from pathlib import Path

metadata_path, destination_arg = map(Path, sys.argv[1:])
destination_arg.mkdir(parents=True, exist_ok=True)
metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
name_re = re.compile(r"^(?:LICENSE|COPYING|NOTICE)(?:[-_.].*)?$", re.IGNORECASE)
for package in metadata["packages"]:
    if not (package.get("source") or "").startswith("registry+"):
        continue
    root = Path(package["manifest_path"]).parent
    files = [path for path in root.iterdir() if path.is_file() and name_re.match(path.name)]
    if not files and package.get("license_file"):
        declared = (root / package["license_file"]).resolve()
        if root.resolve() not in declared.parents:
            raise SystemExit(f"Cargo license_file escapes package directory: {package['name']}")
        if declared.is_file():
            files = [declared]
    if not files:
        raise SystemExit(f"Cargo package has no license text: {package['name']} {package['version']}")
    target = destination_arg / f"{package['name']}-{package['version']}"
    target.mkdir(parents=True, exist_ok=True)
    for path in files:
        shutil.copy2(path, target / path.name)
PY

python3 "$repo/scripts/verify-macos-package.py" --bundle "$package/PocketGigaScan.app" --smoke
python3 "$repo/scripts/verify-macos-package.py" --write-manifest "$package" --lock "$repo/scripts/macos-dependencies.lock.json"
ditto -c -k --sequesterRsrc --keepParent "$package" "$output_dir/PocketGigaScan-macos-arm64.zip"
(cd "$output_dir" && shasum -a 256 PocketGigaScan-macos-arm64.zip > PocketGigaScan-macos-arm64.zip.sha256)
echo "Package ready: $output_dir/PocketGigaScan-macos-arm64.zip"
