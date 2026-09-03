# Decision memo: `CliRunner` capture strategy

**Default to `sys` capture.** Use `fd` only when the code under test can bypass the current Python streams.

| Mode | Captures | Misses / limitation |
|---|---|---|
| `sys` | `print`, `click.echo`, and writes through the current `sys.stdout` or `sys.stderr` | Direct writes to descriptors 1/2, cached or stale stream references, native extensions, and subprocess output. Its wrappers do not provide a usable `fileno()`. |
| `fd` | Everything above, plus direct fd writes, stale stream/logging references, C extensions, subprocesses, and consumers such as `faulthandler` | Unsupported on Windows. It does not reconstruct exact interleaving between Python-level and fd-level writes. |

## Lifecycle and results

`CliRunner.invoke()` optionally redirects descriptors 1 and 2 for `fd` capture, then enters `isolation()`. Isolation replaces `sys.stdin`, `stdout`, and `stderr`; applies environment overrides; fixes formatting width at 80; patches prompt and character-input hooks; controls ANSI stripping; and redirects default debugger streams. Its `finally` path restores all saved process state.

Python stdout and stderr writes go to separate byte buffers and are copied, in write order, into a mixed buffer used for `Result.output`.

For `fd` mode, teardown flushes the Python wrappers, restores descriptors 1 and 2, reads the temporary capture files, and appends those bytes to the corresponding Python buffers; those appends also enter the mixed output. Therefore:

- `Result.stdout` and `Result.stderr` remain separately assertable.
- `Result.output` preserves Python-level stdout/stderr order.
- Exact chronology across Python and fd emissions is unavailable.

The wiki does not specify the precise ordering between the final fd-1 and fd-2 append operations, so tests should not depend on it.

## Invocation and exception behavior

The runner shell-splits string arguments, passes sequence arguments unchanged, derives `prog_name`, and calls `Command.main(...)`. `SystemExit` becomes a result exit code; a nonzero exit is retained as the result exception. Other exceptions are either re-raised or captured as exit code 1 according to `catch_exceptions`.

`Result` contains callback return value, exit code, exception, traceback information, and raw stdout/stderr/mixed bytes. Text accessors use the runner charset, replace decoding errors, and normalize CRLF to LF.

The execution path is:

```text
CliRunner.invoke
  → Command.main
  → make_context / argument parsing
  → Command.invoke or Group.invoke
  → Context.invoke
  → callback
```

A regular group resolves one child command; a chained group prepares child contexts and then invokes callbacks in order, passing their return-value list to its result callback. `Context.invoke` is the callback boundary: it reuses the current context for a callable, or creates a child context and fills/type-casts missing defaults for a `Command`.

## Operational guidance

- Use `sys` for ordinary Click commands. It is simpler and portable.
- Add focused `fd` tests only where a dependency uses logging handlers bound early, `os.write`, native code, subprocesses, cached streams, or `faulthandler`.
- Assert stdout and stderr separately. In `fd` mode, avoid assertions about Python/fd cross-level ordering.
- Do not overlap runners in threads: streams, environment, hooks, formatting, debugger state, descriptors, and current directory are process-global. Use process-based parallelism.
- Prefer test-framework temporary directories and absolute paths. The deprecated `isolated_filesystem()` changes the process-wide working directory.
- If supporting Windows, retain `sys` coverage or conditionally skip the `fd`-specific cases.
- Existing focused coverage includes direct fd writes, stale stdout/logging references, stream separation, nested fd runners, `faulthandler`, and coexistence with Pytest `capsys`/`capfd`.

Durable references:

- [CliRunner Isolation and Capture Strategies](/local-study/benchmark/click-target/openwiki/testing/cli-runner-isolation.md)
- [Command.main and Group.invoke Execution Path](/local-study/benchmark/click-target/openwiki/execution/command-and-group-dispatch.md)
- [Context.invoke and Programmatic Calls](/local-study/benchmark/click-target/openwiki/execution/context-invoke.md)