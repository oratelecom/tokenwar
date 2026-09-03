#!/usr/bin/env python3
"""Deterministic checklist scorer for the fixed Click benchmark."""

from __future__ import annotations

import csv
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent
RUNS = ROOT / "runs"
CONDITIONS = [
    "graphify_solo",
    "serena_solo",
    "openwiki_solo",
    "graphify_serena",
    "graphify_openwiki",
    "serena_openwiki",
    "all_tools",
]


def has(text: str, *patterns: str) -> bool:
    return all(re.search(pattern, text, re.I | re.S) is not None for pattern in patterns)


def score(answer: str) -> tuple[int, dict[str, list[dict[str, object]]]]:
    sections = {
        "A": [
            ("make_context", has(answer, r"make_context")),
            ("parse_args", has(answer, r"parse_args")),
            ("Group.invoke", has(answer, r"Group\.invoke")),
            ("resolve_command", has(answer, r"resolve(?:s|d)? (?:the )?command|resolve_command")),
            ("invoked_subcommand", has(answer, r"invoked_subcommand")),
            ("child context", has(answer, r"child context|sub_ctx")),
            ("callback via Context.invoke", has(answer, r"ctx\.invoke|Context\.invoke")),
            ("EOF/KeyboardInterrupt to Abort", has(answer, r"EOF|KeyboardInterrupt|keyboard interrupt", r"Abort")),
            ("ClickException behavior", has(answer, r"ClickException", r"exit|propagat|standalone")),
            ("EPIPE and explicit Exit behavior", has(answer, r"EPIPE|broken.?pipe", r"\bExit\b|exit code")),
        ],
        "B": [
            ("core.py:1415", has(answer, r"src/click/core\.py:1415\b")),
            ("core.py:2001", has(answer, r"src/click/core\.py:2001\b")),
            ("decorators.py:93", has(answer, r"src/click/decorators\.py:93\b")),
            ("decorators.py:119", has(answer, r"src/click/decorators\.py:119\b")),
            (
                "complete four-site inventory",
                sum(
                    has(answer, p)
                    for p in [
                        r"src/click/core\.py:1415\b",
                        r"src/click/core\.py:2001\b",
                        r"src/click/decorators\.py:93\b",
                        r"src/click/decorators\.py:119\b",
                    ]
                )
                == 4
                and not has(answer, r"src/click/decorators\.py:67\b\s+—\s+(?!.*docstring)"),
            ),
        ],
        "C": [
            ("sys mode Python streams", has(answer, r"sys", r"Python-level|Python stream")),
            ("fd mode descriptors 1 and 2", has(answer, r"fd", r"descriptors? 1 and 2|fd 1/2")),
            ("temporary file and dup2", has(answer, r"temporary", r"dup2")),
            ("fd capture before isolation", has(answer, r"before (?:stream )?isolation|installed before")),
            ("saved original descriptor", has(answer, r"saved|original descriptor")),
            ("restore/stop", has(answer, r"restore|restores", r"stop|teardown")),
            ("stdout/stderr/result merge", has(answer, r"stdout", r"stderr", r"output_bytes|mixed|combined")),
            ("direct/native/subprocess output", has(answer, r"subprocess", r"direct|native|C extension|stale")),
            ("Windows restriction", has(answer, r"Windows", r"reject|unsupported|unavailable|not supported")),
            ("thread/concurrency limitation", has(answer, r"thread|concurr", r"global|process")),
        ],
    }
    detailed: dict[str, list[dict[str, object]]] = {}
    total = 0
    for name, checks in sections.items():
        weight = 2 if name == "B" else 1
        detailed[name] = []
        for label, passed in checks:
            points = weight if passed else 0
            total += points
            detailed[name].append({"criterion": label, "passed": passed, "points": points})
    return total, detailed


def completed_calls(events_file: Path) -> tuple[int, dict[str, int]]:
    counts: dict[str, int] = {}
    total = 0
    for line in events_file.read_text().splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        item = event.get("item")
        if event.get("type") != "item.completed" or not isinstance(item, dict):
            continue
        if item.get("type") not in {"command_execution", "mcp_tool_call"}:
            continue
        label = str(item.get("server") or "shell")
        counts[label] = counts.get(label, 0) + 1
        total += 1
    return total, counts


def main() -> None:
    rows: list[dict[str, object]] = []
    details: dict[str, object] = {}
    for condition in CONDITIONS:
        run_dir = RUNS / condition
        if not (run_dir / "metadata.json").exists():
            continue
        metadata = json.loads((run_dir / "metadata.json").read_text())
        answer = (run_dir / "answer.md").read_text()
        points, checklist = score(answer)
        usage = metadata["usage"]
        calls, calls_by_source = completed_calls(run_dir / "events.jsonl")
        row = {
            "condition": condition,
            "score": points,
            "max_score": 30,
            "elapsed_seconds": metadata["elapsed_seconds"],
            "input_tokens": usage.get("input_tokens", 0),
            "cached_input_tokens": usage.get("cached_input_tokens", 0),
            "fresh_input_tokens": usage.get("input_tokens", 0)
            - usage.get("cached_input_tokens", 0),
            "output_tokens": usage.get("output_tokens", 0),
            "reasoning_output_tokens": usage.get("reasoning_output_tokens", 0),
            "completed_tool_calls": calls,
            "calls_by_source": calls_by_source,
        }
        rows.append(row)
        details[condition] = checklist

    (ROOT / "results.json").write_text(
        json.dumps({"rows": rows, "checklists": details}, indent=2, ensure_ascii=False)
        + "\n"
    )
    if rows:
        with (ROOT / "results.csv").open("w", newline="") as file:
            writer = csv.DictWriter(file, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
    print(json.dumps(rows, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
