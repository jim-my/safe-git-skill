# safe-git regression suite

Plain-bash tests for `safe-git check {start,pr,done}` and the
`pre-commit` / `pre-push` hooks.

```sh
claude/skills/safe-git/test/run.sh
```

Each `*_test.sh` file defines `test_*` functions. `run.sh` discovers
them, runs each in its own subshell with an isolated tempdir and a
hermetic PATH (sandbox-bin + mock-bin), and reports per-test pass/fail.

Helpers live in `lib/`:

- `assert.sh` — `capture`, `assert_ok`, `assert_fails_with`, etc.
- `fixtures.sh` — temp repo + remote, linked worktrees, `gh` PATH mocks,
  `git` wrappers for fetch / `worktree list` interception, partial-HEAD
  state manufacture.
