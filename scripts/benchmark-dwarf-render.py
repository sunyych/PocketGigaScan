#!/usr/bin/env python3
"""Run and compare controlled full-resolution DWARF layout render benchmarks."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time
from typing import Any
import uuid


MAX_WORKERS = 32
MAX_JOB_MEMORY_MIB = 128 * 1024
MIN_BENCHMARK_MEMORY_MIB = 32


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_run_args(binary: Path, layout: Path, output_root: Path, workers: int, budget_mib: int) -> None:
    if not binary.is_file():
        raise ValueError(f"benchmark binary does not exist: {binary}")
    if not layout.is_file():
        raise ValueError(f"layout file does not exist: {layout}")
    if not 1 <= workers <= MAX_WORKERS:
        raise ValueError(f"workers must be 1..={MAX_WORKERS}")
    if not MIN_BENCHMARK_MEMORY_MIB <= budget_mib <= MAX_JOB_MEMORY_MIB:
        raise ValueError(f"memoryBudgetMiB must be {MIN_BENCHMARK_MEMORY_MIB}..={MAX_JOB_MEMORY_MIB}")
    if output_root.exists() and not output_root.is_dir():
        raise ValueError("output root must be a directory")


def _read_receipt(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("benchmark") != "spherical-layout-render-pyramid-lossless-tiff":
        raise ValueError(f"not a spherical layout benchmark receipt: {path}")
    return value


def compare_receipts(
    first_path: Path, second_path: Path, allow_budget_change: bool = False
) -> dict[str, Any]:
    first = _read_receipt(first_path)
    second = _read_receipt(second_path)
    identity_fields = (
        "layoutSha256",
        "outputGeometry",
        "workersRequested",
        "endpoint",
    )
    mismatches = [field for field in identity_fields if first.get(field) != second.get(field)]
    if not allow_budget_change and first.get("memoryBudgetMiB") != second.get("memoryBudgetMiB"):
        mismatches.append("memoryBudgetMiB")
    if mismatches:
        raise ValueError("benchmark runs do not share controlled inputs/settings: " + ", ".join(mismatches))
    first_pixel_hash = first.get("pixelComparison", {}).get("level0RgbaPixelsSha256")
    second_pixel_hash = second.get("pixelComparison", {}).get("level0RgbaPixelsSha256")
    first_pixel_count = first.get("pixelComparison", {}).get("level0TileCount")
    second_pixel_count = second.get("pixelComparison", {}).get("level0TileCount")
    if not all(isinstance(value, str) and value for value in (first_pixel_hash, second_pixel_hash)):
        raise ValueError("both receipts must include non-empty decoded-pixel fingerprints")
    if not all(isinstance(value, int) and value > 0 for value in (first_pixel_count, second_pixel_count)):
        raise ValueError("both receipts must include a positive level-zero tile count")
    if first_pixel_count != second_pixel_count:
        raise ValueError("benchmark runs contain different level-zero tile counts")
    first_times = first.get("phaseTimesMs", {})
    second_times = second.get("phaseTimesMs", {})
    def host_metrics(receipt_path: Path) -> dict[str, Any] | None:
        summary_path = receipt_path.parent.parent / "host-benchmark.json"
        if not summary_path.is_file():
            return None
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        measurement = summary.get("measurement", {})
        return {
            "wallSeconds": measurement.get("wallSeconds"),
            "processCpuSeconds": measurement.get("processCpuSeconds"),
            "averageProcessCpuPercentOfOneLogicalCpu": measurement.get(
                "averageProcessCpuPercentOfOneLogicalCpu"
            ),
            "peakSampledRssBytes": measurement.get("peakSampledRssBytes"),
            "averageSampledThreadCount": measurement.get("averageSampledThreadCount"),
            "peakSampledThreadCount": measurement.get("peakSampledThreadCount"),
            "averageSampledProcessCpuPercent": measurement.get("averageSampledProcessCpuPercent"),
            "host": summary.get("host"),
        }
    return {
        "schemaVersion": 1,
        "comparison": "identical-layout-workers-and-render-pyramid-lossless-tiff-endpoint",
        "layoutSha256": first["layoutSha256"],
        "outputGeometry": first["outputGeometry"],
        "workersRequested": first["workersRequested"],
        "memoryBudgetsMiB": [first.get("memoryBudgetMiB"), second.get("memoryBudgetMiB")],
        "budgetComparison": "intentional-memory-budget-change-only" if allow_budget_change and first.get("memoryBudgetMiB") != second.get("memoryBudgetMiB") else "same-budget",
        "level0PixelsIdentical": first_pixel_hash == second_pixel_hash,
        "pixelComparison": "decoded level-zero RGBA8 tile pixels with exact coordinates and dimensions",
        "runs": [str(first_path), str(second_path)],
        "elapsedMs": {
            phase: {"first": first_times.get(phase), "second": second_times.get(phase)}
            for phase in ("render", "pyramid", "losslessTiff", "total")
        },
        "hostMeasurements": {
            "first": host_metrics(first_path),
            "second": host_metrics(second_path),
            "caveat": "host load and available memory can vary; peak RSS and process CPU are sampled for each benchmark child",
        },
    }


def _process_sampler_module():
    try:
        import psutil  # type: ignore[import-not-found]
    except ImportError as error:
        raise RuntimeError("benchmark runner needs psutil; install it with `python -m pip install psutil`") from error
    return psutil


def run_benchmark(
    binary: Path,
    layout: Path,
    output_root: Path,
    workers: int,
    budget_mib: int,
    label: str,
    sample_interval_seconds: float = 0.25,
) -> tuple[int, Path]:
    validate_run_args(binary, layout, output_root, workers, budget_mib)
    psutil = _process_sampler_module()
    output_root.mkdir(parents=True, exist_ok=True)
    run_dir = output_root / f"{label}-{time.strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:8]}"
    run_dir.mkdir()
    render_output_dir = run_dir / "render-output"
    log_path = run_dir / "benchmark-output.log"
    summary_path = run_dir / "host-benchmark.json"
    command = [str(binary.resolve()), str(layout.resolve()), str(render_output_dir.resolve()), str(workers), str(budget_mib)]
    started = time.monotonic()
    samples: list[tuple[int, int, float]] = []
    return_code = -1
    sampler_error: str | None = None
    last_process_cpu_seconds = 0.0
    memory_at_start = psutil.virtual_memory()
    with log_path.open("w", encoding="utf-8", errors="replace") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        process_info = psutil.Process(process.pid)
        try:
            process_info.cpu_percent(None)
        except Exception as error:  # process can exit before the first sample
            sampler_error = str(error)
        while process.poll() is None:
            try:
                rss = int(process_info.memory_info().rss)
                cpu = process_info.cpu_times()
                last_process_cpu_seconds = float(cpu.user + cpu.system)
                threads = int(process_info.num_threads())
                cpu_percent = float(process_info.cpu_percent(None))
                samples.append((rss, threads, cpu_percent))
            except Exception as error:
                sampler_error = str(error)
            time.sleep(max(0.01, sample_interval_seconds))
        return_code = process.wait()
        try:
            rss = int(process_info.memory_info().rss)
            cpu = process_info.cpu_times()
            threads = int(process_info.num_threads())
            samples.append((rss, threads, 0.0))
        except Exception as error:
            sampler_error = str(error)
        process_cpu_seconds = last_process_cpu_seconds
    elapsed_seconds = max(time.monotonic() - started, 1e-9)
    receipt_path = render_output_dir / "benchmark-receipt.json"
    receipt = _read_receipt(receipt_path) if receipt_path.exists() else None
    logical_cpus = psutil.cpu_count(logical=True) or os.cpu_count() or 1
    summary = {
        "schemaVersion": 1,
        "exitCode": return_code,
        "command": command,
        "binaryPath": str(binary.resolve()),
        "binarySha256": sha256_file(binary),
        "layoutPath": str(layout.resolve()),
        "layoutSha256": sha256_file(layout),
        "outputDirectory": str(run_dir.resolve()),
        "renderOutputDirectory": str(render_output_dir.resolve()),
        "receiptPath": str(receipt_path.resolve()) if receipt else None,
        "label": label,
        "settings": {"workers": workers, "memoryBudgetMiB": budget_mib},
        "host": {
            "system": platform.platform(),
            "machine": platform.machine(),
            "processor": platform.processor(),
            "logicalCpuCount": logical_cpus,
            "totalMemoryBytes": int(memory_at_start.total),
            "availableMemoryBytesAtStart": int(memory_at_start.available),
            "psutilVersion": getattr(psutil, "__version__", "unknown"),
        },
        "measurement": {
            "wallSeconds": elapsed_seconds,
            "processCpuSeconds": process_cpu_seconds,
            "averageProcessCpuPercentOfOneLogicalCpu": process_cpu_seconds / elapsed_seconds * 100.0,
            "peakSampledRssBytes": max((sample[0] for sample in samples), default=0),
            "averageSampledThreadCount": sum(sample[1] for sample in samples) / len(samples) if samples else 0,
            "peakSampledThreadCount": max((sample[1] for sample in samples), default=0),
            "averageSampledProcessCpuPercent": sum(sample[2] for sample in samples) / len(samples) if samples else 0,
            "sampleCount": len(samples),
            "sampleIntervalSeconds": sample_interval_seconds,
            "samplerError": sampler_error,
            "concurrentProcessCaveat": "other host processes may affect available-memory readings and system load; process RSS/CPU are sampled for this child only",
        },
        "receipt": receipt,
        "logPath": str(log_path.resolve()),
    }
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return return_code, summary_path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="run render, pyramid, and lossless TIFF into a fresh directory")
    run.add_argument("--binary", type=Path, required=True)
    run.add_argument("--layout", type=Path, required=True)
    run.add_argument("--output-root", type=Path, required=True)
    run.add_argument("--workers", type=int, required=True)
    run.add_argument("--memory-budget-mib", type=int, required=True)
    run.add_argument("--label", default="run")
    run.add_argument("--sample-interval-seconds", type=float, default=0.25)
    compare = commands.add_parser("compare", help="compare two controlled benchmark receipts")
    compare.add_argument("first", type=Path)
    compare.add_argument("second", type=Path)
    compare.add_argument("--output", type=Path)
    compare.add_argument("--allow-budget-change", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "run":
            if args.sample_interval_seconds <= 0:
                raise ValueError("sample interval must be positive")
            return_code, summary_path = run_benchmark(
                args.binary,
                args.layout,
                args.output_root,
                args.workers,
                args.memory_budget_mib,
                args.label,
                args.sample_interval_seconds,
            )
            print(json.dumps({"summaryPath": str(summary_path), "exitCode": return_code}))
            return return_code
        comparison = compare_receipts(args.first, args.second, args.allow_budget_change)
        serialized = json.dumps(comparison, indent=2) + "\n"
        if args.output:
            args.output.write_text(serialized, encoding="utf-8")
        else:
            print(serialized, end="")
        return 0 if comparison["level0PixelsIdentical"] else 2
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
