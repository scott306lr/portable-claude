# my-portable-claude

[![tests](https://github.com/scott306lr/my-portable-claude/actions/workflows/tests.yml/badge.svg)](https://github.com/scott306lr/my-portable-claude/actions/workflows/tests.yml)

Use this template if you run Claude Code on multiple computers or servers
and want your global memory, settings, skills, hooks, agents, and private
plugins to behave consistently everywhere.

## Quickstart

```bash
# Once — create your private copy of this template:
gh repo create my-claude-setup --template scott306lr/my-portable-claude --private

# First machine — capture its existing ~/.claude setup:
gh repo clone my-claude-setup ~/my-claude-setup
cd ~/my-claude-setup && ./install.sh --adopt

# Every other machine — receive the synced setup:
gh repo clone my-claude-setup ~/my-claude-setup
cd ~/my-claude-setup && ./install.sh
```

Every line works as written: [`gh`](https://cli.github.com/) fills in your
account. Without `gh`, click **Use this template** and `git clone` the new
repo instead. To undo, `./install.sh --rollback` restores
the pre-install backups, and `gh repo delete my-claude-setup` removes the
repo — after `gh auth refresh -s delete_repo` grants the scope.

After that, syncing is one command — publish from the machine you edited
on, receive on the others:

```bash
sync-claude "what I changed"        # in a shell (install.sh puts it on PATH)
```

```
/my-toolkit:sync-claude what I changed    # inside Claude Code
```

A sync is an ordinary git commit: preview with `sync-claude --dry-run`,
undo with `git revert`.

That's the whole workflow. The rest of this README is detail.

## First machine: adopting an existing setup

`./install.sh --adopt` copies the machine's setup into the repo before
anything is linked. The repo adopts the machine, not the other way around.
It captures three things:

- **Files** — your memory and settings replace the template placeholders.
- **Directories** — user-level `skills/` and `hooks/`, verbatim. A skill
  invoked as `/name` here stays `/name` on every machine (`docs/adr/0003`).
- **Marketplaces** — already-registered ones land in the settings record,
  and the catalog `owner` is stamped from `git config user.name`.

`--adopt --dry-run` previews all of it.

> [!NOTE]
> A third-party skill set synced this way becomes a fork: it stops
> tracking upstream. If it also ships as a Claude Code plugin, install
> the plugin instead — updates then flow through the marketplace:
>
> ```bash
> claude plugin marketplace add <owner>/<repo>
> claude plugin install <plugin>@<marketplace>
> ```

`--adopt` is for the first machine only. On a repo that already holds an
adopted setup it stops and asks; under `-y` it refuses unless
`FORCE_ADOPT=1` is set.

Adoption commits nothing. Review with `git diff`, then publish with
`sync-claude "adopt this machine's setup"` — the secret scan runs first.
Let `--adopt` run that first sync itself and it prints the exact clone
commands for your other machines.

No existing setup? Plain `./install.sh` works as-is — and on a machine
that *does* have one, it reminds you about `--adopt` before touching
anything.

## Why not just a dotfiles repo?

A plain dotfiles setup (chezmoi, stow, bare-git `~/.claude`) syncs the
files fine, but Claude Code keeps state outside the files:

- Plugins are served from a cache keyed on the `plugin.json` version
  string, not git SHAs — a synced skill edit stays stale on other
  machines until the version changes.
- Marketplace registration is machine-local state, and
  `extraKnownMarketplaces` in settings does not auto-register on a fresh
  machine (verified — `docs/adr/0001`).

The repo uses two mechanisms:

- **Symlinked dotfiles.** Every entry in `dotfiles/` — file or directory —
  is linked into `~/.claude/`; the listing is the manifest. Because they
  are links, whatever writes to `~/.claude` lands in the repo: Claude Code
  editing `settings.json`, or an installer dropping a skill into
  `~/.claude/skills/`.
- **A self-hosted plugin marketplace.** The repo is also a Claude Code
  plugin marketplace, registered from the local clone path — no separate
  repo, no GitHub fetch, no auth.

## Personalizing

The installed files are symlinks into the repo, so personalization happens
through normal use — no setup phase:

- **Memory**: edit `~/.claude/CLAUDE.md` (or let Claude edit it) — that *is*
  the repo file.
- **Settings**: change them in Claude Code as usual; they land in the repo
  the same way.
- **Skills**: a folder holding a `SKILL.md` — see
  `plugins/my-toolkit/skills/sync-claude/` for the format. Put it in
  `dotfiles/skills/` to invoke as `/name`, or in
  `plugins/my-toolkit/skills/` for `/my-toolkit:name`. Add
  `disable-model-invocation: true` for user-only skills ("slash commands").

Prefer different names than `my-tools`/`my-toolkit`? Rename them once in
`.claude-plugin/marketplace.json` and `plugins/` before the first install —
the scripts read the names from the catalog.

## What a sync run does

- pulls other machines' changes first (rebase, autostash)
- bumps the version of any plugin whose content changed, so edited skills
  actually reload on other machines
- warns if a marketplace registered on this machine isn't recorded for the
  others yet, printing the JSON to paste in
- refuses to commit anything matching secret patterns (tokens, private-key
  blocks)
- commits, pushes, and refreshes the local plugin cache
- stops if `install.sh` hasn't wired the symlinks, since edits in
  `~/.claude` wouldn't be reaching the repo

Sync is git, not realtime: edit the same file on two machines before
syncing and you get an ordinary merge conflict to resolve.

## What's inside

```
dotfiles/                         # the manifest: every entry here syncs
  CLAUDE.md                       #   global memory → ~/.claude/CLAUDE.md
  settings.json                   #   user settings → ~/.claude/settings.json
  statusline-command.sh           #   example statusline (dir | git | model | ctx%)
  skills/                         #   user-level skills, synced verbatim (/name)
plugins/my-toolkit/               # your plugin — skills, agents, hooks
  skills/sync-claude/             #   the /sync-claude command (and a format example)
.claude-plugin/marketplace.json   # marketplace catalog (rename "my-tools" if you like)
install.sh                        # bootstrap, adopt, cache self-heal, rollback
sync.sh                           # what sync-claude points at
tests/run.sh                      # test suite — plain bash, CI on macOS + Linux
CONTEXT.md · docs/adr/            # vocabulary and design decisions
```

## Command reference

| Command | What it does |
|---|---|
| `./install.sh` | Set up this machine; prompts before overwriting, keeps backups |
| `./install.sh -y` | Same, without prompts (still backs up) |
| `./install.sh --adopt` | First install on a lived-in machine: capture its setup into the repo, then link |
| `./install.sh --dry-run` | Print the full plan, touch nothing |
| `./install.sh --rollback` | Undo the links, restore the newest backups |
| `sync-claude "msg"` | Pull → bump → check → commit → push → refresh (same as `./sync.sh`) |
| `sync-claude --dry-run` | Show what a sync would do, write nothing |

`install.sh` is idempotent, and re-running it is also the recovery path:
if plugins stop loading (cache corruption), it removes and re-registers
broken marketplaces from their recorded sources.

## What does not sync (on purpose)

- Login/OAuth (`~/.claude/.credentials.json`, `~/.claude.json`) → `/login` per machine
- Conversation history and auto-memory (`~/.claude/projects/`, `history.jsonl`)
- API keys/tokens → per-machine env vars, referenced as `${VAR}` in configs

> [!WARNING]
> Don't commit secrets, even to a private repo. The scan gate catches
> known token shapes in changed files — it cannot recognize a novel
> secret; it's a tripwire, not permission to be careless. Keep the
> generated repo private, and read any hooks or skills a template
> shipped before running `install.sh` — they execute on your machine.

## Development

`./tests/run.sh` runs the suite; ground rules are in
[CONTRIBUTING.md](./CONTRIBUTING.md), design decisions in
[docs/adr/](./docs/adr/). CI covers macOS and Linux; Windows works via
WSL (native is untested — symlinks + bash).

## License

[MIT](./LICENSE)
