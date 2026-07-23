#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generate software copyright "source code pages" (front 30 + tail 30).

Output:
  respeaker-app/docs/SOFTCOPYRIGHT_SOURCE_CODE_PAGES.txt

Rules (default):
  - 60 pages total: 30 front + 30 tail
  - 50 lines per page
  - Each page includes: software name, version, file path, page index
  - Basic redaction for sensitive-looking values in logs/config lines
"""

from __future__ import annotations

import argparse
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Tuple


LINES_PER_PAGE = 50
FRONT_PAGES = 30
TAIL_PAGES = 30


SENSITIVE_KEYS = {
    "password",
    "token",
    "access_token",
    "refresh_token",
    "id_token",
    "authorization",
    "api_key",
    "api_secret",
    "secret",
    "secret_key",
    "client_secret",
}


_QUOTED = re.compile(r"(['\"])([^'\"]+)\1")


def _redact_line(line: str) -> str:
    # Never redact Dart import/export paths; they are not secrets and are required
    # for reviewers to see the code structure.
    s = line.lstrip()
    if s.startswith("import ") or s.startswith("export "):
        return line

    low = line.lower()
    if not any(k in low for k in SENSITIVE_KEYS):
        return line

    # Replace long quoted literals on sensitive lines.
    def repl(m: re.Match[str]) -> str:
        quote = m.group(1)
        content = m.group(2)
        # Keep very short literals (e.g., "OK", "ERR", enum names).
        if len(content) <= 6:
            return f"{quote}{content}{quote}"
        # Keep Dart file paths (imports, asset refs) as-is.
        if content.endswith(".dart") or content.endswith(".png") or content.endswith(".json"):
            return f"{quote}{content}{quote}"
        if "/" in content and ".dart" in content:
            return f"{quote}{content}{quote}"
        # Keep obvious non-secret constants (URLs, UUID-like service ids)
        if content.startswith("http://") or content.startswith("https://"):
            return f"{quote}{content}{quote}"
        if re.fullmatch(r"[0-9a-fA-F\-]{16,}", content):
            return f"{quote}{content}{quote}"
        return f'{quote}<redacted>{quote}'

    return _QUOTED.sub(repl, line)


def _read_lines(file_path: Path) -> List[str]:
    try:
        text = file_path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        text = file_path.read_text(encoding="utf-8", errors="replace")
    return text.splitlines()


@dataclass(frozen=True)
class FilePlan:
    rel_path: str
    max_pages: int


def _emit_page_header(*, software_name: str, version: str, rel_path: str, page_no: int, total_pages: int) -> str:
    # Keep header short so it doesn't eat into 50-line body.
    return (
        f"软件名称：{software_name}    版本号：{version}\n"
        f"文件：{rel_path}\n"
        f"第 {page_no} 页 / 共 {total_pages} 页\n"
        + ("-" * 72)
    )


def _chunk(lines: List[str], size: int) -> List[List[str]]:
    return [lines[i : i + size] for i in range(0, len(lines), size)]


def _pages_from_start(repo_root: Path, plans: List[FilePlan], want_pages: int) -> List[Tuple[str, List[str]]]:
    pages: List[Tuple[str, List[str]]] = []
    for plan in plans:
        if len(pages) >= want_pages:
            break
        fp = repo_root / plan.rel_path
        if not fp.exists():
            continue
        lines = _read_lines(fp)
        chunks = _chunk(lines, LINES_PER_PAGE)
        take = min(plan.max_pages, max(0, want_pages - len(pages)), len(chunks))
        for i in range(take):
            pages.append((plan.rel_path, chunks[i]))
    return pages


def _pages_from_end(repo_root: Path, plans: List[FilePlan], want_pages: int) -> List[Tuple[str, List[str]]]:
    pages: List[Tuple[str, List[str]]] = []
    for plan in plans:
        if len(pages) >= want_pages:
            break
        fp = repo_root / plan.rel_path
        if not fp.exists():
            continue
        lines = _read_lines(fp)
        chunks = _chunk(lines, LINES_PER_PAGE)
        if not chunks:
            continue
        take = min(plan.max_pages, max(0, want_pages - len(pages)), len(chunks))
        # Take from file tail, but keep chunk order stable.
        selected = chunks[-take:]
        for ch in selected:
            pages.append((plan.rel_path, ch))
    return pages


def _format_body(lines: List[str]) -> List[str]:
    out: List[str] = []
    for i in range(LINES_PER_PAGE):
        raw = lines[i] if i < len(lines) else ""
        raw = _redact_line(raw)
        out.append(f"{i+1:04d}|{raw}")
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", default="【待填：软件名称】", help="软件名称（用于页眉）")
    parser.add_argument("--version", default="V【待填】", help="版本号（用于页眉）")
    parser.add_argument(
        "--repo-root",
        default=str(Path(__file__).resolve().parents[1]),
        help="仓库子项目根目录（默认：respeaker-app/）",
    )
    parser.add_argument(
        "--out",
        default="docs/SOFTCOPYRIGHT_SOURCE_CODE_PAGES.txt",
        help="输出文件（相对 repo-root）",
    )
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    out_file = (repo_root / args.out).resolve()

    front_plans: List[FilePlan] = [
        FilePlan("lib/main.dart", 2),
        FilePlan("lib/src/app/router/app_router.dart", 6),
        FilePlan("lib/src/features/home/presentation/home_shell_page.dart", 4),
        FilePlan("lib/src/features/recordings/presentation/recordings_page.dart", 12),
        FilePlan("lib/src/features/recordings/presentation/widgets/recording_session_sheet.dart", 8),
        FilePlan("lib/src/features/device/presentation/widgets/device_selector_dropdown.dart", 6),
        FilePlan("lib/src/features/ai_config/presentation/ai_config_page.dart", 6),
        FilePlan("lib/src/features/settings/presentation/settings_page.dart", 6),
    ]

    tail_plans: List[FilePlan] = [
        FilePlan("lib/src/core/db/app_database.dart", 10),
        FilePlan("lib/src/features/recordings/data/recordings_repository.dart", 10),
        FilePlan("lib/src/features/device/presentation/device_controller.dart", 8),
        FilePlan("lib/src/features/device/data/lua/lua_transport.dart", 6),
        FilePlan("lib/src/features/device/data/lua/lua_rpc.dart", 6),
        FilePlan("lib/src/core/server/http/api_client.dart", 8),
        FilePlan("lib/src/features/ai_config/domain/ai_providers.dart", 6),
        FilePlan("lib/src/features/ai_config/presentation/widgets/ai_config_validation.dart", 6),
    ]

    front_pages = _pages_from_start(repo_root, front_plans, FRONT_PAGES)
    tail_pages = _pages_from_end(repo_root, tail_plans, TAIL_PAGES)

    # If still not enough pages (unlikely), extend by relaxing caps (take more from the biggest files).
    if len(front_pages) < FRONT_PAGES:
        extra = _pages_from_start(
            repo_root,
            [
                FilePlan("lib/src/features/recordings/presentation/recordings_page.dart", 999),
                FilePlan("lib/src/features/recordings/presentation/widgets/recording_session_sheet.dart", 999),
            ],
            FRONT_PAGES,
        )
        front_pages = extra

    if len(tail_pages) < TAIL_PAGES:
        extra = _pages_from_end(
            repo_root,
            [
                FilePlan("lib/src/core/db/app_database.dart", 999),
                FilePlan("lib/src/features/recordings/data/recordings_repository.dart", 999),
                FilePlan("lib/src/core/server/http/api_client.dart", 999),
            ],
            TAIL_PAGES,
        )
        tail_pages = extra

    total_pages = len(front_pages) + len(tail_pages)
    if total_pages == 0:
        raise SystemExit("No pages generated. Check repo-root and file paths.")

    # Ensure output directory exists.
    out_file.parent.mkdir(parents=True, exist_ok=True)

    blocks: List[str] = []
    blocks.append("计算机软件著作权登记材料（源代码页）")
    blocks.append(f"软件名称：{args.name}")
    blocks.append(f"版本号：{args.version}")
    blocks.append(f"规则：前{FRONT_PAGES}页 + 后{TAIL_PAGES}页；每页{LINES_PER_PAGE}行")
    blocks.append("")

    page_no = 1
    for rel_path, lines in front_pages + tail_pages:
        blocks.append(_emit_page_header(software_name=args.name, version=args.version, rel_path=rel_path, page_no=page_no, total_pages=total_pages))
        blocks.extend(_format_body(lines))
        blocks.append("\f")  # form feed page break (Word-friendly)
        page_no += 1

    out_file.write_text("\n".join(blocks), encoding="utf-8")
    print(f"[OK] wrote {out_file}  pages={total_pages}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

