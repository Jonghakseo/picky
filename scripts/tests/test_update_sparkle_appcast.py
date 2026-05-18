import importlib.util
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "update-sparkle-appcast.py"
spec = importlib.util.spec_from_file_location("update_sparkle_appcast", SCRIPT_PATH)
update_sparkle_appcast = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(update_sparkle_appcast)

SPARKLE_NS = update_sparkle_appcast.SPARKLE_NS
SPARKLE = f"{{{SPARKLE_NS}}}"


class UpdateSparkleAppcastTests(unittest.TestCase):
    def update(self, path: Path, **overrides):
        args = {
            "appcast_path": path,
            "repository": "Jonghakseo/picky",
            "marketing_version": "0.7.1",
            "build_number": "992",
            "release_channel": "stable",
            "download_url": "https://github.com/Jonghakseo/picky/releases/download/0.7.1/Picky.zip",
            "ed_signature": "signature",
            "length_bytes": "123",
            "pub_date": "Fri, 15 May 2026 12:34:14 GMT",
        }
        args.update(overrides)
        update_sparkle_appcast.update_appcast(**args)

    def items(self, path: Path):
        return ET.parse(path).getroot().findall("./channel/item")

    def test_creates_stable_appcast_with_explicit_stable_channel_tag(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appcast.xml"

            self.update(path)

            items = self.items(path)
            self.assertEqual(len(items), 1)
            self.assertEqual(items[0].findtext("title"), "Picky 0.7.1")
            self.assertEqual(items[0].findtext(f"{SPARKLE}version"), "992")
            self.assertEqual(items[0].findtext(f"{SPARKLE}channel"), "stable")
            self.assertEqual(items[0].find("enclosure").attrib["url"], "https://github.com/Jonghakseo/picky/releases/download/0.7.1/Picky.zip")

    def test_beta_appcast_item_includes_beta_channel(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appcast.xml"

            self.update(path, release_channel="beta")

            item = self.items(path)[0]
            self.assertEqual(item.findtext(f"{SPARKLE}channel"), "beta")

    def test_rerun_replaces_same_build_on_same_channel(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appcast.xml"

            self.update(path, download_url="https://example.com/old.zip")
            self.update(path, download_url="https://example.com/new.zip", ed_signature="new-signature")

            items = self.items(path)
            self.assertEqual(len(items), 1)
            self.assertEqual(items[0].find("enclosure").attrib["url"], "https://example.com/new.zip")
            self.assertEqual(items[0].find("enclosure").attrib[f"{SPARKLE}edSignature"], "new-signature")

    def test_same_build_can_exist_on_stable_and_beta_channels(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appcast.xml"

            self.update(path, release_channel="stable", download_url="https://example.com/stable.zip")
            self.update(path, release_channel="beta", download_url="https://example.com/beta.zip")

            items = self.items(path)
            self.assertEqual(len(items), 2)
            channels = [item.findtext(f"{SPARKLE}channel") for item in items]
            urls = [item.find("enclosure").attrib["url"] for item in items]
            self.assertEqual(channels, ["beta", "stable"])
            self.assertEqual(urls, ["https://example.com/beta.zip", "https://example.com/stable.zip"])

    def test_existing_default_channel_items_are_migrated_to_explicit_stable(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appcast.xml"
            path.write_text(
                f"""<?xml version='1.0' encoding='utf-8'?>
<rss xmlns:sparkle=\"{SPARKLE_NS}\" version=\"2.0\">
  <channel>
    <title>Picky</title>
    <item>
      <title>Picky 0.7.0</title>
      <sparkle:version>991</sparkle:version>
    </item>
  </channel>
</rss>
""",
                encoding="utf-8",
            )

            self.update(path, release_channel="beta", build_number="992")

            items = self.items(path)
            channels = {item.findtext(f"{SPARKLE}version"): item.findtext(f"{SPARKLE}channel") for item in items}
            self.assertEqual(channels["991"], "stable")
            self.assertEqual(channels["992"], "beta")


if __name__ == "__main__":
    unittest.main()
