Renamed `_expand_args` to `_expand_windows_args` using Serena’s semantic refactoring.

Changed files:

- `src/click/utils.py`
- `src/click/core.py`
- `tests/test_utils/test__expand_args.py`

Verification:

- New definition resolves uniquely.
- Production import and `Command.main` call resolve.
- All six test calls use the new symbol.
- No `_expand_args` occurrences remain.
- Requested tests: **104 passed** in 0.09s.