# Product status and verification

PocketGigaScan is an independent panorama stitcher for DWARF photo grids. The
Flutter app imports local files and can connect to a DWARF camera over its local
network to list panorama packages and download original photos. Stitching and
export run locally; remote camera capture and control are not supported.

## Platform status

- **Windows:** source-built Release and signing-input packaging are qualified.
  The app package remains unsigned until signing is configured.
- **Android:** ARM64 Release packaging and connected-phone workflows are
  qualified. DWARF phone evidence covers camera identity, package listing and
  original-photo transfer. Full camera-origin panorama and seam acceptance
  remain separate checks.
- **macOS:** Apple silicon Release packaging, offline inference and image
  export are qualified. Physical Mac launch and user-photo acceptance remain
  outstanding.
- **iOS:** hosted Release device and Debug simulator bundles compile without
  linking the Rust stitching engine. Physical transfer, native stitching,
  signing and distribution are not qualified.

## Verification records

- [Build and packaging instructions](../BUILD.md)
- [Windows build and standalone source evidence](evidence/DWARF-STANDALONE-2026-10-05.md)
- [Android stitching evidence](evidence/ANDROID-STITCH-2026-10-05.md)
- [DWARF mobile transfer evidence](evidence/DWARF-MOBILE-IMPORT-2026-10-07.md)
- [Four-platform qualification evidence](evidence/FOUR-PLATFORM-BUILD-2026-10-17.md)
- [Four-platform build evidence](evidence/FOUR-PLATFORM-BUILD-2026-10-17.md)
- [Corner texture and export evidence](evidence/CORNER-AUTO-EXPORT-2026-10-05.md)
- [Test commands and acceptance limits](STITCH-TESTING.md)

Historical test records describe the source revisions and environments named
in each evidence document. Synthetic fixtures and host builds do not establish
physical-device behavior or visual quality unless the evidence says so.
