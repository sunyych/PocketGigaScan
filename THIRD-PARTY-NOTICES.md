# PocketGigaScan dependency notices

This standalone application contains no retired OpenPocketCine/DJI protocol, mobile UI, LUT, font or icon sources. The repository's historical NOTICE and Apache2.0 LICENSE remain for attribution/history; descriptions of retired assets in the historical notice do not mean those assets are bundled in this Windows product.

Current dependencies: Flutter/Dart and package licenses are included in Flutter's generated application notices; the Rust dependency graph is locked in `native/core/Cargo.lock`. Cargo registry license texts are collected into the Windows ZIP's `licenses/rust` directory and their identities/hashes recorded in the build manifest. The native engine uses OpenCV 4.13.0 and official static libjxl 0.12.0. Redistributed native dependency license texts are in `third_party/licenses` and copied into the Windows ZIP. The new application icon is original project artwork, generated from `branding` sources under the repository license.

OpenCV: Apache2.0. libjxl, Highway, Brotli, JPEG/PNG/WebP/zlib and other bundled official codec dependency notices are supplied as individual license files. Distribution checks must keep these alongside the complete package.
