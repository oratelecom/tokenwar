#!/usr/bin/env python3
"""Score the role-aligned specialist-vs-trio benchmark."""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parent
RUNS = ROOT / "runs"
TARGETS = ROOT / "role-targets"


def has(text: str, *patterns: str) -> bool:
    return all(re.search(pattern, text, re.I | re.S) is not None for pattern in patterns)


def answer_checks(role: str, answer: str) -> list[tuple[str, bool]]:
    if role == "graphify":
        return [
            ("Command.main is the CLI boundary", has(answer, r"Command\.main", r"argv|entry|boundary")),
            ("sys.argv and Windows expansion", has(answer, r"sys\.argv", r"Windows", r"expand")),
            ("shell completion short-circuit", has(answer, r"shell completion", r"before|early|short")),
            ("make_context creates parsing context", has(answer, r"make_context", r"Context|context")),
            ("parser/parse_args stage", has(answer, r"parse_args|OptionParser|parser")),
            ("plain Command.invoke", has(answer, r"Command\.invoke", r"callback")),
            ("Group.parse_args token staging", has(answer, r"Group\.parse_args|group pars", r"protected_args|stages?|token")),
            ("Group.invoke dispatch", has(answer, r"Group\.invoke", r"dispatch|subcommand|chain")),
            ("resolve_command", has(answer, r"resolve_command|resolves? (?:the )?subcommand")),
            ("child context parent relationship", has(answer, r"child context|sub_ctx", r"parent")),
            ("Context.invoke callback boundary", has(answer, r"Context\.invoke", r"callback")),
            ("active context scope", has(answer, r"active context|push|pop|scope|with .*context")),
            ("EOF/keyboard interrupt becomes Abort", has(answer, r"EOF|KeyboardInterrupt|keyboard interrupt", r"Abort")),
            ("ClickException standalone handling", has(answer, r"ClickException", r"standalone|exit|show")),
            ("EPIPE/broken pipe handling", has(answer, r"EPIPE|broken.?pipe", r"exit|pacif")),
            ("explicit Exit translation", has(answer, r"\bExit\b", r"standalone|exit code|return")),
            ("CliRunner.invoke calls Command.main", has(answer, r"CliRunner\.invoke", r"Command\.main")),
            ("runner isolation/capture impact", has(answer, r"isolation|capture", r"test|risk|surface")),
            ("shell_completion audit module", has(answer, r"shell_completion")),
            ("prioritized audit list", has(answer, r"priorit|audit")),
        ]
    if role == "openwiki":
        return [
            ("sys is default", has(answer, r"sys", r"default")),
            ("sys captures Python streams", has(answer, r"sys", r"Python.*stream|sys\.stdout")),
            ("sys misses direct fd/native paths", has(answer, r"sys", r"direct fd|native|C extension|subprocess|stale")),
            ("fileno limitation", has(answer, r"fileno", r"Unsupported|not|raise")),
            ("fd redirects descriptors 1 and 2", has(answer, r"fd", r"descriptors? 1 and 2|fd 1/2")),
            ("fd uses temporary files/dup2", has(answer, r"temporary|tmpfile|dup2")),
            ("fd captures subprocess/native/stale", has(answer, r"fd", r"subprocess", r"native|C extension|stale")),
            ("fd unavailable on Windows", has(answer, r"Windows", r"unavailable|unsupported|reject")),
            ("global state is not thread safe", has(answer, r"thread|concurr", r"global|process")),
            ("process parallelism recommendation", has(answer, r"process", r"parallel|thread")),
            ("teardown restores state/descriptors", has(answer, r"teardown|finally|restore", r"descriptor|stream|state")),
            ("captured fd bytes appended/combined", has(answer, r"append|merge|combined", r"stdout|stderr|buffer")),
            ("SystemExit/exception Result behavior", has(answer, r"SystemExit|exception", r"Result|exit code|exit_code")),
            ("CliRunner.invoke reaches Command.main", has(answer, r"CliRunner\.invoke", r"Command\.main")),
            ("dispatch and Context.invoke connection", has(answer, r"Group\.invoke|Command\.invoke", r"Context\.invoke")),
            ("practical test recommendation", has(answer, r"recommend|guidance|choose|use `?sys|use `?fd")),
            ("interleaving limitation", has(answer, r"interleav", r"not|cannot|isn.t")),
            ("wiki citations", has(answer, r"openwiki/|CliRunner Isolation and Capture Strategies|cli-runner-isolation\.md")),
        ]
    raise ValueError(role)


def telemetry_row(name: str, role: str, mode: str, repetition: int) -> dict[str, object]:
    run_dir = RUNS / name
    metadata = json.loads((run_dir / "metadata.json").read_text())
    usage = metadata.get("usage", {})
    calls: dict[str, int] = {}
    for item in metadata.get("tool_calls", []):
        source = str(item.get("server") or "shell")
        calls[source] = calls.get(source, 0) + 1
    return {
        "name": name,
        "role": role,
        "mode": mode,
        "repetition": repetition,
        "elapsed_seconds": metadata.get("elapsed_seconds", 0),
        "return_code": metadata.get("return_code"),
        "token_telemetry_available": bool(usage),
        "input_tokens": usage.get("input_tokens", 0),
        "cached_input_tokens": usage.get("cached_input_tokens", 0),
        "fresh_input_tokens": usage.get("input_tokens", 0) - usage.get("cached_input_tokens", 0),
        "output_tokens": usage.get("output_tokens", 0),
        "tool_calls": sum(calls.values()),
        "calls_by_source": calls,
    }


def usage_row(name: str, role: str, mode: str, repetition: int) -> dict[str, object]:
    row = telemetry_row(name, role, mode, repetition)
    answer = (RUNS / name / "answer.md").read_text()
    checks = answer_checks(role, answer)
    row.update({
        "score": sum(passed for _, passed in checks),
        "max_score": len(checks),
        "checks": [{"criterion": label, "passed": passed} for label, passed in checks],
    })
    return row


def refactor_row(name: str, mode: str, repetition: int) -> dict[str, object]:
    row = telemetry_row(name, "serena", mode, repetition)
    target = TARGETS / f"{'serena_multi_solo' if mode == 'specialist' else 'trio_multi'}_r{repetition}"
    source_and_tests = "\n".join(
        path.read_text()
        for base in (target / "src", target / "tests")
        for path in base.rglob("*.py")
    )
    core = (target / "src/click/core.py").read_text()
    utils = (target / "src/click/utils.py").read_text()
    expand_tests = (target / "tests/test_utils/test__expand_args.py").read_text()
    diff_names = subprocess.run(
        ["git", "diff", "--name-only", "HEAD", "--", "src", "tests"],
        cwd=target, text=True, capture_output=True, check=True,
    ).stdout.splitlines()
    test = subprocess.run(
        ["uv", "run", "--frozen", "pytest", "tests/test_utils/test__expand_args.py", "tests/test_commands.py", "-q"],
        cwd=target, text=True, capture_output=True,
    )
    diff_check = subprocess.run(
        ["git", "diff", "--check", "HEAD"], cwd=target, text=True, capture_output=True
    )
    metadata = json.loads((RUNS / name / "metadata.json").read_text())
    completed = row["return_code"] == 0
    called_tools = {
        str(item.get("tool"))
        for item in metadata.get("tool_calls", [])
        if item.get("server") == "serena" and item.get("status") == "completed"
    }
    checks = [
        ("new function definition", completed and "def _expand_windows_args(" in utils),
        ("production import updated", completed and "from .utils import _expand_windows_args" in core),
        ("production call updated", completed and "args = _expand_windows_args(args)" in core),
        ("test references updated", completed and expand_tests.count("click.utils._expand_windows_args") == 6),
        ("old symbol absent from source/tests", completed and re.search(r"(?<![A-Za-z0-9_])_expand_args\b", source_and_tests) is None),
        ("only three expected files changed", completed and diff_names == ["src/click/core.py", "src/click/utils.py", "tests/test_utils/test__expand_args.py"]),
        ("semantic rename tool used", completed and "rename_symbol" in called_tools),
        ("independent targeted tests pass", completed and test.returncode == 0),
        ("diff has no whitespace errors", completed and bool(diff_names) and diff_check.returncode == 0),
        ("semantic navigation/reference lookup used", completed and {"find_symbol", "find_referencing_symbols"}.issubset(called_tools)),
    ]
    row.update({
        "role": "serena",
        "score": sum(passed for _, passed in checks),
        "max_score": len(checks),
        "checks": [{"criterion": label, "passed": passed} for label, passed in checks],
        "changed_source_files": diff_names,
        "independent_test_return_code": test.returncode,
        "independent_test_output": (test.stdout + test.stderr)[-2000:],
    })
    return row


def summarize(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    summaries: list[dict[str, object]] = []
    for role in ("graphify", "serena", "openwiki"):
        for mode in ("specialist", "trio"):
            selected = [r for r in rows if r["role"] == role and r["mode"] == mode]
            if not selected:
                continue
            def mean(key: str, telemetry_only: bool = False) -> float | None:
                values = [
                    float(r[key]) for r in selected
                    if not telemetry_only or r["token_telemetry_available"]
                ]
                return round(sum(values) / len(values), 2) if values else None
            completed = [r for r in selected if r["return_code"] == 0]
            summaries.append({
                "role": role,
                "mode": mode,
                "runs": len(selected),
                "completed_runs": len(completed),
                "fully_successful_runs": sum(
                    r["return_code"] == 0 and r["score"] == r["max_score"]
                    for r in selected
                ),
                "mean_score": mean("score"),
                "mean_score_completed": round(
                    sum(float(r["score"]) for r in completed) / len(completed), 2
                ) if completed else None,
                "max_score": selected[0]["max_score"],
                "mean_elapsed_seconds": mean("elapsed_seconds"),
                "token_telemetry_runs": sum(r["token_telemetry_available"] for r in selected),
                "mean_fresh_input_tokens": mean("fresh_input_tokens", telemetry_only=True),
                "mean_cached_input_tokens": mean("cached_input_tokens", telemetry_only=True),
                "mean_output_tokens": mean("output_tokens", telemetry_only=True),
                "mean_tool_calls": mean("tool_calls"),
            })
    return summaries


def main() -> None:
    rows: list[dict[str, object]] = []
    for role in ("graphify", "openwiki"):
        for mode in ("specialist", "trio"):
            for repetition in (1, 2, 3):
                name = f"role_{role}_{mode}_r{repetition}"
                rows.append(usage_row(name, role, mode, repetition))
    for mode in ("specialist", "trio"):
        for repetition in (1, 2, 3):
            name = f"role_serena_v2_{mode}_r{repetition}"
            rows.append(refactor_row(name, mode, repetition))
    output = {"protocol": "role-aligned specialist versus all-three, n=3", "rows": rows, "summary": summarize(rows)}
    (ROOT / "role-results.json").write_text(json.dumps(output, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(output["summary"], indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
