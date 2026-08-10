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

# SemVer, by the published grammar rather than a loose shape check. A bash ERE of
# `[0-9]+\.[0-9]+\.[0-9]+([-+].*)?` accepts `1.2.3-`, `1.2.3+` and `01.2.3` — a typo that would
# sail through this gate and leave the manifests declaring a version that is not a version.
# semver() also implements precedence comparison (numeric identifiers numerically, alphanumeric
# ones lexically, a pre-release sorting BEFORE its own release), which the downgrade check below
# needs and string comparison cannot express: "0.10.0" < "0.9.0" as strings.
semver() {  # semver valid <v>  |  semver gt <a> <b>   -> exit status only
  python3 - "$@" <<'PY'
import re, sys

# [0-9] throughout, never \d: in Python \d matches any Unicode decimal digit, so
# `1.2.3\u0662` would parse as SemVer -- and int() accepts that character too, so it would go on
# to compare as a real number and report a successful increase. SemVer numeric identifiers are
# ASCII 0-9 only. re.ASCII is set as well, belt and braces, since it also constrains the
# \w-class shorthands if this pattern is ever extended.
SEMVER = re.compile(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    r'(?:-((?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)'
    r'(?:\.(?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?'
    r'(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$', re.ASCII)

ASCII_DIGITS = re.compile(r'^[0-9]+$')

def parse(v):
    m = SEMVER.match(v)
    return m if m else None

def key(m):
    core = tuple(int(m.group(i)) for i in (1, 2, 3))
    pre = m.group(4)
    if pre is None:
        return (core, ())            # no pre-release sorts above any pre-release
    ids = []
    for p in pre.split('.'):
        # Numeric identifiers compare numerically and always rank below alphanumeric ones.
        # str.isdigit() is likewise Unicode-aware ('\u0662'.isdigit() is True). The regex above
        # already excludes those, but this classification decides numeric-vs-alphanumeric
        # ORDERING, so it is checked against ASCII explicitly rather than resting on that.
        ids.append((0, int(p), '') if ASCII_DIGITS.match(p) else (1, 0, p))
    return (core, tuple(ids))

op = sys.argv[1]
if op == 'valid':
    sys.exit(0 if parse(sys.argv[2]) else 1)
if op == 'gt':
    a, b = parse(sys.argv[2]), parse(sys.argv[3])
    if not a or not b:
        sys.exit(2)                  # unparseable: caller reports it separately
    ka, kb = key(a), key(b)
    if ka[0] != kb[0]:
        sys.exit(0 if ka[0] > kb[0] else 1)
    # Equal cores: no pre-release outranks any pre-release. Build metadata (group 5) is
    # explicitly ignored for precedence, per the spec.
    if not ka[1] and kb[1]:
        sys.exit(0)
    if ka[1] and not kb[1]:
        sys.exit(1)
    sys.exit(0 if ka[1] > kb[1] else 1)
sys.exit(2)
PY
}

if ! semver valid "$PLUGIN_VER"; then
  bad "$PLUGIN_JSON version '$PLUGIN_VER' is not valid SemVer (https://semver.org)"
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
  changed_list=$(printf '%s\n' "$changed" | sed 's/^/          /')
  if [ -z "$BASE_VER" ]; then
    note SKIP "cannot read $PLUGIN_JSON at $MERGE_BASE; drift check not run"
  elif ! semver valid "$BASE_VER"; then
    bad "$PLUGIN_JSON at $MERGE_BASE declares '$BASE_VER', which is not valid SemVer,
        so this gate cannot tell whether $PLUGIN_VER is an increase. Fix the base first."
  elif semver gt "$PLUGIN_VER" "$BASE_VER"; then
    ok "$n packaged file(s) changed; version raised $BASE_VER -> $PLUGIN_VER"
  else
    # "different" is not enough. 0.2.0 -> 0.1.0 is a change, and it points every installer at a
    # 0.1.0 cache directory that already exists and still holds the OLD content — precisely the
    # failure this gate exists to prevent, dressed up as a bump.
    bad "$n packaged file(s) changed but the version did not increase ($BASE_VER -> $PLUGIN_VER).
        Raise .version in $PLUGIN_JSON and both version fields in $MARKET_JSON.
        The plugin cache is version-named: a version that is unchanged — or moved BACKWARD to one
        already on disk — means an installed plugin keeps serving the old content and this change
        never takes effect.
        Changed:
$changed_list"
  fi
fi

echo
echo "check-plugin-version: $fail failure(s)"
[ "$fail" -eq 0 ] || exit 1
exit 0
