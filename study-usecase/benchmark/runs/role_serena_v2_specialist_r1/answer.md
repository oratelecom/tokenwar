Renamed `_expand_args` to `_expand_windows_args` with behavior unchanged.

Changed files:

- [src/click/utils.py](/local-study/benchmark/role-targets/serena_multi_solo_r1/src/click/utils.py)
- [src/click/core.py](/local-study/benchmark/role-targets/serena_multi_solo_r1/src/click/core.py)
- [tests/test_utils/test__expand_args.py](/local-study/benchmark/role-targets/serena_multi_solo_r1/tests/test_utils/test__expand_args.py)

Serena verified the new definition, production import/call, and test calls resolve. Project-wide search found no remaining `_expand_args` symbol occurrences.

Tests: `104 passed in 0.10s`.