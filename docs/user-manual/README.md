# PocketGigaScan bilingual feature manuals

This folder contains the ReportLab source and bilingual content for the Chinese
and English PDF feature manuals. The content baseline is PocketGigaScan
`1.5.2+31`, checked on `2026-10-29`. Update the version/date when the screenshots
or descriptions are refreshed for a different app build.

## Build PDFs

Use the bundled Python runtime (not a system Python or a user-installed office
suite):

```powershell
if (-not $env:MANUAL_PYTHON) {
  $env:MANUAL_PYTHON = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
}
& $env:MANUAL_PYTHON 'docs/user-manual/build_manuals.py'
```

The script reads `manual_content.json` and requires every referenced screenshot
under `docs/user-manual/screenshots/`, plus an available English and Chinese
TrueType font. It fails before producing either PDF if a required screenshot or
font is missing. Use `POCKETGIGASCAN_ZH_FONT` and `POCKETGIGASCAN_EN_FONT` to
specify different font files. The output files are:

- `output/pdf/PocketGigaScan_Functional_Manual_ZH.pdf`
- `output/pdf/PocketGigaScan_Functional_Manual_EN.pdf`

The PDF builder checks that each manual renders from its configured cover and
chapters without exceeding a five-page overflow allowance. Each screenshot is
kept legible at up to 174 mm wide. Render every page with Poppler and inspect
the complete PDFs for clipped text, separated captions, or blank pages before
delivery.

## Reproduce capture inputs and widget screenshots

After setting `MANUAL_PYTHON` as above, create the default sparse synthetic
inputs and render the result-viewer fixture with a native DLL from a local
package:

```powershell
& $env:MANUAL_PYTHON 'docs/user-manual/generate_capture_fixtures.py' '.local/manual-capture/originals'
if (-not $env:POCKETGIGASCAN_NATIVE_LIBRARY) {
  throw 'Set POCKETGIGASCAN_NATIVE_LIBRARY to the local package lumia_gigascan_core.dll'
}
& $env:MANUAL_PYTHON 'docs/user-manual/render_capture_fixture.py' `
  --library $env:POCKETGIGASCAN_NATIVE_LIBRARY `
  --source-dir '.local/manual-capture/originals' `
  --output-dir '.local/manual-capture/native-result'
```

The generator's `--dense` option creates a separate experiment and is not the
input used for the current manual example.

On Windows, run the opt-in large-text widget capture from the Flutter app
directory:

```powershell
Push-Location 'Apps/Flutter/stitch_app'
try {
  flutter test test/large_text_visual_test.dart --dart-define=CAPTURE_LARGE_TEXT_QA=true
} finally {
  Pop-Location
}
```

The opt-in test is skipped by default. It reads the local Windows SimHei font
and Flutter SDK MaterialIcons font; regular Flutter tests do not require local
manual capture fixtures. The test renders real Flutter widgets with synthetic
inputs, not the installed application's GUI. It writes the full QA matrix to
`.local/manual-capture/qa-widget` and selected 150% desktop manual pages with
final names under `docs/user-manual/screenshots`. Review those images before
building or accepting the manuals. The result-viewer page uses a separate
native-render fixture capture and must retain its visual-review caption.

## Screenshot evidence

The paired screenshots use the `zh-` and `en-` prefixes and are rendered from
the app's real Flutter widgets with isolated synthetic fixtures. They are
widget-render evidence, not screenshots of the installed application, an
interactive GUI run or a hardware-validated build. Current references in
`manual_content.json` are:

- `01-home.png` - imported grid and main workspace
- `02-arrangement.png` - grid arrangement controls
- `03-output.png` - output format and quality controls
- `04-preview.png` - double-click source-photo preview
- `05-result.png` - native-rendered synthetic viewer example; the current
  fixture has 4 of 6 tile positions estimated from the grid and requires visual
  review, so it does not demonstrate alignment quality
- `06-queue.png` - batch queue
- `07-settings.png` - general settings
- `08-performance.png` - performance defaults
- `09-large-text.png` - text-size controls and live preview

The sample photographs are synthetic; no user photos, device serial numbers,
task names or personal filesystem paths belong in the manual. The result screen
uses a real native render/export from the synthetic sample and includes its
visual-review boundary. If that native render/export is unavailable, label the
viewer screenshot as an interface example and say that its widget fixture does
not demonstrate a stitched result.

Screenshots document widget layout and visible controls. Synthetic inputs do
not establish registration accuracy, image quality on real scenes, hardware
performance, device acceptance or field reliability. The manuals should keep
those boundaries explicit.

## Build status

The Windows Release build using `lib/main.dart` on `codex/security-cleanup`
passed on `2026-10-29`. The manuals and synthetic native-render fixture are
local documentation artifacts; they do not constitute a signed release package
or hardware acceptance. On Windows, extract the complete package and run
`PocketGigaScan.exe` with its `data` directory and DLLs retained; copying only
the EXE is insufficient.

After the PDFs and widget captures are ready, create review contact sheets and
run the PDF text/image/font/privacy checks with:

```powershell
& $env:MANUAL_PYTHON 'docs/user-manual/review_manual_artifacts.py' `
  --screenshots '.local/manual-capture/qa-widget' `
  --output '.local/manual-capture/contact-sheets'
```

The contact sheets are separate review artifacts and do not modify their
source captures. The JSON report is written beside them.
