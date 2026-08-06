#!/usr/bin/env bash
# preflight.sh — read-only gate before any nf-core launch on this host. Safe to re-run.
# usage: bash preflight.sh <windows-visible-run-dir> <estimated_work_GB>
set -euo pipefail

RUNDIR="${1:?usage: preflight.sh <rundir> <est_work_gb>}"
EST_GB="${2:?usage: preflight.sh <rundir> <est_work_gb>}"
RUNID="$(basename "$RUNDIR")"
WORKROOT="${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}"
WORKDIR="$WORKROOT/$RUNID/work"
REFS="${BIOINFO_REFS:-/refs}"
TSV="$(cd "$(dirname "$0")/.." && pwd)/config/pipelines.tsv"
MANIFEST="$(cd "$(dirname "$0")/.." && pwd)/config/refs.manifest.tsv"

fail=0; warn=0
ok()   { printf '  OK    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
note() { printf '  WARN  %s\n' "$*"; warn=$((warn+1)); }
# nearest existing ancestor — this script creates nothing.
upto() { local d="$1"; while [ ! -d "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done; printf '%s' "$d"; }

echo "== host =="
cores="$(nproc)"
memgb="$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)"
ok "cores visible to WSL = $cores"
if [ "$memgb" -ge 40 ]; then
  ok "RAM visible to WSL = ${memgb} GB"
else
  note "RAM visible to WSL = ${memgb} GB. WSL2 defaults to ~half of host RAM; set memory= in %USERPROFILE%\\.wslconfig and 'wsl --shutdown'."
fi

echo "== docker =="
if docker info >/dev/null 2>&1; then
  ok "docker responsive ($(docker version --format '{{.Server.Version}}'))"
  droot="$(docker info --format '{{.DockerRootDir}}')"
  case "$droot" in
    /mnt/*) bad "docker data-root is on drvfs: $droot" ;;
    *)      ok "docker data-root = $droot" ;;
  esac
else
  bad "docker not responding (pid1=$(ps -p 1 -o comm=)). Try: sudo systemctl start docker"
fi

echo "== filesystems =="
case "$WORKDIR" in
  /mnt/*) bad "work dir is on drvfs: $WORKDIR — must be ext4, refusing" ;;
  *)      ok "work dir on ext4: $WORKDIR" ;;
esac
[ -d "$WORKROOT" ] || note "$WORKROOT does not exist yet — free space measured on $(upto "$WORKDIR")"
avail_gb="$(df -BG --output=avail "$(upto "$WORKDIR")" | tail -1 | tr -dc '0-9')"
need_gb=$(( (EST_GB * 3 + 1) / 2 ))
if [ "$avail_gb" -ge "$need_gb" ]; then
  ok "ext4 free ${avail_gb} GB >= 1.5x estimate (${need_gb} GB)"
else
  bad "ext4 free ${avail_gb} GB < 1.5x estimate (${need_gb} GB). DO NOT LAUNCH."
fi
WINMNT="$(printf '%s' "${BIOINFO_HOME:-/mnt/d/bioinfo-agent}" | grep -oE '^/mnt/[a-z]+' || true)"
if [ -n "$WINMNT" ] && mountpoint -q "$WINMNT" 2>/dev/null; then
  d_gb="$(df -BG --output=avail "$WINMNT" | tail -1 | tr -dc '0-9')"
  ok "$WINMNT free ${d_gb} GB (rsync target for results)"
else
  note "${WINMNT:-the BIOINFO_HOME mount} is not mounted — copy-out target for results unchecked"
fi

echo "== nextflow =="
if command -v nextflow >/dev/null 2>&1; then
  ok "nextflow $(nextflow -v 2>&1 | head -1)"
else
  bad "nextflow not on PATH"
fi
REV=""; PIPE=""
if [ -f "$RUNDIR/cmd.sh" ]; then
  if grep -qE '(^| )-r +"?\$?\{?[0-9A-Za-z._-]+\}?"?' "$RUNDIR/cmd.sh" && ! grep -qE '(^| )-r +"?\$?\{?(dev|master|main)\}?"?( |$)' "$RUNDIR/cmd.sh"; then
    REV="$(grep -oE '(^| )-r +"?\$?\{?[0-9A-Za-z._-]+\}?"?' "$RUNDIR/cmd.sh" | head -1 | tr -d ' "${}' | sed 's/^-r//')"
    if grep -qE "^[[:space:]]*${REV}=" "$RUNDIR/cmd.sh"; then   # -r $REV — resolve the assignment
      # sed strips a trailing comment first: the cmd.sh template writes
      #   REV=3.18.0        # from config/pipelines.tsv
      # and `tr -d ' '` alone would glue the comment onto the revision.
      REV="$(grep -E "^[[:space:]]*${REV}=" "$RUNDIR/cmd.sh" | head -1 | cut -d= -f2- | sed 's/#.*$//' | tr -d '\047" ')"
    fi
    # Re-test AFTER resolving. The check above reads the command line as text, so
    # `-r "$REV"` with `REV=dev` assigned two lines up passes it: the literal string
    # "dev" never appears next to -r. Every shipped cmd.sh uses exactly that indirect
    # form, which made the floating-branch gate unreachable for the template the repo
    # tells you to copy.
    case "$REV" in
      dev|master|main) bad "cmd.sh resolves -r to the floating branch '$REV'. Pin an exact release tag." ;;
      *)               ok "revision pinned in cmd.sh: $REV" ;;
    esac
  else
    bad "cmd.sh has no -r revision pin, or pins a floating branch (dev/master/main)"
  fi
  PIPE="$(grep -oE 'nf-core/[A-Za-z0-9_-]+' "$RUNDIR/cmd.sh" | head -1 | cut -d/ -f2 || true)"
  grep -q -- '-work-dir' "$RUNDIR/cmd.sh" || bad "cmd.sh does not set -work-dir"
  grep -q -- '-profile docker' "$RUNDIR/cmd.sh" || note "cmd.sh does not use -profile docker"
else
  bad "missing $RUNDIR/cmd.sh"
fi

echo "== stocked set =="
if [ -z "$PIPE" ]; then
  bad "cmd.sh names no nf-core/<pipeline> to look up"
elif [ ! -f "$TSV" ]; then
  note "$TSV absent — pipeline and revision unchecked against the stocked set"
else
  pin="$(awk -F'\t' -v p="$PIPE" '/^#/{next} $1=="pipeline"&&$2=="revision"{next} $1==p{print $2; exit}' "$TSV")"
  if [ -z "$pin" ]; then
    bad "nf-core/$PIPE has no row in $TSV — it is not stocked"
  elif [ "$pin" = "$REV" ]; then
    ok "nf-core/$PIPE -r $REV matches the pin in $TSV"
  else
    # FAIL, not warn. config/pipelines.tsv, references/new-pipeline.md and SKILL.md all
    # tell the reader this gate "refuses" a disagreeing -r; a warning that still exits 0
    # made a passing preflight mean nothing about the pin. Deviating from the pin is a
    # procurement decision -- change the row, do not talk past it.
    bad "nf-core/$PIPE -r ${REV:-none} disagrees with the pin $pin in $TSV. Change the row or the -r; do not launch on a pin nobody approved."
  fi
fi

echo "== samplesheet =="
SS="$RUNDIR/samplesheet.csv"
nrow=""; nsamp=""
if [ -f "$SS" ]; then
  ok "found $SS"
  if LC_ALL=C grep -q $'\r' "$SS"; then
    bad "samplesheet has CRLF line endings (edited on Windows). Fix: sed -i 's/\r\$//' \"$SS\""
  else
    ok "LF line endings"
  fi
  hdr="$(head -1 "$SS")"
  ok "header: $hdr"
  nrow="$(tail -n +2 "$SS" | grep -c '[^[:space:]]' || true)"
  nsamp="$(tail -n +2 "$SS" | cut -d, -f1 | sort -u | grep -c '[^[:space:]]' || true)"
  [ "$nrow" -gt 0 ] && ok "$nrow data rows, $nsamp distinct first-column IDs" || bad "no data rows"
  dups="$(tail -n +2 "$SS" | cut -d, -f1 | sort | uniq -d | tr '\n' ' ')"
  [ -z "$dups" ] || note "repeated first-column IDs: $dups (legitimate for merged tech reps; confirm it is intended)"
  while read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$p" ]; then ok "input exists: $p"; else bad "input MISSING: $p"; fi
  done < <(tail -n +2 "$SS" | tr ',' '\n' | tr -d '"' | grep '/' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u)
else
  bad "missing $SS"
fi

echo "== plan =="
PLAN="$RUNDIR/plan.md"
if [ ! -f "$PLAN" ]; then
  bad "missing $PLAN — the plan is what the user approved; nothing launches without it"
else
  ok "found $PLAN"
  if [ -n "$REV" ]; then
    if grep -qF -- "$REV" "$PLAN"; then ok "plan.md names the revision cmd.sh pins ($REV)"
    else bad "plan.md never names revision $REV — the approved plan and cmd.sh describe different runs"; fi
  fi
  planN="$(grep -oiE '([0-9]+[[:space:]]+samples?|samples?[[:space:]]*[:=][[:space:]]*[0-9]+)' "$PLAN" | head -1 | tr -dc '0-9' || true)"
  if [ -z "$planN" ]; then
    note "plan.md states no sample count — sheet size not cross-checked"
  elif [ -z "$nrow" ]; then
    note "plan.md says $planN sample(s); no samplesheet to compare against"
  elif [ "$planN" -eq "$nrow" ] || [ "$planN" -eq "$nsamp" ]; then
    ok "plan.md sample count agrees with the sheet ($planN)"
  else
    bad "plan.md says $planN sample(s); sheet has $nrow rows / $nsamp distinct IDs"
  fi
fi

echo "== references =="
if [ -d "$REFS" ]; then ok "refs root $REFS"; else bad "refs root $REFS absent — run bootstrap/04-refs.sh"; fi

manifest_has() {
  local rel="$1"
  [ -f "$MANIFEST" ] && awk -F'\t' -v r="$rel" '/^#/{next} $1==r||$1==r"/"{f=1} END{exit !f}' "$MANIFEST"
}

# 04-refs.sh derives three build-named aliases from canonical manifest rows. The aliases
# deliberately have no rows of their own; adding one transfers ownership away from the alias
# mechanism. Print the canonical row when a missing path is one of those generated aliases.
generated_alias_source() {
  local rel="$1" top build kind file extra canonical=""
  IFS=/ read -r top build kind file extra <<EOF
$rel
EOF
  [ "$top" = genomes ] && [ -n "$build" ] && [ -z "${extra:-}" ] || return 1
  case "$kind/$file" in
    "fasta/$build.fa")      canonical="genomes/$build/fasta/genome.fa" ;;
    "fasta/$build.fa.fai")  canonical="genomes/$build/fasta/genome.fa.fai" ;;
    "gtf/$build.gtf.gz")    canonical="genomes/$build/gtf/genes.gtf.gz" ;;
    *) return 1 ;;
  esac
  manifest_has "$canonical" || return 1
  printf '%s' "$canonical"
}

# BOTH files, not params.yaml alone. A run that passes its references as --fasta/--gtf
# on the command line has no params.yaml at all (runs/20260804-rnaseq-scer-verify is one),
# and this block used to skip it while printing "checked via cmd.sh instead" -- a check
# that did not exist anywhere in this script. Scan whichever of the two are present.
#
# COMMENTS ARE STRIPPED FIRST. A run record explains itself in prose, and that prose
# names reference paths that are deliberately NOT arguments. runs/20260804-rnaseq-scer-verify
# is the case that proves it: it passes --star_index false ON PURPOSE and its comment says why,
# quoting '/refs/genomes/R64-1-1/index/star' as the directory that does not exist. Scanning the
# comment turns a correct run into "ref MISSING" and fails preflight. Both # forms go: a line
# that is only a comment, and a trailing comment after real content. (Caught in review of PR #18.)
#
# What survives that is then anchored on a real path boundary: the char immediately before REFS
# must be start-of-line, whitespace, or a quote -- never a path/word character. Without this,
# prose like "config/refs.manifest.tsv" is misread as the path /refs.manifest.tsv, because it
# contains "/refs.manifest.tsv" as a raw substring. Found live on run
# 20260805-atacseq-gbr-lcl-smoke: a comment citing the manifest file by its repo-relative path
# failed preflight with "ref MISSING: /refs.manifest.tsv" -- a real file, just not the one meant.
#
# REFERENCE-ROOT VARIABLES ARE EXPANDED BEFORE MATCHING. This script reads cmd.sh as TEXT, so
# a reference written the way config/genomes.config's own examples write it --
#   --fasta $BIOINFO_REFS/genomes/GRCh38/fasta/GRCh38.fa
# -- contains no literal "/refs" and was invisible here. The run then passed the reference gate
# with a warning while pointing at a file that may not exist. Copying the documented form is
# exactly what a new run does, so this was the common case, not the exotic one. Rewrite the four
# spellings of the two reference roots to their value first. The trailing "/" in the pattern is
# required so $REFSOMETHING is left alone; a bare $BIOINFO_REFS with nothing after it names the
# root, which the check above already covers. (Caught in review of PR #18.)
refsrc=""
if [ -f "$RUNDIR/params.yaml" ]; then refsrc="$refsrc $RUNDIR/params.yaml"; fi
if [ -f "$RUNDIR/cmd.sh" ];      then refsrc="$refsrc $RUNDIR/cmd.sh"; fi
if [ -n "$refsrc" ]; then
  # $REFS is a filesystem path, and below it goes into a sed REPLACEMENT and a grep -E PATTERN,
  # which read it as neither. An absolute root may legally contain regex metacharacters --
  # /ref+store is a valid directory name -- and unescaped the '+' became a quantifier: the
  # pattern matched nothing, so a missing reference was downgraded to the "nothing from the
  # store" warning instead of failing. Escape once per destination, before the loop, because
  # the process substitution that feeds it is expanded first. (Caught in review of PR #18.)
  REFS_RE="$(printf '%s' "$REFS" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
  REFS_SED="$(printf '%s' "$REFS" | sed 's/[\\&#]/\\&/g')"
  nref=0
  while read -r p; do
    [ -n "$p" ] || continue
    nref=$((nref+1))
    if [ -e "$p" ]; then ok "ref resolves: $p"
    # A MISSING ROW AND A MISSING FILE NEED DIFFERENT WORK, and telling everyone to "add a
    # manifest row" sends half of them to add a duplicate of a row that is already there.
    # That confusion is not hypothetical: it is what put genomes/GRCh38/index/bowtie2/ on
    # reference-store.md's missing-rows list for months while the row existed and the index
    # did not. Ask the manifest which case this is.
    elif alias_source="$(generated_alias_source "${p#"$REFS"/}" || true)" && [ -n "$alias_source" ]; then
      bad "ref MISSING: $p — this is a generated alias of manifest row $alias_source. Do not add an alias row; run bootstrap/04-refs.sh. If it reports PENDING, materialize the canonical row first."
    elif manifest_has "${p#"$REFS"/}"; then
      bad "ref MISSING: $p — the manifest HAS this row; the file was never produced. Run bootstrap/04-refs.sh for a fetch row, or build it (references/reference-store.md)."
    else
      bad "ref MISSING: $p — and no row for it in config/refs.manifest.tsv. Add the row, then re-run bootstrap/04-refs.sh."
    fi
  # word-split $refsrc deliberately: these are run-dir paths this script just built.
  done < <(sed 's/^[[:space:]]*#.*$//; s/[[:space:]]#.*$//' $refsrc \
           | sed -E "s#\\\$\\{?(BIOINFO_)?REFS\\}?/#${REFS_SED}/#g" \
           | grep -oE "(^|[^A-Za-z0-9_./-])${REFS_RE}[^\"' ]*" | sed -E 's#^[^/]*(/.*)#\1#' | sed 's/[,:]$//' | sort -u)
  [ "$nref" -gt 0 ] || note "no $REFS path appears in params.yaml/cmd.sh outside comments — this run references nothing from the store"
else
  note "neither params.yaml nor cmd.sh present; reference paths not checked"
fi

echo "== concurrency =="
running="$(pgrep -fc 'nextflow.*run ' || true)"
if [ "${running:-0}" -eq 0 ]; then ok "no other nextflow run active"
else bad "$running nextflow process(es) already running — one heavy pipeline at a time on this host"; fi

printf '\npreflight: %d failure(s), %d warning(s)\n' "$fail" "$warn"
[ "$fail" -eq 0 ] || exit 1
