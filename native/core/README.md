# PocketGigaScan native engine

Vendored independent Lumia GigaScan Rust/OpenCV engine, snapshot bff2a6627d3afdc90a0b62cea4565124920d40a3. Public job ABI names stay compatible with existing task files. No Pocket/DJI protocol or application code is included.

Build via the repository Windows builder. `cargo test --release --locked` covers neighbor registration, texture/grid reconstruction, bounded rendering, export, cancellation and job lifecycle. Some real-photo tests are opt-in; synthetic checks do not prove arbitrary panorama seams.
