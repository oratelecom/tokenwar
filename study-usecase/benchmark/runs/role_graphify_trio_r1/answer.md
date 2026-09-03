## Connected execution map

```text
process / CliRunner
    │
    ▼
Command.__call__ ───────────────► Command.main
                                      │
                                      ├─ argv omitted
                                      │    └─ sys.argv[1:]
                                      │         └─ Windows only + enabled
                                      │              └─ utils._expand_args
                                      │                   expanduser → expandvars → glob
                                      │
                                      ├─ argv supplied explicitly
                                      │    └─ list(args), no Windows expansion
                                      │
                                      ├─ derive prog_name
                                      │
                                      ├─ _main_shell_completion
                                      │    ├─ inspect _<PROG>_COMPLETE
                                      │    ├─ unset: continue normally
                                      │    └─ set: shell_completion.shell_complete
                                      │         ├─ source script, or
                                      │         └─ resilient context hierarchy
                                      │              → resolve incomplete object
                                      │              → object.shell_complete
                                      │         └─ sys.exit(status), bypassing normal invoke
                                      │
                                      └─ make_context
                                           │
                                           ├─ merge Command.context_settings
                                           ├─ construct context_class(command, parent, ...)
                                           └─ with ctx.scope(cleanup=False)
                                                └─ Command.parse_args
                                                     ├─ make_parser
                                                     │    └─ _OptionParser(ctx)
                                                     │         + each parameter.add_to_parser
                                                     ├─ parser.parse_args
                                                     ├─ parameters.handle_parse_result
                                                     └─ store ctx.params, ctx.args,
                                                        and option prefixes
```

### Normal command dispatch

After `make_context`, `Command.main` enters `with ctx`, making that context current, and calls `self.invoke(ctx)`.

For a plain `Command`:

```text
Command.invoke(ctx)
    └─ ctx.invoke(command.callback, **ctx.params)
         ├─ direct callable: reuse ctx
         ├─ augment_usage_errors(ctx)
         ├─ enter ctx
         │    └─ push_context(ctx)
         ├─ callback(...)
         └─ exit ctx
              ├─ run cleanup when outermost depth closes
              └─ pop_context()
```

This activation is observable behavior. `pass_context`, `pass_obj`, pass-object decorators, `get_current_context`, and helpers such as context-sensitive output resolve the context from the active stack. Changing activation timing in `Context.invoke` can therefore alter callback arguments, nested invocation, error attribution, resource lifetime, and which context helpers observe.

`Context.invoke` also has a distinct command-object mode:

```text
parent_ctx.invoke(other_command, **overrides)
    ├─ require other_command.callback
    ├─ parent_ctx._make_sub_context(other_command)
    │    └─ same Context subclass, parent=parent_ctx
    ├─ fill absent exposed parameters from defaults
    ├─ type-cast defaults and hide UNSET as None
    ├─ copy all kwargs into child_ctx.params
    └─ activate child_ctx and call other_command.callback
```

`Context.forward` first fills missing values from the current context’s parameters, then delegates to this command-object path.

### Group dispatch and token staging

`Group.parse_args` first uses ordinary `Command.parse_args`. It then separates tokens intended for command resolution from leftover child arguments:

```text
non-chain: first remaining token → ctx._protected_args
           remaining tokens     → ctx.args

chain:     all remaining tokens  → ctx._protected_args
           ctx.args              → []
```

`Group.invoke` recombines and clears those staging fields before dispatch.

For a normal group:

```text
Group.invoke(parent_ctx)
    ├─ no protected command
    │    ├─ invoke_without_command=False → ctx.fail("Missing command")
    │    └─ invoke_without_command=True
    │         → activate parent
    │         → invoke group callback
    │         → optional result callback
    │
    └─ protected command exists
         ├─ activate parent
         ├─ resolve_command(parent, tokens)
         │    ├─ Group.get_command(name)
         │    │    └─ normally commands[name]
         │    ├─ retry normalized name if configured
         │    ├─ option-looking unknown token → reparse for cases such as --help
         │    └─ otherwise raise NoSuchCommand
         ├─ set parent.invoked_subcommand
         ├─ invoke group callback
         ├─ child_command.make_context(name, remaining, parent=parent)
         ├─ activate child context
         ├─ child_command.invoke(child)
         └─ invoke optional result callback in parent context
```

`CommandCollection.get_command` extends the resolution edge by consulting its own commands and then each source group. Custom `Group.get_command` implementations and aliases sit on the same critical path.

For chained groups, resolution and execution are deliberately separated:

```text
activate parent
    → mark invoked_subcommand="*"
    → invoke group callback
    → repeatedly resolve command
         and build child contexts with:
             allow_extra_args=True
             allow_interspersed_args=False
    → transfer each child's unconsumed args to the next resolution
    → invoke staged child contexts in order
    → collect results into a list
    → parent-context result callback(list, **parent.params)
```

That separation makes `_protected_args`, `ctx.args`, child-context parenting, and cleanup depth especially sensitive to changes.

### Completion is an alternate parser client

Completion exits from `Command.main` before its normal `make_context` and `invoke` block. For an actual completion request, however, `shell_completion._resolve_context` calls the same `make_context`, parsing, group staging, and `resolve_command` machinery with `resilient_parsing=True`.

It constructs enough of the parent/child hierarchy to identify the active command or parameter, but does not dispatch command callbacks. A change that assumes every created context will reach `Command.invoke`, or that parsing always runs in ordinary error mode, can break completion without breaking normal execution.

### Exit and error translation

Inside `Command.main`:

- Successful standalone execution calls `ctx.exit()` with no callback return value. `Context.exit` closes resources and raises Click’s `Exit(0)`, which `main` translates to `SystemExit(0)`.
- With `standalone_mode=False`, a normal callback return value is returned after context cleanup.
- An explicit `ctx.exit(code)` becomes `SystemExit(code)` in standalone mode, but becomes the numeric code returned by `main` in non-standalone mode.
- `EOFError` and `KeyboardInterrupt` become `Abort`.
- `ClickException`, including usage and parsing errors, is rendered through `show()` and exits with its declared code in standalone mode; it propagates otherwise.
- `Abort` prints `Aborted!` and exits 1 in standalone mode; it propagates otherwise.
- `OSError` with `EPIPE` pacifies stdout/stderr flushing and exits 1.
- Other exceptions propagate out of `main`.
- Completion uses `sys.exit` directly before this translation block.

`augment_usage_errors` in `Context.invoke` attaches the active context, and optionally parameter information, to otherwise unbound `BadParameter` and `UsageError` instances. Moving or removing it affects usage text, command paths, help hints, and color selection.

### `CliRunner` exposure

```text
CliRunner.invoke
    ├─ establish isolated stdin/stdout/stderr/environment
    ├─ optionally establish file-descriptor capture
    ├─ shlex.split(args) when args is a string
    ├─ choose prog_name
    └─ cli.main(args=args or (), prog_name=..., **extra)
         ├─ SystemExit → Result.exit_code
         ├─ non-integer SystemExit payload
         │    → print payload and use exit code 1
         ├─ other exception
         │    → propagate or capture as Result.exception
         └─ normal return
              → Result.return_value
```

Because the runner passes an explicit argument sequence—even when empty—`Command.main` does not use `sys.argv` or perform Windows expansion during normal runner invocation. Everything after that boundary remains shared: completion, context creation, parsing, dispatch, cleanup, output, and exit translation.

A behavioral change to `Command.main` can therefore alter virtually every test using `runner.invoke`, particularly `Result.exit_code`, `return_value`, exception capture, stderr/stdout ordering, completion exits, and cleanup. A change to `Context.invoke` has a narrower but still broad blast radius across ordinary callbacks, result callbacks, decorators, forwarding, programmatic command invocation, and error context.

## Prioritized audit list

1. [`src/click/core.py`](/local-study/benchmark/click-target/src/click/core.py) — `Command.main`, context construction/parsing, `Context.invoke` and lifecycle, `Group.parse_args`/`invoke`/`resolve_command`, `CommandCollection`, exit and usage augmentation.
2. [`tests/test_commands.py`](/local-study/benchmark/click-target/tests/test_commands.py), [`tests/test_context.py`](/local-study/benchmark/click-target/tests/test_context.py), and [`tests/test_chain.py`](/local-study/benchmark/click-target/tests/test_chain.py) — direct invocation, forwarding/defaults, activation, cleanup, subcommand state, token staging, chains, and result callbacks.
3. [`src/click/shell_completion.py`](/local-study/benchmark/click-target/src/click/shell_completion.py) and [`tests/test_shell_completion.py`](/local-study/benchmark/click-target/tests/test_shell_completion.py) — early exit plus resilient reuse of context creation, parsing, and group resolution.
4. [`src/click/testing.py`](/local-study/benchmark/click-target/src/click/testing.py), [`tests/test_testing.py`](/local-study/benchmark/click-target/tests/test_testing.py), and `tests/test_stream_lifecycle.py` — `CliRunner` entry, capture, return/exit semantics, exceptions, and stream cleanup.
5. [`src/click/globals.py`](/local-study/benchmark/click-target/src/click/globals.py) and [`src/click/decorators.py`](/local-study/benchmark/click-target/src/click/decorators.py) — current-context stack and context-dependent callback wrappers.
6. [`src/click/parser.py`](/local-study/benchmark/click-target/src/click/parser.py), parameter handling in `core.py`, and parsing-heavy option/argument/default tests — especially if context timing or staged args change.
7. [`src/click/exceptions.py`](/local-study/benchmark/click-target/src/click/exceptions.py) — rendered usage, command paths, help hints, colors, and exit codes.
8. [`src/click/utils.py`](/local-study/benchmark/click-target/src/click/utils.py) and [`tests/test_utils/test__expand_args.py`](/local-study/benchmark/click-target/tests/test_utils/test__expand_args.py) — Windows-only implicit argv expansion and program-name detection.