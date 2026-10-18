# PocketGigaScan app icon

The mark uses layered cyan and teal panoramic ribbons to form a letter G. The inner sweep suggests stitched coverage, and the amber point marks alignment. The dark navy tile keeps the icon legible against light and dark launchers. The artwork has no lettering so it remains clear at small sizes.

`dwarf-stitch-icon.svg` is the editable vector export. The cubic path coordinates and colors in `generate_app_icon.py` are the shared geometry source; the script writes both the SVG and all raster platform assets. Pillow rasterizes each PNG at four times its final size and downsamples with Lanczos.

With Pillow 10.1.0 installed from `requirements.txt`, regenerate the Windows, Android, iOS and macOS assets from the repository root:

```powershell
python branding/generate_app_icon.py
```

The script creates `app-icon-master.png` at 1024×1024 and `app-icon-preview.png` at 256×256. `app-icon-small-sizes.png` enlarges 16, 24 and 32 px marks with nearest-neighbor scaling for a pixel-level inspection. The script also updates the Windows ICO (16, 24, 32, 48, 64, 128 and 256 px), Android launcher PNGs for mdpi through xxxhdpi, every PNG listed in the iOS AppIcon asset catalog, and all seven macOS AppIcon PNG sizes (16, 32, 64, 128, 256, 512 and 1024 px). The iOS images use a full-bleed opaque navy background with no baked corner mask; the system applies its platform shape. The macOS images use the shared rounded navy tile with transparent corners.

The macOS build can regenerate just its asset catalog with `python branding/generate_app_icon.py --macos`; this leaves the other platform assets untouched.
