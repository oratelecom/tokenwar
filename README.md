<h1 align="center">TokenWar</h1>

<p align="center"><img src="docs/logo.png" alt="TokenWar logo" width="160"></p>
<p align="center"><img src="docs/tokenwar-stack.png" alt="TokenWar token-saving stack" width="100%"></p>

[![CI](https://github.com/oratelecom/tokenwar/actions/workflows/ci.yml/badge.svg)](https://github.com/oratelecom/tokenwar/actions/workflows/ci.yml)

**Seven complementary token-saving tools plus a shared project-memory layer.**
TokenWar reduces shell output, heavy context, repeated memory, provider payloads,
verbose responses, oversized code, and repository exploration. OpenWiki adds a
durable wiki that lets an entire team reuse the cost of understanding a project.

## Documentation menu

| Page | Use it for |
| --- | --- |
| [Install](docs/installation.md) | Default behavior, `--all`, optional flags, verification |
| [Project memory](docs/project-memory.md) | Graphify + OpenWiki, team workflow, CI, costs and refresh policy |
| [Tool map](docs/tokenwar-tools.md) | What each tool saves and when to use it |
| [Savings](docs/savings.md) | Why the lanes stack and how gains are measured honestly |
| [Commands](docs/operations.md) | Status, gain, doctor, providers and maintenance |
| [Local scan](docs/scan.md) | Log audit, recommendations and break-even method |
| [Copilot](docs/copilot.md) | GitHub Copilot CLI wiring |

## Quick start

Install everything, including Graphify and OpenWiki:

```bash
curl -fsSL https://raw.githubusercontent.com/oratelecom/tokenwar/main/install.sh | bash -s -- --all
source ~/.bashrc
tokenwar status
tokenwar check
tokenwar gain
```

A bare install is intentionally non-invasive: it installs TokenWar and its shell
integration, but none of the managed tools. See [installation modes](docs/installation.md).

## The stack

| Tool | Lane |
| --- | --- |
| caveman | Compact model responses |
| RTK | Compress shell and tool output |
| context-mode | Keep heavy data outside the context window |
| claude-mem | Preserve personal cross-session memory |
| pxpipe | Reduce provider-bound prompt payloads |
| Graphify | Query repository structure instead of repeatedly sweeping files |
| ponytail | Produce smaller code that stays cheaper to read |
| **OpenWiki** | **Create shared, versioned project memory for the whole team** |

OpenWiki is deliberately shown separately from the seven live compression lanes.
It spends tokens to synthesize grounded Markdown, then amortizes that cost across
developers, agents, providers, sessions, onboarding, reviews and incidents.

```text
claude-mem = what my agent learned
OpenWiki   = what the team knows about the project
```

## Recommended project routine

Inside every active, long-lived repository:

```bash
graphify .             # initial structural graph
openwiki --init        # initial grounded project wiki (uses an LLM)

graphify update .      # after code changes; AST update needs no LLM
openwiki --update      # after merges; clean no-op uses no LLM
```

For teams, commit the OpenWiki output and run updates in CI so one generation is
shared by everyone. Details and a CI pattern are in
[Project memory](docs/project-memory.md).

## Commands

```bash
tokenwar status
tokenwar test
tokenwar check
tokenwar gain
tokenwar doctor
tokenwar scan
tokenwar upgrade
```

TokenWar never fabricates savings. Native telemetry is reported where available;
otherwise the result is `N/A` or an explicitly labelled estimate.

## License

[MIT](LICENSE) — © 2026 Ora Telecom.
