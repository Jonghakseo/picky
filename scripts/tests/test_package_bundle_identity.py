"""Exercise packaging with a tiny signed executable, without launching Picky."""
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


@unittest.skipUnless(sys.platform == "darwin", "requires macOS codesign")
class PackageBundleIdentityTests(unittest.TestCase):
    def test_only_export_has_the_notification_identity_across_rebuilds(self):
        with tempfile.TemporaryDirectory(prefix="PickyPackageIdentity") as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in ("package-signed-app.sh", "release-version-policy.py"):
                shutil.copy2(REPO / "scripts" / name, scripts / name)
            shutil.copytree(REPO / "scripts/lib", scripts / "lib")
            (root / "agentd").mkdir()
            (root / "agentd/package.json").write_text("{}")
            shutil.copytree(REPO / "Picky.xcodeproj", root / "Picky.xcodeproj")
            source = root / "fixture.c"
            source.write_text("int main(void) { return 0; }\n")
            executable = root / "fixture"
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith("PICKY_")}
            environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
            subprocess.run(["/usr/bin/xcrun", "clang", str(source), "-o", str(executable)],
                           env=environment, check=True, capture_output=True)
            tools = root / "tools"
            tools.mkdir()
            builder = tools / "xcodebuild"
            builder.write_text('''#!/usr/bin/python3
import os, pathlib, plistlib, shutil, subprocess, sys
args = sys.argv[1:]
bundle_id = next(a.split("=", 1)[1] for a in args if a.startswith("PRODUCT_BUNDLE_IDENTIFIER="))
app = pathlib.Path(args[args.index("-derivedDataPath") + 1]) / "Build/Products/Release/Picky.app"
(app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
shutil.copy2(os.environ["FIXTURE_EXECUTABLE"], app / "Contents/MacOS/Picky")
with (app / "Contents/Info.plist").open("wb") as f:
    plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "Picky", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"}, f)
helper = app / "Contents/Helpers/FixtureHelper.app"
(helper / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
shutil.copy2(os.environ["FIXTURE_EXECUTABLE"], helper / "Contents/MacOS/FixtureHelper")
with (helper / "Contents/Info.plist").open("wb") as f:
    plistlib.dump({"CFBundleIdentifier": "org.picky.fixture.helper", "CFBundleExecutable": "FixtureHelper", "CFBundlePackageType": "APPL"}, f)
subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
''')
            builder.chmod(0o755)
            # A unique fixture ID never competes with an installed Picky app.
            bundle_id = "org.picky.fixture." + root.name.lower()
            build = root / "build"
            environment.update({
                "PATH": str(tools) + ":" + environment["PATH"],
                "FIXTURE_EXECUTABLE": str(executable),
                "PICKY_PACKAGE_BUILD_DIR": str(build),
                "PICKY_BUNDLE_ID": bundle_id,
                "PICKY_CONFIGURATION": "Release",
                "PICKY_MARKETING_VERSION": "1.0.0",
                "PICKY_CODE_SIGN_IDENTITY": "-",
                "PICKY_PACKAGE_AGENTD": "0",
                "PICKY_SKIP_NODE_BUNDLE": "1",
                "PICKY_CREATE_ZIP": "0",
                "PICKY_CLEAN": "0",
                "PICKY_SLACK_BOT_TOKEN": "",
                "PICKY_SLACK_CHANNEL_ID": "",
            })
            intermediate = build / "DerivedData/Build/Products/Release/Picky.app"
            exported = build / "export/Picky.app"
            try:
                for _ in range(2):
                    result = subprocess.run(["bash", str(scripts / "package-signed-app.sh")],
                                            env=environment, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    with (intermediate / "Contents/Info.plist").open("rb") as f:
                        intermediate_id = plistlib.load(f)["CFBundleIdentifier"]
                    self.assertNotEqual(intermediate_id, bundle_id)
                    with (exported / "Contents/Info.plist").open("rb") as f:
                        self.assertEqual(plistlib.load(f)["CFBundleIdentifier"], bundle_id)
                    helper = exported / "Contents/Helpers/FixtureHelper.app"
                    for app, expected in ((intermediate, intermediate_id), (exported, bundle_id),
                                          (helper, "org.picky.fixture.helper")):
                        signature = subprocess.run(["/usr/bin/codesign", "-dv", str(app)],
                                                   check=True, capture_output=True, text=True)
                        self.assertIn("Identifier=" + expected + "\n", signature.stderr)
                        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                                       check=True, capture_output=True)
            finally:
                subprocess.run([LSREGISTER, "-u", "-R", str(root)], capture_output=True)


if __name__ == "__main__":
    unittest.main()
