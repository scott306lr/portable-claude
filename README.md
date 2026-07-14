# my-portable-claude

[![tests](https://github.com/scott306lr/my-portable-claude/actions/workflows/tests.yml/badge.svg)](https://github.com/scott306lr/my-portable-claude/actions/workflows/tests.yml)

A template for keeping a Claude Code setup — global memory, settings,
skills — consistent across machines.

## All the commands you need

With the [GitHub CLI](https://cli.github.com/) every step below is
copy-paste-able exactly as written — `gh` fills in your account, so there
is nothing to edit:

```bash
# Once — create your private copy of this template:
gh repo create my-claude-setup --template scott306lr/my-portable-claude --private

# First machine — captures your existing ~/.claude setup into the repo:
gh repo clone my-claude-setup ~/claude-setup
cd ~/claude-setup && ./install.sh --adopt

# Every other machine — the repo's synced setup wins (local files backed up):
gh repo clone my-claude-setup ~/claude-setup
cd ~/claude-setup && ./install.sh
```

No `gh`? Click **Use this template** (button above) to create a private
repo, then `git clone` the URL GitHub shows you to `~/claude-setup` and run
the same `install.sh` steps. Either way, after the first machine publishes,
`install.sh` prints the exact clone commands for your other machines — with
the real URL filled in.

After that, syncing is one command, from anywhere, on any machine — run it
after editing something to publish, run it on the other machines to receive:

```bash
sync-claude "what I changed"        # in a shell (install.sh puts it on PATH)
```

```
/my-toolkit:sync-claude what I changed    # inside Claude Code
```

That's the whole workflow. The rest of this README is detail.

## First machine: adopting an existing setup

`./install.sh --adopt` captures the machine's existing setup into the repo
before anything is linked: your memory and settings replace the template
placeholders, user-level `skills/` and `hooks/` are captured **verbatim**
into `dotfiles/`, and already-registered marketplaces are written into the
settings record. Nothing is renamed or moved between scopes — a skill you
invoke as `/name` on this machine is `/name` on every machine
(`docs/adr/0003`). The first adoption also stamps the marketplace catalog's
`owner` from your `git config user.name` — no manual editing. The repo
adopts the machine, not the other way around (`--adopt --dry-run`
previews it).

One heads-up: syncing a third-party skill set this way copies it into your
repo — a fork that stops tracking upstream. A set that also ships as a
Claude Code plugin is better installed as one; updates then flow through
the marketplace and the registration syncs via the settings record:

```bash
claude plugin marketplace add <owner>/<repo>
claude plugin install <plugin>@<marketplace>
```

`--adopt` is a first-machine tool. Running it against a repo that already
holds an adopted setup (say, on machine 2 by mistake) would replace that
setup with the current machine's — so it stops and asks first, and refuses
under `-y` unless you force it with `FORCE_ADOPT=1`.

Adoption doesn't commit anything — review with `git diff`, then publish
with `sync-claude "adopt this machine's setup"`, which also runs the capture
through the secret scan before it reaches your remote.

Starting truly fresh, with no existing setup? Plain `./install.sh` works
as-is; the template's defaults are functional without any editing. And if
you run plain `./install.sh` on a machine that *does* have an existing
setup, it notices and reminds you about `--adopt` before touching anything.

## Personalizing

The installed files are symlinks into the repo, so personalization happens
through normal use — no setup phase:

- **Memory**: edit `~/.claude/CLAUDE.md` (or let Claude edit it) — that *is*
  the repo file.
- **Settings**: change them in Claude Code as usual; they land in the repo
  the same way.
- **Skills**: add a folder under `dotfiles/skills/` (invoked as `/name`,
  like any user-level skill) or under `plugins/my-toolkit/skills/`
  (invoked as `/my-toolkit:name`), or ask Claude to write one. A skill is
  a folder containing a `SKILL.md` with YAML frontmatter (`name`,
  `description`) followed by instructions — see `skills/sync-claude/` for
  a working example. Add `disable-model-invocation: true` to the
  frontmatter for skills only the user should trigger (a "slash command").

Run `sync-claude` whenever you want the changes on your other machines. The
sample `CLAUDE.md` text can be replaced once you have your own preferences
in it. Different marketplace/plugin
names than `my-tools`/`my-toolkit`? Rename them in
`.claude-plugin/marketplace.json` and `plugins/` once, before the first
install — the scripts read the names from the catalog.

## What a sync run does

- pulls other machines' changes first (rebase, autostash)
- bumps the version of any plugin whose content changed, so edited skills
  actually reload on other machines (see below)
- warns if a marketplace registered on this machine isn't recorded for the
  others yet, printing the JSON to paste in
- refuses to commit anything matching secret patterns (tokens, private-key
  blocks)
- commits, pushes, and refreshes the local plugin cache
- stops if `install.sh` hasn't wired the symlinks, since edits in
  `~/.claude` wouldn't be reaching the repo

`sync-claude --dry-run` shows what a run would do without writing anything.

## Why not just a dotfiles repo?

A plain dotfiles setup (chezmoi, stow, bare-git `~/.claude`) syncs the
files fine, but Claude Code keeps state outside the files:

- Plugins are served from a cache keyed on the `plugin.json` version
  string, not git SHAs. Syncing an edited skill as a plain file leaves
  other machines loading the stale cached copy until the version changes.
  The sync script bumps the version automatically when plugin content
  changes.
- Marketplace registration is machine-local state, and
  `extraKnownMarketplaces` in settings does not auto-register on a fresh
  machine (verified — `docs/adr/0001`). `install.sh` registers what the
  settings declare; the sync script warns about drift.

The repo uses two mechanisms:

- **Symlinked dotfiles.** Every top-level entry in `dotfiles/` — file or
  directory — is linked into `~/.claude/`; the directory listing is the
  manifest, so adding an entry is all it takes to sync it. Because they're
  links rather than copies, changes Claude Code itself writes to
  `settings.json` (enabling a plugin, adding a marketplace) land in the
  repo too — as do skills a tool like skills.sh installs into the linked
  `~/.claude/skills/`.
- **A self-hosted plugin marketplace.** The repo is also a Claude Code
  plugin marketplace, registered from the local clone path — no separate
  repo, no GitHub fetch, no auth.

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

Don't commit secrets, even to a private repo. The scan gate is a tripwire,
not permission to be careless.

## Support

CI runs the test suite and shellcheck on macOS and Linux. Windows works via
WSL; native Windows is untested (symlinks + bash).

## Development

`./tests/run.sh` — plain bash, no framework, no network; everything runs
against scratch homes and a scratch git clone. Ground rules are in
[CONTRIBUTING.md](./CONTRIBUTING.md); design decisions, including the
verified findings about Claude Code's undocumented plugin internals, are in
[docs/adr/](./docs/adr/).

## License

[MIT](./LICENSE)
