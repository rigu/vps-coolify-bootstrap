#!/usr/bin/env python3
"""Harden Coolify compose port exposure for production bootstrap.

Behavior:
- Removes canonical APP_PORT/8000->8080 publish lines from both compose files.
- When realtime close mode is enabled, converts Soketi 6001/6002 public ports
  block to expose-only in docker-compose.prod.yml.

Exit codes:
- 0: already hardened / no changes required
- 10: changes applied
- 20: unsupported compose format (cannot safely mutate)
- 1: usage/runtime error
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from datetime import datetime, timezone

APP_PORT_PUBLISH = re.compile(r'(?m)^[ \t]*-[ \t]*"(?:\$\{APP_PORT:-8000\}|8000):8080"[ \t]*(?:\r?\n|$)')
ANY_8080_PUBLISH = re.compile(r'(?m)^[ \t]*-\s*"[^"\n]*:8080"\s*$')

SOKETI_PUBLIC_PORTS_BLOCK = re.compile(
    r'(?m)^([ \t]*)ports:\n\1  - "\$\{SOKETI_PORT:-6001\}:6001"\n\1  - "6002:6002"\n?'
)
SOKETI_EXPOSE_BLOCK = re.compile(r'(?m)^([ \t]*)expose:\n\1  - "6001"\n\1  - "6002"\n?')
ANY_6001_PUBLISH = re.compile(r'(?m)^[ \t]*-\s*"[^"\n]*:6001"\s*$')
ANY_6002_PUBLISH = re.compile(r'(?m)^[ \t]*-\s*"[^"\n]*:6002"\s*$')


def _log(level: str, message: str, stream=sys.stderr) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{level}] [{ts}] [harden-coolify-compose-ports.py] {message}", file=stream)


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _write_text(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")


def _remove_empty_ports_keys(text: str) -> tuple[str, int]:
    """Remove `ports:` keys that no longer have list items beneath them."""
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    i = 0
    removed = 0

    while i < len(lines):
        line = lines[i]
        m = re.match(r'^([ \t]*)ports:[ \t]*(?:#.*)?(?:\r?\n|$)$', line)
        if not m:
            out.append(line)
            i += 1
            continue

        base_indent = len(m.group(1))
        j = i + 1
        has_list_item = False
        while j < len(lines):
            candidate = lines[j]
            stripped = candidate.strip()
            if stripped == "" or stripped.startswith("#"):
                j += 1
                continue

            indent = len(candidate) - len(candidate.lstrip(" \t"))
            if indent > base_indent and candidate.lstrip(" \t").startswith("-"):
                has_list_item = True
            break

        if has_list_item:
            out.append(line)
        else:
            removed += 1
        i += 1

    return "".join(out), removed


def _parse_close_realtime_arg(raw: str) -> bool:
    v = raw.strip().lower()
    if v in ("true", "1"):
        return True
    if v in ("false", "0"):
        return False
    raise ValueError("close-realtime flag must be true/false or 1/0")


def harden_compose(base_path: Path, prod_path: Path, close_realtime_ports: bool = True) -> int:
    base_text = _read_text(base_path)
    prod_text = _read_text(prod_path)

    unknown_patterns: list[str] = []
    changed = False

    new_base_text, base_replacements = APP_PORT_PUBLISH.subn("", base_text)
    new_prod_text, prod_8080_replacements = APP_PORT_PUBLISH.subn("", prod_text)

    if base_replacements > 0:
        changed = True
    if prod_8080_replacements > 0:
        changed = True

    new_base_text, removed_empty_base_ports = _remove_empty_ports_keys(new_base_text)
    new_prod_text, removed_empty_prod_ports = _remove_empty_ports_keys(new_prod_text)
    if removed_empty_base_ports > 0 or removed_empty_prod_ports > 0:
        changed = True

    # If canonical APP_PORT/8000 publish patterns are absent, tolerate
    # already-hardened state only when there is no remaining 8080 publish rule.
    if ANY_8080_PUBLISH.search(new_base_text):
        unknown_patterns.append(
            "unrecognized 8080 publish rule in docker-compose.yml"
        )
    if ANY_8080_PUBLISH.search(new_prod_text):
        unknown_patterns.append(
            "unrecognized 8080 publish rule in docker-compose.prod.yml"
        )

    prod_replacements = 0
    if close_realtime_ports:
        new_prod_text, prod_replacements = SOKETI_PUBLIC_PORTS_BLOCK.subn(
            '\\1expose:\\n\\1  - "6001"\\n\\1  - "6002"\\n', new_prod_text
        )
        if prod_replacements > 0:
            changed = True
        else:
            # If canonical public block is absent, accept only expose-only state.
            if not SOKETI_EXPOSE_BLOCK.search(new_prod_text) and (
                ANY_6001_PUBLISH.search(new_prod_text) or ANY_6002_PUBLISH.search(new_prod_text)
            ):
                unknown_patterns.append(
                    "unrecognized 6001/6002 publish rules in docker-compose.prod.yml"
                )

    if unknown_patterns:
        for item in unknown_patterns:
            _log("ERROR", item, sys.stderr)
        _log("ERROR", "refusing partial compose hardening; review Coolify compose format.", sys.stderr)
        return 20

    if changed:
        _write_text(base_path, new_base_text)
        _write_text(prod_path, new_prod_text)
        if base_replacements > 0:
            _log("SUCCESS", "Removed APP_PORT/8000:8080 binding from docker-compose.yml", sys.stdout)
        if prod_8080_replacements > 0:
            _log("SUCCESS", "Removed APP_PORT/8000:8080 binding from docker-compose.prod.yml", sys.stdout)
        if removed_empty_base_ports > 0:
            _log("SUCCESS", "Removed empty ports key(s) from docker-compose.yml", sys.stdout)
        if removed_empty_prod_ports > 0:
            _log("SUCCESS", "Removed empty ports key(s) from docker-compose.prod.yml", sys.stdout)
        if prod_replacements > 0:
            _log("SUCCESS", "Converted Soketi ports to expose-only in docker-compose.prod.yml", sys.stdout)
        return 10

    _log("SUCCESS", "Coolify compose ports already hardened; no file changes applied", sys.stdout)
    return 0


def main() -> int:
    if len(sys.argv) not in (3, 4):
        _log(
            "ERROR",
            "Usage: harden-coolify-compose-ports.py <base-compose> <prod-compose> [<close-realtime-ports:true|false>]",
            sys.stderr,
        )
        return 1

    base_path = Path(sys.argv[1])
    prod_path = Path(sys.argv[2])
    close_realtime_ports = True
    if len(sys.argv) == 4:
        try:
            close_realtime_ports = _parse_close_realtime_arg(sys.argv[3])
        except ValueError as exc:
            _log("ERROR", str(exc), sys.stderr)
            return 1

    if not base_path.is_file() or not prod_path.is_file():
        _log("ERROR", "compose files not found", sys.stderr)
        return 1

    try:
        return harden_compose(base_path, prod_path, close_realtime_ports=close_realtime_ports)
    except Exception as exc:  # pragma: no cover - defensive guard
        _log("ERROR", f"compose hardening failed: {exc}", sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
