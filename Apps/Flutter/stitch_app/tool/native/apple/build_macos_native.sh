#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: build_macos_native.sh <repo-root> <cache-root>

Builds the pinned Apple Silicon OpenCV, libjxl, and Rust core inputs from source.
The ONNX Runtime SDK is downloaded from the official 1.31.0 release.
USAGE
  exit 64
}

[[ $# == 2 ]] || usage
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS native builds require Xcode on macOS.' >&2; exit 69; }
[[ "$(uname -m)" == arm64 ]] || { echo 'This package currently supports native Apple Silicon arm64 only.' >&2; exit 69; }

repo="$(cd "$1" && pwd)"
cache="$(mkdir -p "$2" && cd "$2" && pwd)"
app="$repo/Apps/Flutter/stitch_app"
core="$repo/native/core"
lock="$repo/scripts/macos-dependencies.lock.json"
arch=arm64
minimum="14.0"
rust_version="1.88.0"
target="aarch64-apple-darwin"

for command in cargo rustc rustup cmake tar curl shasum otool install_name_tool; do
  command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 69; }
done
rustc "+$rust_version" --version >/dev/null 2>&1 || {
  echo "Rust $rust_version is required; install it with: rustup toolchain install $rust_version --profile minimal" >&2
  exit 69
}
rustup target list --installed --toolchain "$rust_version" | grep -qx "$target" || rustup target add "$target" --toolchain "$rust_version"

verify_sha() {
  local file="$1" expected="$2" actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "SHA-256 mismatch for $file: $actual" >&2; exit 65; }
}

download() {
  local url="$1" file="$2" expected="$3"
  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]]; then
    if shasum -a 256 "$file" | awk '{print $1}' | grep -qx "$expected"; then return; fi
    rm -f "$file"
  fi
  local partial="$file.partial"
  rm -f "$partial"
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$url" --output "$partial"
  verify_sha "$partial" "$expected"
  mv "$partial" "$file"
}

extract_source() {
  local archive="$1" destination="$2" marker="$3"
  if [[ ! -f "$destination/$marker" ]]; then
    mkdir -p "$destination"
    tar -xzf "$archive" --strip-components=1 -C "$destination"
  fi
  [[ -f "$destination/$marker" ]] || { echo "Source marker missing after extraction: $destination/$marker" >&2; exit 66; }
}

opencv_archive="$cache/downloads/opencv-4.13.0.tar.gz"
opencv_source="$cache/sources/opencv-4.13.0"
opencv_build="$cache/build/opencv-4.13.0"
opencv_sdk="$cache/sdk/opencv"
download 'https://github.com/opencv/opencv/archive/refs/tags/4.13.0.tar.gz' "$opencv_archive" '1d40ca017ea51c533cf9fd5cbde5b5fe7ae248291ddf2af99d4c17cf8e13017d'
extract_source "$opencv_archive" "$opencv_source" include/opencv2/core/version.hpp
cmake -S "$opencv_source" -B "$opencv_build" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$opencv_sdk" \
  -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum" \
  -DBUILD_LIST=stitching,calib3d,features2d,flann,imgcodecs,imgproc,core,photo \
  -DBUILD_SHARED_LIBS=ON -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF \
  -DBUILD_opencv_apps=OFF -DBUILD_opencv_python3=OFF -DBUILD_opencv_java=OFF \
  -DWITH_FFMPEG=OFF -DWITH_GSTREAMER=OFF -DWITH_1394=OFF -DWITH_AVFOUNDATION=OFF \
  -DWITH_OPENEXR=OFF -DWITH_OPENJPEG=OFF -DWITH_TIFF=OFF -DWITH_WEBP=OFF \
  -DWITH_JPEG=ON -DWITH_PNG=ON -DBUILD_JPEG=ON -DBUILD_PNG=ON -DBUILD_ZLIB=ON
cmake --build "$opencv_build" --target install --parallel "$(sysctl -n hw.logicalcpu)"

source_url=('https://github.com/libjxl/libjxl/archive/v0.12.0.tar.gz' 'https://github.com/google/brotli/archive/028fb5a23661f123017c060daa546b55cf4bde29.tar.gz' 'https://github.com/google/highway/archive/457c891775a7397bdb0376bb1031e6e027af1c48.tar.gz' 'https://github.com/google/skcms/archive/96d9171c94b937a1b5f0293de7309ac16311b722.tar.gz')
source_sha=('03e9be69a30be4011f559da75328b6d7cea8ad921fabfbd551ce10bf45cdc992' '0afe09a53c8bad9861c8dd1fc1284308d54f19d2979ba3541cfdcc9b05fe360f' '5124b0501c98d9930dbb065bfa1a5bbbd59ce0f12facb7e1e33aaef01a5f1f1a' '9bb4b5bba0b7c04f6c2bce9ff713d61e23c9a20c4945161ae16290498ad74627')
source_archive=("$cache/downloads/libjxl-0.12.0.tar.gz" "$cache/downloads/brotli-028fb5a23661f123017c060daa546b55cf4bde29.tar.gz" "$cache/downloads/highway-457c891775a7397bdb0376bb1031e6e027af1c48.tar.gz" "$cache/downloads/skcms-96d9171c94b937a1b5f0293de7309ac16311b722.tar.gz")
source_dir=("$cache/sources/libjxl-0.12.0" "$cache/sources/brotli-028fb5a23661f123017c060daa546b55cf4bde29" "$cache/sources/highway-457c891775a7397bdb0376bb1031e6e027af1c48" "$cache/sources/skcms-96d9171c94b937a1b5f0293de7309ac16311b722")
dependency_name=(libjxl brotli highway skcms)
for index in 0 1 2 3; do
  download "${source_url[$index]}" "${source_archive[$index]}" "${source_sha[$index]}"
  marker=CMakeLists.txt
  [[ "$index" == 3 ]] && marker=src/skcms.cc
  extract_source "${source_archive[$index]}" "${source_dir[$index]}" "$marker"
done
for dependency in brotli highway skcms; do
  case "$dependency" in
    brotli) dependency_index=1 ;;
    highway) dependency_index=2 ;;
    skcms) dependency_index=3 ;;
  esac
  destination="${source_dir[0]}/third_party/$dependency"
  marker="$destination/CMakeLists.txt"
  [[ "$dependency" == brotli ]] && marker="$destination/c/CMakeLists.txt"
  [[ "$dependency" == skcms ]] && marker="$destination/src/skcms.cc"
  if [[ ! -f "$marker" ]]; then
    mkdir -p "$destination"
    cp -R "${source_dir[$dependency_index]}/." "$destination/"
  fi
  [[ -f "$marker" ]] || { echo "Missing hydrated libjxl dependency $dependency" >&2; exit 66; }
done

jxl_build="$cache/build/libjxl-0.12.0"
jxl_sdk="$cache/sdk/libjxl"
cmake -S "${source_dir[0]}" -B "$jxl_build" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$jxl_sdk" -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DJPEGXL_ENABLE_TOOLS=OFF \
  -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF \
  -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF \
  -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_FUZZERS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF \
  -DJPEGXL_ENABLE_TCMALLOC=OFF -DJPEGXL_ENABLE_SKCMS=ON -DJPEGXL_VERSION=0.12.0 \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$jxl_build" --target install --parallel "$(sysctl -n hw.logicalcpu)"

ort_archive="$cache/downloads/onnxruntime-osx-arm64-1.31.0.tgz"
ort_root="$cache/sdk/onnxruntime/onnxruntime-osx-arm64-1.31.0"
download 'https://github.com/microsoft/onnxruntime/releases/download/v1.31.0/onnxruntime-osx-arm64-1.31.0.tgz' "$ort_archive" '1031b36dd3bdaa8d976a6130d9cf2a05e9be320b93ae804f8427b91dc3432afc'
extract_source "$ort_archive" "$ort_root" include/onnxruntime_cxx_api.h
[[ "$(cat "$ort_root/VERSION_NUMBER" | tr -d '\r\n')" == '1.31.0' ]] || { echo 'Unexpected ONNX Runtime SDK version.' >&2; exit 66; }

native_dir="$app/macos/Native"
runtime_dir="$native_dir/runtime"
mkdir -p "$runtime_dir"
export LUMIA_JXL_SDK="$jxl_sdk"
export LUMIA_ORT_SDK="$ort_root"
export OPENCV_DIR="$opencv_sdk"
export OPENCV_INCLUDE_PATHS="$opencv_sdk/include/opencv4"
export OPENCV_LINK_PATHS="$opencv_sdk/lib"
export OPENCV_LINK_LIBS='opencv_stitching;opencv_calib3d;opencv_features2d;opencv_flann;opencv_imgcodecs;opencv_imgproc;opencv_core;opencv_photo'
export LUMIA_NATIVE_APPLE_ENABLED=YES
(cd "$core" && cargo "+$rust_version" fmt --all -- --check)
(cd "$core" && DYLD_LIBRARY_PATH="$opencv_sdk/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" cargo "+$rust_version" test --locked --target "$target")
(cd "$core" && cargo "+$rust_version" build --locked --release --target "$target" --lib)
core_dylib="$core/target/$target/release/liblumia_gigascan_core.dylib"
[[ -f "$core_dylib" ]] || { echo "Cargo did not produce the macOS core dylib: $core_dylib" >&2; exit 66; }
cp "$core_dylib" "$native_dir/liblumia_gigascan_core.dylib"
cp -L "$ort_root/lib/libonnxruntime.dylib" "$runtime_dir/libonnxruntime.dylib"
shopt -s nullglob
opencv_dylibs=("$opencv_sdk"/lib/libopencv_*.dylib)
shopt -u nullglob
for library in "${opencv_dylibs[@]}"; do cp -L "$library" "$runtime_dir/$(basename "$library")"; done
[[ -f "$jxl_sdk/include/jxl/encode.h" ]] || { echo 'libjxl headers are missing from the installed SDK.' >&2; exit 66; }
for library in jxl jxl_cms hwy brotlienc brotlidec brotlicommon; do
  [[ -f "$jxl_sdk/lib/lib$library.a" ]] || { echo "Missing libjxl SDK library: $jxl_sdk/lib/lib$library.a" >&2; exit 66; }
done
for library in opencv_stitching opencv_calib3d opencv_features2d opencv_flann opencv_imgcodecs opencv_imgproc opencv_core opencv_photo; do
  [[ -f "$runtime_dir/lib$library.dylib" ]] || { echo "Missing OpenCV runtime dylib: $runtime_dir/lib$library.dylib" >&2; exit 66; }
done

echo "Built Apple Silicon core and pinned native SDKs under $native_dir"
