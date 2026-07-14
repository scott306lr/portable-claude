# Sync reproduces machines verbatim — adoption never transforms

Adopting a machine must not change how anything is invoked or where it
lives: a user-level skill invoked as `/name` on the first machine is
`/name`, user-level, on every machine. We replaced two earlier designs
that violated this. The original `--adopt` swept `~/.claude/skills/`
wholesale into the repo's plugin, which silently rebranded skills as
`my-toolkit:<name>` — including third-party sets a tool like skills.sh
had installed, cutting them off from their upstream. An interim per-skill
consent prompt didn't fix it: whatever the user accepted was still
transformed. Both are gone — `dotfiles/` takes directories, and `--adopt`
captures `skills/` and `hooks/` byte-for-byte.

The underlying fact (why renaming is unavoidable once files move): a
skill's identity in Claude Code is its serving location, not its files.
`SKILL.md` carries no author or origin field; a folder under
`~/.claude/skills/` presents as a personal unprefixed skill, the same
folder inside a plugin presents as `plugin:name`, and update flow exists
only at the plugin channel (marketplace → version bump → cache refresh).
Preserving identity therefore means preserving the distribution channel.

Consequences: a third-party skill set synced through `dotfiles/skills/`
is a fork of upstream — refreshing it is manual (its installer writes
through the symlink; sync propagates). Sets that ship as a plugin
marketplace should instead be installed as plugins, which the Record
(`docs/adr/0001`) already syncs — that path keeps provenance and updates.
The README steers users there; the scripts do not enforce it, because
skills.sh-installed folders carry no marker that would let them be told
apart from user-authored ones (verified 2026-07-14, skills.sh ≈1.5.x:
no lockfile or metadata lands in `~/.claude`).
