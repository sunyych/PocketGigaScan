# Regression fixtures

Keep small, deterministic inputs here for fast tests. Real PTZ captures stay
outside the repository and are supplied through a manifest. The Rust example
uses JSON with a `tiles` array containing `row`, `column`, and `path`; paths
are resolved from the manifest directory. The standalone benchmark uses a
UTF-8 TSV with the same three columns. Generate synthetic PNG tiles with
`python tools/generate_fixtures.py fixtures/generated` when needed.

Do not treat output dimensions as stitch acceptance. The comparison harness
also records pixel error and seam-boundary error; real captures must additionally
pass the quality report gate.
