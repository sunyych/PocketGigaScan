# PocketGigaScan dependency notices

The PocketGigaScan application and its original branding are licensed under
Apache-2.0; see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). The vendored Rust
stitching engine carries its own Apache-2.0 license at
[`native/core/LICENSE`](native/core/LICENSE).

Flutter and Dart package notices are generated from the resolved package graph
in each Flutter build. Rust registry dependency license files are collected
from `native/core/Cargo.lock` and included in platform package inventories.
Pinned and redistributed native dependency licenses are retained in
[`third_party/licenses`](third_party/licenses), including OpenCV, libjxl,
Highway, Brotli, JPEG/PNG/WebP/TIFF codecs, zlib, OpenJPEG, skcms and the
Microsoft runtime notice.

The offline scene model has a separate pinned license declaration and
attribution notice, generated from the model card and recorded in
`scripts/scene-model-export.lock.json`. Platform packages include that notice
with the model. iOS build-validation bundles currently omit the Rust stitching
engine and therefore do not represent native iOS processing releases.

Keep each package's generated Flutter notices, Cargo license inventory, native
dependency notices and model notice with the corresponding distributed files.
