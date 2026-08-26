#!/usr/bin/env python3
"""Fail closed when default Swift tests can affect the logged-in macOS session."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI_EFFECT_GATE = "@Test(.enabled(if: PickyRuntimeEnvironment.runsPrePushUIEffectTests))"
UI_EFFECT_TESTS = {
    ("PickyTests/PickyBubbleTableCellTests.swift", "clickingACodeCellKeepsItsMonospacedRun"),
    ("PickyTests/PickyBubbleTableCellTests.swift", "clickingABoldCellKeepsItsWeight"),
    ("PickyTests/PickyIMETextViewTests.swift", "responderActionsUndoAndRedoTheFocusedEditorsPrivateHistory"),
    ("PickyTests/PickyVoiceInputTargetTests.swift", "appKitRegionExcludesOrderedOutHiddenAndIneligibleCards"),
    ("PickyTests/PickySecureSurfaceWindowCoordinatorTests.swift", "secureSuppressionAndRestorationUpdateTheHUDActualVisibilityStore"),
}
UI_EFFECT_HELPERS = {
    ("PickyTests/PickyBubbleTableCellTests.swift", "fieldEditorAttributes"),
}
UI_EFFECT_CALLERS = {
    ("PickyTests/PickyIMETextViewTests.swift", "responderActionsUndoAndRedoTheFocusedEditorsPrivateHistory"),
    ("PickyTests/PickyVoiceInputTargetTests.swift", "appKitRegionExcludesOrderedOutHiddenAndIneligibleCards"),
    ("PickyTests/PickySecureSurfaceWindowCoordinatorTests.swift", "secureSuppressionAndRestorationUpdateTheHUDActualVisibilityStore"),
} | UI_EFFECT_HELPERS
UI_EFFECT_CALL = re.compile(
    r"\.(?:makeKeyAndOrderFront|orderFrontRegardless|orderFront|makeKey)\s*\(|"
    r"\b(?:window|panel|hud)\.isVisible\s*=\s*true|"
    r"\bNSApp\.activate\s*\(|"
    r"\bNSApplication\.shared\.activate\s*\("
)
FORBIDDEN_TEST_BOUNDARY_CALL = re.compile(
    r"\bSecItem(?:Add|CopyMatching|Delete|Update)\s*\(|"
    r"\bAVAudioEngine\s*\(|"
    r"\bAVCaptureDevice\.requestAccess\s*\(|"
    r"\bSFSpeechRecognizer\.requestAuthorization\s*\(|"
    r"\bCGEvent\.tapCreate\s*\(|"
    r"\bNSEvent\.add(?:Local|Global)MonitorForEvents\s*\(|"
    r"\bUserDefaults\.standard\.(?:set|removeObject|removePersistentDomain|register)\s*\("
)
EVENT_MONITOR_INSTALL_CALL = re.compile(
    r"\bCGEvent\.tapCreate\s*\(|"
    r"\bNSEvent\.add(?:Local|Global)MonitorForEvents\s*\("
)
FUNCTION_DECLARATION = re.compile(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")

REQUIRED_BOUNDARY_SNIPPETS = {
    "Picky/PickyAdvancedContext.swift": {
        "PickyRuntimeEnvironment.allowsUserEnvironmentEffects && AXIsProcessTrusted()": 1,
        "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return false }": 1,
        "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return nil }": 1,
    },
    "Picky/Context/AccessibilityBrowserContextProvider.swift": {
        "PickyRuntimeEnvironment.allowsUserEnvironmentEffects && AXIsProcessTrusted()": 1,
    },
    "Picky/Context/PickyAnnotationSceneMonitor.swift": {
        "window: PickyRuntimeEnvironment.allowsUserEnvironmentEffects": 1,
    },
    "Picky/Sessions/PickyGitRepositoryStatus.swift": {
        "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }": 1,
    },
    "Picky/Sessions/PickyGitHubPullRequestStatus.swift": {
        "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }": 2,
    },
}

REQUIRED_GUARDS = {
    "Picky/Context/PickyAppSupport.swift": "unit-tests.\\(ProcessInfo.processInfo.processIdentifier)",
    "Picky/QuickInput/QuickInputPanelManager.swift": "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else {",
    "Picky/App/MenuBarPanelManager.swift": "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }",
    "Picky/CompanionManager.swift": "if PickyRuntimeEnvironment.allowsUserEnvironmentEffects {",
    "Picky/Companion/Dictation/GlobalPushToTalkShortcutMonitor.swift": "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }",
    "Picky/Companion/Onboarding/OnboardingFlowController.swift": "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }",
    "Picky/BuddyDictationManager.swift": "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return false }",
    "Picky/Shortcuts/ShortcutCaptureRecorder.swift": "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }",
    "Picky/HUD/Conversation/PickyConversationComposerView.swift": "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }",
    "Picky/HUD/PickyHUDDockGroupListView.swift": "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }",
    "Picky/HUD/PickyHUDDockReorderDragController.swift": "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }",
    "Picky/HUD/PickyHUDOverlayManager.swift": "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }",
    "Picky/HUD/PickyHUDView.swift": "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }",
    "Picky/Overlay/PickyInkCaptureController.swift": "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return false }",
    "Picky/Context/PickyAnnotationSceneMonitor.swift": "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }",
    "Picky/Context/PickySystemPermissionGateway.swift": "guard isRunningUnitTests() else { return }",
    "Picky/Localization/LocaleManager.swift": "if PickyRuntimeEnvironment.allowsUserEnvironmentEffects {",
    "Picky/App/WindowPositionManager.swift": "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return false }",
    "Picky/Companion/AzureOpenAI/AzureOpenAIKeychainStore.swift": "guard allowsKeychainAccess else { return nil }",
    "Picky/PickyApp.swift": "PickyRuntimeEnvironment.resetUnitTestUserDefaults()",
}


def fail(message: str) -> None:
    print(f"❌ test environment isolation: {message}", file=sys.stderr)
    raise SystemExit(1)


def test_functions(source: str) -> dict[str, bool]:
    functions: dict[str, bool] = {}
    pending_gate = False
    for line in source.splitlines():
        stripped = line.strip()
        if stripped == UI_EFFECT_GATE:
            pending_gate = True
            continue
        match = FUNCTION_DECLARATION.search(line)
        if match:
            functions[match.group(1)] = pending_gate
            pending_gate = False
        elif stripped and not stripped.startswith("@"):
            pending_gate = False
    return functions


def validate_ui_effect_tests() -> None:
    observed_effect_callers: set[tuple[str, str]] = set()
    observed_gated_tests: set[tuple[str, str]] = set()

    for path in sorted((ROOT / "PickyTests").glob("*.swift")):
        relative = path.relative_to(ROOT).as_posix()
        source = path.read_text()
        functions = test_functions(source)
        current_function: str | None = None
        for line_number, line in enumerate(source.splitlines(), start=1):
            match = FUNCTION_DECLARATION.search(line)
            if match:
                current_function = match.group(1)
            if not UI_EFFECT_CALL.search(line):
                continue
            if current_function is None:
                fail(f"{relative}:{line_number} UI-effect call is outside a test function")
            key = (relative, current_function)
            observed_effect_callers.add(key)
            if key not in UI_EFFECT_CALLERS:
                fail(f"{relative}:{line_number} {current_function} is not in the UI-effect caller allowlist")
            if key not in UI_EFFECT_HELPERS and not functions.get(current_function, False):
                fail(f"{relative}:{line_number} {current_function} lacks the pre-push-only Swift Testing gate")

        for function, is_gated in functions.items():
            if is_gated:
                observed_gated_tests.add((relative, function))

    if observed_effect_callers != UI_EFFECT_CALLERS:
        missing = sorted(UI_EFFECT_CALLERS - observed_effect_callers)
        extra = sorted(observed_effect_callers - UI_EFFECT_CALLERS)
        fail(f"UI-effect caller allowlist drifted, missing={missing}, extra={extra}")
    if observed_gated_tests != UI_EFFECT_TESTS:
        missing = sorted(UI_EFFECT_TESTS - observed_gated_tests)
        extra = sorted(observed_gated_tests - UI_EFFECT_TESTS)
        fail(f"pre-push UI-effect gates drifted, missing={missing}, extra={extra}")

    bubble_source = (ROOT / "PickyTests/PickyBubbleTableCellTests.swift").read_text()
    bubble_functions = test_functions(bubble_source)
    current_function: str | None = None
    for line_number, line in enumerate(bubble_source.splitlines(), start=1):
        match = FUNCTION_DECLARATION.search(line)
        if match:
            current_function = match.group(1)
        if "fieldEditorAttributes(for:" not in line or current_function == "fieldEditorAttributes":
            continue
        if current_function is None or not bubble_functions.get(current_function, False):
            fail(f"PickyTests/PickyBubbleTableCellTests.swift:{line_number} field-editor helper caller is not pre-push gated")


def validate_test_boundary_calls() -> None:
    for path in sorted((ROOT / "PickyTests").rglob("*.swift")):
        relative = path.relative_to(ROOT).as_posix()
        for line_number, line in enumerate(path.read_text().splitlines(), start=1):
            if FORBIDDEN_TEST_BOUNDARY_CALL.search(line):
                fail(f"{relative}:{line_number} directly reaches a user-environment boundary")


def validate_runtime_guards() -> None:
    for relative, required_snippet in REQUIRED_GUARDS.items():
        source = (ROOT / relative).read_text()
        if required_snippet not in source:
            fail(f"{relative} lost required guard: {required_snippet}")

    for relative, required_snippets in REQUIRED_BOUNDARY_SNIPPETS.items():
        source = (ROOT / relative).read_text()
        for required_snippet, minimum_count in required_snippets.items():
            if source.count(required_snippet) < minimum_count:
                fail(
                    f"{relative} lost boundary guard: {required_snippet} "
                    f"(expected at least {minimum_count})"
                )

    buddy_source = (ROOT / "Picky/BuddyDictationManager.swift").read_text()
    for required_snippet in (
        "private lazy var audioEngine = AVAudioEngine()",
        "private func stopAudioEngineAndRemoveInputTap()",
        "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }",
    ):
        if required_snippet not in buddy_source:
            fail(f"Picky/BuddyDictationManager.swift lost audio isolation guard: {required_snippet}")

    standard_defaults_callers: list[str] = []
    unguarded_monitor_installers: list[str] = []
    for path in sorted((ROOT / "Picky").rglob("*.swift")):
        relative = path.relative_to(ROOT).as_posix()
        lines = path.read_text().splitlines()
        if relative != "Picky/Context/PickyAppSupport.swift":
            for line_number, line in enumerate(lines, start=1):
                if "UserDefaults.standard" in line or "UserDefaults = .standard" in line:
                    standard_defaults_callers.append(f"{relative}:{line_number}")
                if "@AppStorage" in line and "store:" not in "\n".join(lines[line_number - 1:line_number + 3]):
                    standard_defaults_callers.append(f"{relative}:{line_number} (@AppStorage without isolated store)")

        for index, line in enumerate(lines):
            if line.lstrip().startswith("//") or not EVENT_MONITOR_INSTALL_CALL.search(line):
                continue
            function_start = next(
                (candidate for candidate in range(index, -1, -1) if FUNCTION_DECLARATION.search(lines[candidate])),
                None,
            )
            if function_start is None:
                unguarded_monitor_installers.append(f"{relative}:{index + 1} (outside a function)")
                continue
            enclosing_function_region = "\n".join(lines[function_start:index])
            if "guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else" not in enclosing_function_region:
                function_name = FUNCTION_DECLARATION.search(lines[function_start]).group(1)
                unguarded_monitor_installers.append(f"{relative}:{index + 1} ({function_name})")

    if standard_defaults_callers:
        fail(f"production UserDefaults.standard bypasses isolated routing: {standard_defaults_callers}")
    if unguarded_monitor_installers:
        fail(f"event monitor installers lack fail-closed runtime guards: {unguarded_monitor_installers}")


def validate_pre_push_gate() -> None:
    pre_push_path = ROOT / "scripts/pre-push-checks.sh"
    pre_push = pre_push_path.read_text()
    assignment = "PICKY_PRE_PUSH_UI_EFFECT_TESTS=1"
    if pre_push.count(assignment) != 1:
        fail(f"pre-push must opt into UI-effect tests exactly once with {assignment}")

    swift_test_commands = [
        line for line in pre_push.splitlines()
        if "xcodebuild" in line and re.search(r"\btest\b", line)
    ]
    if len(swift_test_commands) != 1 or assignment not in swift_test_commands[0]:
        fail("pre-push must run exactly one Swift test command and attach the UI-effect opt-in to it")

    for shell_script in sorted((ROOT / "scripts").rglob("*.sh")):
        if shell_script == pre_push_path:
            continue
        if assignment in shell_script.read_text():
            fail(f"{shell_script.relative_to(ROOT)} must not opt into UI-effect tests")

    scheme = (ROOT / "Picky.xcodeproj/xcshareddata/xcschemes/Picky.xcscheme").read_text()
    test_action = scheme.split("<TestAction", 1)[1].split("</TestAction>", 1)[0]
    if "PickyUITests" in test_action:
        fail("PickyUITests must stay excluded from the shared default TestAction")


def main() -> None:
    validate_ui_effect_tests()
    validate_test_boundary_calls()
    validate_runtime_guards()
    validate_pre_push_gate()
    print("✅ test environment isolation guard passed")


if __name__ == "__main__":
    main()
