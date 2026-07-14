#!/usr/bin/env bash
# sync.sh — one command to sync your Claude Code setup, in both directions.
#
#   ./sync.sh                    # sync with default commit message
#   ./sync.sh "added pdf skill"  # sync with a custom message
#   ./sync.sh --dry-run          # run the checks, show what would change, write nothing
#
# What it does (data flows machine → repo → other machines):
#   0. Stops if install.sh hasn't wired up the dotfile symlinks
#   1. Pulls latest changes (rebase, autostash)
#   2. Bumps the version of each plugin whose content changed
#   3. Warns if a marketplace registered on this machine is missing from
#      extraKnownMarketplaces in dotfiles/settings.json — that key is the
#      single record of marketplace sources (see docs/adr/0001)
#   4. Refuses to commit if a changed file contains something that looks
#      like a secret (token patterns, private-key blocks)
#   5. Commits + pushes everything that changed
#   6. Refreshes Claude Code's cached copy of this repo's marketplace
#
# Memory/settings need no extra step — they're symlinked, so editing
# ~/.claude/CLAUDE.md or settings.json already edits this repo.

set -euo pipefail
# Resolve through the optional ~/.local/bin/sync-claude symlink so the
# script still finds the repo when invoked from anywhere.
SELF="${BASH_SOURCE[0]}"
[ -L "$SELF" ] && SELF="$(readlink "$SELF")"
cd "$(dirname "$SELF")"

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"   # overridable to test against a throwaway HOME
DRY_RUN=false
COMMIT_MSG="sync: update Claude Code config"
case "${1:-}" in
  --dry-run) DRY_RUN=true ;;
  ?*) COMMIT_MSG="$1" ;;
esac
MARKETPLACE="$(python3 -c 'import json; print(json.load(open(".claude-plugin/marketplace.json"))["name"])')"

# ── 0. Gate: are the dotfiles actually wired up? ─────────────────────────────
# If $CLAUDE_HOME/<file> isn't a symlink into this repo, edits made there are
# NOT reaching the repo — syncing would silently publish stale files. This
# stops hard rather than warns: the warning version proved ignorable while
# the links had quietly come undone.
# dotfiles/ itself is the manifest: every top-level entry in it must be linked.
unlinked=false
for path in dotfiles/*; do
  [ -e "$path" ] || continue
  f="$(basename "$path")"
  if [ "$(readlink "$CLAUDE_HOME/$f" 2>/dev/null)" != "$PWD/dotfiles/$f" ]; then
    echo "✖ $CLAUDE_HOME/$f is not linked to this repo — edits made there are NOT syncing."
    unlinked=true
  fi
done
if [ "$unlinked" = true ]; then
  echo "  Run ./install.sh first, then re-run ./sync.sh."
  exit 1
fi

# ── 1. Pull remote changes first (skip silently if no remote yet) ────────────
if [ "$DRY_RUN" = true ]; then
  echo "· --dry-run: skipping pull"
elif git remote get-url origin >/dev/null 2>&1; then
  if ! git pull --rebase --autostash; then
    echo "✖ pull failed — resolve manually, then re-run ./sync.sh"
    exit 1
  fi
fi

# ── 2. Bump the version of each plugin whose content changed ─────────────────
# Version changes are what tell other machines "there's something new to fetch".
changed_plugins="$(git status --porcelain -- plugins 2>/dev/null \
  | cut -c4- | sed 's/.* -> //' \
  | grep -oE '^plugins/[^/]+' | sed 's|^plugins/||' | sort -u || true)"

if [ -n "$changed_plugins" ] && [ "$DRY_RUN" = true ]; then
  # shellcheck disable=SC2086  # word-splitting collapses the newlines
  echo "· would bump version of:" $changed_plugins
elif [ -n "$changed_plugins" ]; then
  # shellcheck disable=SC2086  # word-splitting is intended: one arg per plugin
  python3 - $changed_plugins <<'EOF'
import json, sys

def bump(v):
    parts = v.split(".")
    parts[-1] = str(int(parts[-1]) + 1)
    return ".".join(parts)

versions = {}
for name in sys.argv[1:]:
    path = f"plugins/{name}/.claude-plugin/plugin.json"
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        continue   # deleted plugin or stray dir — nothing to bump
    data["version"] = bump(data.get("version", "1.0.0"))
    versions[data.get("name", name)] = data["version"]
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

# Keep the marketplace catalog in agreement
with open(".claude-plugin/marketplace.json") as f:
    mp = json.load(f)
for p in mp.get("plugins", []):
    if p["name"] in versions:
        p["version"] = versions[p["name"]]
with open(".claude-plugin/marketplace.json", "w") as f:
    json.dump(mp, f, indent=2)
    f.write("\n")

if versions:
    print("✔ bumped: " + ", ".join(f"{k} → {v}" for k, v in versions.items()))
EOF
fi

# ── 3. Drift check: is every registered marketplace in the record? ───────────
# extraKnownMarketplaces in the synced settings.json is the single record of
# marketplace sources (see docs/adr/0001). Read-only and warn-only: Claude
# Code's registry file is undocumented, so parse it tolerantly — the worst
# this can do is miss a warning, never corrupt the record.
python3 - "$MARKETPLACE" "$CLAUDE_HOME" <<'EOF'
import json, os, sys

own = sys.argv[1]
try:
    with open(os.path.join(sys.argv[2], "plugins/known_marketplaces.json")) as f:
        registered = json.load(f)
except Exception:
    raise SystemExit(0)   # no registry on this machine — nothing to check

try:
    with open("dotfiles/settings.json") as f:
        recorded = json.load(f).get("extraKnownMarketplaces", {})
except Exception as e:
    raise SystemExit(f"could not parse dotfiles/settings.json: {e}")

entries = registered.get("marketplaces", registered) if isinstance(registered, dict) else {}
missing = {}
if isinstance(entries, dict):
    for name in sorted(entries):
        if name == own or name in recorded:
            continue
        src = entries[name].get("source") if isinstance(entries[name], dict) else None
        if not isinstance(src, dict):
            continue
        if src.get("source") in ("directory", "file"):
            continue   # machine-local path — doesn't belong in the shared record
        missing[name] = {"source": src}
        if entries[name].get("autoUpdate"):
            missing[name]["autoUpdate"] = True

if missing:
    print("⚠ registered on this machine but missing from extraKnownMarketplaces")
    print("  in dotfiles/settings.json — other machines won't get them. Paste in:")
    for line in json.dumps(missing, indent=2).splitlines()[1:-1]:
        print("   " + line)
EOF

# ── 4. Secret scan gate: never commit anything that looks like a secret ──────
# High-signal patterns only (real token prefixes, key blocks) so docs that
# *mention* tokens don't trip it. False positive? SKIP_SECRET_SCAN=1 ./sync.sh
SECRET_PATTERNS='gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|AKIA[0-9A-Z]{16}|sk-ant-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{20,}|glpat-[A-Za-z0-9_-]{20}|npm_[A-Za-z0-9]{36}|hf_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
if [ "${SKIP_SECRET_SCAN:-}" != "1" ]; then
  leaks=""
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    hits="$(grep -nIE "$SECRET_PATTERNS" "$f" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      leaks="${leaks}  $f
$(printf '%s\n' "$hits" | sed 's/^/    /')
"
    fi
  done < <(git status --porcelain -uall | cut -c4- | sed 's/.* -> //')
  # -uall: without it, files inside an UNTRACKED DIRECTORY surface only as
  # "dir/" — which the -f check skips, letting a secret in a new folder through.
  if [ -n "$leaks" ]; then
    echo "✖ possible secret in files about to be committed:"
    printf '%s' "$leaks"
    echo "  Remove it (reference an env var instead — see README), or if this"
    echo "  is a false positive: SKIP_SECRET_SCAN=1 ./sync.sh"
    exit 1
  fi
fi

# ── 5. Commit and push whatever changed ──────────────────────────────────────
if [ "$DRY_RUN" = true ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "· would commit and push:"
    git status --short | sed 's/^/    /'
  else
    echo "· nothing new to commit"
  fi
elif [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "$COMMIT_MSG"
  echo "✔ committed: $COMMIT_MSG"
else
  echo "· nothing new to commit"
fi

if [ "$DRY_RUN" = false ] && git remote get-url origin >/dev/null 2>&1; then
  git push && echo "✔ pushed"
fi

# ── 6. Refresh Claude Code's cached marketplace copy ─────────────────────────
# Installed plugins are served from a cache, not from this folder directly,
# so tell Claude Code to re-fetch after any change.
if [ "$DRY_RUN" = true ]; then
  echo "· would refresh marketplace '$MARKETPLACE'"
elif command -v claude >/dev/null 2>&1; then
  claude plugin marketplace update "$MARKETPLACE" >/dev/null 2>&1 \
    && echo "✔ marketplace '$MARKETPLACE' refreshed" \
    || echo "⚠ couldn't refresh — run /plugin marketplace update $MARKETPLACE inside Claude Code"
else
  echo "· claude CLI not found — run /plugin marketplace update $MARKETPLACE inside Claude Code"
fi

echo "Done."
