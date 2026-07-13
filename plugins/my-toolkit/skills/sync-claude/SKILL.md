---
name: sync-claude
description: Commit and push this machine's Claude Code setup changes (memory, settings, skills) and pull everyone else's — runs the repo's sync.sh.
disable-model-invocation: true
---

# Sync the setup repo

Run the setup repo's `sync.sh` and report the result. The dotfiles are
symlinked from the repo, so the repo root can always be found from the
`CLAUDE.md` link:

```bash
REPO="$(dirname "$(readlink "$HOME/.claude/CLAUDE.md")")/.."
bash "$REPO/sync.sh" "<commit message>"
```

Steps:

1. If the user gave a message (e.g. `/sync-claude added pdf skill`), pass it
   through as the commit message. Otherwise summarize what changed in a few
   words yourself (check `git -C "$REPO" status --short`), or fall back to
   the script's default message.
2. Run the command and show the user the real output.
3. If it stops at a gate, don't override it — explain the fix:
   - **"not linked"** → the machine needs `./install.sh` first.
   - **"possible secret"** → the flagged content must be removed and moved
     to a per-machine env var; only suggest `SKIP_SECRET_SCAN=1` if the user
     confirms it's a false positive.
