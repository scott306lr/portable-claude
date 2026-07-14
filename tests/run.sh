#!/usr/bin/env bash
# tests/run.sh — plain-bash test suite for install.sh and sync.sh.
#
# No framework; needs only what the scripts themselves need (git, python3).
# Every scenario runs against a scratch CLAUDE_HOME and a scratch git clone
# with a local bare "origin", so nothing touches your real ~/.claude, this
# repo's checkout, or the network. The claude CLI is deliberately kept OFF
# the PATH — CLI-dependent paths are exercised via --dry-run only.
#
#   ./tests/run.sh

# shellcheck disable=SC2015,SC2012
# SC2015: `[ cond ] && ok || bad` is safe here — ok()/bad() never fail.
# SC2012: ls is only ever globbing our own timestamped fixture names.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcs-tests.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"   # normalize: macOS TMPDIR ends in '/', and the
                                 # scripts canonicalize paths — comparisons must match
trap 'rm -rf "$WORK"' EXIT

# Scripts must run without the claude CLI (and on both BSD and GNU userlands).
SAFE_PATH="/usr/bin:/bin"

PASS=0 FAIL=0

section() { printf '\n— %s\n' "$1"; }
ok()      { printf '  ✔ %s\n' "$1"; PASS=$((PASS+1)); }
bad()     { printf '  ✘ %s\n' "$1"; FAIL=$((FAIL+1)); }

assert_eq()    { [ "$2" = "$3" ] && ok "$1" || bad "$1 — want [$2], got [$3]"; }
assert_has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — output lacks [$3]" ;; esac; }
assert_lacks() { case "$2" in *"$3"*) bad "$1 — output unexpectedly has [$3]" ;; *) ok "$1" ;; esac; }

run() {  # run <claude_home> <workdir> <cmd...>  → sets OUT and CODE
  local home="$1" dir="$2"; shift 2
  OUT="$(cd "$dir" && CLAUDE_HOME="$home" PATH="$SAFE_PATH" "$@" 2>&1)"
  CODE=$?
}

# ── Fixture: copy of the working tree with a local bare origin ───────────────
# Copying (not cloning) means uncommitted script changes are what gets tested.
BARE="$WORK/origin.git"
CLONE="$WORK/clone"
git init -q --bare -b main "$BARE"
mkdir -p "$CLONE"
for item in dotfiles plugins .claude-plugin install.sh sync.sh README.md .gitignore; do
  cp -R "$REPO/$item" "$CLONE/"
done
(
  cd "$CLONE" || exit 1
  git init -q -b main
  git config user.email test@example.com
  git config user.name "test suite"
  git add -A
  git commit -qm "test fixture"
  git remote add origin "$BARE"
  git push -q -u origin main
)

# ── install.sh ────────────────────────────────────────────────────────────────

section "install.sh --dry-run on an empty HOME, no claude CLI"
mkdir -p "$WORK/home_a"
run "$WORK/home_a" "$CLONE" ./install.sh --dry-run
assert_eq    "exits 0" 0 "$CODE"
assert_has   "plans the dotfile links" "$OUT" "would link CLAUDE.md → repo"
assert_has   "notes the missing claude CLI but continues" "$OUT" "claude CLI not found"
assert_has   "plans registration from the record" "$OUT" "would register marketplace"
assert_lacks "links nothing for real" "$OUT" "✔ linked"
[ -e "$WORK/home_a/CLAUDE.md" ] && bad "dry-run created files" || ok "dry-run created nothing"

section "install.sh -y links, backs up, prunes backups to 3"
H="$WORK/home_b"; mkdir -p "$H"
echo "original content" > "$H/CLAUDE.md"
for i in 1 2 3 4; do
  echo "old $i" > "$H/CLAUDE.md.bak.2026010${i}000000"
  touch -t "2026010${i}0000" "$H/CLAUDE.md.bak.2026010${i}000000"
done
run "$H" "$CLONE" ./install.sh -y
assert_eq  "exits 1 (stops at the missing claude CLI)" 1 "$CODE"
assert_has "hints at --adopt for first machines" "$OUT" "./install.sh --adopt"
assert_has "backs up the pre-existing file" "$OUT" "backed up old version"
[ -L "$H/CLAUDE.md" ] && ok "CLAUDE.md became a symlink" || bad "CLAUDE.md is not a symlink"
assert_eq  "symlink targets the repo copy" "$CLONE/dotfiles/CLAUDE.md" "$(readlink "$H/CLAUDE.md")"
assert_eq  "backups pruned to 3" 3 "$(ls "$H"/CLAUDE.md.bak.* | wc -l | tr -d ' ')"
assert_has "prune is reported" "$OUT" "pruned old backup"

section "install.sh --rollback restores the newest backup"
run "$H" "$CLONE" ./install.sh --rollback --dry-run
assert_has "previews the restore" "$OUT" "would restore CLAUDE.md"
[ -L "$H/CLAUDE.md" ] && ok "dry-run rollback touched nothing" || bad "dry-run rollback mutated state"
run "$H" "$CLONE" ./install.sh --rollback
assert_eq  "exits 0" 0 "$CODE"
assert_has "reports the restore" "$OUT" "✔ restored CLAUDE.md"
[ -L "$H/CLAUDE.md" ] && bad "symlink still present after rollback" || ok "symlink removed"
assert_eq  "original content is back" "original content" "$(cat "$H/CLAUDE.md")"
run "$H" "$CLONE" ./install.sh --rollback
assert_has "second rollback is a no-op" "$OUT" "no backup to restore"

section "install.sh --rollback refuses a destination it didn't create"
rm -f "$H/settings.json"
echo "user file" > "$H/settings.json"
echo "bak" > "$H/settings.json.bak.20260101000000"
run "$H" "$CLONE" ./install.sh --rollback
assert_has "refuses the non-symlink" "$OUT" "not a symlink; not touching"
assert_eq  "file left untouched" "user file" "$(cat "$H/settings.json")"

section "install.sh suggests the alias when the seam is overridden"
run "$WORK/home_a" "$CLONE" ./install.sh --dry-run
assert_has   "suggests the sync-claude alias" "$OUT" "alias sync-claude="
assert_lacks "does not touch the real ~/.local/bin" "$OUT" "sync-claude installed"

section "install.sh rejects unknown flags"
run "$WORK/home_a" "$CLONE" ./install.sh --bogus
assert_eq  "exits 2" 2 "$CODE"
assert_has "prints usage" "$OUT" "usage:"

# ── sync.sh ───────────────────────────────────────────────────────────────────

section "sync.sh gate: unlinked dotfiles block hard"
HC="$WORK/home_c"; mkdir -p "$HC"
run "$HC" "$CLONE" ./sync.sh --dry-run
assert_eq  "exits 1" 1 "$CODE"
assert_has "names an unlinked file" "$OUT" "CLAUDE.md is not linked"
assert_has "points at install.sh" "$OUT" "Run ./install.sh first"

section "sync.sh clean run against a wired HOME"
for f in "$CLONE"/dotfiles/*; do ln -s "$f" "$HC/$(basename "$f")"; done
run "$HC" "$CLONE" ./sync.sh "test sync"
assert_eq  "exits 0" 0 "$CODE"
assert_has "nothing to commit" "$OUT" "nothing new to commit"

section "sync.sh --dry-run previews the commit without writing"
echo "extra line" >> "$CLONE/README.md"
run "$HC" "$CLONE" ./sync.sh --dry-run
assert_eq  "exits 0" 0 "$CODE"
assert_has "skips the pull" "$OUT" "skipping pull"
assert_has "previews the commit" "$OUT" "would commit and push"
assert_has "lists the changed file" "$OUT" "README.md"
assert_eq  "committed nothing" "test fixture" "$(git -C "$CLONE" log -1 --format=%s)"

section "sync.sh secret gate blocks a leak before commit"
# Assembled at runtime so this test file itself never matches the gate.
fake_token="ghp_$(printf '%s' '0123456789abcdefghijklmnopqrstuvwxyz')"
printf 'notes\n%s\n' "$fake_token" > "$CLONE/leak.md"
run "$HC" "$CLONE" ./sync.sh "must never land"
assert_eq  "exits 1" 1 "$CODE"
assert_has "flags the finding" "$OUT" "possible secret"
assert_has "names file and line" "$OUT" "leak.md"
assert_has "offers the escape hatch" "$OUT" "SKIP_SECRET_SCAN=1"
assert_eq  "committed nothing" "test fixture" "$(git -C "$CLONE" log -1 --format=%s)"
rm "$CLONE/leak.md"

section "sync.sh secret gate catches a leak inside an UNTRACKED directory"
mkdir -p "$CLONE/newdir"
printf '%s\n' "$fake_token" > "$CLONE/newdir/leak.md"
run "$HC" "$CLONE" ./sync.sh "must never land"
assert_eq  "exits 1" 1 "$CODE"
assert_has "finds the nested leak" "$OUT" "newdir/leak.md"
assert_eq  "committed nothing" "test fixture" "$(git -C "$CLONE" log -1 --format=%s)"
rm -rf "$CLONE/newdir"

section "sync.sh secret gate knows newer provider prefixes"
fake_hf="hf_$(printf '%s' 'abcdefghijklmnopqrstuvwxyz0123456789')"
printf 'notes\n%s\n' "$fake_hf" > "$CLONE/leak.md"
run "$HC" "$CLONE" ./sync.sh "must never land"
assert_eq  "exits 1" 1 "$CODE"
assert_has "flags the hugging face token" "$OUT" "leak.md"
assert_eq  "committed nothing" "test fixture" "$(git -C "$CLONE" log -1 --format=%s)"
rm "$CLONE/leak.md"

section "sync.sh bumps changed plugin versions, commits, pushes"
PLUGIN="$(python3 -c "import json; print(json.load(open('$CLONE/.claude-plugin/marketplace.json'))['plugins'][0]['name'])")"
PLUGIN_JSON="$CLONE/plugins/$PLUGIN/.claude-plugin/plugin.json"
old_ver="$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['version'])")"
echo "tweak" >> "$CLONE/plugins/$PLUGIN/test-tweak.md"
run "$HC" "$CLONE" ./sync.sh "bump test"
assert_eq  "exits 0" 0 "$CODE"
assert_has "reports the bump" "$OUT" "✔ bumped: $PLUGIN"
new_ver="$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['version'])")"
[ "$new_ver" != "$old_ver" ] && ok "plugin.json version changed ($old_ver → $new_ver)" \
                             || bad "plugin.json version unchanged ($old_ver)"
cat_ver="$(python3 -c "import json; print([p['version'] for p in json.load(open('$CLONE/.claude-plugin/marketplace.json'))['plugins'] if p['name']=='$PLUGIN'][0])")"
assert_eq  "marketplace catalog agrees" "$new_ver" "$cat_ver"
assert_has "commits" "$OUT" "✔ committed"
assert_eq  "pushed to origin" "bump test" "$(git -C "$BARE" log -1 --format=%s)"

section "sync.sh pulls remote changes first"
C2="$WORK/clone2"
git clone -q "$BARE" "$C2"
(
  cd "$C2" || exit 1
  git config user.email test@example.com
  git config user.name "test suite"
  echo "from machine B" >> README.md
  git add -A && git commit -qm "remote change" && git push -q
)
run "$HC" "$CLONE" ./sync.sh "pull test"
assert_eq  "exits 0" 0 "$CODE"
grep -q "from machine B" "$CLONE/README.md" && ok "remote change integrated" \
                                            || bad "remote change missing after sync"

section "sync.sh drift check: paste-ready JSON, autoUpdate kept, local paths skipped"
mkdir -p "$HC/plugins"
cat > "$HC/plugins/known_marketplaces.json" <<'EOF'
{
  "foo-mkt": {"source": {"source": "github", "repo": "acme/foo-mkt"}, "autoUpdate": true},
  "local-mkt": {"source": {"source": "directory", "path": "/tmp/nowhere"}}
}
EOF
run "$HC" "$CLONE" ./sync.sh --dry-run
assert_eq    "exits 0 (warn-only)" 0 "$CODE"
assert_has   "warns about the unrecorded marketplace" "$OUT" "missing from extraKnownMarketplaces"
assert_has   "prints the source" "$OUT" "acme/foo-mkt"
assert_has   "keeps the autoUpdate flag" "$OUT" '"autoUpdate": true'
assert_lacks "skips machine-local directory sources" "$OUT" "local-mkt"

section "sync.sh works when invoked through a symlink (sync-claude)"
ln -s "$CLONE/sync.sh" "$WORK/sync-claude"
run "$HC" "$WORK" "$WORK/sync-claude" --dry-run
assert_eq  "exits 0" 0 "$CODE"
assert_has "resolves the repo through the symlink" "$OUT" "would refresh marketplace"

section "install.sh --adopt captures an existing machine setup"
HA="$WORK/home_adopt"; mkdir -p "$HA/skills/my-skill" "$HA/hooks" "$HA/plugins"
echo "my precious memory" > "$HA/CLAUDE.md"
printf '{\n  "enabledPlugins": {}\n}\n' > "$HA/settings.json"
echo "skill body" > "$HA/skills/my-skill/SKILL.md"
echo "hook body" > "$HA/hooks/my-hook.sh"
cat > "$HA/plugins/known_marketplaces.json" <<'EOF'
{"acme-mkt": {"source": {"source": "github", "repo": "acme/mkt"}, "autoUpdate": true}}
EOF
run "$HA" "$CLONE" ./install.sh --adopt --dry-run
assert_eq  "dry-run exits 0" 0 "$CODE"
assert_has "previews file adoption" "$OUT" "would adopt CLAUDE.md"
assert_has "previews skills adoption" "$OUT" "would adopt skills/"
assert_has "previews hooks adoption" "$OUT" "would adopt hooks/"
assert_has "previews the marketplace record" "$OUT" "would record marketplaces: acme-mkt"
assert_has "previews the first-commit offer" "$OUT" "would offer to sync the adopted setup"
assert_has "previews owner personalization" "$OUT" "would set marketplace owner to 'test suite'"
grep -q "my precious memory" "$CLONE/dotfiles/CLAUDE.md" \
  && bad "dry-run modified the repo" || ok "dry-run left the repo untouched"
[ -e "$CLONE/dotfiles/skills/my-skill" ] \
  && bad "dry-run adopted the skills dir" || ok "dry-run adopted no directories"

run "$HA" "$CLONE" ./install.sh --adopt -y
assert_eq  "exits 1 (stops at the missing claude CLI)" 1 "$CODE"
assert_eq  "repo CLAUDE.md is the machine's" "my precious memory" "$(cat "$CLONE/dotfiles/CLAUDE.md")"
[ -f "$CLONE/dotfiles/skills/my-skill/SKILL.md" ] \
  && ok "skill captured verbatim into dotfiles/skills" || bad "skill missing from dotfiles/skills"
[ -e "$CLONE/plugins/$PLUGIN/skills/my-skill" ] \
  && bad "skill moved into the plugin (rebranded)" || ok "skill NOT moved into the plugin"
[ -L "$HA/CLAUDE.md" ] && ok "machine file linked after adoption" || bad "machine file not linked"
assert_eq  "skills dir linked to the repo" "$CLONE/dotfiles/skills" "$(readlink "$HA/skills")"
[ -f "$HA/skills/my-skill/SKILL.md" ] \
  && ok "skill still user-level after adoption (same name, same scope)" \
  || bad "skill unreachable through the link"
ls -d "$HA"/skills.bak.* >/dev/null 2>&1 \
  && ok "pre-link skills backup kept" || bad "skills backup missing"
assert_eq  "hooks dir linked to the repo" "$CLONE/dotfiles/hooks" "$(readlink "$HA/hooks")"
[ -f "$CLONE/dotfiles/hooks/my-hook.sh" ] \
  && ok "hook captured verbatim into dotfiles/hooks" || bad "hook missing from dotfiles/hooks"
rec="$(python3 -c "import json; print(json.load(open('$CLONE/dotfiles/settings.json'))['extraKnownMarketplaces']['acme-mkt']['autoUpdate'])")"
assert_eq  "marketplace recorded with autoUpdate" "True" "$rec"
own="$(python3 -c "import json; print(json.load(open('$CLONE/.claude-plugin/marketplace.json'))['owner']['name'])")"
assert_eq  "marketplace owner personalized from git identity" "test suite" "$own"

run "$HA" "$CLONE" ./install.sh --adopt -y
assert_has "re-adopt is idempotent (dirs already linked)" "$OUT" "skills already linked"
[ -f "$CLONE/dotfiles/skills/my-skill/SKILL.md" ] \
  && ok "re-adopt kept the captured skill" || bad "re-adopt lost the captured skill"

section "install.sh --rollback restores an adopted directory"
run "$HA" "$CLONE" ./install.sh --rollback
assert_has "reports the dir restore" "$OUT" "✔ restored skills"
[ -L "$HA/skills" ] && bad "skills is still a symlink after rollback" || ok "skills symlink removed"
[ -f "$HA/skills/my-skill/SKILL.md" ] \
  && ok "original skills dir restored" || bad "original skills dir missing"

section "install.sh --adopt refuses to clobber an already-adopted repo"
HG="$WORK/home_guard"; mkdir -p "$HG"
echo "machine two memory" > "$HG/CLAUDE.md"
run "$HG" "$CLONE" ./install.sh --adopt -y
assert_eq  "blocks -y adopt of an adopted repo" 1 "$CODE"
assert_has "explains the overwrite risk" "$OUT" "already holds an adopted setup"
assert_has "offers the escape hatch" "$OUT" "FORCE_ADOPT=1"
assert_eq  "repo CLAUDE.md untouched" "my precious memory" "$(cat "$CLONE/dotfiles/CLAUDE.md")"
OUT="$(cd "$CLONE" && printf 'n\n' | CLAUDE_HOME="$HG" PATH="$SAFE_PATH" ./install.sh --adopt 2>&1)"; CODE=$?
assert_eq  "interactive decline aborts" 1 "$CODE"
assert_has "reports the abort" "$OUT" "aborted, nothing changed"
run "$HG" "$CLONE" ./install.sh --adopt --dry-run
assert_eq  "dry-run previews the guard without stopping" 0 "$CODE"
assert_has "dry-run mentions the confirmation" "$OUT" "would stop here for confirmation"
OUT="$(cd "$CLONE" && FORCE_ADOPT=1 CLAUDE_HOME="$HG" PATH="$SAFE_PATH" ./install.sh --adopt -y 2>&1)"; CODE=$?
assert_eq  "FORCE_ADOPT=1 proceeds (stops later at the missing CLI)" 1 "$CODE"
assert_has "notes the override" "$OUT" "FORCE_ADOPT=1 → continuing"
assert_eq  "repo CLAUDE.md is now machine two's" "machine two memory" "$(cat "$CLONE/dotfiles/CLAUDE.md")"

section "install.sh --adopt offers the first-commit sync (stub claude CLI)"
# A stub claude on PATH lets install.sh run to completion, so the prompt at
# the end is reachable and the accepted sync pushes to the fixture origin.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/claude"
chmod +x "$WORK/bin/claude"
HB="$WORK/home_firstcommit"; mkdir -p "$HB"
echo "machine one memory" > "$HB/CLAUDE.md"
printf '{\n  "enabledPlugins": {}\n}\n' > "$HB/settings.json"

OUT="$(cd "$CLONE" && yes | CLAUDE_HOME="$HB" PATH="$SAFE_PATH:$WORK/bin" ./install.sh --adopt 2>&1)"; CODE=$?
assert_eq  "exits 0 (stub claude present)" 0 "$CODE"
# (read -p shows its prompt only on a TTY, so the prompt text itself isn't
# capturable here — the accepted/declined behaviors below prove the flow.)
assert_has "sync ran and committed" "$OUT" "✔ committed: first commit: adopt this machine's setup"
assert_eq  "first commit reached origin" "first commit: adopt this machine's setup" \
           "$(git -C "$BARE" log -1 --format=%s)"
assert_has "prints the machine-2 bootstrap with the real URL" "$OUT" "git clone $BARE ~/claude-setup"

HB2="$WORK/home_firstcommit2"; mkdir -p "$HB2"
echo "machine declined" > "$HB2/CLAUDE.md"
# stdin: confirm the machine-2 guard (y), overwrite CLAUDE.md at the link
# step (y), decline the first-commit sync (n).
OUT="$(cd "$CLONE" && printf 'y\ny\nn\n' | CLAUDE_HOME="$HB2" PATH="$SAFE_PATH:$WORK/bin" ./install.sh --adopt 2>&1)"; CODE=$?
assert_eq  "exits 0" 0 "$CODE"
assert_has "declining prints the manual command" "$OUT" 'review with'
assert_lacks "declining does not commit the new adoption" "$OUT" "✔ committed: first commit"

OUT="$(cd "$CLONE" && CLAUDE_HOME="$HB2" PATH="$SAFE_PATH:$WORK/bin" ./install.sh --adopt -y 2>&1)"; CODE=$?
assert_has "-y skips the prompt, prints the command instead" "$OUT" "captured but not committed"

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
