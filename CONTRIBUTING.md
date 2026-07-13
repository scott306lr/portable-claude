# Contributing

This repo is deliberately small: two bash scripts, zero runtime dependencies
beyond git + python3 (jq only for the statusline). Keep it that way — the
whole point is that a fresh machine can bootstrap with nothing pre-installed.

## Ground rules

- **Vocabulary.** [CONTEXT.md](./CONTEXT.md) defines the terms: *Dotfile*,
  *Record*, *Registry*, *Drift check*, *Self-heal*. Use them in code
  comments, docs, and PRs — don't invent synonyms.
- **Decisions.** Architectural decisions live in [docs/adr/](./docs/adr/).
  If a change contradicts one (e.g. ADR-0001: marketplace sources live in
  `extraKnownMarketplaces`, never a snapshot file), reopen the ADR in the PR
  instead of silently diverging.
- **Both userlands.** Scripts must work on macOS (BSD tools) and Linux (GNU).
  CI runs the suite on both. The classic trap: BSD and GNU tools disagree on
  exit codes and flags, and `set -o pipefail` turns that into a silent abort.
- **Use the test seam.** Everything is testable via `CLAUDE_HOME=<tmpdir>`
  and `--dry-run`; never test against your real `~/.claude`. Don't add code
  paths that only work against the real machine.
- **No secrets, ever.** `sync.sh` has a scan gate, but it's a tripwire, not
  permission to be careless. Secrets stay in per-machine env vars,
  referenced as `${VAR}` from configs.

## Running tests

```bash
./tests/run.sh
```

Plain bash, no framework. It builds a scratch git clone with a local bare
origin and scratch `CLAUDE_HOME`s, then replays real scenarios: install,
backup + prune, rollback, both blocking gates, secret scan, plugin version
bump, pull integration, and the drift check. Nothing touches your real
`~/.claude` or the network, and the `claude` CLI is kept off the PATH.

**When you add behavior, add its scenario.** The suite exists because an
untested write/read pair in this repo once drifted into incompatible formats
without anyone noticing (see ADR-0001), and because a BSD/GNU `ls` difference
once aborted `install.sh` halfway — both classes are caught here now.

## Known sharp edges

- `~/.claude/plugins/known_marketplaces.json` is **undocumented** Claude Code
  internal state. Only the drift check reads it, tolerantly, and nothing here
  ever writes it. Expect it to change shape across CLI versions.
- Plugin cache staleness is keyed on the `plugin.json` **version string**,
  not git SHAs — that's why `sync.sh` auto-bumps versions for changed
  plugins. Don't remove the bump without understanding that.
- `extraKnownMarketplaces` in user settings does **not** auto-register
  marketplaces (verified 2026-07-14, CLI v2.1.207 — see ADR-0001);
  `install.sh`'s registration loop is load-bearing.
