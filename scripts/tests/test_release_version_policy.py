import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "release-version-policy.py"
spec = importlib.util.spec_from_file_location("release_version_policy", SCRIPT_PATH)
release_version_policy = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = release_version_policy
spec.loader.exec_module(release_version_policy)

ReleaseVersionPolicyError = release_version_policy.ReleaseVersionPolicyError


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


if __name__ == "__main__":
    unittest.main()
