import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "benchmark-dwarf-render.py"
SPEC = importlib.util.spec_from_file_location("benchmark_dwarf_render", SCRIPT)
benchmark = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(benchmark)


def receipt(pixel_hash="same-pixels", width=2048):
    return {
        "schemaVersion": 1,
        "benchmark": "spherical-layout-render-pyramid-lossless-tiff",
        "layoutSha256": "layout-hash",
        "outputGeometry": {"width": width, "height": 1024, "tileSize": 512},
        "workersRequested": 4,
        "memoryBudgetMiB": 512,
        "endpoint": "complete-level0-render+pyramid+uncompressed-lossless-RGBA8-BigTIFF-or-TIFF",
        "pixelComparison": {"level0RgbaPixelsSha256": pixel_hash, "level0TileCount": 4},
        "phaseTimesMs": {"render": 12, "pyramid": 34, "losslessTiff": 56, "total": 102},
    }


class BenchmarkDwarfRenderTests(unittest.TestCase):
    def test_run_validation_rejects_invalid_worker_budget_and_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / "benchmark.exe"
            layout = root / "layout.json"
            binary.write_bytes(b"binary")
            layout.write_text("{}", encoding="utf-8")
            output = root / "out"
            with self.assertRaisesRegex(ValueError, "workers"):
                benchmark.validate_run_args(binary, layout, output, 33, 512)
            with self.assertRaisesRegex(ValueError, "memoryBudgetMiB"):
                benchmark.validate_run_args(binary, layout, output, 4, 31)
            with self.assertRaisesRegex(ValueError, "binary"):
                benchmark.validate_run_args(root / "missing", layout, output, 4, 512)

    def test_failed_run_preserves_fresh_output_and_failure_log(self):
        class FakeProcess:
            pid = 4321

            def __init__(self, command, stdout, stderr):
                stdout.write("intentional benchmark failure\n")

            def poll(self):
                return 17

            def wait(self):
                return 17

        fake_psutil = SimpleNamespace(
            __version__="test-double",
            Process=lambda _pid: SimpleNamespace(
                cpu_percent=lambda _interval=None: 0.0,
                memory_info=lambda: SimpleNamespace(rss=1234),
                cpu_times=lambda: SimpleNamespace(user=1.0, system=0.5),
                num_threads=lambda: 2,
            ),
            virtual_memory=lambda: SimpleNamespace(total=16_000, available=8_000),
            cpu_count=lambda logical=True: 8,
        )
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / "benchmark.exe"
            layout = root / "layout.json"
            binary.write_bytes(b"benchmark-binary")
            layout.write_text('{"width":1,"height":1}', encoding="utf-8")
            output_root = root / "runs"
            with (
                patch.object(benchmark, "_process_sampler_module", return_value=fake_psutil),
                patch.object(benchmark.subprocess, "Popen", side_effect=FakeProcess),
                patch.object(benchmark.platform, "platform", return_value="test-platform"),
                patch.object(benchmark.platform, "machine", return_value="test-machine"),
                patch.object(benchmark.platform, "processor", return_value="test-cpu"),
            ):
                return_code, summary_path = benchmark.run_benchmark(
                    binary, layout, output_root, 4, 512, "failed", 0.01
                )
            self.assertEqual(return_code, 17)
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            run_dir = Path(summary["outputDirectory"])
            self.assertTrue(run_dir.is_dir())
            self.assertIn("intentional benchmark failure", Path(summary["logPath"]).read_text(encoding="utf-8"))
            self.assertEqual(summary["exitCode"], 17)
            self.assertIsNone(summary["receipt"])

    def test_compare_requires_same_layout_geometry_workers_budget_and_endpoint(self):
        with tempfile.TemporaryDirectory() as temp:
            first = Path(temp) / "first.json"
            second = Path(temp) / "second.json"
            first.write_text(json.dumps(receipt()), encoding="utf-8")
            second.write_text(json.dumps(receipt()), encoding="utf-8")
            result = benchmark.compare_receipts(first, second)
            self.assertTrue(result["level0PixelsIdentical"])
            self.assertEqual(result["elapsedMs"]["losslessTiff"], {"first": 56, "second": 56})
            second.write_text(json.dumps(receipt(width=4096)), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "outputGeometry"):
                benchmark.compare_receipts(first, second)

    def test_compare_reports_pixel_difference_without_mislabeling_as_comparable(self):
        with tempfile.TemporaryDirectory() as temp:
            first = Path(temp) / "first.json"
            second = Path(temp) / "second.json"
            first.write_text(json.dumps(receipt("pixel-a")), encoding="utf-8")
            second.write_text(json.dumps(receipt("pixel-b")), encoding="utf-8")
            result = benchmark.compare_receipts(first, second)
            self.assertFalse(result["level0PixelsIdentical"])

    def test_compare_allows_only_explicit_memory_budget_change(self):
        with tempfile.TemporaryDirectory() as temp:
            first = Path(temp) / "first.json"
            second = Path(temp) / "second.json"
            first.write_text(json.dumps(receipt()), encoding="utf-8")
            higher_budget = receipt()
            higher_budget["memoryBudgetMiB"] = 32_768
            second.write_text(json.dumps(higher_budget), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "memoryBudgetMiB"):
                benchmark.compare_receipts(first, second)
            comparison = benchmark.compare_receipts(first, second, allow_budget_change=True)
            self.assertEqual(comparison["budgetComparison"], "intentional-memory-budget-change-only")
            self.assertEqual(comparison["memoryBudgetsMiB"], [512, 32_768])

    def test_compare_rejects_receipts_without_actual_pixel_fingerprints(self):
        with tempfile.TemporaryDirectory() as temp:
            first = Path(temp) / "first.json"
            second = Path(temp) / "second.json"
            missing_pixel_receipt = receipt()
            missing_pixel_receipt["pixelComparison"]["level0RgbaPixelsSha256"] = None
            first.write_text(json.dumps(missing_pixel_receipt), encoding="utf-8")
            second.write_text(json.dumps(receipt()), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "fingerprints"):
                benchmark.compare_receipts(first, second)


if __name__ == "__main__":
    unittest.main()
