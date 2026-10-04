#!/usr/bin/env python3
"""Validate a SwiftUI scene manifest and display PNGs at their logical size."""
import argparse
import html
import json
import math
import struct
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path, help="Directory containing manifest.json and rendered PNGs")
parser.add_argument("--title", default="Picky SwiftUI 1:1 목업")
args = parser.parse_args()
root = args.output.resolve()
manifest = json.loads((root / "manifest.json").read_text())
scenes = manifest["scenes"]
if not scenes:
    raise SystemExit("No rendered scenes")

by_id = {}
seen_files = set()
for scene in scenes:
    path = (root / scene["file"]).resolve()
    if not path.is_relative_to(root) or path.suffix.lower() != ".png":
        raise SystemExit(f"Scene must reference a PNG inside the output directory: {scene['file']}")
    if scene["file"] in seen_files:
        raise SystemExit(f"Duplicate scene file: {scene['file']}")
    seen_files.add(scene["file"])
    for key in ("width", "height", "pixelWidth", "pixelHeight", "scale"):
        value = scene[key]
        if not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
            raise SystemExit(f"Invalid {key}: {scene['file']}")
    if scene["appearance"] not in ("dark", "light"):
        raise SystemExit(f"Invalid appearance: {scene['file']}")
    data = path.read_bytes()
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise SystemExit(f"Invalid PNG: {path}")
    if struct.unpack(">II", data[16:24]) != (scene["pixelWidth"], scene["pixelHeight"]):
        raise SystemExit(f"PNG dimensions differ from manifest: {path}")
    by_id.setdefault(scene["id"], []).append(scene)

sections = []
for scene_id, variants in by_id.items():
    first = variants[0]
    images = []
    for variant in variants:
        theme = "다크" if variant["appearance"] == "dark" else "라이트"
        label = f"{theme} · {variant['width']:.0f}pt / 글자 {variant['scale'] * 100:.0f}%"
        file = html.escape(variant["file"], quote=True)
        images.append(
            f'<figure data-theme="{variant["appearance"]}" data-large-font="{str(variant["scale"] != 1).lower()}">'
            f'<figcaption>{label} · 높이 {variant["height"]:.0f}pt</figcaption>'
            f'<a href="{file}" target="_blank"><img src="{file}" '
            f'style="width:{variant["width"]:g}px;height:{variant["height"]:g}px" '
            f'alt="{html.escape(first["title"], quote=True)}" loading="lazy"></a></figure>'
        )
    sections.append(
        f'<section id="{html.escape(scene_id, quote=True)}"><h2>{html.escape(first["title"])}</h2>'
        f'<p>{html.escape(first.get("note", ""))}</p><div class="variants">{"".join(images)}</div></section>'
    )
nav = "".join(
    f'<a href="#{html.escape(scene_id, quote=True)}">{html.escape(variants[0]["title"])}</a>'
    for scene_id, variants in by_id.items()
)
links = '<a class="source" href="manifest.json">장면·치수</a>'
for source in sorted(root.glob("*.swift")):
    links += f'<a class="source" href="{html.escape(source.name, quote=True)}">Swift 소스</a>'
if (root / "README.md").is_file():
    links += '<a class="source" href="README.md">범위·렌더 한계</a>'

page = '''<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>__TITLE__</title>
<style>
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:#f4f5f5;color:#202421;font:14px -apple-system,BlinkMacSystemFont,sans-serif}header{position:sticky;top:0;background:#fff;border-bottom:1px solid #d9ddda;padding:18px 24px;z-index:2}h1{font-size:20px;margin:0 0 8px}header p{margin:0 0 12px;color:#59635d;line-height:1.6}.controls{display:flex;gap:8px;align-items:center;flex-wrap:wrap}button,.source{font:inherit;border:1px solid #cbd1cd;border-radius:6px;background:white;padding:6px 10px;color:#24342a;cursor:pointer}button.active{background:#202621;color:white}.body{display:grid;grid-template-columns:220px minmax(0,1fr);gap:24px;padding:24px}nav{position:sticky;top:180px;align-self:start;max-height:calc(100vh - 210px);overflow:auto}nav a{display:block;padding:8px 6px;color:#37473d;text-decoration:none;font-size:13px}nav a:hover{background:#e3e8e4}section{scroll-margin-top:175px;margin:0 0 24px;padding:20px;background:white;border:1px solid #dce1dd;border-radius:10px;max-width:1120px;overflow-x:auto}h2{font-size:16px;margin:0 0 8px}section p{margin:0 0 16px;color:#58665e;line-height:1.6;max-width:850px}.variants{display:flex;gap:24px;flex-wrap:wrap;align-items:flex-start}figure{margin:0;flex-shrink:0}figcaption{font-size:12px;color:#68756d;margin-bottom:8px}img{display:block;max-width:none}a.source{text-decoration:none;font-size:12px}[hidden]{display:none!important}@media(max-width:800px){.body{display:block;padding:12px}nav{display:none}header{position:static}section{scroll-margin-top:12px}}
</style>
<header><h1>__TITLE__</h1><p>__RENDERER__<br>PNG를 논리 크기 1:1로 표시합니다(브라우저 zoom 100%). 좁은 화면에서는 가로로 스크롤합니다. 시안의 앱 적용 여부와 미검증 범위는 장면 설명·README에서 확인하세요.</p><div class="controls"><button class="active" onclick="theme('both',this)">다크 + 라이트</button><button onclick="theme('dark',this)">다크</button><button onclick="theme('light',this)">라이트</button><label><input type="checkbox" id="largeFont" onchange="refresh()" checked> 다른 글자 배율 함께 보기</label>__LINKS__</div></header>
<div class="body"><nav>__NAV__</nav><main>__SECTIONS__</main></div><script>let selected='both';function theme(value,button){selected=value;document.querySelectorAll('button').forEach(b=>b.classList.toggle('active',b===button));refresh()}function refresh(){document.querySelectorAll('figure').forEach(f=>f.hidden=(selected!=='both'&&f.dataset.theme!==selected)||(f.dataset.largeFont==='true'&&!document.getElementById('largeFont').checked))}</script></html>'''
replacements = {
    "__TITLE__": html.escape(args.title),
    "__RENDERER__": html.escape(manifest.get("renderer", "SwiftUI render")),
    "__LINKS__": links,
    "__NAV__": nav,
    "__SECTIONS__": "".join(sections),
}
# One substitution pass preserves placeholders that happen to occur in fixture text.
import re
page = re.sub(r"__(?:TITLE|RENDERER|LINKS|NAV|SECTIONS)__", lambda match: replacements[match.group()], page)
(root / "index.html").write_text(page)
print(f"Validated {len(scenes)} PNG dimensions; wrote gallery for {len(by_id)} situations.")
