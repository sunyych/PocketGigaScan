#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: build_apple_native.sh ios|macos

Run on macOS with Xcode command-line tools and Rust Apple targets installed.
The selected OPENCV_*_ROOT must contain include/ and lib/ for that Apple SDK.
USAGE
  exit 64
}

[[ $# == 1 ]] || usage
platform="$1"
case "$platform" in ios|macos) ;; *) usage ;; esac
[[ "$(uname -s)" == Darwin ]] || {
  echo "Apple native builds require macOS with Xcode; this script cannot run on Windows or Linux." >&2
  exit 69
}

app_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
core_dir="${LUMIA_CORE_DIR:-$app_root/../../../native/core}"
[[ -f "$core_dir/Cargo.toml" ]] || {
  echo "Vendored Rust core not found at $core_dir; set LUMIA_CORE_DIR to an explicit core checkout." >&2
  exit 66
}

rust_toolchain="${LUMIA_RUST_TOOLCHAIN:-1.88.0}"
for command in cargo rustc rustup lipo xcodebuild; do
  command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 69; }
done
rustc "+$rust_toolchain" --version >/dev/null 2>&1 || {
  echo "Rust toolchain $rust_toolchain is not installed; install it with rustup toolchain install $rust_toolchain." >&2
  exit 69
}

default_modules="opencv_stitching opencv_calib3d opencv_features2d opencv_flann opencv_imgcodecs opencv_imgproc opencv_core opencv_photo"
modules="${LUMIA_OPENCV_LINK_LIBS:-$default_modules}"
extra_libs="${LUMIA_APPLE_EXTRA_LIBS:-}"
link_libs="$modules${extra_libs:+ $extra_libs}"
cargo_libs="$(printf '%s' "$link_libs" | tr ' ' ';')"
opencv_link_flags=""
for name in $link_libs; do
  [[ "$name" =~ ^[A-Za-z0-9_+-]+$ ]] || {
    echo "Invalid OpenCV library name '$name'; use base names such as opencv_core or jpeg." >&2
    exit 64
  }
  opencv_link_flags+=" -l${name}"
done

require_opencv() {
  local root="$1"
  [[ -d "$root/include" && -d "$root/lib" ]] || {
    echo "OpenCV root must contain include/ and lib/: $root" >&2
    exit 66
  }
  local name
  for name in $link_libs; do
    [[ -f "$root/lib/lib${name}.a" || -f "$root/lib/lib${name}.dylib" ]] || {
      echo "Missing required OpenCV library lib${name}.a or lib${name}.dylib under $root/lib" >&2
      exit 66
    }
  done
}

build_core() {
  local target="$1" opencv_root="$2"
  require_opencv "$opencv_root"
  echo "Building lumia-gigascan-core for $target using $opencv_root"
  (
    cd "$core_dir"
    OPENCV_DIR="$opencv_root" \
      OPENCV_INCLUDE_PATHS="$opencv_root/include" \
      OPENCV_LINK_PATHS="$opencv_root/lib" \
      OPENCV_LINK_LIBS="$cargo_libs" \
      cargo "+$rust_toolchain" build --locked --release --target "$target" --lib
  )
}

build_ios_core() {
  local target="$1" opencv_root="$2"
  require_static_opencv "$opencv_root"
  echo "Building lumia-gigascan-core for $target using $opencv_root"
  (
    cd "$core_dir"
    OPENCV_DIR="$opencv_root" \
      OPENCV_INCLUDE_PATHS="$opencv_root/include" \
      OPENCV_LINK_PATHS="$opencv_root/lib" \
      OPENCV_LINK_LIBS="$cargo_libs" \
      cargo "+$rust_toolchain" rustc --locked --release --target "$target" --lib -- \
        -C link-arg=-framework -C link-arg=Accelerate \
        -C link-arg=-framework -C link-arg=AVFoundation \
        -C link-arg=-framework -C link-arg=CoreGraphics \
        -C link-arg=-framework -C link-arg=CoreImage \
        -C link-arg=-framework -C link-arg=CoreMedia \
        -C link-arg=-framework -C link-arg=CoreVideo \
        -C link-arg=-framework -C link-arg=Foundation \
        -C link-arg=-framework -C link-arg=ImageIO \
        -C link-arg=-framework -C link-arg=QuartzCore \
        -C link-arg=-framework -C link-arg=UIKit \
        -C link-arg=-framework -C link-arg=VideoToolbox \
        -C link-arg=-lc++ -C link-arg=-lz
  )
}

require_static_opencv() {
  local root="$1" name
  require_opencv "$root"
  for name in $link_libs; do
    [[ -f "$root/lib/lib${name}.a" ]] || {
      echo "iOS requires static OpenCV archive lib${name}.a under $root/lib; dynamic libraries are not supported." >&2
      exit 66
    }
  done
}

if [[ "$platform" == ios ]]; then
  device_root="${OPENCV_IOS_DEVICE_ROOT:-}"
  simulator_arm_root="${OPENCV_IOS_SIMULATOR_ARM64_ROOT:-}"
  simulator_x86_root="${OPENCV_IOS_SIMULATOR_X86_64_ROOT:-}"
  [[ -n "$device_root" && -n "$simulator_arm_root" && -n "$simulator_x86_root" ]] || {
    echo "Set OPENCV_IOS_DEVICE_ROOT, OPENCV_IOS_SIMULATOR_ARM64_ROOT, and OPENCV_IOS_SIMULATOR_X86_64_ROOT to OpenCV builds for their respective SDK architectures." >&2
    exit 64
  }
  require_static_opencv "$device_root"
  require_static_opencv "$simulator_arm_root"
  require_static_opencv "$simulator_x86_root"
  for name in $link_libs; do
    lipo -verify_arch arm64 "$simulator_arm_root/lib/lib${name}.a" >/dev/null || {
      echo "Simulator arm64 archive lib${name}.a has no arm64 slice: $simulator_arm_root/lib/lib${name}.a" >&2
      exit 66
    }
    lipo -verify_arch x86_64 "$simulator_x86_root/lib/lib${name}.a" >/dev/null || {
      echo "Simulator x86_64 archive lib${name}.a has no x86_64 slice: $simulator_x86_root/lib/lib${name}.a" >&2
      exit 66
    }
    lipo -verify_arch arm64 "$device_root/lib/lib${name}.a" >/dev/null || {
      echo "Device archive lib${name}.a must contain arm64: $device_root/lib/lib${name}.a" >&2
      exit 66
    }
  done

  build_ios_core aarch64-apple-ios "$device_root"
  build_ios_core aarch64-apple-ios-sim "$simulator_arm_root"
  build_ios_core x86_64-apple-ios "$simulator_x86_root"

  for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    [[ -f "$core_dir/target/$target/release/liblumia_gigascan_core.a" ]] || {
      echo "Cargo did not produce target/$target/release/liblumia_gigascan_core.a; check Rust target support and OpenCV static link inputs." >&2
      exit 66
    }
  done

  device_out="$app_root/ios/Native/iphoneos"
  simulator_out="$app_root/ios/Native/iphonesimulator"
  mkdir -p "$device_out" "$simulator_out"
  cp "$core_dir/target/aarch64-apple-ios/release/liblumia_gigascan_core.a" "$device_out/"
  lipo -create \
    "$core_dir/target/aarch64-apple-ios-sim/release/liblumia_gigascan_core.a" \
    "$core_dir/target/x86_64-apple-ios/release/liblumia_gigascan_core.a" \
    -output "$simulator_out/liblumia_gigascan_core.a"
  for name in $link_libs; do
    cp "$device_root/lib/lib${name}.a" "$device_out/"
    lipo -create "$simulator_arm_root/lib/lib${name}.a" "$simulator_x86_root/lib/lib${name}.a" -output "$simulator_out/lib${name}.a"
  done

  cat > "$app_root/ios/Flutter/NativeCore.generated.xcconfig.tmp" <<XCCONFIG
LUMIA_NATIVE_APPLE_ENABLED = YES
LIBRARY_SEARCH_PATHS[sdk=iphoneos*] = \$(inherited) "\$(PROJECT_DIR)/Native/iphoneos"
OTHER_LDFLAGS[sdk=iphoneos*] = \$(inherited) -Wl,-force_load,"\$(PROJECT_DIR)/Native/iphoneos/liblumia_gigascan_core.a" -Wl,-export_dynamic$opencv_link_flags -lc++ -lz -framework Accelerate -framework AVFoundation -framework CoreGraphics -framework CoreImage -framework CoreMedia -framework CoreVideo -framework Foundation -framework ImageIO -framework QuartzCore -framework UIKit -framework VideoToolbox
LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*] = \$(inherited) "\$(PROJECT_DIR)/Native/iphonesimulator"
OTHER_LDFLAGS[sdk=iphonesimulator*] = \$(inherited) -Wl,-force_load,"\$(PROJECT_DIR)/Native/iphonesimulator/liblumia_gigascan_core.a" -Wl,-export_dynamic$opencv_link_flags -lc++ -lz -framework Accelerate -framework AVFoundation -framework CoreGraphics -framework CoreImage -framework CoreMedia -framework CoreVideo -framework Foundation -framework ImageIO -framework QuartzCore -framework UIKit -framework VideoToolbox
XCCONFIG
  mv "$app_root/ios/Flutter/NativeCore.generated.xcconfig.tmp" "$app_root/ios/Flutter/NativeCore.generated.xcconfig"
  echo "iOS core and OpenCV archives staged under ios/Native; optional Xcode linker config generated."
else
  macos_arm_root="${OPENCV_MACOS_ARM64_ROOT:-}"
  macos_x86_root="${OPENCV_MACOS_X86_64_ROOT:-}"
  [[ -n "$macos_arm_root" && -n "$macos_x86_root" ]] || {
    echo "Set OPENCV_MACOS_ARM64_ROOT and OPENCV_MACOS_X86_64_ROOT to matching per-architecture OpenCV builds." >&2
    exit 64
  }
  require_opencv "$macos_arm_root"
  require_opencv "$macos_x86_root"
  for name in $modules; do
    [[ -f "$macos_arm_root/lib/lib${name}.dylib" ]] || {
      echo "macOS requires the OpenCV runtime dylib lib${name}.dylib under $macos_arm_root/lib." >&2
      exit 66
    }
    [[ -f "$macos_x86_root/lib/lib${name}.dylib" ]] || {
      echo "macOS requires the OpenCV runtime dylib lib${name}.dylib under $macos_x86_root/lib." >&2
      exit 66
    }
    lipo -verify_arch arm64 "$macos_arm_root/lib/lib${name}.dylib" >/dev/null || {
      echo "OpenCV module lib${name}.dylib has no arm64 slice." >&2
      exit 66
    }
    lipo -verify_arch x86_64 "$macos_x86_root/lib/lib${name}.dylib" >/dev/null || {
      echo "OpenCV module lib${name}.dylib has no x86_64 slice." >&2
      exit 66
    }
  done
  build_core aarch64-apple-darwin "$macos_arm_root"
  build_core x86_64-apple-darwin "$macos_x86_root"
  for target in aarch64-apple-darwin x86_64-apple-darwin; do
    [[ -f "$core_dir/target/$target/release/liblumia_gigascan_core.dylib" ]] || {
      echo "Cargo did not produce target/$target/release/liblumia_gigascan_core.dylib; check Rust target support and OpenCV link inputs." >&2
      exit 66
    }
  done

  native_dir="$app_root/macos/Native"
  runtime_dir="$native_dir/runtime"
  mkdir -p "$runtime_dir"
  lipo -create \
    "$core_dir/target/aarch64-apple-darwin/release/liblumia_gigascan_core.dylib" \
    "$core_dir/target/x86_64-apple-darwin/release/liblumia_gigascan_core.dylib" \
    -output "$native_dir/liblumia_gigascan_core.dylib"
  shopt -s nullglob
  arm_dylibs=("$macos_arm_root"/lib/*.dylib)
  x86_dylibs=("$macos_x86_root"/lib/*.dylib)
  shopt -u nullglob
  ((${#arm_dylibs[@]} > 0 && ${#arm_dylibs[@]} == ${#x86_dylibs[@]})) || {
    echo "macOS OpenCV roots must provide the same .dylib filenames for arm64 and x86_64." >&2
    exit 66
  }
  for index in "${!arm_dylibs[@]}"; do
    arm_lib="${arm_dylibs[$index]}"
    x86_lib="${x86_dylibs[$index]}"
    [[ "$(basename "$arm_lib")" == "$(basename "$x86_lib")" ]] || {
      echo "macOS OpenCV runtime filenames differ by architecture: $arm_lib and $x86_lib" >&2
      exit 66
    }
    lipo -verify_arch arm64 "$arm_lib" >/dev/null || {
      echo "OpenCV runtime $(basename "$arm_lib") has no arm64 slice." >&2
      exit 66
    }
    lipo -verify_arch x86_64 "$x86_lib" >/dev/null || {
      echo "OpenCV runtime $(basename "$x86_lib") has no x86_64 slice." >&2
      exit 66
    }
    lipo -create "$arm_lib" "$x86_lib" -output "$runtime_dir/$(basename "$arm_lib")"
  done

  core_dylib="$native_dir/liblumia_gigascan_core.dylib"
  install_name_tool -id '@rpath/liblumia_gigascan_core.dylib' "$core_dylib"
  shopt -s nullglob
  staged_dylibs=("$runtime_dir"/*.dylib)
  shopt -u nullglob
  for library in "${staged_dylibs[@]}"; do
    install_name_tool -id "@rpath/$(basename "$library")" "$library"
  done
  for binary in "$core_dylib" "${staged_dylibs[@]}"; do
    while IFS= read -r raw_dependency; do
      [[ "$raw_dependency" == *"(architecture "* ]] && continue
      dependency="$(printf '%s' "$raw_dependency" | sed -E 's/[[:space:]]+\(compatibility version.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
      [[ -n "$dependency" ]] || continue
      base="$(basename "$dependency")"
      [[ "$base" == "$(basename "$binary")" ]] && continue
      if [[ -f "$runtime_dir/$base" ]]; then
        [[ "$dependency" == "@rpath/$base" ]] || install_name_tool -change "$dependency" "@rpath/$base" "$binary"
      elif [[ "$dependency" == /System/Library/* || "$dependency" == /usr/lib/* || "$dependency" == @rpath/*.framework/* || "$dependency" == @loader_path/* ]]; then
        :
      else
        echo "Unbundled macOS runtime dependency '$dependency' referenced by $(basename "$binary"). Add matching arm64 and x86_64 dylibs to their OpenCV lib directories." >&2
        exit 66
      fi
    done < <(otool -L "$binary" | tail -n +2)
  done
  cat > "$app_root/macos/Flutter/NativeCore.generated.xcconfig.tmp" <<'XCCONFIG'
LUMIA_NATIVE_APPLE_ENABLED = YES
XCCONFIG
  mv "$app_root/macos/Flutter/NativeCore.generated.xcconfig.tmp" "$app_root/macos/Flutter/NativeCore.generated.xcconfig"
  echo "macOS arm64/x86_64 core and OpenCV runtimes combined and staged under macos/Native."
fi
