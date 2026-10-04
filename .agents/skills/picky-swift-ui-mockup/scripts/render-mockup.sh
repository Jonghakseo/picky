#!/usr/bin/env bash
# Render a reviewed Swift proposal against this checkout's existing Debug module.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <swift-source> <output-directory>" >&2
  exit 2
fi
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 127; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SOURCE="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$1")"
OUT="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$2")"
DD="${PICKY_DERIVED_DATA_PATH:-/private/tmp/PickyAgentDD}"
PRODUCTS="$DD/Build/Products/Debug"
APP="$PRODUCTS/Picky.app"
BINARY="$APP/Contents/MacOS/Picky.debug.dylib"
MODULE="$PRODUCTS/Picky.swiftmodule/$(uname -m)-apple-macos.swiftmodule"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

fail() { echo "mockup render: $*" >&2; exit 1; }
[ -f "$SOURCE" ] || fail "Swift source not found: $SOURCE"
# A known, different DerivedData cannot mutate these products. Unknown paths
# remain fail-closed; this harness never starts another xcodebuild.
python3 - "$DD" <<'PY_BUILD_GUARD'
import pathlib,re,subprocess,sys
selected=pathlib.Path(sys.argv[1]).resolve()
pids=subprocess.run(['pgrep','-x','xcodebuild'],capture_output=True,text=True)
if pids.returncode not in (0,1):
    raise SystemExit('Could not check active Xcode builds')
for pid in pids.stdout.split():
    process=subprocess.run(['ps','-p',pid,'-o','command='],capture_output=True,text=True)
    if process.returncode != 0 or not process.stdout.strip():continue
    command=process.stdout
    match=re.search(r'(?:^|\s)-derivedDataPath\s+(\S+)(?=\s+-|\s+(?:build|test|build-for-testing|test-without-building)\b|\s*$)',command)
    if not match or pathlib.Path(match.group(1)).resolve()==selected:
        raise SystemExit('An xcodebuild may be writing the selected Debug products. Wait for it to finish.')
PY_BUILD_GUARD
XCODE_VERSION="$(xcodebuild -version)"
[[ "$XCODE_VERSION" == Xcode\ 16.3$'\n'* ]] || fail "Xcode 16.3 is required; do not change signing or the global toolchain."
for required in "$BINARY" "$MODULE" "$APP/Contents/Resources/ko.lproj/Localizable.strings" "$APP/Contents/Resources/en.lproj/Localizable.strings"; do
  [ -f "$required" ] || fail "Missing Debug product: $required. Build with the runbook's incremental command first."
done

# A conservative timestamp fence. Do not claim a copied build's commit from this.
python3 - "$ROOT" "$BINARY" "$MODULE" <<'PY_CHECK'
import pathlib,sys
root,binary,module=map(pathlib.Path,sys.argv[1:])
built=min(binary.stat().st_mtime,module.stat().st_mtime)
candidates=[p for p in (root/'Picky').rglob('*') if p.is_file()]
candidates += [root/'Picky.xcodeproj/project.pbxproj']
stale=[str(p.relative_to(root)) for p in candidates if p.stat().st_mtime>built]
if stale:
    raise SystemExit('Debug build may be stale; rebuild with Xcode 16.3 before rendering:\n'+'\n'.join(stale[:12]))
PY_CHECK

HARNESS_ROOT="$(mktemp -d /private/tmp/PickyMockupHarness.XXXXXX)"
cleanup() {
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u -R "$HARNESS_ROOT" >/dev/null 2>&1 || true
  rm -rf "$HARNESS_ROOT"
}
trap cleanup EXIT
HARNESS="$HARNESS_ROOT/Renderer.app"
mkdir -p "$HARNESS/Contents/MacOS" "$HARNESS/Contents/Resources" "$OUT"
cp -R "$APP/Contents/Resources/ko.lproj" "$HARNESS/Contents/Resources/"
cp -R "$APP/Contents/Resources/en.lproj" "$HARNESS/Contents/Resources/"
cat > "$HARNESS/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.picky.swift-ui-mockup</string>
<key>CFBundleExecutable</key><string>Renderer</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
</dict></plist>
PLIST

# Picky.debug.dylib has no 'lib' prefix; link its exact path, not -lPicky.debug.
xcrun swiftc -parse-as-library -enable-testing -swift-version 5 \
  -I "$PRODUCTS" -F "$PRODUCTS" "$BINARY" \
  -Xlinker -rpath -Xlinker "$APP/Contents/MacOS" \
  -Xlinker -rpath -Xlinker "$APP/Contents/Frameworks" \
  "$SOURCE" "$ROOT/PickyTests/PickyRenderGalleryRasterizer.swift" \
  "$ROOT/PickyTests/FakePickyAgentClient.swift" \
  -o "$HARNESS/Contents/MacOS/Renderer"

# No desktop opt-in. A fake host alone is not a reason to access live state.
XCTestConfigurationFilePath="$HARNESS_ROOT/offscreen-fixture" \
PICKY_PRE_PUSH_UI_EFFECT_TESTS=0 PICKY_UI_TEST_SESSION=offscreen \
  "$HARNESS/Contents/MacOS/Renderer" "$OUT"

python3 - "$ROOT" "$SOURCE" "$OUT" "$BINARY" "$MODULE" "$XCODE_VERSION" <<'PY_ARTIFACTS'
import datetime,hashlib,json,os,pathlib,shutil,subprocess,sys
root,source,out,binary,module=map(pathlib.Path,sys.argv[1:6])
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
provenance={
    'renderedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'checkoutHead':subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(),
    'source':str(source), 'sourceSHA256':sha(source), 'sourceFile':source.name,
    'productionBinary':str(binary), 'productionBinarySHA256':sha(binary),
    'moduleSHA256':sha(module), 'xcode':sys.argv[6],
    'swift':subprocess.check_output(['xcrun','swiftc','--version'],text=True).strip(),
    'scope':'proposal render only; checkoutHead is not a claim about the binary build commit',
}
(out/'render-provenance.json').write_text(json.dumps(provenance,ensure_ascii=False,indent=2)+'\n')
if source != out/source.name:shutil.copyfile(source,out/source.name)
runbook=os.path.relpath(root/'runbook/swift-ui-mockup.md',out)
readme=f'# SwiftUI render artifacts\n\n정본 절차는 [Swift UI 목업 런북]({runbook})을 참고한다.\n\n- 소스: `{source.name}`\n- 구성·치수·검수 메모: `manifest.json`\n- 사용한 모듈·소스·툴체인: `render-provenance.json`\n- 이 렌더는 제안 목업이며 앱 적용·실제 상태 전이 검증이 아니다.\n'
example=source.parent/'README.md'
if example.exists() and example != out/'README.md':
    readme+=f'- 화면별 설명: [예제 README]({os.path.relpath(example,out)})\n'
(out/'README.md').write_text(readme)
PY_ARTIFACTS
python3 "$SCRIPT_DIR/make-gallery.py" "$OUT"
printf 'Render gallery: %s/index.html\n' "$OUT"
