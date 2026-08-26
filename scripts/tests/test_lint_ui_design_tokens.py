import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "lint-ui-design-tokens.py"
spec = importlib.util.spec_from_file_location("lint_ui_design_tokens", SCRIPT_PATH)
lint_ui_design_tokens = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = lint_ui_design_tokens
spec.loader.exec_module(lint_ui_design_tokens)

FIXTURE_ROOT = Path(__file__).parent / "fixtures" / "ui-design-tokens"


class UIDesignTokenLintTests(unittest.TestCase):
    def copy_fixture(self, fixture_name: str, destination: Path) -> Path:
        target = destination / "Picky" / "HUD" / "Example.swift"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(FIXTURE_ROOT / fixture_name, target)
        return target

    def baseline_for(self, root: Path) -> Path:
        baseline = root / "baseline.json"
        lint_ui_design_tokens.write_baseline(root, baseline, "fixture", scan_roots=("Picky/HUD",))
        return baseline

    def test_legacy_entry_passes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.copy_fixture("legacy.swift", root)
            baseline = self.baseline_for(root)

            self.assertEqual(lint_ui_design_tokens.lint(root, baseline, scan_roots=("Picky/HUD",)), [])

    def test_new_raw_value_fails_with_category_and_suggestion(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.copy_fixture("legacy.swift", root)
            baseline = self.baseline_for(root)
            self.copy_fixture("new-raw.swift", root)

            failures = lint_ui_design_tokens.lint(root, baseline, scan_roots=("Picky/HUD",))

            self.assertEqual(len(failures), 1)
            self.assertIn("new raw padding", failures[0])
            self.assertIn("DS.Spacing.space1...space8", failures[0])

    def test_duplicate_occurrences_are_counted_by_ordinal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.copy_fixture("duplicate.swift", root)
            baseline = self.baseline_for(root)
            target = root / "Picky" / "HUD" / "Example.swift"
            target.write_text(target.read_text(encoding="utf-8") + "\nText(\"third\").padding(4)\n", encoding="utf-8")

            document = json.loads(baseline.read_text(encoding="utf-8"))
            self.assertEqual([entry["ordinal"] for entry in document["entries"]], [1, 2])
            self.assertEqual(len(lint_ui_design_tokens.lint(root, baseline, scan_roots=("Picky/HUD",))), 1)

    def test_moved_legacy_lines_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.copy_fixture("legacy.swift", root)
            baseline = self.baseline_for(root)
            target = root / "Picky" / "HUD" / "Example.swift"
            target.write_text("\n\n" + target.read_text(encoding="utf-8"), encoding="utf-8")

            self.assertEqual(lint_ui_design_tokens.lint(root, baseline, scan_roots=("Picky/HUD",)), [])

    def test_changed_raw_value_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.copy_fixture("legacy.swift", root)
            baseline = self.baseline_for(root)
            self.copy_fixture("changed.swift", root)

            failures = lint_ui_design_tokens.lint(root, baseline, scan_roots=("Picky/HUD",))

            self.assertEqual(len(failures), 1)
            self.assertIn("new raw cornerRadius", failures[0])

    def test_valid_component_exception_passes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.copy_fixture("valid-exception.swift", root)
            baseline = self.baseline_for(root)
            self.copy_fixture("valid-exception.swift", root)
            target = root / "Picky" / "HUD" / "Example.swift"
            target.write_text(target.read_text(encoding="utf-8").replace(".padding(4)", ".padding(5)"), encoding="utf-8")

            self.assertEqual(lint_ui_design_tokens.lint(root, baseline, scan_roots=("Picky/HUD",)), [])

    def test_empty_or_generic_exception_reason_fails(self):
        for fixture_name in ("empty-exception.swift", "generic-exception.swift"):
            with self.subTest(fixture_name=fixture_name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.copy_fixture(fixture_name, root)
                baseline = root / "baseline.json"
                lint_ui_design_tokens.write_baseline(root, baseline, "fixture", scan_roots=())

                failures = lint_ui_design_tokens.lint(root, baseline, scan_roots=("Picky/HUD",))

                self.assertEqual(len(failures), 1)
                self.assertIn("invalid design-token-exception: reason", failures[0])

    def test_semantic_token_usage_passes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.copy_fixture("semantic.swift", root)
            baseline = root / "baseline.json"
            lint_ui_design_tokens.write_baseline(root, baseline, "fixture", scan_roots=())

            self.assertEqual(lint_ui_design_tokens.lint(root, baseline, scan_roots=("Picky/HUD",)), [])


if __name__ == "__main__":
    unittest.main()
