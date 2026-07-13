#!/usr/bin/env bash
# install.sh — set up this machine from the repo. Idempotent: safe to re-run
# any time; it's also the recovery tool for a broken plugin cache.
#
#   ./install.sh            # interactive: asks before overwriting anything
#   ./install.sh -y         # non-interactive: overwrite without asking (still backs up)
#   ./install.sh --dry-run  # print the full plan, mutate nothing
#   ./install.sh --rollback # undo the dotfile links, restore the newest backups
#   ./install.sh --adopt    # first install on a machine with an existing setup:
#                           # copy its ~/.claude config INTO the repo, then link
#
# What it does (data flows repo → machine; sync.sh is the reverse):
#   1. Symlinks dotfiles/ into ~/.claude   (confirm + backup before replacing)
#   2. Registers this repo as a plugin marketplace from the LOCAL clone path
#      (no fetch, no auth), registers external marketplaces from
#      extraKnownMarketplaces in dotfiles/settings.json (the single record of
#      marketplace sources, see docs/adr/0001), and self-heals broken caches
#      (failed refresh → remove + re-add, which re-clones)
#   3. Installs this repo's plugins, then everything else that
#      enabledPlugins in dotfiles/settings.json expects

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"   # overridable to test against a throwaway HOME
cd "$REPO"   # so relative paths (dotfiles/, .claude-plugin/) work from anywhere

AUTO_YES=false
DRY_RUN=false
ROLLBACK=false
ADOPT=false
for arg in "$@"; do
  case "$arg" in
    -y) AUTO_YES=true ;;
    --dry-run) DRY_RUN=true ;;
    --rollback) ROLLBACK=true ;;
    --adopt) ADOPT=true ;;
    *) echo "usage: ./install.sh [-y] [--dry-run] [--rollback] [--adopt]"; exit 2 ;;
  esac
done

if [ "$ROLLBACK" = true ]; then
  echo "Rolling back dotfile links to their pre-install backups:"
  for path in dotfiles/*; do
    [ -f "$path" ] || continue
    name="$(basename "$path")"
    dest="$CLAUDE_HOME/$name"
    # shellcheck disable=SC2012  # backup names are our own timestamped pattern
    backup="$(ls -t "$dest".bak.* 2>/dev/null | head -1 || true)"
    if [ -z "$backup" ]; then
      echo "· $name — no backup to restore, left as is"
      continue
    fi
    if [ ! -L "$dest" ]; then
      echo "⚠ $name — $dest is not a symlink; not touching it (backup kept: $backup)"
      continue
    fi
    if [ "$DRY_RUN" = true ]; then
      echo "· would restore $name from $(basename "$backup")"
      continue
    fi
    rm "$dest"
    mv "$backup" "$dest"
    echo "✔ restored $name from $(basename "$backup")"
  done
  exit 0
fi

# Single source of truth: marketplace + plugin names come from the catalog.
MARKETPLACE="$(python3 -c 'import json; print(json.load(open(".claude-plugin/marketplace.json"))["name"])')"
# shellcheck disable=SC2207  # plugin names contain no whitespace
PLUGINS=($(python3 -c 'import json; [print(p["name"]) for p in json.load(open(".claude-plugin/marketplace.json"))["plugins"]]'))

# ── helpers ───────────────────────────────────────────────────────────────────

mtime_of() {  # human-readable mtime, portable best-effort (GNU / BSD / fallback)
  date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null \
    || stat -c '%y' "$1" 2>/dev/null | cut -d. -f1 \
    || stat -f '%Sm' "$1" 2>/dev/null \
    || echo "unknown"
}

link_file() {  # symlink dotfiles/<name> → ~/.claude/<name>, with confirm + backup
  local name="$1"
  local target="$REPO/dotfiles/$name"
  local dest="$CLAUDE_HOME/$name"

  [ -e "$target" ] || { echo "· skipping $name (not present in repo)"; return; }

  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$target" ]; then
    echo "✔ $name already linked"
    return
  fi

  if [ "$DRY_RUN" = true ]; then
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      echo "· would back up $dest and replace it with a link to the repo version"
    else
      echo "· would link $name → repo"
    fi
    return
  fi

  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if [ -L "$dest" ]; then
      echo "⚠ $dest is a symlink to: $(readlink "$dest")"
    else
      echo "⚠ $dest is an existing file ($(wc -c < "$dest") bytes, modified $(mtime_of "$dest"))"
    fi

    if [ "$AUTO_YES" = true ]; then
      echo "  -y given → overwriting (backup will be kept)"
    else
      local answer
      read -r -p "  Overwrite it with a link to the repo version? A backup will be kept. [y/N] " answer
      case "$answer" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "  → left untouched, $name NOT linked"; return ;;
      esac
    fi

    local backup
    backup="$dest.bak.$(date +%Y%m%d%H%M%S)"
    mv "$dest" "$backup"
    echo "  backed up old version to: $backup"
  fi

  ln -s "$target" "$dest"
  echo "✔ linked $name → repo"

  # Backups would otherwise accumulate forever — keep only the 3 most recent.
  # `|| true`: with pipefail, ls failing on zero matches must not kill the run.
  # shellcheck disable=SC2012  # backup names are our own timestamped pattern
  ls -dt "$dest".bak.* 2>/dev/null | tail -n +4 | while IFS= read -r old; do
    rm -- "$old" && echo "  pruned old backup: $old"
  done || true
}

registered_names() {  # one registered marketplace name per line; empty on any failure
  # `claude plugin marketplace list` prints names as "  ❯ <name>" lines; extract
  # just the names so callers can match exactly instead of by substring.
  claude plugin marketplace list 2>/dev/null | sed -n 's/^ *❯ *//p' || true
}

register_marketplace() {  # $1 = name, $2 = source
  local name="$1" src="$2" out
  if registered_names | grep -qxF -- "$name"; then
    if [ "$DRY_RUN" = true ]; then
      echo "· would refresh marketplace '$name' (re-adding from $src if the cache is broken)"
      return
    fi
    if claude plugin marketplace update "$name" >/dev/null 2>&1; then
      echo "✔ marketplace '$name' — refreshed"
      return
    fi
    # Registered but refresh failed — usually a deleted/corrupt cache.
    # Recover by re-adding from the known source (re-clones the cache).
    echo "· marketplace '$name' refresh failed — re-adding from $src"
    claude plugin marketplace remove "$name" >/dev/null 2>&1 || true
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "· would register marketplace '$name' from $src"
    return
  fi
  if out="$(claude plugin marketplace add "$src" 2>&1)"; then
    echo "✔ marketplace '$name' registered from $src"
  else
    echo "⚠ could NOT register '$name' from $src — its plugins will stay broken"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

install_plugin() {  # $1 = plugin@marketplace
  local spec="$1" out
  if [ "$DRY_RUN" = true ]; then
    echo "· would ensure $spec is installed"
    return
  fi
  if out="$(claude plugin install "$spec" 2>&1)"; then
    echo "✔ $spec installed"
  elif printf '%s' "$out" | grep -qi "already"; then
    echo "· $spec already installed"
  else
    echo "⚠ $spec install FAILED:"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

recorded_marketplaces() {  # "name=source" lines from the record in settings
  # extraKnownMarketplaces is a documented Claude Code settings key, so this
  # reader is strict: entries must be {"source": {...}} — anything else warns.
  python3 - <<'EOF'
import json, sys

try:
    settings = json.load(open("dotfiles/settings.json"))
except Exception as e:
    sys.exit(f"could not parse dotfiles/settings.json: {e}")

for name, entry in settings.get("extraKnownMarketplaces", {}).items():
    src = entry.get("source") if isinstance(entry, dict) else None
    if not isinstance(src, dict):
        print(f"⚠ '{name}': malformed extraKnownMarketplaces entry — skipped",
              file=sys.stderr)
        continue
    val = src.get("repo") or src.get("url") or src.get("path")
    if val:
        print(f"{name}={val}")
    else:
        print(f"⚠ '{name}': no repo/url/path in source — skipped", file=sys.stderr)
EOF
}

# ── Step 0 (--adopt): capture this machine's existing setup INTO the repo ────
# For the first install on a machine that already has a lived-in ~/.claude:
# the machine's config wins over the repo's placeholders, BEFORE anything is
# linked or overwritten. Captures three things: manifest files, user-level
# skills (moved into the plugin — they'd double-load otherwise), and
# already-registered marketplaces (merged into the settings record).
if [ "$ADOPT" = true ]; then
  echo "Adopting this machine's existing setup into the repo:"

  for path in dotfiles/*; do
    [ -f "$path" ] || continue
    name="$(basename "$path")"
    dest="$CLAUDE_HOME/$name"
    if [ -f "$dest" ] && [ ! -L "$dest" ]; then
      if [ "$DRY_RUN" = true ]; then
        echo "· would adopt $name (this machine's copy replaces the repo one)"
      else
        cp "$dest" "$path"
        echo "✔ adopted $name"
      fi
    fi
  done

  PLUGIN_DIR="$(python3 -c 'import json; print(json.load(open(".claude-plugin/marketplace.json"))["plugins"][0]["source"].removeprefix("./"))')"
  if [ -d "$CLAUDE_HOME/skills" ]; then
    for s in "$CLAUDE_HOME/skills"/*/; do
      [ -e "$s" ] || continue
      sname="$(basename "$s")"
      if [ -e "$PLUGIN_DIR/skills/$sname" ]; then
        echo "· skill '$sname' already in the plugin — skipped"
        continue
      fi
      if [ "$DRY_RUN" = true ]; then
        echo "· would adopt skill '$sname' into $PLUGIN_DIR/skills/"
      else
        cp -RL "${s%/}" "$PLUGIN_DIR/skills/$sname"
        echo "✔ adopted skill '$sname'"
      fi
    done
    if [ "$DRY_RUN" = true ]; then
      echo "· would move $CLAUDE_HOME/skills aside (the plugin serves them from now on)"
    else
      skills_bak="$CLAUDE_HOME/skills.pre-adopt.$(date +%Y%m%d%H%M%S)"
      mv "$CLAUDE_HOME/skills" "$skills_bak"
      echo "✔ moved ~/.claude/skills aside → $skills_bak (the plugin serves them now)"
    fi
  fi

  python3 - "$MARKETPLACE" "$CLAUDE_HOME" "$DRY_RUN" <<'EOF'
import json, os, sys

own, chome, dry = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
try:
    with open(os.path.join(chome, "plugins/known_marketplaces.json")) as f:
        registered = json.load(f)
except Exception:
    raise SystemExit(0)   # no registry on this machine — nothing to record

entries = registered.get("marketplaces", registered) if isinstance(registered, dict) else {}
with open("dotfiles/settings.json") as f:
    settings = json.load(f)
record = settings.setdefault("extraKnownMarketplaces", {})
added = []
if isinstance(entries, dict):
    for name in sorted(entries):
        if name == own or name in record:
            continue
        src = entries[name].get("source") if isinstance(entries[name], dict) else None
        if not isinstance(src, dict) or src.get("source") in ("directory", "file"):
            continue
        record[name] = {"source": src}
        if entries[name].get("autoUpdate"):
            record[name]["autoUpdate"] = True
        added.append(name)
if added:
    if dry:
        print("· would record marketplaces: " + ", ".join(added))
    else:
        with open("dotfiles/settings.json", "w") as f:
            json.dump(settings, f, indent=2)
            f.write("\n")
        print("✔ recorded marketplaces: " + ", ".join(added))
EOF
  echo
fi

# ── Step 1: dotfiles ──────────────────────────────────────────────────────────

echo "Installing Claude Code config from: $REPO"
echo

# First-machine guard: a real (non-symlink) config here without --adopt is
# the one combination where users can bury a setup they meant to keep.
if [ "$ADOPT" = false ]; then
  for path in dotfiles/*; do
    [ -f "$path" ] || continue
    dest="$CLAUDE_HOME/$(basename "$path")"
    if [ -f "$dest" ] && [ ! -L "$dest" ]; then
      echo "ℹ This machine already has a Claude Code setup (e.g. $dest)."
      echo "  · FIRST machine, and you want to keep this setup?"
      echo "      stop now and re-run:  ./install.sh --adopt"
      echo "  · LATER machine, and the repo holds your synced setup?"
      echo "      continue — existing files are backed up before being replaced."
      echo
      break
    fi
  done
fi
[ "$DRY_RUN" = true ] || mkdir -p "$CLAUDE_HOME"
# dotfiles/ itself is the manifest: every top-level file in it gets linked.
# To sync a new file, just add it to dotfiles/ — no script changes needed.
for path in dotfiles/*; do
  if [ -d "$path" ]; then
    echo "⚠ skipping $path/ — directories in dotfiles/ are not supported yet"
    continue
  fi
  [ -f "$path" ] && link_file "$(basename "$path")"
done

if ! command -v claude >/dev/null 2>&1; then
  echo
  echo "⚠ claude CLI not found — install Claude Code first:"
  echo "  curl -fsSL https://claude.ai/install.sh | bash"
  echo "  then re-run ./install.sh"
  [ "$DRY_RUN" = true ] || exit 1
  echo "· --dry-run: continuing; the plan below assumes nothing is registered yet"
fi

# ── Step 2: register ALL marketplaces ─────────────────────────────────────────

echo
# This repo itself, from the LOCAL clone path
register_marketplace "$MARKETPLACE" "$REPO"

# Everything else: from the record in the synced settings. Registrations are
# sequential on purpose — the claude CLI's registry has no documented
# concurrency guarantees, and this registry is exactly what we self-heal.
while IFS='=' read -r name src; do
  [ -z "$name" ] && continue
  [ "$name" = "$MARKETPLACE" ] && continue   # own marketplace handled above
  if [ "${src#/}" != "$src" ] && [ ! -d "$src" ]; then
    echo "⚠ skipping '$name': local path $src does not exist on this machine"
    continue
  fi
  register_marketplace "$name" "$src"
done < <(recorded_marketplaces)

# ── Step 3: install this repo's plugins ───────────────────────────────────────

echo
for p in "${PLUGINS[@]}"; do
  install_plugin "$p@$MARKETPLACE"
done

# ── Step 4: install everything else settings.json expects ────────────────────
# enabledPlugins in the synced settings is the source of truth for what
# should exist on every machine.

registered="$(registered_names)"
if [ "$DRY_RUN" = true ]; then
  # Step 2 hasn't actually run, so count recorded marketplaces as registered.
  registered="$registered
$(recorded_marketplaces 2>/dev/null | cut -d= -f1)"
fi
while IFS= read -r spec; do
  [ -z "$spec" ] && continue
  mp="${spec#*@}"
  [ "$mp" = "$MARKETPLACE" ] && continue   # handled in step 3
  if ! printf '%s\n' "$registered" | grep -qxF -- "$mp"; then
    echo "⚠ $spec: no source for marketplace '$mp' on this machine."
    echo "    → add '$mp' to extraKnownMarketplaces in dotfiles/settings.json"
    echo "      (./sync.sh on a machine where it works prints the exact JSON),"
    echo "      or delete this entry from dotfiles/settings.json enabledPlugins."
    continue
  fi
  install_plugin "$spec"
done < <(python3 -c '
import json, sys
try:
    s = json.load(open("dotfiles/settings.json"))
except Exception as e:
    sys.exit(f"could not parse dotfiles/settings.json: {e}")
for k, v in s.get("enabledPlugins", {}).items():
    if v:
        print(k)
')

# ── Step 5: a `sync-claude` command on PATH (real installs only) ─────────────
# Lets you run `sync-claude "message"` from any directory.
echo
case ":$PATH:" in *":$HOME/.local/bin:"*) bin_on_path=true ;; *) bin_on_path=false ;; esac
if [ "$CLAUDE_HOME" = "$HOME/.claude" ] && [ -d "$HOME/.local/bin" ] && [ "$bin_on_path" = true ]; then
  if [ "$DRY_RUN" = true ]; then
    echo "· would link sync-claude → $REPO/sync.sh"
  elif [ "$(readlink "$HOME/.local/bin/sync-claude" 2>/dev/null)" = "$REPO/sync.sh" ]; then
    echo "✔ sync-claude already on PATH"
  else
    ln -sf "$REPO/sync.sh" "$HOME/.local/bin/sync-claude"
    echo "✔ sync-claude installed — run: sync-claude \"what I changed\" (from anywhere)"
  fi
else
  echo "· tip: alias sync-claude='$REPO/sync.sh'   # add to your shell profile"
fi

# ── Step 6 (--adopt): offer to publish the adopted setup as its first commit ──
if [ "$ADOPT" = true ]; then
  echo
  if [ "$DRY_RUN" = true ]; then
    echo "· would offer to sync the adopted setup now (commit + push)"
  elif [ "$AUTO_YES" = true ]; then
    echo "· adopted setup is captured but not committed — review with 'git diff',"
    echo "  then publish with:  ./sync.sh \"first commit: adopt this machine's setup\""
  else
    read -r -p "Sync the adopted setup now (commit + push)? [Y/n] " answer
    case "$answer" in
      [nN]*)
        echo "· skipped — review with 'git diff', then publish with:"
        echo "    ./sync.sh \"first commit: adopt this machine's setup\""
        ;;
      *)
        ./sync.sh "first commit: adopt this machine's setup"
        ;;
    esac
  fi
fi

echo
echo "Done. Next steps:"
echo "  1. claude          # start Claude Code"
echo "  2. /login          # authenticate this machine (first time only)"
echo "  3. /skills         # verify your skills are loaded"
