## Connected execution map

```text
console entry / Command.__call__
        │
        ▼
Command.main
  ├─ args omitted → sys.argv[1:]
  │    └─ Windows + windows_expand_args → utils._expand_args
  ├─ utils._detect_program_name
  ├─ Command._main_shell_completion
  │    └─ shell_completion.shell_complete
  │         ├─ interpret completion environment instruction
  │         ├─ ShellComplete.complete
  │         │    ├─ get_completion_args
  │         │    ├─ get_completions
  │         │    │    ├─ _resolve_context
  │         │    │    └─ _resolve_incomplete
  │         │    └─ format_completion
  │         └─ exit immediately
  └─ Command.make_context
       ├─ construct Context
       ├─ temporarily activate it with scope(cleanup=False)
       └─ Command.parse_args / Group.parse_args
             │
             ▼
       Command.main → self.invoke(ctx)
          ├─ ordinary Command → Command.invoke → Context.invoke(callback)
          └─ Group → Group.invoke
               ├─ invoke group callback
               ├─ resolve_command
               ├─ child_command.make_context(parent=group_ctx)
               └─ child_command.invoke(child_ctx)
```

### Entry, argv, and completion

`Command.__call__` is the callable-command entry and delegates to `Command.main`.

When `main` receives no explicit arguments, it takes `sys.argv[1:]`. Only this implicit-argv branch performs Windows expansion: on Windows, when `windows_expand_args` is enabled, `click.utils._expand_args` simulates Unix-style environment-variable, user-directory, and glob expansion. Explicitly supplied argument sequences bypass that expansion. Program-name detection then goes through `click.utils._detect_program_name`.

Completion occurs before normal context construction and dispatch. `Command._main_shell_completion` derives or accepts the completion environment variable, reads its instruction, and calls `click.shell_completion.shell_complete`. A completion request selects a registered shell implementation and runs its `complete` path: parse the shell’s incomplete command line, resolve a completion context with `_resolve_context`, identify the incomplete option or argument with `_resolve_incomplete`, obtain completion items, format them for the shell, and exit. Consequently, a completion request never reaches the ordinary `main → make_context → invoke` path, although completion builds its own partial context hierarchy while resolving the incomplete command.

### Context construction and parsing

`Command.make_context` applies `context_settings`, constructs the command’s configured `context_class`, and calls `parse_args` while the new context is temporarily current through `Context.scope(cleanup=False)`. The no-cleanup scope matters: parameter and eager callbacks can access the current context during parsing, but resources registered on it are retained for later command execution.

Ordinary `Command.parse_args` builds the parser, parses options and arguments, and processes parameters in Click’s declared/eager ordering. Parameter handling populates `ctx.params`, tracks parameter sources, and may run callbacks or raise usage-oriented exceptions.

`Group.parse_args` adds dispatch staging after the ordinary parser:

- In non-chain mode, the first unconsumed token is staged as the prospective subcommand in `ctx._protected_args`; remaining tokens stay in `ctx.args`.
- In chain mode, all remaining tokens are protected for iterative command resolution and `ctx.args` is cleared.
- With no arguments and `no_args_is_help`, it raises `NoArgsIsHelpError` unless resilient parsing is active.

`Context.protected_args` exposes that internal staging but is not the primary storage used by group dispatch.

### Callback and subcommand dispatch

`Command.main` calls `self.invoke(ctx)`, so Python dispatch selects the implementation:

- For a plain command, `Command.invoke` emits the deprecation warning when applicable, then calls `ctx.invoke(command.callback, **ctx.params)`.
- For a group, `Group.invoke` owns both the group callback and subcommand lifecycle.

`Context.invoke` is therefore the common callback gateway. Given a direct callback, it uses the existing context. Given a `Command` object, it creates a subcontext with `_make_sub_context`, fills missing exposed parameters from that command’s defaults, updates the subcontext parameters, and invokes the command’s callback. Invocation occurs inside `augment_usage_errors` and an active `with ctx` scope.

`Context.forward` is layered on top: it copies matching values from the current context’s parameters, then calls `Context.invoke`.

For a non-chain group, `Group.invoke` combines the staged subcommand token with the remaining arguments, clears the staging fields, and calls `resolve_command`. Resolution normalizes the candidate token, delegates lookup to `get_command`, and may reparse when option-like tokens require it; failure becomes `NoSuchCommand`. The group records `ctx.invoked_subcommand`, invokes its own callback through the base `Command.invoke`, creates the selected command’s context with `parent=ctx`, activates that child, and calls the child command’s `invoke`.

For a chain group, resolution repeats. Each child context is created with extra arguments allowed and interspersed parsing disabled; its leftover arguments feed the next resolution. The prepared child contexts are then activated and invoked in sequence. Their return values form a list.

A group result callback runs through `ctx.invoke` after dispatch. It receives the single child result in ordinary mode or the result list in chain mode, plus the group parameters. With `invoke_without_command`, the group callback still runs; the result callback receives the group result in ordinary mode and an empty result list in chain mode.

### Context activation

Activation is operational, not cosmetic:

```text
Context.__enter__ → globals.push_context
Context.__exit__  → close handling → globals.pop_context
get_current_context reads that stack
```

This controls what callbacks, `pass_context`, `pass_obj`, `make_pass_decorator`, output color resolution, and other context-aware helpers observe. Root parsing, root execution, group callbacks, child callbacks, result callbacks, and programmatic `Context.invoke` calls all depend on the correct context being current. Contexts are deliberately re-entrant, so changing enter/exit depth or cleanup behavior could break nested invocation even when callback arguments remain correct.

### Exit and error translation

The normal standalone path is:

```text
callback return
  → Command.main receives result
  → Context.exit
  → context resources and close callbacks run
  → click.exceptions.Exit
  → SystemExit(exit_code) in standalone mode
```

With `standalone_mode=False`, an ordinary callback result is returned directly. A caught Click `Exit` is translated to its numeric exit code rather than `SystemExit`.

Other translations in `Command.main` are:

- `ClickException`, including usage and command-resolution errors: re-raised when standalone handling is disabled; otherwise shown through the exception’s formatter and converted to `SystemExit(exception.exit_code)`.
- `EOFError` or `KeyboardInterrupt`: converted to `Abort`.
- `Abort`: re-raised outside standalone mode; otherwise prints the aborted message and exits with status 1.
- Broken-pipe `OSError`: stdout and stderr are wrapped with `_PacifyFlushWrapper` to suppress secondary flush failures, then execution exits with status 1.
- Other `OSError` and unexpected exceptions propagate.

Because the root and child contexts are context managers, cleanup and registered close callbacks run while these results and failures unwind.

### `CliRunner` and the exposed test surface

`CliRunner.invoke` enters its stream/environment isolation, normalizes string arguments, determines the program name, and calls `cli.main` directly. It passes an explicit argument collection, so it exercises `Command.main` but normally does not exercise the implicit `sys.argv` or Windows-expansion branch.

By default, successful standalone execution still reaches `SystemExit(0)`. `CliRunner` catches `SystemExit`, normalizes its code, and captures non-integer exit payloads as output with status 1. It optionally catches other exceptions, records exception information, flushes captured streams, and constructs `Result` with return value, output streams, exit code, and exception. Passing `standalone_mode=False` through runner extras is what exposes a command callback’s actual return value.

This makes virtually every runner-based command test dependent on the path under consideration. The highest-risk focused suites are:

- `tests/test_testing.py`: runner invocation, exception catching, exit-code normalization, output capture, and non-standalone return values.
- `tests/test_stream_lifecycle.py`: restoration and ownership of streams across success, exceptions, `SystemExit`, repeated invocation, and threaded execution.
- `tests/test_commands.py`: plain/group dispatch, missing commands, standalone-mode behavior, nested commands, and object propagation.
- `tests/test_context.py`: context activation, callbacks, cleanup, eager callbacks, and current-context behavior.
- `tests/test_chain.py`: staged tokens, chained child contexts, `invoke_without_command`, and result callbacks.
- `tests/test_shell_completion.py`: completion environment dispatch, context resolution, and early termination.
- `tests/test_utils/test__expand_args.py`: the expansion helper; additional direct `Command.main` coverage is needed to prove its Windows-only entry condition.
- `tests/test_arguments.py` and `tests/test_options.py`: parameter ordering, defaults, conversion, eager callbacks, and parse-time context visibility.

## Prioritized audit order

1. `src/click/core.py`: `Command.main`, `Command.make_context`, all three invocation layers (`Context`, `Command`, `Group`), group parsing/resolution, context enter/exit/scope, and result callbacks.
2. `src/click/testing.py`: `CliRunner.invoke`, isolation, `Result`, `SystemExit` normalization, and stream flushing.
3. `src/click/shell_completion.py`: the completion short-circuit and its independent partial-context resolution.
4. `src/click/globals.py` plus context-aware decorators: push/pop/current-context behavior used by callbacks.
5. `src/click/parser.py` and core parameter processing: parser output, callback order, leftover-token semantics, and usage errors.
6. `src/click/exceptions.py`: `Exit`, `Abort`, `ClickException`, `UsageError`, `NoArgsIsHelpError`, and `NoSuchCommand`.
7. `src/click/utils.py`: `_expand_args`, program-name detection, broken-pipe flush suppression, and output helpers.
8. Focused tests in `test_testing`, `test_stream_lifecycle`, `test_commands`, `test_context`, `test_chain`, `test_shell_completion`, and `test__expand_args`; then the wider argument and option suites because they reach the same path through the shared `CliRunner` fixture.