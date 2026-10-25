# PocketGigaScan native engine

Vendored independent Lumia GigaScan Rust/OpenCV engine, snapshot bff2a6627d3afdc90a0b62cea4565124920d40a3. Public job ABI names stay compatible with existing task files. No Pocket/DJI protocol or application code is included.

Build via the repository Windows builder. `cargo test --release --locked` covers neighbor registration, texture/grid reconstruction, bounded rendering, export, cancellation and job lifecycle. Some real-photo tests are opt-in; synthetic checks do not prove arbitrary panorama seams.

JPEG export uses quality 90 and composites transparency onto white. It reads the full-resolution level-0 tiles and preserves their dimensions while both axes are at most 65,500 pixels. If either axis is larger, it scales the image proportionally so the longest axis is 65,500 pixels and rounds/clamps the other axis to at least one pixel. This is a compatibility cap: the bundled encoder accepts dimensions through 65,535, while common libjpeg-turbo builds reject dimensions above 65,500. Export keeps memory bounded with a disk-backed RGB spool, row-wise bilinear resizing and an eight-row encoder cache.
