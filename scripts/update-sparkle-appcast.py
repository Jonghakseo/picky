#!/usr/bin/env python3
"""Create or update Picky's Sparkle appcast.

The release workflow calls this after the signed Sparkle update zip is uploaded.
It prepends the new item and removes an older item with the same Sparkle build
number on the same channel so GitHub Actions reruns replace the appcast entry
instead of duplicating it.
"""

from __future__ import annotations

import argparse
import email.utils
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE = f"{{{SPARKLE_NS}}}"
ET.register_namespace("sparkle", SPARKLE_NS)


def normalized_channel(raw: str) -> str:
    channel = raw.strip().lower()
    if channel in {"stable", ""}:
        return "stable"
    if channel == "beta":
        return "beta"
    raise ValueError(f"unsupported release channel for Sparkle appcast: {raw!r}")


def create_empty_appcast(repository: str) -> ET.ElementTree:
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Picky"
    ET.SubElement(channel, "link").text = f"https://github.com/{repository}"
    ET.SubElement(channel, "description").text = "Picky release feed"
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(root)


def load_or_create_appcast(path: Path, repository: str) -> ET.ElementTree:
    if path.exists() and path.stat().st_size > 0:
        return ET.parse(path)
    return create_empty_appcast(repository)


def appcast_channel(tree: ET.ElementTree) -> ET.Element:
    channel = tree.getroot().find("channel")
    if channel is None:
        raise ValueError("appcast missing <channel>")
    return channel


def item_version(item: ET.Element) -> str | None:
    version = item.find(f"{SPARKLE}version")
    return version.text.strip() if version is not None and version.text else None


def item_channel(item: ET.Element) -> str:
    channel = item.find(f"{SPARKLE}channel")
    if channel is None or channel.text is None or not channel.text.strip():
        return "stable"
    return channel.text.strip().lower()


def build_item(
    *,
    marketing_version: str,
    build_number: str,
    release_channel: str,
    download_url: str,
    ed_signature: str,
    length_bytes: str,
    pub_date: str,
    minimum_system_version: str = "14.2",
) -> ET.Element:
    channel = normalized_channel(release_channel)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Picky {marketing_version}"
    ET.SubElement(item, f"{SPARKLE}channel").text = channel
    ET.SubElement(item, "pubDate").text = pub_date
    ET.SubElement(item, f"{SPARKLE}version").text = build_number
    ET.SubElement(item, f"{SPARKLE}shortVersionString").text = marketing_version
    ET.SubElement(item, f"{SPARKLE}minimumSystemVersion").text = minimum_system_version
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": download_url,
            f"{SPARKLE}edSignature": ed_signature,
            "length": length_bytes,
            "type": "application/octet-stream",
        },
    )
    return item


def ensure_explicit_stable_channels(tree: ET.ElementTree) -> None:
    for item in appcast_channel(tree).findall("item"):
        if item.find(f"{SPARKLE}channel") is not None:
            continue
        channel = ET.Element(f"{SPARKLE}channel")
        channel.text = "stable"
        title_index = next((index for index, child in enumerate(list(item)) if child.tag == "title"), -1)
        item.insert(title_index + 1 if title_index >= 0 else 0, channel)


def prepend_replacing_duplicate(tree: ET.ElementTree, new_item: ET.Element) -> None:
    ensure_explicit_stable_channels(tree)
    channel = appcast_channel(tree)
    new_version = item_version(new_item)
    new_channel = item_channel(new_item)
    if not new_version:
        raise ValueError("new appcast item missing sparkle:version")

    for existing in list(channel.findall("item")):
        if item_version(existing) == new_version and item_channel(existing) == new_channel:
            channel.remove(existing)

    children = list(channel)
    language_index = next((index for index, child in enumerate(children) if child.tag == "language"), -1)
    insert_index = language_index + 1 if language_index >= 0 else 0
    channel.insert(insert_index, new_item)


def write_appcast(tree: ET.ElementTree, path: Path) -> None:
    ET.indent(tree, space="  ")
    path.parent.mkdir(parents=True, exist_ok=True)
    tree.write(path, encoding="utf-8", xml_declaration=True)


def update_appcast(
    *,
    appcast_path: Path,
    repository: str,
    marketing_version: str,
    build_number: str,
    release_channel: str,
    download_url: str,
    ed_signature: str,
    length_bytes: str,
    pub_date: str | None = None,
) -> None:
    resolved_pub_date = pub_date or email.utils.formatdate(usegmt=True)
    tree = load_or_create_appcast(appcast_path, repository)
    new_item = build_item(
        marketing_version=marketing_version,
        build_number=build_number,
        release_channel=release_channel,
        download_url=download_url,
        ed_signature=ed_signature,
        length_bytes=length_bytes,
        pub_date=resolved_pub_date,
    )
    prepend_replacing_duplicate(tree, new_item)
    write_appcast(tree, appcast_path)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Update Picky Sparkle appcast.xml")
    parser.add_argument("--appcast", required=True, type=Path)
    parser.add_argument("--repository", required=True, help="owner/repo, used for the appcast <link>")
    parser.add_argument("--marketing-version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--release-channel", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--ed-signature", required=True)
    parser.add_argument("--length-bytes", required=True)
    parser.add_argument("--pub-date", default=None)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        update_appcast(
            appcast_path=args.appcast,
            repository=args.repository,
            marketing_version=args.marketing_version,
            build_number=args.build_number,
            release_channel=args.release_channel,
            download_url=args.download_url,
            ed_signature=args.ed_signature,
            length_bytes=args.length_bytes,
            pub_date=args.pub_date,
        )
    except Exception as error:  # noqa: BLE001 - CLI should print concise failures
        print(f"update-sparkle-appcast: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
