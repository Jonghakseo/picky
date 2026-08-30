import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "prune-build-artifacts.sh"


class PruneBuildArtifactsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.fake_lsregister = self.root / "fake-lsregister.sh"
        self.fake_lsregister.write_text(
            """#!/usr/bin/env bash
set -u
case "${1:-}" in
  -u)
    printf '%s\\n' "${FAKE_UNREGISTER_ERROR:-fake unregister failure}" >&2
    exit "${FAKE_UNREGISTER_STATUS:-1}"
    ;;
  -dump)
    printf '%s\\n' "${FAKE_LSREGISTER_DUMP:-}"
    if [[ "${FAKE_DUMP_ERROR:-}" != "" ]]; then
      printf '%s\\n' "${FAKE_DUMP_ERROR}" >&2
    fi
    exit "${FAKE_DUMP_STATUS:-0}"
    ;;
  *)
    printf 'unexpected fake lsregister arguments: %s\\n' "$*" >&2
    exit 64
    ;;
esac
""",
            encoding="utf-8",
        )
        self.fake_lsregister.chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    def make_candidate(self, name: str = "PickyFixtureDD") -> Path:
        candidate = self.root / name
        products = candidate / "Build" / "Products"
        products.mkdir(parents=True)
        (products / "artifact").write_text("fixture", encoding="utf-8")
        old = time.time() - 7_200
        os.utime(candidate, (old, old))
        return candidate

    def run_prune(self, *, registry_dump: str = "", dump_status: int = 0) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "PICKY_LSREGISTER_PATH": str(self.fake_lsregister),
                "FAKE_LSREGISTER_DUMP": registry_dump,
                "FAKE_DUMP_STATUS": str(dump_status),
            }
        )
        return subprocess.run(
            [
                str(SCRIPT_PATH),
                "--apply",
                "--keep-hours",
                "0",
                "--root",
                str(self.root),
            ],
            capture_output=True,
            text=True,
            env=environment,
            check=False,
        )

    def test_removes_directory_when_registry_dump_has_no_reference(self):
        candidate = self.make_candidate()

        result = self.run_prune()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(candidate.exists())
        self.assertIn("lsregister unregister reported failure", result.stderr)
        self.assertIn("removed 1 directories", result.stdout)

    def test_retains_directory_when_registry_dump_still_references_it(self):
        candidate = self.make_candidate()

        result = self.run_prune(registry_dump=f"bundle path: {candidate}")

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(candidate.exists())
        self.assertIn("retained because LaunchServices still references it", result.stderr)
        self.assertIn("removed 0 directories", result.stdout)

    def test_retains_all_directories_when_registry_dump_fails(self):
        candidate = self.make_candidate()

        result = self.run_prune(dump_status=1)

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(candidate.exists())
        self.assertIn("registry dump failed", result.stderr)
        self.assertIn("found 1 stale DerivedData directories", result.stdout)


if __name__ == "__main__":
    unittest.main()
