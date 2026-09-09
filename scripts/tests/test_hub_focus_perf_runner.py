#!/usr/bin/env python3
"""Validate the local artifact emitted by the WindowServer Hub focus gate."""

from __future__ import annotations

import argparse
import json
import math
import tempfile
import unittest
from pathlib import Path

TEST_NAME = "productionHubFocusTransitionsMeetTheLocalLatencyBudget"
EXPECTED_SAMPLE_COUNT = 7


def fail(message: str) -> None:
    raise ValueError(f"Hub focus performance report is invalid: {message}")


def require_number(value: object, path: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
        fail(f"{path} must be a finite number")
    if value < 0:
        fail(f"{path} must not be negative")
    return float(value)


def validate_report(report_path: Path, log_path: Path) -> None:
    try:
        report = json.loads(report_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"could not read JSON at {report_path}: {error}")
    if not isinstance(report, dict):
        fail("top-level value must be an object")
    if report.get("schemaVersion") != 1:
        fail("schemaVersion must be 1")
    if report.get("scenario") != "finder-to-isolated-hub-settings":
        fail("the cross-application settings scenario must execute")
    if report.get("mode") != "gate":
        fail("calibration or unknown mode cannot satisfy the pre-push gate")
    if report.get("gateStatus") != "passed":
        fail("gateStatus must be passed")

    samples = report.get("samples")
    if not isinstance(samples, list) or len(samples) != EXPECTED_SAMPLE_COUNT:
        fail(f"samples must contain exactly {EXPECTED_SAMPLE_COUNT} measured transitions")
    key_values: list[float] = []
    render_values: list[float] = []
    cpu_values: list[float] = []
    for index, sample in enumerate(samples, start=1):
        if not isinstance(sample, dict) or sample.get("transition") != index:
            fail(f"samples[{index - 1}] must name transition {index}")
        key_values.append(require_number(sample.get("keyAcquisitionMilliseconds"), f"samples[{index - 1}].keyAcquisitionMilliseconds"))
        render_values.append(require_number(sample.get("renderReadyAfterKeyMilliseconds"), f"samples[{index - 1}].renderReadyAfterKeyMilliseconds"))
        cpu_values.append(require_number(sample.get("mainThreadCPUMilliseconds"), f"samples[{index - 1}].mainThreadCPUMilliseconds"))

    summary = report.get("summary")
    if not isinstance(summary, dict):
        fail("summary must be an object")
    validate_summary(summary.get("keyAcquisition"), key_values, "summary.keyAcquisition")
    validate_summary(summary.get("renderReadyAfterKey"), render_values, "summary.renderReadyAfterKey")
    validate_summary(summary.get("totalReady"), [key + render for key, render in zip(key_values, render_values)], "summary.totalReady")
    validate_summary(summary.get("mainThreadCPU"), cpu_values, "summary.mainThreadCPU")

    threshold = report.get("threshold")
    if not isinstance(threshold, dict):
        fail("threshold must be an object")
    for field in ("keyMedianMilliseconds", "keyP95Milliseconds", "keyMaxMilliseconds", "renderP95Milliseconds"):
        require_number(threshold.get(field), f"threshold.{field}")
    for actual, limit in (
        (summary["keyAcquisition"]["medianMilliseconds"], threshold["keyMedianMilliseconds"]),
        (summary["keyAcquisition"]["p95Milliseconds"], threshold["keyP95Milliseconds"]),
        (summary["keyAcquisition"]["maxMilliseconds"], threshold["keyMaxMilliseconds"]),
        (summary["renderReadyAfterKey"]["p95Milliseconds"], threshold["renderP95Milliseconds"]),
    ):
        if actual > limit:
            fail("recorded latency exceeds its budget despite a passed status")

    negative = report.get("negativeControl")
    if not isinstance(negative, dict):
        fail("negativeControl must be an object")
    injected = require_number(negative.get("injectedDelayMilliseconds"), "negativeControl.injectedDelayMilliseconds")
    observed = require_number(negative.get("observedKeyAcquisitionMilliseconds"), "negativeControl.observedKeyAcquisitionMilliseconds")
    if injected <= threshold["keyMaxMilliseconds"] or observed <= threshold["keyMaxMilliseconds"]:
        fail("negative control must be rejected by the same latency budget")
    if observed < injected * 0.75:
        fail("negative control did not observe its injected synchronous delay")

    screenshot = report.get("screenshot")
    if not isinstance(screenshot, str) or not screenshot or Path(screenshot).name != screenshot:
        fail("screenshot must be a filename beside the JSON report")
    screenshot_path = report_path.parent / screenshot
    if not screenshot_path.is_file() or screenshot_path.stat().st_size == 0:
        fail(f"screenshot artifact is missing or empty: {screenshot_path}")
    if not screenshot_path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
        fail("screenshot artifact is not PNG data")

    try:
        log = log_path.read_text(errors="replace")
    except OSError as error:
        fail(f"could not read xcodebuild log at {log_path}: {error}")
    if TEST_NAME not in log:
        fail(f"xcodebuild log does not prove {TEST_NAME} executed")
    # Swift Testing can execute after XCTest prints 'Executed 0 tests'. Only
    # this exact test's passing record is evidence, not the legacy summary.
    matching_lines = [line.lower() for line in log.splitlines() if TEST_NAME.lower() in line.lower()]
    if not any("pass" in line for line in matching_lines):
        fail(f"xcodebuild log does not prove {TEST_NAME} passed")


def validate_summary(summary: object, values: list[float], name: str) -> None:
    if not isinstance(summary, dict):
        fail(f"{name} must be an object")
    sorted_values = sorted(values)
    expected = {
        "medianMilliseconds": sorted_values[len(sorted_values) // 2],
        "p95Milliseconds": sorted_values[math.ceil(len(sorted_values) * 0.95) - 1],
        "maxMilliseconds": sorted_values[-1],
    }
    for field, expected_value in expected.items():
        actual = require_number(summary.get(field), f"{name}.{field}")
        if not math.isclose(actual, expected_value, rel_tol=0, abs_tol=0.000_001):
            fail(f"{name}.{field} does not match the recorded samples")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--xcode-log", required=True, type=Path)
    args = parser.parse_args()
    try:
        validate_report(args.report, args.xcode_log)
    except ValueError as error:
        parser.error(str(error))


class HubFocusPerformanceRunnerTests(unittest.TestCase):
    def write_artifacts(self, directory: Path, *, gate_status: str = "passed") -> tuple[Path, Path]:
        screenshot = directory / "fixture.png"
        screenshot.write_bytes(b"\x89PNG\r\n\x1a\nfixture")
        samples = [
            {
                "transition": index,
                "keyAcquisitionMilliseconds": float(index),
                "renderReadyAfterKeyMilliseconds": float(index) / 2,
                "mainThreadCPUMilliseconds": float(index) / 2,
            }
            for index in range(1, EXPECTED_SAMPLE_COUNT + 1)
        ]
        report = {
            "schemaVersion": 1,
            "scenario": "finder-to-isolated-hub-settings",
            "mode": "gate",
            "gateStatus": gate_status,
            "samples": samples,
            "summary": {
                "keyAcquisition": {"medianMilliseconds": 4, "p95Milliseconds": 7, "maxMilliseconds": 7},
                "renderReadyAfterKey": {"medianMilliseconds": 2, "p95Milliseconds": 3.5, "maxMilliseconds": 3.5},
                "mainThreadCPU": {"medianMilliseconds": 2, "p95Milliseconds": 3.5, "maxMilliseconds": 3.5},
                "totalReady": {"medianMilliseconds": 6, "p95Milliseconds": 10.5, "maxMilliseconds": 10.5},
            },
            "threshold": {
                "keyMedianMilliseconds": 100,
                "keyP95Milliseconds": 150,
                "keyMaxMilliseconds": 250,
                "renderP95Milliseconds": 100,
            },
            "negativeControl": {
                "injectedDelayMilliseconds": 300,
                "observedKeyAcquisitionMilliseconds": 300,
            },
            "screenshot": screenshot.name,
        }
        report_path = directory / "report.json"
        report_path.write_text(json.dumps(report))
        log_path = directory / "xcodebuild.log"
        log_path.write_text(
            f"◇ Test {TEST_NAME} started\n"
            f"✔ Test {TEST_NAME} passed after 0.1 seconds\n"
        )
        return report_path, log_path

    def test_accepts_a_complete_passing_measurement(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            report, log = self.write_artifacts(Path(raw_directory))
            validate_report(report, log)

    def test_rejects_latency_over_budget_even_with_a_passed_status(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            report, log = self.write_artifacts(Path(raw_directory))
            data = json.loads(report.read_text())
            data["threshold"]["keyMedianMilliseconds"] = 1
            report.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, "exceeds its budget"):
                validate_report(report, log)

    def test_requires_the_exact_test_to_execute(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            report, log = self.write_artifacts(Path(raw_directory))
            log.write_text("Executed 0 tests. TEST SUCCEEDED")
            with self.assertRaisesRegex(ValueError, "executed"):
                validate_report(report, log)

    def test_accepts_swift_testing_after_an_empty_xctest_summary(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            report, log = self.write_artifacts(Path(raw_directory))
            log.write_text("Executed 0 tests\n" + log.read_text())
            validate_report(report, log)

    def test_rejects_a_report_that_only_calibrated_or_failed(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            report, log = self.write_artifacts(Path(raw_directory), gate_status="failed")
            with self.assertRaisesRegex(ValueError, "gateStatus"):
                validate_report(report, log)


if __name__ == "__main__":
    main()
