# Decision memo: `CliRunner` capture strategy

## Recommendation

Use default `sys` capture for ordinary Click tests. Use `fd` only when code under test—or a dependency—may bypass the current Python stream objects.

| Mode | Captures | Misses / limitations |
|---|---|---|
| `sys` | `print`, `click.echo`, and writes through the current `sys.stdout` or `sys.stderr` | Direct writes to fd 1/2, cached or stale stream references, subprocess output, native extensions, and pre-existing logging handlers. `fileno()` raises `UnsupportedOperation`. |
| `fd` | Everything above, plus direct fd 1/2 writes, stale references, logging handlers, C extensions, and subprocesses using those descriptors | Does not reconstruct true interleaving between Python-level and fd-level writes. It is unavailable on Windows. Output sent somewhere other than the redirected stdout/stderr descriptors is outside the documented capture boundary. |

Source: [CliRunner Isolation and Capture Strategies](openwiki/testing/cli-runner-isolation.md).

## Setup, teardown, and result streams

For both modes, `CliRunner.invoke`:

1. Builds isolated stdin/stdout/stderr wrappers over in-memory buffers.
2. Applies environment overrides, fixed formatting width, prompt/input hooks, color handling, and debugger-stream handling.
3. Calls `Command.main`.
4. Restores all saved streams, environment values, Click hooks, formatting state, and debugger construction in a `finally` path.
5. Returns a `Result`.

Separate stdout and stderr buffers copy Python-level writes into a third mixed buffer in write order. Consequently:

- `Result.stdout_bytes` and `Result.stderr_bytes` remain separately assertable.
- The combined `Result.output` reflects Python-level stdout/stderr ordering.
- Text properties decode using the runner charset, replace decoding errors, and normalize CRLF to LF.

With `fd`, descriptors 1 and 2 are redirected to temporary files before Python stream isolation. During teardown, the wrappers are flushed, the original descriptors restored, and captured fd bytes appended to their corresponding in-memory buffers. These appends also enter the mixed buffer. Thus fd output is retained and separated correctly, but its chronology relative to earlier Python-level writes is not reconstructed.

The wiki does not document stronger ordering guarantees, temporary-file capacity behavior, or capture behavior after abnormal process termination.

## Portability and concurrency

- `sys` is the portable default.
- `fd` is rejected on Windows; the wiki provides no more detailed supported-platform matrix.
- Both modes mutate process-global streams, environment, formatting state, and hooks. Concurrent invocations in threads are unsupported and may corrupt each other.
- Prefer process-based parallelism.
- Prefer test-managed temporary directories and absolute paths over the deprecated `isolated_filesystem()` helper, which changes the process-wide current directory.

## Exceptions and results

`invoke` shell-splits string arguments; argument sequences pass through unchanged. `prog_name` defaults to the command name or `"root"`, and extra keyword arguments are forwarded to `Command.main`.

- `SystemExit` always becomes a result exit code.
- A nonzero `SystemExit` is also retained as the result exception.
- Other exceptions are captured with exit code 1 when `catch_exceptions` is enabled; otherwise they are re-raised.
- `Result` contains the callback return value, exit code, exception, traceback tuple, and stdout, stderr, and combined output bytes.

## Runtime connection

The exercised path is the real in-process CLI path:

```text
CliRunner.invoke
  → Command.main
  → make_context + argument parsing
  → Command.invoke or Group.invoke
  → Context.invoke(callback)
  → Result
```

A leaf command passes parsed `ctx.params` through `Context.invoke`. A regular group runs its own callback, creates a child context, dispatches one subcommand, and optionally processes its result. A chained group prepares child contexts, invokes callbacks in order, and sends their result list to its result callback.

Programmatic `Context.invoke` behaves differently by target:

- A callable runs in the current context with supplied arguments.
- A `Command` gets a child context; missing exposed parameters receive typed defaults.
- `Context.forward` additionally copies matching values from the current context before delegating.

See [Command.main and Group.invoke Execution Path](openwiki/execution/command-and-group-dispatch.md) and [Context.invoke and Programmatic Calls](openwiki/execution/context-invoke.md).

## Practical testing guidance

- Start with `sys`; assertions remain simple and portable.
- Select `fd` only for a demonstrated fd-boundary requirement.
- Assert `stdout` and `stderr` separately when channel correctness matters.
- Do not assert exact mixed ordering across Python-level and fd-level writes.
- Add focused coverage when behavior involves direct fd writes, stale streams, logging handlers, subprocesses, native code, `faulthandler`, nested runners, or interaction with Pytest `capsys`/`capfd`.
- Avoid thread-parallel runner calls; isolate them in processes.

The concise repository-level map is [Click Runtime Quickstart](openwiki/quickstart.md).