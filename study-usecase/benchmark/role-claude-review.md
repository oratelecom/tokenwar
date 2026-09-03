# Claude challenge of the role-aligned benchmark

## Audit 1: FAIL

Claude Opus 5 rejected the first role-aligned version for four material reasons:

- the Serena rename covered only two occurrences in one file;
- the OpenWiki label did not clearly say that query-time retrieval was a read of
  the generated Markdown corpus, not an OpenWiki MCP query;
- the OpenWiki scorer required the literal word `dup2` even when the answer
  correctly described temporary-file descriptor redirection;
- the observed trio routing favored Serena even on the Graphify/OpenWiki tasks,
  so the measurements did not prove the proposed “route to the named
  specialist” rule.

Claude usage for this audit: 52,067 cache-created input tokens, 873,842
cache-read input tokens, 11,761 output tokens, 146.0 s API duration, $1.251816
reported cost.

## Corrections applied

- Serena now renames `_expand_args` across `utils.py`, `core.py`, and six test
  references; the scorer verifies three changed files and runs 104 Click tests.
- The report and README distinguish OpenWiki generation from Markdown retrieval
  and report the 315.46 s generation cost separately.
- The OpenWiki implementation-detail criterion accepts an accurate temporary
  file description without requiring one identifier spelling.
- Conclusions no longer claim that this benchmark proves a role-based router or
  the necessity of all three tools.
- A Serena-specialist run stuck before editing was manually stopped at 352.4 s
  and retained as a reliability failure.

## Audit 2: PASS WITH RESERVATIONS

Claude accepted the structural corrections, but found that the scorer searched
raw event text for Serena tool names. Serena's own instruction payload mentions
those names, causing false positives in the stopped run. Claude also noted that
unchanged-code tests and an empty `git diff --check` should not earn points.

The scorer was corrected again: it now reads completed typed MCP calls from
metadata and conditions every Serena postcondition on a completed agent run and
a non-empty expected diff. The interrupted run therefore scores 0/10, not 4/10;
the two other specialist runs and all three trio runs remain 10/10.

Claude usage for the second audit: 42,088 cache-created input tokens, 778,992
cache-read input tokens, 8,488 output tokens, 117.6 s API duration, $1.022756
reported cost.

## Accepted final reservations

- `n=3`, one repository and one commit: results are descriptive, not universal
  or statistically significant.
- Graphify and generated-wiki answers are checklist-scored prose; only Serena
  has postconditions verified on disk.
- Specialist and trio policies differ by design because one restricts available
  sources and the other allows routing; this is a practical routing comparison,
  not a strict identical-tool experiment.
- In the trio runs, the agent often used Serena for tasks labeled Graphify or
  OpenWiki without a quality loss. The data therefore do not prove that the
  named specialist is necessary for those two scenarios.

One factual Claude statement was not accepted: its second response said the
strengthened Serena run executed 161 tests. The preserved independent output is
`104 passed`; the report uses 104.
