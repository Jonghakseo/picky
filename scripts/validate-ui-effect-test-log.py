#!/usr/bin/env python3
"""Reject a successful Xcode exit that did not execute the selected UI contract."""

import argparse
import re
from pathlib import Path


def validate_log(selector: str, log: str) -> None:
    suite, method = selector.split("/", 1)
    method = method.removesuffix("()")
    if not re.search(rf"^✔ Test {re.escape(method)}\(\) passed\b", log, re.MULTILINE):
        raise ValueError(f"Selected UI contract did not pass: {selector}")
    if not re.search(rf"^✔ Suite {re.escape(suite)} passed\b", log, re.MULTILINE):
        raise ValueError(f"Selected UI suite did not pass: {suite}")
    if not re.search(r"^✔ Test run with 1 test passed\b", log, re.MULTILINE):
        raise ValueError("An isolated UI host must execute exactly one test")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selector", required=True)
    parser.add_argument("--log", required=True, type=Path)
    args = parser.parse_args()
    try:
        validate_log(args.selector, args.log.read_text(errors="replace"))
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
