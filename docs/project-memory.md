# Shared project memory

Graphify and OpenWiki solve two different forms of repeated repository reading.
Use both on active projects.

## Why this saves tokens

Without durable project memory, every agent repeatedly discovers the tree, entry
points, architecture, data flows and invariants. OpenWiki spends tokens once to
turn that understanding into grounded Markdown. The resulting wiki is committed,
reviewed and reused by every developer and every compatible agent.

```text
source code
    ├── Graphify → structural graph → bounded architecture queries
    └── OpenWiki → grounded Markdown → shared team understanding
```

The useful accounting is:

```text
OpenWiki net gain
= repeated repository-reading tokens avoided
- wiki generation and changed-update tokens
```

The cost normally amortizes faster as the repository, team, agent count and
project lifetime grow. A tiny throwaway repository or one-off task may not break
even.

## OpenWiki is team memory

[OpenWiki](https://github.com/langchain-ai/openwiki) is comparable to shared
project memory, not shared chat history:

| claude-mem | OpenWiki |
| --- | --- |
| Personal/session memory | Project-owned team memory |
| Usually local | Plain Markdown committed in Git |
| Remembers observations and decisions | Documents architecture, flows and invariants |
| Helps one agent resume | Helps humans and agents across providers |

Grounded Claims connect important statements to versioned repository evidence.
That makes the wiki a reviewable reference instead of an opaque conversation log.

Do not inject the whole wiki into every prompt. Read its index first and open only
the pages relevant to the task; blindly loading everything would erase part of
the gain.

## Cost behavior

`openwiki --init` invokes a planning agent and page-writing agents, so it consumes
LLM tokens. A changed `openwiki --update` also consumes tokens for the affected
work. A clean update checks Git state and Claims locally, skips model work, and
costs zero LLM tokens.

Using a coding-agent integration may draw on an authenticated subscription rather
than a metered API key, but it still consumes that provider's token quota. Local
models avoid an API invoice but still consume compute.

## Install and initialize

TokenWar pins the reviewed OpenWiki release:

```bash
bash install.sh --with-openwiki
cd /path/to/repository
openwiki --init
```

Installation never initializes a repository automatically: initialization writes
generated documentation and invokes an LLM, so it remains an explicit project
decision. OpenWiki requires Node.js 22 or newer.

For a coding-agent integration, follow its native integration command after
installing the CLI, for example:

```bash
openwiki integrations install codex
```

## Graphify lifecycle

Graphify is the structural lane:

```bash
graphify .
graphify update .
```

Its AST extraction and code-only update are deterministic and use no LLM. Semantic
extraction for documents, papers or images may use an LLM. Do not describe every
Graphify scan as free; only the structural/code-only path has that guarantee.

Use Graphify before broad `rg`, `find`, `sed` and file-reading sweeps. Refresh its
index after the final code change so the next task queries current structure.

## Team and CI workflow

Recommended lifecycle:

1. Initialize Graphify and OpenWiki once on the canonical repository.
2. Commit OpenWiki's generated Markdown and grounded Claim metadata.
3. After code changes, refresh Graphify's structural index.
4. After merges, run `openwiki --update` in CI.
5. Publish wiki changes as a documentation-only PR so normal checks and review
   rules still apply.
6. Let every developer and agent read the same reviewed wiki.

OpenWiki ships maintained CI examples. Copy and pin the workflow appropriate for
your forge rather than hand-building a second updater:

- [GitHub Actions update PR](https://github.com/langchain-ai/openwiki/blob/main/examples/openwiki-update.yml)
- [GitHub Actions with auto-merge](https://github.com/langchain-ai/openwiki/blob/main/examples/openwiki-update-auto-merge.yml)
- [GitLab CI](https://github.com/langchain-ai/openwiki/blob/main/examples/openwiki-update.gitlab-ci.yml)
- [Bitbucket Pipelines](https://github.com/langchain-ai/openwiki/blob/main/examples/openwiki-update.bitbucket-pipelines.yml)

Prefer a scheduled or post-merge job over regenerating the wiki independently in
every PR branch. The project pays once, reviews once and shares the result with the
whole team.

## Recommended policy

For active team repositories:

- Graphify initial scan once, then structural update after code changes.
- OpenWiki initial generation once, then update after merges or on a schedule.
- Treat a clean OpenWiki no-op as cheap and a changed update as metered work.
- Keep generated knowledge reviewable in Git.
- Measure provider usage before claiming a cumulative net saving.

TokenWar strongly recommends OpenWiki when it is absent from a long-lived team
project because it mutualizes the cost of understanding that project.
