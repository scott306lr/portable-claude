# Claude Code Setup Sync

Portable Claude Code configuration: one repo that makes every machine
behave the same. Data flows repo → machine via `install.sh` and
machine → repo → other machines via `sync.sh`.

## Language

**Dotfile**:
A top-level entry in `dotfiles/` — file or directory — symlinked into
`~/.claude/`. The directory listing itself is the manifest — dropping
an entry in makes it sync; no script changes needed.
_Avoid_: config file, settings file

**Record**:
The `extraKnownMarketplaces` key in the synced `dotfiles/settings.json`;
the single source of truth for where each external marketplace comes
from (see `docs/adr/0001`).
_Avoid_: snapshot

**Registry**:
Claude Code's own machine-local marketplace state
(`~/.claude/plugins/known_marketplaces.json`). Undocumented format:
scripts read it tolerantly and never write it.
_Avoid_: cache (that's the plugin content store Claude serves from)

**Drift check**:
sync.sh's read-only comparison of the Registry against the Record.
Warns with paste-ready JSON when a marketplace is registered locally
but not recorded; it can under-warn, never corrupt.

**Self-heal**:
install.sh's recovery path for a corrupt Registry or cache: a failed
marketplace refresh triggers remove + re-add from the Record, which
re-clones.
