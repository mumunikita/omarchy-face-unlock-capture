#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Update the few Howdy settings this project needs, preserving comments.

The installer runs this with sudo. It changes only:
  [video] device_path
  [video] timeout
  [core]  abort_if_lid_closed

Everything else in /etc/howdy/config.ini is left untouched.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime
from pathlib import Path


def section_span(lines: list[str], section: str) -> tuple[int, int] | None:
    header = f"[{section}]"
    start = None
    for i, line in enumerate(lines):
        if line.strip() == header:
            start = i
            break
    if start is None:
        return None

    end = len(lines)
    for j in range(start + 1, len(lines)):
        stripped = lines[j].strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            end = j
            break
    return start, end


def set_key(lines: list[str], section: str, key: str, value: str) -> bool:
    span = section_span(lines, section)
    if span is None:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(f"\n[{section}]\n")
        lines.append(f"{key} = {value}\n")
        return True

    start, end = span
    key_re = re.compile(rf"^\s*{re.escape(key)}\s*=")
    for i in range(start + 1, end):
        if key_re.match(lines[i]):
            indent = lines[i][: len(lines[i]) - len(lines[i].lstrip())]
            newline = "\n" if lines[i].endswith("\n") else ""
            replacement = f"{indent}{key} = {value}{newline}"
            if lines[i] == replacement:
                return False
            lines[i] = replacement
            return True

    # Insert before trailing blank lines so the section keeps its spacing.
    insert_at = end
    while insert_at > start + 1 and lines[insert_at - 1].strip() == "":
        insert_at -= 1
    lines.insert(insert_at, f"{key} = {value}\n")
    return True


def read_value(lines: list[str], section: str, key: str) -> str | None:
    span = section_span(lines, section)
    if span is None:
        return None
    start, end = span
    key_re = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.*?)\s*$")
    for i in range(start + 1, end):
        match = key_re.match(lines[i].rstrip("\n"))
        if match:
            return match.group(1)
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="/etc/howdy/config.ini")
    parser.add_argument("--device", default="", help="stable IR camera path")
    parser.add_argument("--timeout", type=float, default=4.0)
    parser.add_argument(
        "--allow-non-root",
        action="store_true",
        help="skip the root check (for tests; do not use on the real file)",
    )
    args = parser.parse_args()

    config = Path(args.config)
    if not args.allow_non_root and os.geteuid() != 0:
        print("run this with sudo (it edits /etc/howdy/config.ini)", file=sys.stderr)
        return 2
    if not config.is_file():
        print(f"missing Howdy config: {config}", file=sys.stderr)
        return 1

    lines = config.read_text().splitlines(keepends=True)
    changes: list[str] = []

    if set_key(lines, "core", "abort_if_lid_closed", "true"):
        changes.append("core.abort_if_lid_closed = true")
    timeout = f"{args.timeout:g}"
    if set_key(lines, "video", "timeout", timeout):
        changes.append(f"video.timeout = {timeout}")
    if args.device and set_key(lines, "video", "device_path", args.device):
        changes.append(f"video.device_path = {args.device}")

    if not changes:
        print("Howdy config already up to date.")
    else:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = config.with_name(f"{config.name}.omarchy-face-unlock.bak.{stamp}")
        shutil.copy2(config, backup)

        fd, tmp_name = tempfile.mkstemp(prefix=f".{config.name}.", dir=config.parent)
        try:
            with os.fdopen(fd, "w") as tmp:
                tmp.writelines(lines)
                tmp.flush()
                os.fsync(tmp.fileno())
            os.chmod(tmp_name, 0o644)
            os.replace(tmp_name, config)
        except BaseException:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass
            raise

        print(f"Updated {config} (backup: {backup})")
        for change in changes:
            print(f"  {change}")

    disabled = read_value(lines, "core", "disabled")
    if disabled and disabled.lower() == "true":
        print(
            "warning: Howdy is disabled ([core] disabled = true); "
            "face unlock will stay off until you run: sudo howdy disable false",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
