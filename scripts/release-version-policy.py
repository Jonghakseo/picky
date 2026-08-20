#!/usr/bin/env python3
"""Validate Picky release tags and derive bundle version metadata."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from typing import List, Optional, Union

NUMERIC_COMPONENT = r"(?:0|[1-9][0-9]*)"
BASE_VERSION_PATTERN = rf"(?P<base>{NUMERIC_COMPONENT}\.{NUMERIC_COMPONENT}\.{NUMERIC_COMPONENT})"
CANONICAL_STABLE_RE = re.compile(rf"^{BASE_VERSION_PATTERN}$")
CANONICAL_PRERELEASE_RE = re.compile(
    rf"^{BASE_VERSION_PATTERN}-(?P<channel>beta|alpha)\.(?P<iteration>[1-9][0-9]*)$"
)
LEGACY_STABLE_RE = re.compile(rf"^{BASE_VERSION_PATTERN}-stable$")
MARKETING_VERSION_RE = re.compile(
    rf"^{NUMERIC_COMPONENT}\.{NUMERIC_COMPONENT}(?:\.{NUMERIC_COMPONENT})?$"
)


class ReleaseVersionPolicyError(ValueError):
    pass


@dataclass(frozen=True)
class ReleaseMetadata:
    tag: str
    marketingVersion: str
    releaseChannel: str
    prerelease: bool
    tagPolicy: str


def parse_bool(value: Union[str, bool]) -> bool:
    if isinstance(value, bool):
        return value
    normalized = value.strip().lower()
    if normalized == "true":
        return True
    if normalized == "false":
        return False
    raise ReleaseVersionPolicyError(f"expected true or false, got {value!r}")


def validate_marketing_version(version: str) -> str:
    if not MARKETING_VERSION_RE.fullmatch(version):
        raise ReleaseVersionPolicyError(
            "CFBundleShortVersionString must contain two or three numeric components "
            f"(for example 0.8.5), got {version!r}"
        )
    return version


def resolve_release_metadata(
    *,
    tag: str,
    release_channel: str,
    prerelease: Union[str, bool],
    allow_legacy: bool = False,
) -> ReleaseMetadata:
    channel = release_channel.strip().lower()
    is_prerelease = parse_bool(prerelease)

    if channel not in {"stable", "beta", "alpha"}:
        raise ReleaseVersionPolicyError(
            f"release channel must be stable, beta, or alpha, got {release_channel!r}"
        )

    expected_prerelease = channel != "stable"
    if is_prerelease != expected_prerelease:
        expected = "true" if expected_prerelease else "false"
        raise ReleaseVersionPolicyError(
            f"release channel {channel!r} requires prerelease={expected}"
        )

    stable_match = CANONICAL_STABLE_RE.fullmatch(tag)
    prerelease_match = CANONICAL_PRERELEASE_RE.fullmatch(tag)

    if channel == "stable" and stable_match:
        return ReleaseMetadata(tag, stable_match.group("base"), channel, is_prerelease, "canonical")

    if channel in {"beta", "alpha"} and prerelease_match:
        tag_channel = prerelease_match.group("channel")
        if tag_channel != channel:
            raise ReleaseVersionPolicyError(
                f"tag channel {tag_channel!r} does not match release channel {channel!r}"
            )
        return ReleaseMetadata(
            tag,
            prerelease_match.group("base"),
            channel,
            is_prerelease,
            "canonical",
        )

    if allow_legacy:
        legacy_stable_match = LEGACY_STABLE_RE.fullmatch(tag)
        if channel == "stable" and legacy_stable_match:
            # Preserve the historical bundle version when explicitly rerunning an old release.
            return ReleaseMetadata(tag, tag, channel, is_prerelease, "legacy")
        if channel == "beta" and stable_match:
            return ReleaseMetadata(tag, stable_match.group("base"), channel, is_prerelease, "legacy")

    expected_tag = {
        "stable": "X.Y.Z",
        "beta": "X.Y.Z-beta.N",
        "alpha": "X.Y.Z-alpha.N",
    }[channel]
    legacy_hint = " Pass --allow-legacy only when rerunning an existing historical release."
    raise ReleaseVersionPolicyError(
        f"{channel} releases require tag format {expected_tag}; got {tag!r}.{legacy_hint}"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    resolve = subparsers.add_parser("resolve", help="validate a release tag and emit metadata")
    resolve.add_argument("--tag", required=True)
    resolve.add_argument("--release-channel", required=True)
    resolve.add_argument("--prerelease", required=True)
    resolve.add_argument("--allow-legacy", action="store_true")

    validate = subparsers.add_parser(
        "validate-marketing-version",
        help="validate a numeric CFBundleShortVersionString",
    )
    validate.add_argument("version")
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "resolve":
            metadata = resolve_release_metadata(
                tag=args.tag,
                release_channel=args.release_channel,
                prerelease=args.prerelease,
                allow_legacy=args.allow_legacy,
            )
            print(json.dumps(asdict(metadata), separators=(",", ":")))
        else:
            print(validate_marketing_version(args.version))
    except ReleaseVersionPolicyError as error:
        print(f"release version policy error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
