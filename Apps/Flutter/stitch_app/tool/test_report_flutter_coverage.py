"""Small contract tests for the LCOV summarizer (stdlib only)."""

import importlib.util
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("report_flutter_coverage.py")
SPEC = importlib.util.spec_from_file_location("coverage_report", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
coverage_report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(coverage_report)


class LcovReaderTests(unittest.TestCase):
    def test_counts_only_recorded_executable_lines_and_resets_records(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory, "app")
            root.mkdir()
            (root / "lib").mkdir()
            lcov = Path(directory, "lcov.info")
            lcov.write_text(
                f"SF:{root.as_posix()}/lib/a.dart\nDA:1,3\nDA:2,0\nDA:2,9\nend_of_record\n"
                "SF:test/a_test.dart\nDA:1,8\nend_of_record\n",
                encoding="utf-8",
            )
            self.assertEqual(
                coverage_report.read_lcov(lcov, root),
                {"lib/a.dart": (2, 2)},
            )

    def test_ignores_malformed_hit_counts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lcov = Path(directory, "lcov.info")
            lcov.write_text(
                "SF:lib/a.dart\nDA:1,not-a-count\nDA:2,0\nend_of_record\n",
                encoding="utf-8",
            )
            self.assertEqual(coverage_report.read_lcov(lcov, Path.cwd()), {"lib/a.dart": (0, 1)})

    def test_rejects_an_lcov_file_without_app_executable_lines(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lcov = Path(directory, "lcov.info")
            lcov.write_text("SF:test/a_test.dart\nDA:1,1\nend_of_record\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "no executable Dart lines"):
                coverage_report.read_lcov(lcov, Path(directory))


if __name__ == "__main__":
    unittest.main()
