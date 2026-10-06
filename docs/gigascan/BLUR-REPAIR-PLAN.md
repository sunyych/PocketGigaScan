# PG-051: unreliable center-photo repair

The user approved the algorithm proposal on 2026-10-06 and requested implementation.

## Scope and contracts

Extend existing neighboring-photo refinement and deghost rendering rather than
introducing another reconstruction engine. Keep every input, sole-source
coverage, bounded tiled memory, estimated placement provenance, separate preview
and final exports, and old task JSON defaults. Never label synthetic results as
acceptance of the supplied photograph set. No source originals for that set have
been provided in this request.

## Owned tasks

- [x] Luna registration coder: `native/core/src/spherical.rs` and
  `native/core/src/pipeline/register.rs`. Inspect existing robust solver; add
  spatial correspondence support and independent neighbor consistency evidence
  to unreliable edge treatment. Test false repetitive matches and reliable
  weak-photo constraints. Version changed alignment caches.
- [x] Luna rendering coder: `native/core/src/spherical_renderer.rs`. Compare
  local sharpness at corresponding overlap locations, require textured sharper
  peers, preserve sole-source/flat regions and existing obstruction behavior.
  Include synthetic blurred-texture and coverage regressions; account new maps.
- [x] Luna Flutter coder: localized settings explanations and regression tests.
  Reuse neighboring refinement/deghost options; preserve old task defaults.
- [ ] Coordinator: independently review numerical/coverage/memory behavior;
  run Rust formatting/tests, Flutter analysis/tests, builder contracts and the
  standard Windows source Release builder. Record evidence and limitations in
  collaboration, roadmap and qualification documents.

## Acceptance

Blur repair must prefer the sharper source where the same scene is covered,
without making flat scene content disappear. Unreliable neighbor constraints
must not silently move a trusted surrounding graph; grid-estimated positions
remain disclosed. Regression suites and normal packaged Windows Release must
pass. Real-photo four-border acceptance remains pending original inputs.
