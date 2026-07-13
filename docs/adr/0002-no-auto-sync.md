# Syncing is deliberate — no auto-sync hooks

`sync.sh` runs only when a human runs it (directly, via `sync-claude`, or
via the `/sync-claude` command). We deliberately do not auto-sync on session
start/end hooks, even though other tools in this space do (e.g.
claude-brain). Reasons: sync commits and pushes — an outward-facing action
that should stay deliberate; the safety gates (symlink check, secret scan,
drift warning) are designed around a human reading their output, and a
silent hook would reduce them to log noise; and a failed background sync
(rebase conflict, blocked secret) leaves the repo in a state someone needs
to actually look at. If demand appears, auto-sync becomes a documented
opt-in snippet in the README — never the default.
