# Marketplace sources live in extraKnownMarketplaces, not a snapshot

Cross-machine marketplace sources are recorded in `extraKnownMarketplaces`
in `dotfiles/settings.json` — a documented Claude Code settings key that
already syncs via the dotfile symlink. We deleted the previous mechanism
(sync.sh scraping `~/.claude/plugins/known_marketplaces.json` into a
committed `marketplaces.snapshot.json`, install.sh reading it back) because
the registry file's schema is undocumented, the write and read halves had
already drifted into different formats unnoticed, and the whole round-trip
duplicated a native mechanism. Do not reintroduce a snapshot pipeline.

Consequences: capture is manual but prompted — sync.sh's read-only drift
check warns with paste-ready JSON when a registered marketplace is missing
from the record. `enabledPlugins` does NOT auto-install plugins (docs
verified 2026-07-14), so install.sh still runs `claude plugin install`
itself, sequentially — the CLI documents no concurrency guarantees for
registry writes.

Verified empirically 2026-07-14 on Claude Code v2.1.207 (clean
CLAUDE_CONFIG_DIR + authenticated startup with a marketplace declared in
settings but absent from the registry): `extraKnownMarketplaces` does NOT
auto-register marketplaces — it is a declaration/allowlist (the binary's
policy strings read "pre-register allowed marketplaces"), so install.sh's
registration loop is load-bearing, not belt-and-suspenders. Also observed:
`claude plugin marketplace remove` writes through to the symlinked
settings.json, deleting both the `extraKnownMarketplaces` and
`enabledPlugins` entries — and `add` most likely wrote the original
entries too (inferred, not directly observed) — so the record largely
maintains itself while the symlinks are intact. Re-check on major CLI
upgrades.
