"""CLI contract tests. No Xcode build, app launch, or external service is needed."""
import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from html.parser import HTMLParser
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
GALLERY = SKILL / "scripts/make-gallery.py"
RENDER = SKILL / "scripts/render-mockup.sh"
PIXEL = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/h9sAAAAASUVORK5CYII="
)


class Images(HTMLParser):
    def __init__(self):
        super().__init__()
        self.images = []

    def handle_starttag(self, tag, attrs):
        if tag == "img":
            self.images.append(dict(attrs))


class MockupToolContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "gallery"
        self.output.mkdir()
        (self.output / "fixture.png").write_bytes(PIXEL)
        self.scene = {
            "id": "fixture", "title": "검토 시안", "note": "정적 렌더",
            "file": "fixture.png", "appearance": "dark", "scale": 1,
            "width": 1, "height": 1, "pixelWidth": 1, "pixelHeight": 1,
        }

    def gallery(self, scenes=None):
        (self.output / "manifest.json").write_text(json.dumps({
            "renderer": "SwiftUI proposal", "scenes": [self.scene] if scenes is None else scenes,
        }))
        return subprocess.run([sys.executable, str(GALLERY), str(self.output)],
                              capture_output=True, text=True)

    def test_gallery_displays_logical_dimensions_not_pixel_dimensions(self):
        # A 2x raster's PNG dimensions must not become its CSS/logical size.
        self.scene.update(width=0.5, height=0.5)
        result = self.gallery()
        self.assertEqual(result.returncode, 0, result.stderr)
        images = Images()
        images.feed((self.output / "index.html").read_text())
        self.assertEqual(len(images.images), 1)
        style = dict(pair.split(":") for pair in images.images[0]["style"].split(";"))
        self.assertEqual(style["width"], "0.5px")
        self.assertEqual(style["height"], "0.5px")

    def test_gallery_rejects_dimensions_that_disagree_with_png(self):
        self.scene["pixelWidth"] = 2
        self.assertNotEqual(self.gallery().returncode, 0)
        self.assertFalse((self.output / "index.html").exists())

    def test_gallery_rejects_files_outside_output_directory(self):
        (self.root / "outside.png").write_bytes(PIXEL)
        self.scene["file"] = "../outside.png"
        self.assertNotEqual(self.gallery().returncode, 0)
        self.assertFalse((self.output / "index.html").exists())

    def test_gallery_rejects_empty_or_duplicate_scenes(self):
        for scenes in [[], [self.scene, self.scene]]:
            with self.subTest(scenes=scenes):
                self.assertNotEqual(self.gallery(scenes).returncode, 0)
                self.assertFalse((self.output / "index.html").exists())

    def test_scene_copy_is_escaped_in_generated_html(self):
        self.scene["title"] = '<script>alert("fixture")</script>'
        self.assertEqual(self.gallery().returncode, 0)
        page = (self.output / "index.html").read_text()
        self.assertNotIn(self.scene["title"], page)
        self.assertIn("&lt;script&gt;", page)

    def test_missing_swift_source_fails_before_creating_output(self):
        output = self.root / "never-created"
        result = subprocess.run(["bash", str(RENDER), str(self.root / "missing.swift"), str(output)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def render_with_active_build(self, same_derived_data):
        # Fake only external process discovery/toolchain, not the guard logic.
        commands = self.root / "commands"
        commands.mkdir()
        selected = self.root / "selected-DD"
        active = selected if same_derived_data else self.root / "other-DD"
        tools = {
            "pgrep": "echo 123",
            "ps": f"echo 'xcodebuild -derivedDataPath {active} build'",
            "xcodebuild": "printf 'Xcode 16.3\\nBuild version 16E140\\n'",
        }
        for name, body in tools.items():
            path = commands / name
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o755)
        source = self.root / "fixture.swift"
        source.write_text("// Guard exits before compilation")
        env = {**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"],
               "PICKY_DERIVED_DATA_PATH": str(selected)}
        return subprocess.run(["bash", str(RENDER), str(source), str(self.root / "not-created")],
                              env=env, capture_output=True, text=True)

    def test_render_refuses_debug_products_used_by_active_build(self):
        result = self.render_with_active_build(same_derived_data=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("may be writing the selected Debug products", result.stderr)
        self.assertFalse((self.root / "not-created").exists())

    def test_distinct_derived_data_does_not_block_build_product_preflight(self):
        result = self.render_with_active_build(same_derived_data=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing Debug product", result.stderr)
        self.assertFalse((self.root / "not-created").exists())


if __name__ == "__main__":
    unittest.main()
