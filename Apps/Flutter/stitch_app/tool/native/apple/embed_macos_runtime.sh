#!/usr/bin/env bash
set -euo pipefail

if [[ "${LUMIA_NATIVE_APPLE_ENABLED:-NO}" != YES ]]; then
  exit 0
fi

source_dir="$PROJECT_DIR/Native"
core="$source_dir/liblumia_gigascan_core.dylib"
runtime_dir="$source_dir/runtime"
destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Frameworks"
[[ -f "$core" ]] || { echo "Native macOS integration is enabled but the core dylib is missing: $core" >&2; exit 66; }
[[ -f "$runtime_dir/libonnxruntime.dylib" ]] || { echo "The pinned ONNX Runtime dylib is missing beside the core: $runtime_dir/libonnxruntime.dylib" >&2; exit 66; }
mkdir -p "$destination"
cp "$core" "$destination/"
cp -L "$runtime_dir/libonnxruntime.dylib" "$destination/libonnxruntime.dylib"

shopt -s nullglob
dylibs=("$runtime_dir"/*.dylib)
shopt -u nullglob
for library in "${dylibs[@]}"; do
  [[ "$(basename "$library")" == libonnxruntime.dylib ]] && continue
  cp -L "$library" "$destination/$(basename "$library")"
done

embedded=("$destination"/*.dylib)
((${#embedded[@]} >= 2)) || { echo "No OpenCV runtime libraries were staged in $runtime_dir" >&2; exit 66; }
for binary in "${embedded[@]}" "$destination/liblumia_gigascan_core.dylib"; do
  base="$(basename "$binary")"
  install_name_tool -id "@rpath/$base" "$binary"
done

for binary in "${embedded[@]}" "$destination/liblumia_gigascan_core.dylib"; do
  while IFS= read -r raw_dependency; do
    [[ "$raw_dependency" == *"(architecture "* ]] && continue
    dependency="$(printf '%s' "$raw_dependency" | sed -E 's/[[:space:]]+\(compatibility version.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -n "$dependency" ]] || continue
    base="$(basename "$dependency")"
    [[ "$base" == "$(basename "$binary")" ]] && continue
    if [[ -f "$destination/$base" ]]; then
      [[ "$dependency" == "@rpath/$base" ]] || install_name_tool -change "$dependency" "@rpath/$base" "$binary"
    elif [[ "$dependency" == /System/Library/* || "$dependency" == /usr/lib/* || "$dependency" == @rpath/*.framework/* || "$dependency" == @loader_path/* ]]; then
      :
    else
      echo "Unbundled macOS dependency '$dependency' referenced by $(basename "$binary")" >&2
      exit 66
    fi
  done < <(otool -L "$binary" | tail -n +2)
  if ! otool -l "$binary" | grep -q '@loader_path'; then
    install_name_tool -add_rpath '@loader_path' "$binary"
  fi
done

identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
for binary in "${embedded[@]}" "$destination/liblumia_gigascan_core.dylib"; do
  codesign --force --sign "$identity" --timestamp=none "$binary"
  codesign --verify --strict "$binary"
done
