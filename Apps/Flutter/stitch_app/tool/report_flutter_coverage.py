#!/usr/bin/env python3
"""Summarize Dart line coverage from Flutter's LCOV output."""

from __future__ import annotations

import argparse
from collections import defaultdict
from pathlib import Path


def _app_source_name(source: str, source_root: Path) -> str | None:
    source_path = Path(source)
    root = source_root.resolve()
    try:
        relative = source_path.resolve().relative_to(root) if source_path.is_absolute() else source_path
    except ValueError:
        return None
    if not relative.parts or relative.parts[0] != "lib" or relative.suffix != ".dart":
        return None
    return relative.as_posix()


def read_lcov(path: Path, source_root: Path = Path.cwd()) -> dict[str, tuple[int, int]]:
    """Return covered/valid executable line counts by source file."""
    counts: dict[str, dict[int, int]] = defaultdict(dict)
    source: str | None = None
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if raw_line.startswith("SF:"):
            source = raw_line[3:]
        elif raw_line.startswith("DA:") and source is not None:
            fields = raw_line[3:].split(",")
            if len(fields) < 2:
                continue
            try:
                line_number = int(fields[0])
                hits = int(fields[1])
            except ValueError:
                continue
            app_source = _app_source_name(source, source_root)
            if app_source is not None and line_number > 0:
                counts[app_source][line_number] = max(
                    counts[app_source].get(line_number, 0), hits
                )
        elif raw_line == "end_of_record":
            source = None
    if not counts or sum(len(lines) for lines in counts.values()) == 0:
        raise ValueError("LCOV contains no executable Dart lines under the app lib/ directory")
    return {
        name: (sum(hits > 0 for hits in lines.values()), len(lines))
        for name, lines in counts.items()
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lcov", nargs="?", type=Path, default=Path("coverage/lcov.info"))
    parser.add_argument("--minimum", type=float, help="fail if overall line coverage is below this percent")
    parser.add_argument("--summary-file", type=Path, help="write the measured summary to this file")
    args = parser.parse_args()
    if not args.lcov.is_file():
        parser.error(f"LCOV file not found: {args.lcov}")

    try:
        files = read_lcov(args.lcov)
    except (OSError, UnicodeError, ValueError) as error:
        parser.error(str(error))
    covered = sum(value[0] for value in files.values())
    total = sum(value[1] for value in files.values())
    percent = covered * 100 / total if total else 0.0
    lines = [f"Dart executable lines covered: {covered}/{total} ({percent:.2f}%)", "Per-file coverage (lowest first):"]
    for name, (hit, count) in sorted(
        files.items(), key=lambda item: (item[1][0] / item[1][1] if item[1][1] else 1, item[0])
    ):
        ratio = hit * 100 / count if count else 0.0
        lines.append(f"  {ratio:6.2f}%  {hit:5}/{count:<5} {name}")
    report = "\n".join(lines) + "\n"
    print(report, end="")
    if args.summary_file is not None:
        args.summary_file.parent.mkdir(parents=True, exist_ok=True)
        args.summary_file.write_text(report, encoding="utf-8")
    if args.minimum is not None and percent < args.minimum:
        print(f"Coverage is below the requested {args.minimum:.2f}% minimum.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
