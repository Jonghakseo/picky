import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "release-version-policy.py"
spec = importlib.util.spec_from_file_location("release_version_policy", SCRIPT_PATH)
release_version_policy = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = release_version_policy
spec.loader.exec_module(release_version_policy)

ReleaseVersionPolicyError = release_version_policy.ReleaseVersionPolicyError
TagRecord = release_version_policy.TagRecord


class ReleaseVersionPolicyTests(unittest.TestCase):
    def resolve(self, **overrides):
        args = {
            "tag": "0.8.5",
            "release_channel": "stable",
            "prerelease": False,
            "allow_legacy": False,
        }
        args.update(overrides)
        return release_version_policy.resolve_release_metadata(**args)

    def test_stable_release_uses_plain_version_tag(self):
        metadata = self.resolve()

        self.assertEqual(metadata.marketingVersion, "0.8.5")
        self.assertEqual(metadata.releaseChannel, "stable")
        self.assertFalse(metadata.prerelease)
        self.assertEqual(metadata.tagPolicy, "canonical")

    def test_beta_release_uses_numbered_beta_suffix_and_numeric_marketing_version(self):
        metadata = self.resolve(
            tag="0.8.5-beta.2",
            release_channel="beta",
            prerelease=True,
        )

        self.assertEqual(metadata.marketingVersion, "0.8.5")
        self.assertEqual(metadata.releaseChannel, "beta")
        self.assertTrue(metadata.prerelease)
        self.assertEqual(metadata.tagPolicy, "canonical")

    def test_alpha_release_uses_numbered_alpha_suffix(self):
        metadata = self.resolve(
            tag="0.8.5-alpha.1",
            release_channel="alpha",
            prerelease=True,
        )

        self.assertEqual(metadata.marketingVersion, "0.8.5")
        self.assertEqual(metadata.releaseChannel, "alpha")
        self.assertTrue(metadata.prerelease)

    def test_stable_suffix_is_rejected_for_new_releases(self):
        with self.assertRaisesRegex(ReleaseVersionPolicyError, "stable releases require tag format X.Y.Z"):
            self.resolve(tag="0.8.5-stable")

    def test_plain_version_is_rejected_for_new_beta_releases(self):
        with self.assertRaisesRegex(ReleaseVersionPolicyError, "beta releases require tag format X.Y.Z-beta.N"):
            self.resolve(tag="0.8.5", release_channel="beta", prerelease=True)

    def test_release_channel_and_github_prerelease_state_must_agree(self):
        with self.assertRaisesRegex(ReleaseVersionPolicyError, "requires prerelease=false"):
            self.resolve(prerelease=True)

        with self.assertRaisesRegex(ReleaseVersionPolicyError, "requires prerelease=true"):
            self.resolve(tag="0.8.5-beta.1", release_channel="beta", prerelease=False)

    def test_tag_suffix_must_match_prerelease_channel(self):
        with self.assertRaisesRegex(ReleaseVersionPolicyError, "does not match release channel"):
            self.resolve(tag="0.8.5-alpha.1", release_channel="beta", prerelease=True)

    def test_prerelease_iteration_must_be_positive_without_leading_zeroes(self):
        for tag in ("0.8.5-beta.0", "0.8.5-beta.01", "0.8.5-beta"):
            with self.subTest(tag=tag):
                with self.assertRaises(ReleaseVersionPolicyError):
                    self.resolve(tag=tag, release_channel="beta", prerelease=True)

    def test_legacy_tags_require_explicit_opt_in(self):
        stable = self.resolve(tag="0.7.25-stable", allow_legacy=True)
        beta = self.resolve(
            tag="0.8.4",
            release_channel="beta",
            prerelease=True,
            allow_legacy=True,
        )

        self.assertEqual(stable.marketingVersion, "0.7.25-stable")
        self.assertEqual(stable.tagPolicy, "legacy")
        self.assertEqual(beta.marketingVersion, "0.8.4")
        self.assertEqual(beta.tagPolicy, "legacy")

    def test_marketing_version_accepts_numeric_bundle_versions_only(self):
        self.assertEqual(
            release_version_policy.validate_marketing_version("0.8.5"),
            "0.8.5",
        )
        self.assertEqual(
            release_version_policy.validate_marketing_version("1.0"),
            "1.0",
        )

        for version in ("0.8.5-beta.1", "0.8.5-stable", "01.2.3", "1"):
            with self.subTest(version=version):
                with self.assertRaises(ReleaseVersionPolicyError):
                    release_version_policy.validate_marketing_version(version)


class ReleaseLineageTests(unittest.TestCase):
    def check(self, tag, *records):
        release_version_policy.check_release_lineage(tag=tag, records=list(records))

    def test_stable_must_point_at_the_final_beta_commit(self):
        beta1 = TagRecord("0.9.5-beta.1", "aaa111", 100)
        beta2 = TagRecord("0.9.5-beta.2", "bbb222", 105)
        beta10 = TagRecord("0.9.5-beta.10", "ccc333", 110)

        self.check("0.9.5", beta1, beta2, beta10, TagRecord("0.9.5", "ccc333", 110))
        with self.assertRaisesRegex(ReleaseVersionPolicyError, r"0\.9\.5-beta\.10"):
            self.check("0.9.5", beta1, beta2, beta10, TagRecord("0.9.5", "ddd444", 120))

    def test_stable_without_any_beta_is_allowed(self):
        self.check("0.9.5", TagRecord("0.9.4", "aaa111", 100), TagRecord("0.9.5", "bbb222", 101))

    def test_build_number_must_exceed_older_releases_on_other_commits(self):
        older = TagRecord("0.9.4", "aaa111", 100)

        self.check("0.9.5-beta.1", older, TagRecord("0.9.5-beta.1", "bbb222", 101))
        for build_number in (100, 99):
            with self.subTest(build_number=build_number):
                with self.assertRaisesRegex(ReleaseVersionPolicyError, "not greater"):
                    self.check("0.9.5-beta.1", older, TagRecord("0.9.5-beta.1", "bbb222", build_number))

    def test_rerunning_an_old_release_ignores_newer_tags(self):
        self.check(
            "0.9.5-beta.1",
            TagRecord("0.9.5-beta.1", "aaa111", 100),
            TagRecord("0.9.5-beta.2", "bbb222", 120),
            TagRecord("0.9.6", "ccc333", 150),
        )

    def test_alpha_and_legacy_tags_are_not_ordered(self):
        self.check("0.9.5-alpha.1", TagRecord("0.9.5-alpha.1", "aaa111", 1))
        self.check("0.9.5-stable", TagRecord("0.9.5-stable", "aaa111", 1))

    def test_git_repository_tags_feed_the_same_rules(self):
        with tempfile.TemporaryDirectory() as repo:
            def git(*args):
                subprocess.run(
                    ["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com",
                     "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args],
                    check=True, capture_output=True,
                )

            git("init", "-q")
            git("commit", "-q", "--allow-empty", "-m", "one")
            git("tag", "0.9.4")
            git("commit", "-q", "--allow-empty", "-m", "two")
            git("tag", "-a", "0.9.5-beta.1", "-m", "beta")
            git("commit", "-q", "--allow-empty", "-m", "three")
            git("tag", "0.9.5")

            records = {record.tag: record for record in release_version_policy.collect_tag_records(repo)}
            self.assertEqual(records["0.9.5-beta.1"].build_number, 2)
            self.assertEqual(records["0.9.5"].build_number, 3)
            self.assertEqual(release_version_policy.main(["check-lineage", "--tag", "0.9.5-beta.1", "--repo", repo]), 0)
            self.assertEqual(release_version_policy.main(["check-lineage", "--tag", "0.9.5", "--repo", repo]), 2)


if __name__ == "__main__":
    unittest.main()
