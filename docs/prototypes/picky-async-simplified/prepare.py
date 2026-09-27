#!/usr/bin/env python3
"""Mount current production code; export the exact proposal as an unapplied patch."""
import difflib
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[3]
source = Path(__file__).resolve().parent
out = root / 'build/design-prototypes/async-simplified/production'
products = Path(sys.argv[1])
app = out / 'Picky Async UI Study.app/Contents'
resources = app / 'Resources'
out.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
(app / 'MacOS').mkdir(parents=True, exist_ok=True)
card_path = Path('Picky/HUD/Conversation/PickyConversationCardView.swift')
card = (root / card_path).read_text()
old = '''    private var showsBackgroundStopErrorInShelf: Bool {
        guard case .loaded(let metadata) = sessionStore.metaStore.metadataState,
              let summary = metadata.asyncWorkSummary else { return false }
        return PickyAsyncTaskShelfPresentation.isEmptyAttention(summary: summary,
            detail: sessionStore.asyncTaskStore.detailState)
    }'''
assert card.count(old) == 1, 'Card changed; review the integration seam instead of silently approximating it.'
assert card.count('PickyMountedAsyncTaskShelfView(') == 1
new = card.replace(old, '    private var showsBackgroundStopErrorInShelf: Bool { false }')
new = new.replace('PickyMountedAsyncTaskShelfView(', 'PickyRunningTaskFooterView(')
new = new.replace('                bottomSpacing: DS.Spacing.space2,\n                stopError: backgroundStopError',
                  '                bottomSpacing: DS.Spacing.space2')
(out / 'ProductionConversationCard.swift').write_text('@testable import Picky\n' + new.replace(
    'struct PickyConversationCardView: View', 'struct StudyConversationCardView: View'))
footer = (source / 'PickyRunningTaskFooterView.swift').read_text()
(out / 'PickyRunningTaskFooterView.swift').write_text('@testable import Picky\n' + footer)

def diff(before, after, path):
    return ''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
        fromfile='a/' + str(path) if before else '/dev/null', tofile='b/' + str(path)))

patch = diff(card, new, card_path)
patch += diff('', footer, 'Picky/HUD/Conversation/PickyRunningTaskFooterView.swift')
key = 'hud.asyncTasks.runningCount'
translations = {'en': 'Running tasks · %1$lld', 'ko': '작업 %1$lld개 실행 중',
                'ja': '%1$lld件のタスクを実行中', 'zh-Hans': '%1$lld 个任务正在运行', 'zh-Hant': '%1$lld 個工作正在執行'}
catalog_path = Path('Picky/Resources/Localizable.xcstrings')
catalog_text = (root / catalog_path).read_text()
catalog = json.loads(catalog_text)
entry = {'comment': 'Count of root task families with confirmed running work. %1$lld is the count.',
         'localizations': {lang: {'stringUnit': {'state': 'translated', 'value': value}}
                           for lang, value in translations.items()}}
# Preserve Apple's catalog formatting rather than reformatting the entire file.
anchor = '    "hud.asyncTasks.showLess": {'
assert catalog_text.count(anchor) == 1 and key not in catalog['strings']
entry_text = json.dumps({key: entry}, ensure_ascii=False, indent=2)[2:-2]
entry_text = '\n'.join('  ' + line for line in entry_text.splitlines())
updated_catalog = catalog_text.replace(anchor, entry_text + ',\n' + anchor)
assert json.loads(updated_catalog)['strings'][key] == entry
(out / 'Localizable.xcstrings').write_text(updated_catalog)
patch += diff(catalog_text, updated_catalog, catalog_path)
(out / 'apply-to-production.patch').write_text(patch)

production_resources = products / 'Picky.app/Contents/Resources'
for item in production_resources.iterdir():
    if item.suffix == '.lproj':
        shutil.copytree(item, resources / item.name, dirs_exist_ok=True)
    elif item.name == 'Assets.car' or item.suffix == '.ttf':
        shutil.copy2(item, resources / item.name)
for lang, value in translations.items():
    path = resources / f'{lang}.lproj/Localizable.strings'
    # Xcode currently emits binary plists for .strings; plutil also handles text catalogs.
    data = subprocess.check_output(['plutil', '-convert', 'binary1', '-o', '-', str(path)])
    strings = plistlib.loads(data)
    strings[key] = value
    path.write_bytes(plistlib.dumps(strings, fmt=plistlib.FMT_BINARY))
plist = {'CFBundleIdentifier': 'local.picky.async-ui-study.production', 'CFBundleName': 'Picky Async UI Study',
         'CFBundleExecutable': 'AsyncWorkStudy', 'CFBundleDevelopmentRegion': 'en',
         'CFBundleLocalizations': list(translations), 'NSHighResolutionCapable': True}
(app / 'Info.plist').write_bytes(plistlib.dumps(plist))
manifest = {'sourceRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
            'cardSource': str(card_path), 'cardSHA256': hashlib.sha256(card.encode()).hexdigest(),
            'cardWidth': 446, 'cardHeight': 640, 'productionSourcesCopiedWithoutRestyling': True,
            'patchAppliedToRepository': False, 'transport': 'in-memory fixture only'}
(out / 'provenance.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print(out)
