"""Exercise the real shell entry point with a fake Xcode process, never the desktop."""

import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts/pre-push-checks.sh"
LOG_VALIDATOR = runpy.run_path(str(ROOT / "scripts/validate-ui-effect-test-log.py"))["validate_log"]


class DesktopTestRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.calls = self.directory / "calls.jsonl"
        toolchain = self.directory / "Xcode/Contents/Developer"
        swift = toolchain / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        swift.parent.mkdir(parents=True)
        swift.write_text("#!/bin/sh\necho 'Apple Swift version 6.1'\n")
        swift.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        PICKY_DEVELOPER_DIR=str(toolchain),
                        PICKY_HUB_FOCUS_PERF_REPORT_PATH=str(self.directory / "report.json"),
                        FAKE_CALLS=str(self.calls),
                        GITHUB_ACTIONS="", RUNNER_ENVIRONMENT="")
        # Fake only external executables. Selection, opt-in routing, validation,
        # shell failures and log persistence run through the production scripts.
        xcode = self.bin / "xcodebuild"
        xcode.write_text(f"#!{sys.executable}\n" + '''import json, os, pathlib, shutil, sys
with open(os.environ["FAKE_CALLS"], "a") as file:
    file.write(json.dumps({"args": sys.argv[1:], "environment": {
        key: value for key, value in os.environ.items()
        if "PICKY_PRE_PUSH_UI_EFFECT_TESTS" in key or "PICKY_UI_TEST_SESSION" in key or "PICKY_HUB_FOCUS_PERF_PROFILE" in key
    }}) + "\\n")
if os.environ.get("FAKE_XCODE_FAILURE"):
    sys.exit(int(os.environ["FAKE_XCODE_FAILURE"]))
if os.environ.get("FAKE_EMPTY_RUN"):
    print("** TEST SUCCEEDED **")
    sys.exit(0)
selectors = [arg.split("PickyTests/", 1)[1] for arg in sys.argv if arg.startswith("-only-testing:")]
if selectors:
    selector = selectors[0]
    if selector == "PickyHubFocusPerformanceTests":
        selector += "/productionHubFocusTransitionsMeetTheLocalLatencyBudget()"
        report = pathlib.Path(os.environ["TEST_RUNNER_PICKY_HUB_FOCUS_PERF_REPORT_PATH"])
        fixture = pathlib.Path(os.environ["FAKE_PERF_FIXTURE"])
        shutil.copyfile(fixture, report)
        shutil.copyfile(fixture.parent / "fixture.png", report.parent / "fixture.png")
    suite, method = selector.split("/", 1)
    print(f"✔ Test {method} passed after 0.1 seconds.")
    print(f"✔ Suite {suite} passed after 0.1 seconds.")
    print("✔ Test run with 1 test passed after 0.1 seconds.")
else:
    print("✔ Test run with 2653 tests passed after 1 second.")
''')
        xcode.chmod(0o755)
        # These commands are not the contract under test. Python validators and
        # selector discovery remain real; avoid recursively running this suite.
        python = self.bin / "python3"
        python.write_text(f"#!{sys.executable}\n" + f'''import os, sys
if len(sys.argv) > 1 and ("--ui-effect-selectors" in sys.argv or any(
    sys.argv[1].endswith(name) for name in ("validate-ui-effect-test-log.py", "test_hub_focus_perf_runner.py")
)):
    os.execv({sys.executable!r}, [{sys.executable!r}] + sys.argv[1:])
''')
        python.chmod(0o755)
        for name in ("node", "pnpm", "swiftlint"):
            command = self.bin / name
            command.write_text("#!/bin/sh\nexit 0\n")
            command.chmod(0o755)
        fixture_dir = self.directory / "fixture"
        fixture_dir.mkdir()
        fixture_test = runpy.run_path(str(ROOT / "scripts/tests/test_hub_focus_perf_runner.py"))[
            "HubFocusPerformanceRunnerTests"]()
        fixture, _ = fixture_test.write_artifacts(fixture_dir, profile="github-hosted")
        self.env["FAKE_PERF_FIXTURE"] = str(fixture)

    def run_runner(self, *args, **environment):
        return subprocess.run(["bash", str(RUNNER), *args], cwd=ROOT,
                              env=dict(self.env, **environment), input="", text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)

    def xcode_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_default_push_never_enables_ui_even_with_leaked_flags(self):
        result = self.run_runner(PICKY_PRE_PUSH_UI_EFFECT_TESTS="1", PICKY_UI_TEST_SESSION="isolated",
                                 TEST_RUNNER_PICKY_PRE_PUSH_UI_EFFECT_TESTS="1",
                                 TEST_RUNNER_PICKY_UI_TEST_SESSION="isolated",
                                 TEST_RUNNER_PICKY_HUB_FOCUS_PERF_PROFILE="github-hosted",
                                 GITHUB_ACTIONS="true", RUNNER_ENVIRONMENT="github-hosted")
        self.assertEqual(result.returncode, 0, result.stdout)
        tests = [call for call in self.xcode_calls() if "test" in call["args"]]
        self.assertEqual(len(tests), 1)
        self.assertEqual(tests[0]["environment"]["TEST_RUNNER_PICKY_PRE_PUSH_UI_EFFECT_TESTS"], "0")
        self.assertEqual(tests[0]["environment"]["TEST_RUNNER_PICKY_UI_TEST_SESSION"], "")
        self.assertEqual(tests[0]["environment"]["TEST_RUNNER_PICKY_HUB_FOCUS_PERF_PROFILE"], "")
        self.assertEqual(tests[0]["environment"]["PICKY_PRE_PUSH_UI_EFFECT_TESTS"], "0")
        self.assertFalse(any(arg.startswith("-only-testing:") for arg in tests[0]["args"]))

    def test_intrusive_modes_refuse_local_and_self_hosted_before_xcode(self):
        for mode in ("--ui-effects", "--hub-focus-perf", "--hub-focus-perf-calibrate"):
            for runner in ("", "self-hosted"):
                with self.subTest(mode=mode, runner=runner):
                    result = self.run_runner(mode, CI="true", GITHUB_ACTIONS="true", RUNNER_ENVIRONMENT=runner)
                    self.assertEqual(result.returncode, 78, result.stdout)
        self.assertEqual(self.xcode_calls(), [])

    def test_isolated_mode_executes_every_ui_contract_in_its_own_host(self):
        result = self.run_runner("--ui-effects", GITHUB_ACTIONS="true", RUNNER_ENVIRONMENT="github-hosted")
        self.assertEqual(result.returncode, 0, result.stdout)
        calls = self.xcode_calls()
        expected_suites = {
            "PickyHubFocusPerformanceTests": 1, "PickyHubNativeFocusTests": 1,
            "PickyHubWindowLifecycleTests": 2, "PickyIMETextViewTests": 1,
            "PickySecureSurfaceWindowCoordinatorTests": 1, "PickyVoiceInputTargetTests": 1,
        }
        actual = {}
        for call in calls:
            selections = [arg for arg in call["args"] if arg.startswith("-only-testing:")]
            self.assertEqual(len(selections), 1)
            suite = selections[0].split("/")[1]
            actual[suite] = actual.get(suite, 0) + 1
            self.assertEqual(call["environment"]["TEST_RUNNER_PICKY_PRE_PUSH_UI_EFFECT_TESTS"], "1")
            self.assertEqual(call["environment"]["TEST_RUNNER_PICKY_UI_TEST_SESSION"], "isolated")
            self.assertEqual(call["environment"]["TEST_RUNNER_PICKY_HUB_FOCUS_PERF_PROFILE"], "github-hosted")
        self.assertEqual(actual, expected_suites)

    def test_current_policy_discovers_contracts_from_a_separate_source_checkout(self):
        source = self.directory / "historical-source"
        tests = source / "PickyTests"
        tests.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(source)], check=True)
        for suite, method in (
            ("PickyHubFocusPerformanceTests", "productionHubFocusTransitionsMeetTheLocalLatencyBudget"),
            ("HistoricalWindowTests", "windowContract"),
        ):
            (tests / f"{suite}.swift").write_text(
                f"struct {suite} {{\n"
                "@Test(.enabled(if: PickyRuntimeEnvironment.runsPrePushUIEffectTests))\n"
                f"func {method}() {{}}\n}}\n")
        result = subprocess.run(["bash", str(RUNNER), "--ui-effects"], cwd=source,
                                env=dict(self.env, GITHUB_ACTIONS="true", RUNNER_ENVIRONMENT="github-hosted"),
                                input="", text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout)
        calls = self.xcode_calls()
        self.assertEqual(len(calls), 2)
        self.assertTrue(any("-only-testing:PickyTests/HistoricalWindowTests/windowContract()" in call["args"]
                            for call in calls))

    def test_xcode_failure_is_not_masked_by_tee_or_log_validation(self):
        result = self.run_runner("--swift-tests", FAKE_XCODE_FAILURE="65")
        self.assertEqual(result.returncode, 65, result.stdout)
        self.assertNotIn("checks passed", result.stdout)

    def test_zero_selected_ui_tests_fail_even_when_xcode_succeeds(self):
        result = self.run_runner("--ui-effects", GITHUB_ACTIONS="true", RUNNER_ENVIRONMENT="github-hosted",
                                 FAKE_EMPTY_RUN="1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.xcode_calls()), 1)

    def test_log_validator_rejects_a_skipped_or_different_contract(self):
        for log in ("Executed 0 tests. TEST SUCCEEDED", "✔ Test wanted() skipped",
                    "✔ Test other() passed\n✔ Suite Example passed\n✔ Test run with 1 test passed"):
            with self.assertRaises(ValueError):
                LOG_VALIDATOR("Example/wanted()", log)


if __name__ == "__main__":
    unittest.main()
