#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: build_ios_native.sh <repo-root> <cache-root> [--include-intel-simulator]

Builds pinned static OpenCV, libjxl and Rust core archives for iPhoneOS arm64
and iPhoneSimulator arm64. Intel simulator slices are optional. Run on macOS
with Xcode, CMake, Rust 1.88, and the listed command-line tools installed.
USAGE
  exit 64
}

[[ $# -ge 2 && $# -le 3 ]] || usage
repo_arg="$1"
cache_arg="$2"
include_intel=false
if [[ $# == 3 ]]; then
  [[ "$3" == --include-intel-simulator ]] || usage
  include_intel=true
fi
[[ "$(uname -s)" == Darwin ]] || {
  echo "The iOS native core can only be built on macOS with Xcode; this script cannot run on Windows or Linux." >&2
  exit 69
}

repo="$(cd "$repo_arg" && pwd -P)"
[[ ! -L "$cache_arg" ]] || { echo "Cache root cannot be a symbolic link: $cache_arg" >&2; exit 64; }
mkdir -p "$cache_arg"
cache="$(cd "$cache_arg" && pwd -P)"
[[ "$cache" != / && "$cache" != "$repo" ]] || {
  echo "Cache root must be a dedicated directory beneath or outside the repository, not the filesystem or repository root." >&2
  exit 64
}
cache_marker="$cache/.pocketgigascan-ios-native-cache"
[[ ! -L "$cache_marker" ]] || { echo "Cache ownership marker cannot be a symbolic link: $cache_marker" >&2; exit 64; }
if [[ -f "$cache_marker" ]]; then
  [[ "$(cat "$cache_marker")" == "$repo" ]] || { echo "Cache marker belongs to a different checkout: $cache" >&2; exit 64; }
elif [[ -n "$(find "$cache" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "Refusing to use a non-empty cache directory without this builder's ownership marker: $cache" >&2
  exit 64
else
  printf '%s\n' "$repo" > "$cache_marker"
fi
assert_cache_target() {
  local target="$1" cursor
  case "$target" in "$cache"/*) ;; *) echo "Refusing a path outside the owned iOS build cache: $target" >&2; exit 64 ;; esac
  cursor="$target"
  while [[ "$cursor" != "$cache" ]]; do
    [[ ! -L "$cursor" ]] || { echo "Refusing a cache path with a symbolic-link component: $cursor" >&2; exit 64; }
    cursor="$(dirname "$cursor")"
  done
  [[ ! -L "$cache" ]] || { echo "Cache root cannot be a symbolic link: $cache" >&2; exit 64; }
}
remove_cache_tree() {
  assert_cache_target "$1"
  [[ "$1" != "$cache" ]] || { echo "Refusing to remove the cache root." >&2; exit 64; }
  rm -rf -- "$1"
}
lock="$repo/scripts/ios-dependencies.lock.json"
core="$repo/native/core"
app="$repo/Apps/Flutter/stitch_app"
[[ -f "$lock" && -f "$core/Cargo.toml" && -f "$app/ios/Runner.xcodeproj/project.pbxproj" ]] || {
  echo "Repository is missing the iOS dependency lock, vendored Rust core, or Flutter iOS runner." >&2
  exit 66
}
source_commit="${LUMIA_SOURCE_REVISION:-}"
if [[ -z "$source_commit" && -f "$repo/SOURCE-REVISION" ]]; then
  source_commit="$(tr -d '\r\n' < "$repo/SOURCE-REVISION")"
fi
if [[ -z "$source_commit" ]] && command -v git >/dev/null; then
  source_commit="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
fi
[[ "$source_commit" =~ ^[0-9a-fA-F]{40}$ ]] || {
  echo "Set LUMIA_SOURCE_REVISION to the source Git commit or provide a SOURCE-REVISION file containing its 40-character SHA." >&2
  exit 65
}

for command in cargo rustc rustup cmake curl shasum tar xcodebuild xcode-select xcrun lipo python3 sysctl; do
  command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 69; }
done
xcode-select -p >/dev/null
xcode_version="$(xcodebuild -version | tr '\n' ';' | sed 's/;$//')"
logical_jobs="$(sysctl -n hw.logicalcpu)"
build_jobs="${LUMIA_IOS_BUILD_JOBS:-$logical_jobs}"
[[ "$build_jobs" =~ ^[1-9][0-9]*$ ]] || { echo "LUMIA_IOS_BUILD_JOBS must be a positive integer." >&2; exit 64; }
if (( build_jobs > 8 )); then build_jobs=8; fi
rust_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["rust"]["version"])' "$lock")"
minimum_ios="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["minimumIOS"])' "$lock")"
[[ "$(rustc "+$rust_version" --version)" == rustc\ "$rust_version"* ]] || {
  echo "Rust $rust_version is required; install it with rustup toolchain install $rust_version --profile minimal." >&2
  exit 69
}
rust_targets=(
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["rust"]["deviceTarget"])' "$lock")"
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["rust"]["simulatorArm64Target"])' "$lock")"
)
if [[ "$include_intel" == true ]]; then
  rust_targets+=("$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["rust"]["simulatorX86_64Target"])' "$lock")")
fi
for target in "${rust_targets[@]}"; do
  rustup target list --installed --toolchain "$rust_version" | grep -qx "$target" || \
    rustup target add "$target" --toolchain "$rust_version"
done

dependency_root="$cache/dependencies"
downloads="$dependency_root/downloads"
sources="$dependency_root/sources"
builds="$dependency_root/build"
sdks="$dependency_root/sdk"
for target in "$dependency_root/.probe" "$downloads/.probe" "$sources/.probe" "$builds/.probe" "$sdks/.probe" "$cache/cargo-target/.probe" "$cache/staging/.probe"; do
  assert_cache_target "$target"
done
mkdir -p "$downloads" "$sources" "$builds" "$sdks"

lock_value() {
  python3 - "$lock" "$1" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
PY
}

download_source() {
  local name="$1" url="$2" expected="$3" archive="$4" actual
  assert_cache_target "$archive"
  assert_cache_target "$archive.partial"
  if [[ -f "$archive" ]]; then
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] && return
  fi
  local partial="$archive.partial"
  rm -f "$archive" "$partial"
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$url" --output "$partial"
  actual="$(shasum -a 256 "$partial" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "SHA-256 mismatch for $name source archive: $actual" >&2
    exit 65
  }
  mv "$partial" "$archive"
}

extract_source() {
  local archive="$1" destination="$2" marker="$3" temporary
  assert_cache_target "$destination/$marker"
  [[ -f "$destination/$marker" ]] && return
  temporary="$(mktemp -d "$sources/.extract.XXXXXX")"
  if ! tar -xzf "$archive" --strip-components=1 -C "$temporary"; then
    remove_cache_tree "$temporary"
    return 1
  fi
  [[ -f "$temporary/$marker" ]] || {
    echo "Pinned source archive is missing expected file $marker: $archive" >&2
    remove_cache_tree "$temporary"
    exit 66
  }
  if [[ -e "$destination" ]]; then
    case "$destination" in "$sources"/*) remove_cache_tree "$destination" ;; *) echo "Unsafe source path: $destination" >&2; exit 66 ;; esac
  fi
  mkdir -p "$(dirname "$destination")"
  mv "$temporary" "$destination"
}

opencv_version="$(lock_value opencv.version)"
opencv_url="$(lock_value opencv.url)"
opencv_sha="$(lock_value opencv.sha256)"
opencv_archive="$downloads/opencv-$opencv_version.tar.gz"
opencv_source="$sources/opencv-$opencv_version"
download_source "OpenCV $opencv_version" "$opencv_url" "$opencv_sha" "$opencv_archive"
extract_source "$opencv_archive" "$opencv_source" modules/core/include/opencv2/core/version.hpp

hydrate_jxl_source() {
  local index=0 name url sha marker archive destination dependency
  while IFS=$'\t' read -r name url sha marker; do
    archive="$downloads/$name.tar.gz"
    destination="$sources/$name"
    download_source "$name" "$url" "$sha" "$archive"
    extract_source "$archive" "$destination" "$marker"
  done < <(python3 - "$lock" <<'PY'
import json
import sys
lock = json.load(open(sys.argv[1], encoding="utf-8"))
for source in lock["libjxl"]["sources"]:
    print("\t".join((source["name"], source["url"], source["sha256"], source["marker"])))
PY
)
  local jxl_source="$sources/libjxl"
  for dependency in brotli highway skcms; do
    local destination="$jxl_source/third_party/$dependency"
    local marker="$destination/CMakeLists.txt"
    [[ "$dependency" == brotli ]] && marker="$destination/c/include/brotli/decode.h"
    [[ "$dependency" == skcms ]] && marker="$destination/skcms.cc"
    if [[ ! -f "$marker" ]]; then
      mkdir -p "$destination"
      cp -R "$sources/$dependency/." "$destination/"
    fi
    [[ -f "$marker" ]] || { echo "Pinned libjxl dependency is incomplete: $dependency" >&2; exit 66; }
  done
}
hydrate_jxl_source

# Xcode does not emit an archive for libjxl's object-only `jxl` target. Keep
# this build-only workaround in the iOS dependency cache, never in shared
# source trees: give the target one harmless translation unit so Xcode creates
# the public libjxl.a that the upstream install rule expects.
patch_ios_libjxl_archive_anchor() {
  python3 - "$sources/libjxl/lib/jxl.cmake" <<'PY'
from pathlib import Path
import sys

cmake_file = Path(sys.argv[1])
anchor = cmake_file.with_name("jxl_ios_archive_anchor.cc")
original = "add_library(jxl ${JPEGXL_INTERNAL_OBJECTS})"
patched = 'add_library(jxl ${JPEGXL_INTERNAL_OBJECTS} "${CMAKE_CURRENT_LIST_DIR}/jxl_ios_archive_anchor.cc")'
anchor_contents = "// iOS Xcode archive anchor for the object-only public jxl target.\n"
contents = cmake_file.read_text(encoding="utf-8")
if patched in contents:
    if contents.count(patched) != 1 or not anchor.is_file() or anchor.read_text(encoding="utf-8") != anchor_contents:
        raise SystemExit("Unexpected or incomplete iOS libjxl archive-anchor patch.")
    raise SystemExit(0)
if contents.count(original) != 1 or anchor.exists():
    raise SystemExit("Pinned libjxl source does not match the expected archive-anchor patch context.")
cmake_file.write_text(contents.replace(original, patched), encoding="utf-8")
anchor.write_text(anchor_contents, encoding="utf-8")
PY
}
patch_ios_libjxl_archive_anchor

# OpenCV installs bundled third-party archives under its documented install
# tree; resolve only these two locations rather than searching the SDK.
opencv_archive_path() {
  local sdk="$1" name="$2" archive
  archive="$sdk/lib/lib${name}.a"
  if [[ -f "$archive" ]]; then
    printf '%s\n' "$archive"
    return 0
  fi
  archive="$sdk/lib/opencv4/3rdparty/lib${name}.a"
  if [[ -f "$archive" ]]; then
    printf '%s\n' "$archive"
    return 0
  fi
  echo "OpenCV SDK is missing static archive lib${name}.a under lib/ or lib/opencv4/3rdparty/." >&2
  return 1
}

opencv_modules=()
opencv_libraries=()
opencv_system_libraries=()
jxl_libraries=()
while IFS= read -r name; do opencv_modules+=("${name#opencv_}"); done < <(python3 - "$lock" <<'PY'
import json
import sys
print("\n".join(json.load(open(sys.argv[1], encoding="utf-8"))["opencvModules"]))
PY
)
while IFS= read -r name; do opencv_libraries+=("$name"); done < <(python3 - "$lock" <<'PY'
import json
import sys
print("\n".join(json.load(open(sys.argv[1], encoding="utf-8"))["opencvLibraries"]))
PY
)
while IFS= read -r name; do opencv_system_libraries+=("$name"); done < <(python3 - "$lock" <<'PY'
import json
import sys
print("\n".join(json.load(open(sys.argv[1], encoding="utf-8"))["opencvSystemLibraries"]))
PY
)
while IFS= read -r name; do jxl_libraries+=("$name"); done < <(python3 - "$lock" <<'PY'
import json
import sys
print("\n".join(json.load(open(sys.argv[1], encoding="utf-8"))["jpegXlLibraries"]))
PY
)
for name in "${opencv_libraries[@]}" "${opencv_system_libraries[@]}" "${jxl_libraries[@]}"; do
  [[ "$name" =~ ^[A-Za-z0-9_+.-]+$ ]] || { echo "Invalid native library name in iOS dependency lock: $name" >&2; exit 64; }
done
serialize_link_libraries() {
  local IFS=';'
  printf '%s' "$*"
}

build_dependencies_for_target() {
  local platform="$1" arch="$2" sdk="$3" suffix="$4"
  local sdk_path opencv_build opencv_sdk jxl_build jxl_sdk jxl_version target name
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  [[ -d "$sdk_path" ]] || { echo "Xcode SDK is unavailable: $sdk" >&2; exit 69; }
  IOS_SDK_VERSION="$(xcrun --sdk "$sdk" --show-sdk-version)"
  opencv_build="$builds/opencv-$suffix"
  opencv_sdk="$sdks/opencv-$suffix"
  jxl_build="$builds/libjxl-$suffix"
  jxl_sdk="$sdks/libjxl-$suffix"
  for target in "$opencv_build/.probe" "$opencv_sdk/.probe" "$jxl_build/.probe" "$jxl_sdk/.probe"; do
    assert_cache_target "$target"
  done
  jxl_version="$(lock_value libjxl.version)"

  cmake -S "$opencv_source" -B "$opencv_build" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk_path" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum_ios" \
    -DCMAKE_XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET="$minimum_ios" \
    -DCMAKE_INSTALL_PREFIX="$opencv_sdk" -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_LIST="$(IFS=,; echo "${opencv_modules[*]}")" \
    -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF \
    -DBUILD_opencv_apps=OFF -DBUILD_opencv_python3=OFF -DBUILD_opencv_java=OFF \
    -DWITH_FFMPEG=OFF -DWITH_GSTREAMER=OFF -DWITH_1394=OFF -DWITH_AVFOUNDATION=OFF \
    -DWITH_TBB=OFF -DWITH_ITT=OFF -DWITH_IPP=OFF -DWITH_LAPACK=OFF -DWITH_OPENEXR=OFF \
    -DWITH_OPENJPEG=OFF -DWITH_TIFF=OFF -DWITH_WEBP=OFF \
    -DWITH_JPEG=ON -DBUILD_JPEG=ON -DWITH_PNG=ON -DBUILD_PNG=ON -DBUILD_ZLIB=ON
  cmake --build "$opencv_build" --config Release --target install --parallel "$build_jobs"

  cmake -S "$sources/libjxl" -B "$jxl_build" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk_path" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum_ios" \
    -DCMAKE_XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET="$minimum_ios" \
    -DCMAKE_MACOSX_BUNDLE=OFF -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DCMAKE_INSTALL_PREFIX="$jxl_sdk" -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DJPEGXL_ENABLE_TOOLS=OFF \
    -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
    -DJPEGXL_ENABLE_FUZZERS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF \
    -DJPEGXL_ENABLE_TCMALLOC=OFF -DJPEGXL_ENABLE_SKCMS=ON -DJPEGXL_VERSION="$jxl_version" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  cmake --build "$jxl_build" --config Release --parallel "$build_jobs"
  cmake --install "$jxl_build" --config Release

  for name in "${opencv_libraries[@]}"; do
    opencv_archive_path "$opencv_sdk" "$name" >/dev/null || exit 66
  done
  for name in "${jxl_libraries[@]}"; do
    [[ -f "$jxl_sdk/lib/lib${name}.a" ]] || { echo "libjxl SDK is missing static archive lib${name}.a for $suffix." >&2; exit 66; }
  done
  IOS_OPENCV_SDK="$opencv_sdk"
  IOS_JXL_SDK="$jxl_sdk"
}

verify_archive() {
  local archive="$1" expected_arch="$2" expected_platform="$3" member temporary platform platform_raw commands
  [[ -f "$archive" ]] || { echo "Missing static archive: $archive" >&2; exit 66; }
  lipo "$archive" -verify_arch "$expected_arch" >/dev/null || {
    echo "Archive $archive does not contain $expected_arch." >&2
    exit 66
  }
  member="$(xcrun ar -t "$archive" | awk '/\.o$/ && !found { first=$0; found=1 } END { print first }')"
  [[ -n "$member" ]] || { echo "Archive has no inspectable object members: $archive" >&2; exit 66; }
  temporary="$(mktemp -d "$cache/.archive-check.XXXXXX")"
  (cd "$temporary" && xcrun ar -x "$archive" "$member")
  member="${member##*/}"
  commands="$(xcrun otool -l "$temporary/$member")"
  platform_raw="$(printf '%s\n' "$commands" | awk '$1 == "cmd" && $2 == "LC_BUILD_VERSION" { wanted=1; next } wanted && $1 == "platform" && !found { platform=$2; found=1 } END { print platform }')"
  case "$platform_raw" in
    IOS|2) platform=IOS ;;
    IOSSIMULATOR|7) platform=IOSSIMULATOR ;;
    *)
      if [[ "$expected_platform" == IOS ]] && grep -q 'cmd LC_VERSION_MIN_IPHONEOS' <<<"$commands"; then
        platform=IOS
      elif grep -q 'cmd LC_VERSION_MIN_IPHONEOS' <<<"$commands"; then
        platform=AMBIGUOUS_LEGACY_IOS_SIMULATOR
      else
        platform="${platform_raw:-MISSING_BUILD_VERSION}"
      fi
      ;;
  esac
  remove_cache_tree "$temporary"
  [[ "$platform" == "$expected_platform" ]] || {
    echo "Archive $archive targets platform '$platform', expected '$expected_platform' (architecture alone is insufficient)." >&2
    exit 66
  }
}

native_root="$app/ios/Native"
device_out="$native_root/iphoneos"
simulator_out="$native_root/iphonesimulator"
mkdir -p "$device_out" "$simulator_out" "$native_root/licenses"
declare -a variants=()

build_variant() {
  local kind="$1" arch="$2" sdk="$3" target="$4" suffix="$5" platform_id="$6"
  local opencv_sdk jxl_sdk core_archive output_dir archive_path name
  build_dependencies_for_target "$kind" "$arch" "$sdk" "$suffix"
  opencv_sdk="$IOS_OPENCV_SDK"
  jxl_sdk="$IOS_JXL_SDK"
  core_archive="$cache/cargo-target/$target/release/liblumia_gigascan_core.a"
  (
    cd "$core"
    export OPENCV_DIR="$opencv_sdk"
    export OPENCV_INCLUDE_PATHS="$opencv_sdk/include/opencv4"
    export OPENCV_LINK_PATHS="$opencv_sdk/lib:$opencv_sdk/lib/opencv4/3rdparty"
    export OPENCV_LINK_LIBS="$(serialize_link_libraries "${opencv_libraries[@]}" "${opencv_system_libraries[@]}")"
    export LUMIA_JXL_SDK="$jxl_sdk"
    export LUMIA_JXL_LINK_PATHS="$jxl_sdk/lib"
    export MACOSX_DEPLOYMENT_TARGET="$minimum_ios"
    export IPHONEOS_DEPLOYMENT_TARGET="$minimum_ios"
    export CARGO_TARGET_DIR="$cache/cargo-target"
    cargo "+$rust_version" rustc --locked --release --target "$target" --lib --crate-type staticlib
  )
  [[ -f "$core_archive" ]] || { echo "Cargo did not produce $core_archive." >&2; exit 66; }
  verify_archive "$core_archive" "$arch" "$platform_id"
  for name in "${opencv_libraries[@]}"; do
    archive_path="$(opencv_archive_path "$opencv_sdk" "$name")" || exit 66
    verify_archive "$archive_path" "$arch" "$platform_id"
  done
  for name in "${jxl_libraries[@]}"; do
    verify_archive "$jxl_sdk/lib/lib${name}.a" "$arch" "$platform_id"
  done
  output_dir="$cache/staging/$suffix"
  mkdir -p "$output_dir"
  cp "$core_archive" "$output_dir/liblumia_gigascan_core.a"
  for name in "${opencv_libraries[@]}"; do
    archive_path="$(opencv_archive_path "$opencv_sdk" "$name")" || exit 66
    cp "$archive_path" "$output_dir/"
  done
  for name in "${jxl_libraries[@]}"; do cp "$jxl_sdk/lib/lib${name}.a" "$output_dir/"; done
  assert_cache_target "$output_dir/.probe"
  variants+=("$kind|$arch|$sdk|$target|$suffix|$platform_id|$IOS_SDK_VERSION|$output_dir")
}

build_variant device arm64 iphoneos aarch64-apple-ios iphoneos IOS
build_variant simulator arm64 iphonesimulator aarch64-apple-ios-sim iphonesimulator-arm64 IOSSIMULATOR
if [[ "$include_intel" == true ]]; then
  build_variant simulator x86_64 iphonesimulator x86_64-apple-ios iphonesimulator-x86_64 IOSSIMULATOR
fi

archive_names=(liblumia_gigascan_core.a)
archive_names+=("${opencv_libraries[@]}" "${jxl_libraries[@]}")
for platform_dir in "$device_out" "$simulator_out"; do
  for name in "${archive_names[@]}"; do
    output_archive="$platform_dir/lib${name}.a"
    [[ "$name" == liblumia_gigascan_core.a ]] && output_archive="$platform_dir/$name"
    [[ ! -e "$output_archive" ]] || rm -f "$output_archive"
  done
done
device_source="$cache/staging/iphoneos"
simulator_arm_source="$cache/staging/iphonesimulator-arm64"
[[ -d "$device_source" && -d "$simulator_arm_source" ]] || {
  echo "Device and Apple Silicon simulator archive staging is incomplete." >&2
  exit 66
}
cp "$device_source"/*.a "$device_out/"
if [[ "$include_intel" == true ]]; then
  simulator_x86_source="$cache/staging/iphonesimulator-x86_64"
  [[ -d "$simulator_x86_source" ]] || { echo "Intel simulator staging is incomplete." >&2; exit 66; }
  for archive in "$simulator_arm_source"/*.a; do
    name="$(basename "$archive")"
    [[ -f "$simulator_x86_source/$name" ]] || { echo "Simulator archive sets do not match: $name" >&2; exit 66; }
    lipo -create "$simulator_arm_source/$name" "$simulator_x86_source/$name" -output "$simulator_out/$name"
    lipo "$simulator_out/$name" -verify_arch arm64 >/dev/null
    lipo "$simulator_out/$name" -verify_arch x86_64 >/dev/null
  done
else
  cp "$simulator_arm_source"/*.a "$simulator_out/"
fi

write_linker_config() {
  local config="$app/ios/Flutter/NativeCore.generated.xcconfig"
  local temp="$config.tmp" opencv_flags="" jxl_flags="" symbol_flags="" name symbol
  for name in "${opencv_libraries[@]}"; do opencv_flags+=" -l${name}"; done
  opencv_flags+=" -lz"
  for name in "${jxl_libraries[@]}"; do jxl_flags+=" -l${name}"; done
  for symbol in lumia_gigascan_abi_version lumia_gigascan_job_json lumia_gigascan_free lumia_gigascan_is_available; do
    symbol_flags+=" -Wl,-u,_${symbol}"
  done
  cat > "$temp" <<XCCONFIG
LUMIA_NATIVE_APPLE_ENABLED = YES
LIBRARY_SEARCH_PATHS[sdk=iphoneos*] = \$(inherited) "\$(PROJECT_DIR)/Native/iphoneos"
OTHER_LDFLAGS[sdk=iphoneos*] = \$(inherited) -Wl,-force_load,"\$(PROJECT_DIR)/Native/iphoneos/liblumia_gigascan_core.a" -Wl,-export_dynamic$symbol_flags$opencv_flags$jxl_flags -lc++ -framework Accelerate -framework AVFoundation -framework CoreGraphics -framework CoreImage -framework CoreMedia -framework CoreVideo -framework Foundation -framework ImageIO -framework QuartzCore -framework UIKit -framework VideoToolbox
LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*] = \$(inherited) "\$(PROJECT_DIR)/Native/iphonesimulator"
OTHER_LDFLAGS[sdk=iphonesimulator*] = \$(inherited) -Wl,-force_load,"\$(PROJECT_DIR)/Native/iphonesimulator/liblumia_gigascan_core.a" -Wl,-export_dynamic$symbol_flags$opencv_flags$jxl_flags -lc++ -framework Accelerate -framework AVFoundation -framework CoreGraphics -framework CoreImage -framework CoreMedia -framework CoreVideo -framework Foundation -framework ImageIO -framework QuartzCore -framework UIKit -framework VideoToolbox
XCCONFIG
  mv "$temp" "$config"
}

copy_licenses() {
  local license_root="$native_root/licenses" source_root
  local count=0
  for source_root in "$opencv_source" "$sources/libjxl" "$sources/brotli" "$sources/highway" "$sources/skcms"; do
    local label
    case "$source_root" in
      "$opencv_source") label=OpenCV ;;
      */libjxl) label=libjxl ;;
      */brotli) label=Brotli ;;
      */highway) label=Highway ;;
      */skcms) label=skcms ;;
    esac
    local file
    while IFS= read -r file; do
      [[ -f "$file" ]] || continue
      local relative="${file#"$source_root"/}"
      relative="${relative//\//__}"
      cp "$file" "$license_root/$label-$relative"
      count=$((count + 1))
    done < <(find "$source_root" -type f \( -iname 'LICENSE' -o -iname 'LICENSE-*' -o -iname 'LICENSE_*' -o -iname 'LICENSE.*' -o -iname 'COPYING' -o -iname 'COPYING-*' -o -iname 'NOTICE' -o -iname 'NOTICE-*' -o -iname 'PATENTS*' \) -print)
  done
  (( count > 0 )) || { echo "No dependency license files were copied to $license_root." >&2; exit 66; }

  cargo +"$rust_version" metadata --locked --format-version 1 \
    --manifest-path "$core/Cargo.toml" > "$cache/cargo-metadata.json"
  python3 - "$cache/cargo-metadata.json" "$license_root" <<'PY'
import json
import re
import shutil
import sys
from pathlib import Path

metadata = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
destination = Path(sys.argv[2])
entries = []
for package in metadata["packages"]:
    manifest = Path(package["manifest_path"])
    root = manifest.parent
    license_files = []
    declared = package.get("license_file")
    candidates = [Path(declared)] if declared else []
    if not candidates:
        candidates = [
            path for path in root.iterdir()
            if path.is_file() and re.match(r"(?i)^(license|copying|notice)([-_.].*)?$", path.name)
        ]
    safe_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", f'{package["name"]}-{package["version"]}')
    for candidate in candidates:
        if not candidate.is_absolute():
            candidate = root / candidate
        if not candidate.is_file():
            continue
        output_name = f"Rust-{safe_name}-{candidate.name}"
        shutil.copyfile(candidate, destination / output_name)
        license_files.append(f"licenses/{output_name}")
    entries.append({"name": package["name"], "version": package["version"],
                    "license": package.get("license"), "licenseFiles": license_files})

(destination / "rust-crate-license-inventory.json").write_text(
    json.dumps(entries, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY
}

write_linker_config
copy_licenses
manifest="$native_root/build-manifest.json"
manifest_tmp="$manifest.tmp"
python3 - "$lock" "$manifest_tmp" "$source_commit" "$minimum_ios" "$include_intel" "$xcode_version" "$device_out" "$simulator_out" "$sources/libjxl/lib/jxl.cmake" "$sources/libjxl/lib/jxl_ios_archive_anchor.cc" "${variants[@]}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

lock_path, output, revision, minimum, intel, xcode = sys.argv[1:7]
device, simulator = Path(sys.argv[7]), Path(sys.argv[8])
patched_cmake, archive_anchor = Path(sys.argv[9]), Path(sys.argv[10])
lock = json.loads(Path(lock_path).read_text(encoding="utf-8"))
def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()
archive_names = ["liblumia_gigascan_core.a"]
for library in (lock["opencvLibraries"] + lock["jpegXlLibraries"]):
    archive_names.append("lib" + library + ".a")
def archives(root: Path) -> dict[str, str]:
    result = {}
    for name in archive_names:
        path = root / name
        if not path.is_file():
            raise SystemExit(f"Native manifest is missing required archive: {path}")
        result[name] = digest(path)
    return result
variants = []
for raw in sys.argv[11:]:
    kind, arch, sdk, target, suffix, platform, sdk_version, staging = raw.split("|", 7)
    variants.append({"kind": kind, "architecture": arch, "sdk": sdk,
                     "sdkVersion": sdk_version, "target": target, "archivePlatform": platform,
    "stagingDirectory": f"cache-staging/{suffix}"})
licenses_root = Path(output).parent / "licenses"
licenses = sorted(path.name for path in licenses_root.glob("*"))
payload = {
    "schemaVersion": 1,
    "sourceRevision": revision,
    "nativeCoreSourceRevision": revision,
    "minimumIOS": minimum,
    "xcodeVersion": xcode,
    "rust": lock["rust"],
    "opencv": {"version": lock["opencv"]["version"], "sha256": lock["opencv"]["sha256"]},
    "libjxl": {"version": lock["libjxl"]["version"],
               "sources": [{"name": item["name"], "sha256": item["sha256"]}
                           for item in lock["libjxl"]["sources"]],
               "sourcePatches": [{"name": "ios-xcode-object-only-jxl-archive-anchor",
                                  "files": {"lib/jxl.cmake": digest(patched_cmake),
                                            "lib/jxl_ios_archive_anchor.cc": digest(archive_anchor)}}]},
    "variants": variants,
    "simulatorIncludesIntel": intel == "true",
    "deviceArchives": archives(device),
    "simulatorArchives": archives(simulator),
    "retainedSymbols": ["lumia_gigascan_abi_version", "lumia_gigascan_job_json",
                        "lumia_gigascan_free", "lumia_gigascan_is_available"],
    "capabilities": {"png": True, "tiff": True, "jpeg": True, "jxl": True,
                     "sceneAnalysis": False},
    "libraries": {"opencvModules": lock["opencvModules"],
                   "opencv": lock["opencvLibraries"],
                   "opencvSystem": lock["opencvSystemLibraries"],
                   "jpegXl": lock["jpegXlLibraries"]},
    "rustCrateLicenses": "licenses/rust-crate-license-inventory.json",
    "licenses": [f"licenses/{name}" for name in licenses],
}
if not payload["deviceArchives"] or not payload["simulatorArchives"] or not licenses:
    raise SystemExit("Native manifest cannot be written without device/simulator archives and licenses.")
Path(output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
mv "$manifest_tmp" "$manifest"
echo "Built and staged iOS arm64 native core archives under $native_root; manifest: $manifest"
