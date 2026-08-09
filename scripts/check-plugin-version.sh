#!/usr/bin/env bash
# check-plugin-version.sh — refuse a change to packaged plugin content that does not bump the
# plugin version.
#
# Why this gate exists, measured rather than assumed. The installed plugin is cached in a
# VERSION-NAMED directory:
#
#   ~/.claude/plugins/cache/bioinfo/bioinfo/<version>/...
#
# On 2026-08-10 that cache held exactly one directory, 0.1.0, and its
# skills/bioinfo-analyze/references/runbook.md differed from this repo's by 117 lines —
# including the `comm = java` filter in the section-5 pid-recording loop that hooks/
# guard-workdir.sh's own comment says it shares. `.claude-plugin/plugin.json` still declared
# 0.1.0, and 27 commits had touched skills/ or agents/ since that file was last modified. So a
# running agent, loading the skill from the cache, followed the PRE-fix recipe: pid detection
# matched the tmux server alongside the JVM, reported "found 2", wrote no nextflow.pid, and left
# hooks/guard-workdir.sh's live-run check reading a file that does not exist — for a run that was
# executing at the time. The merged fix was real; it just never reached the thing running it.
#
# A version-named cache only refreshes when the version changes, so shipping skill or agent edits
# under an unchanged version is the mechanism by which merged fixes silently fail to take effect.
#
# Usage:
#   scripts/check-plugin-version.sh [BASE_REF]     # default BASE_REF: origin/main
#
# Exit 0 clean, 1 on failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

BASE_REF="${1:-origin/main}"

PLUGIN_JSON=.claude-plugin/plugin.json
MARKET_JSON=.claude-plugin/marketplace.json

# Paths whose content is served to a running agent out of the version-named cache. A change to
# any of these that does not bump the version cannot reach an already-installed plugin.
PACKAGED_PATHS=(skills agents hooks "$PLUGIN_JSON")

fail=0
note() { printf '  %-5s %s\n' "$1" "$2"; }
bad()  { note FAIL "$1"; fail=$((fail + 1)); }
ok()   { note ok "$1"; }

# These have to be parsed as JSON, not grepped: `"version"` appears as three different keys
# across the two manifests and a line match cannot tell them apart. python3 rather than jq —
# jq is not installed on this project's own WSL host and no other script in this repo assumes it,
# so a jq dependency would make the gate green in CI and unrunnable where it is actually needed.
for f in "$PLUGIN_JSON" "$MARKET_JSON"; do
  [ -f "$f" ] || { echo "check-plugin-version: missing $f" >&2; exit 1; }
done

# One parse, one line of output per field, so a malformed manifest fails once and loudly rather
# than degrading each field to an empty string that the comparisons below would read as a
# mismatch. The marketplace entry is matched by NAME, not by array position: a second plugin
# added ahead of it would otherwise make index 0 the wrong one and this gate would silently
# compare an unrelated version.
if ! read -r PLUGIN_NAME PLUGIN_VER MARKET_PLUGIN_VER MARKET_META_VER < <(
  python3 - "$PLUGIN_JSON" "$MARKET_JSON" <<'PY'
import json, sys
def load(p):
    try:
        return json.load(open(p))
    except Exception as e:
        sys.stderr.write("check-plugin-version: cannot parse %s: %s\n" % (p, e))
        sys.exit(2)
pj, mj = load(sys.argv[1]), load(sys.argv[2])
name = pj.get("name") or "-"
entry = next((p for p in mj.get("plugins", []) if p.get("name") == name), {})
print(name,
      pj.get("version") or "-",
      entry.get("version") or "-",
      (mj.get("metadata") or {}).get("version") or "-")
PY
); then
  exit 1
fi

echo "== plugin version =="

[ "$PLUGIN_VER" != "-" ] || bad "$PLUGIN_JSON declares no .version"
[ "$PLUGIN_NAME" != "-" ] || bad "$PLUGIN_JSON declares no .name"

semver_re='^[0-9]+\.[0-9]+\.[0-9]+([-+].*)?$'
if [[ ! "$PLUGIN_VER" =~ $semver_re ]]; then
  bad "$PLUGIN_JSON version '$PLUGIN_VER' is not semver"
else
  ok "$PLUGIN_JSON version $PLUGIN_VER"
fi

# The three versions are three separate literals in two files and nothing but this check keeps
# them in step. A marketplace entry left behind is served to installers as the truth.
if [ "$MARKET_PLUGIN_VER" != "$PLUGIN_VER" ]; then
  bad "marketplace.json plugins[$PLUGIN_NAME].version ($MARKET_PLUGIN_VER) != plugin.json version ($PLUGIN_VER)"
else
  ok "marketplace.json plugins[$PLUGIN_NAME].version agrees"
fi
if [ "$MARKET_META_VER" != "$PLUGIN_VER" ]; then
  bad "marketplace.json metadata.version ($MARKET_META_VER) != plugin.json version ($PLUGIN_VER)"
else
  ok "marketplace.json metadata.version agrees"
fi

echo "== packaged content vs $BASE_REF =="

if ! git rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null; then
  note SKIP "$BASE_REF not resolvable here; drift check not run (version consistency still checked)"
  echo
  echo "check-plugin-version: $fail failure(s)"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

MERGE_BASE=$(git merge-base "$BASE_REF" HEAD 2>/dev/null) || MERGE_BASE="$BASE_REF"

changed=$(git diff --name-only "$MERGE_BASE"..HEAD -- "${PACKAGED_PATHS[@]}" 2>/dev/null)

if [ -z "$changed" ]; then
  ok "no packaged content changed; no version bump required"
else
  n=$(printf '%s\n' "$changed" | grep -c .)
  BASE_VER=$(git show "$MERGE_BASE:$PLUGIN_JSON" 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("version") or "")
except Exception: print("")')
  if [ -z "$BASE_VER" ]; then
    note SKIP "cannot read $PLUGIN_JSON at $MERGE_BASE; drift check not run"
  elif [ "$BASE_VER" = "$PLUGIN_VER" ]; then
    bad "$n packaged file(s) changed but the version is still $PLUGIN_VER.
        Bump .version in $PLUGIN_JSON and both version fields in $MARKET_JSON.
        The plugin cache is version-named — an unchanged version means an installed
        plugin keeps serving the old content and this change never takes effect.
        Changed:
$(printf '%s\n' "$changed" | sed 's/^/          /')"
  else
    ok "$n packaged file(s) changed; version bumped $BASE_VER -> $PLUGIN_VER"
  fi
fi

echo
echo "check-plugin-version: $fail failure(s)"
[ "$fail" -eq 0 ] || exit 1
exit 0
