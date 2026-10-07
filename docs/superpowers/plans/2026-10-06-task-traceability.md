# Task traceability implementation

The user authorizes a task master file with original file locations and hashes,
actual placement and correction parameters, output references and process timing,
plus task-record deletion without deleting photographs or exported results.
The supplied design explicitly requires null/uncomputed values rather than
invented precision, atomic persistence and legacy resume compatibility.

1. Luna renderer extends the existing task.json master file to version 2;
   retain all existing task fields and support version 1 reads. Add a diagnostic
   record built from the actual saved native layout/manifest, source fingerprints,
   position provenance, accepted/rejected immediate-neighbor constraints,
   applied camera/warp models, algorithm parameters, outputs and timing.
   Reference large artifacts with integrity metadata. Cache unchanged reads.
2. Preserve null/notApplied exposure and color parameters where the current
   renderer does not implement those adjustments. Never infer measured geometry
   from nominal positions or a legacy hard-lock flag.
3. Keep serialized atomic writes, corruption handling and removal tombstones.
   Delete task-owned record files/record temporaries only after checking ownership;
   photographs, shared inputs and exported images remain intact.
4. Luna geometry implements bounded output-coordinate-to-source coverage tracing
   and the viewer's optional collapsed diagnostic mode. Show geometric coverage
   and neighbor diagnostics without claiming exact blend-weight contribution.
   Preserve normal pan/zoom and PNG/TIFF/JXL preview provenance checks.
5. Luna UI integrates the record/context into the viewer and keeps EN/ZH copy.
   Codex independently reviews persistence, migration, deletion and coordinate
   inversion; run reproducible unit/widget tests, normal Windows Release and
   source-built Android Release after performance measurements finish.

Ownership: TaskRepository/task_record_service and their tests are renderer-owned;
exported_image_viewer/output_source_locator and their tests are geometry-owned;
main/l10n remain UI-owned. Codex owns this plan, evidence and serial qualification.
