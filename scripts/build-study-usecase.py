#!/usr/bin/env python3
"""Publish the Graphify/Serena/OpenWiki study as a self-contained static route."""

from __future__ import annotations

import argparse
from html.parser import HTMLParser
from pathlib import Path
import re
from urllib.parse import unquote


REPO = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = REPO.parent

COMMITS = {
    "graphify": (
        "https://github.com/Graphify-Labs/graphify/blob/"
        "33362d969292b57eda82f3fbd9eb5f3f5bc9bbc2/"
    ),
    "serena": (
        "https://github.com/oraios/serena/blob/"
        "801a388c2b7a6a8998f313291678b1609664e794/"
    ),
    "openwiki": (
        "https://github.com/langchain-ai/openwiki/blob/"
        "5c69350c757f3361360de26fc170e1aab6843bbc/"
    ),
}

BENCHMARK_FILES = [
    "mcp-coexistence-results.json",
    "results.json",
    "role-claude-review.md",
    "role-results.json",
    "score_results.py",
    "score_role_benchmark.py",
]

PROMPTS = [
    "role_graphify_architecture.txt",
    "role_openwiki_onboarding.txt",
    "role_serena_multifile_refactor.txt",
]

RUNS = [
    "role_graphify_specialist_r1",
    "role_graphify_trio_r1",
    "role_openwiki_specialist_r1",
    "role_openwiki_trio_r1",
    "role_serena_v2_specialist_r1",
    "role_serena_v2_trio_r1",
]


class LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []
        self.ids: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if values.get("href"):
            self.links.append(values["href"] or "")
        if values.get("id"):
            self.ids.append(values["id"] or "")


def copy_file(source: Path, destination: Path, source_root: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    text = source.read_text()
    text = text.replace(str(source_root), "/local-study")
    text = re.sub(r"/Users/[^/]+", "/home/user", text)
    destination.write_text(text)


def public_html(source_root: Path) -> str:
    report = source_root / "rapport-graphify-serena-openwiki-20260903.html"
    html = report.read_text()
    for project, prefix in COMMITS.items():
        pattern = re.compile(rf'href="{project}/([^"#]+)(#[^"]+)?"')

        def replace(match: re.Match[str]) -> str:
            fragment = match.group(2) or ""
            return f'href="{prefix}{match.group(1)}{fragment}"'

        html = pattern.sub(replace, html)
    html = html.replace(str(source_root), "/path/to/study-token")
    html = re.sub(
        r"/Users/[^/]+/\.nvm/versions/node/[^/]+/bin",
        "/path/to/node/bin",
        html,
    )
    canonical = (
        '  <link rel="canonical" '
        'href="https://studio.oratelecom.net/tokenwar/study-usecase/">\n'
    )
    return html.replace("  <title>", canonical + "  <title>", 1)


def validate(output: Path) -> None:
    parser = LinkParser()
    parser.feed((output / "index.html").read_text())
    if len(parser.ids) != len(set(parser.ids)):
        raise RuntimeError("duplicate HTML ids")
    missing: list[str] = []
    for href in parser.links:
        if href.startswith(("http://", "https://", "mailto:", "#")):
            continue
        relative = unquote(href.split("#", 1)[0])
        if relative and not (output / relative).exists():
            missing.append(href)
    if missing:
        raise RuntimeError(f"missing local links: {missing}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=REPO / "study-usecase")
    args = parser.parse_args()
    source_root = args.source.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / "index.html").write_text(public_html(source_root))

    benchmark = source_root / "benchmark"
    for name in BENCHMARK_FILES:
        copy_file(benchmark / name, output / "benchmark" / name, source_root)
    for name in PROMPTS:
        copy_file(
            benchmark / "prompts" / name,
            output / "benchmark" / "prompts" / name,
            source_root,
        )
    for name in RUNS:
        copy_file(
            benchmark / "runs" / name / "answer.md",
            output / "benchmark" / "runs" / name / "answer.md",
            source_root,
        )
    validate(output)
    print(f"Built {output / 'index.html'} with auditable benchmark evidence")


if __name__ == "__main__":
    main()
