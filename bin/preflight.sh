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
  /mnt/*) bad "work dir is on drvfs: $WORKDIR — must be ext4, refusing. drvfs has no FIFOs; STAR dies there before reading anything (runbook.md section 1)" ;;
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
    # The guard needs the same `export` tolerance as the resolver below. Teaching only the
    # resolver left a cmd.sh whose ONLY assignment is `export REV=2.1.0` skipping this block
    # entirely, so REV stayed the variable NAME and preflight announced `pinned in cmd.sh: REV`.
    # Caught by testing the case rather than by reading the patch.
    if grep -qE "^[[:space:]]*(export[[:space:]]+)?${REV}=" "$RUNDIR/cmd.sh"; then
      # THE LAST ASSIGNMENT BEFORE THE INVOCATION, not the first in the file. bash uses the value
      # in effect when the line runs, so
      #   REV=3.18.0
      #   REV=dev        # left over from a debugging session
      #   nextflow run ... -r "$REV"
      # runs dev while `head -1` reported 3.18.0 -- and then the stocked-set check below compared
      # 3.18.0 against the pin and passed. Both gates cleared a run that was on a floating branch.
      # Exactly the mistake the host.env reader had, on the other side of the same script; I fixed
      # it there and left it here. (Caught in review of PR #18.)
      #
      # The trailing comment is stripped first: the template writes
      #   REV=3.18.0        # from config/pipelines.tsv
      # and `tr -d ' '` alone would glue the comment onto the revision.
      # `export REV=dev` is an assignment too, and skipping it read the value bash discarded.
      # bootstrap/lib/host-env.sh strips the same prefix; I aligned this reader with that one on
      # "last wins" and did not carry the `export` half across. Unlike host.env, whitespace
      # around `=` is NOT accepted here: `REV = dev` is a command in a shell script, not an
      # assignment, so treating it as one would invent a pin bash never sets.
      _rl="$(grep -nE '(^| )-r +' "$RUNDIR/cmd.sh" | head -1 | cut -d: -f1)"
      REV="$(awk -v v="$REV" -v L="${_rl:-0}" '
               L>0 && NR>=L { exit }
               { s=$0
                 sub(/^[[:space:]]+/, "", s)
                 sub(/^export[[:space:]]+/, "", s)
                 sub(/^[[:space:]]+/, "", s)
                 if (index(s, v "=")==1) line=s }
               END { print line }' "$RUNDIR/cmd.sh" \
             | cut -d= -f2- | sed 's/#.*$//' | tr -d '\047" ')"
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
  if [ "$PIPE" = fetchngs ]; then
    # fetchngs takes a HEADERLESS accession list (references/samplesheets.md) -- treating line 1
    # as a header, as every other pipeline's samplesheet does, undercounts by one accession and
    # mislabels an SRR/GSE id as a column name. Measured 20260810-fetchngs-citest: reported "9
    # data rows" against a real 10-accession file.
    ok "fetchngs: headerless accession list, no header row expected"
    nrow="$(grep -c '[^[:space:]]' "$SS" || true)"
    # Strip per-line whitespace before comparing accessions -- the pipeline's own
    # .splitCsv(..., strip:true) treats " SRR15498316 " and "SRR15498316" as the same accession,
    # so a raw sort/uniq here would undercount duplicates and report a false distinct count.
    stripped_ss="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' "$SS")"
    nsamp="$(printf '%s\n' "$stripped_ss" | sort -u | grep -c '[^[:space:]]' || true)"
    [ "$nrow" -gt 0 ] && ok "$nrow accessions, $nsamp distinct" || bad "no accessions"
    dups="$(printf '%s\n' "$stripped_ss" | sort | uniq -d | tr '\n' ' ')"
    [ -z "$dups" ] || note "repeated accessions: $dups"
    # schema_input.json's fetchngs schema is a single unnamed column -- a comma anywhere in a
    # line is an extra field the pipeline's own accession regex does not cleanly reject.
    ragged="$(awk -F, 'NF!=1{printf "line %d has %d fields; ", NR, NF}' "$SS")"
    [ -z "$ragged" ] || bad "ragged rows (fetchngs takes one accession per line, no commas): $ragged"
    # Single-field is necessary but not sufficient -- "id"/"sample"/a typo would pass that check
    # and still be rejected by fetchngs's own isSraId() before any download. Same pattern as
    # assets/schema_input.json. Strip per-line whitespace first, matching the pipeline's own
    # .splitCsv(..., strip:true), so " SRR15498316 " is not flagged when fetchngs would accept it.
    badacc="$( (printf '%s\n' "$stripped_ss" | grep -nvE '^(((SR|ER|DR)[APRSX])|(SAM(N|EA|D))|(PRJ(NA|EB|DB))|(GS[EM]))[0-9]+$' || true) | tr '\n' ' ')"
    [ -z "$badacc" ] || bad "invalid accession(s) (fails SRA/ENA/DDBJ/BioProject/BioSample/GEO pattern): $badacc"
  else
    hdr="$(head -1 "$SS")"
    ok "header: $hdr"
    nrow="$(tail -n +2 "$SS" | grep -c '[^[:space:]]' || true)"
    nsamp="$(tail -n +2 "$SS" | cut -d, -f1 | sort -u | grep -c '[^[:space:]]' || true)"
    [ "$nrow" -gt 0 ] && ok "$nrow data rows, $nsamp distinct first-column IDs" || bad "no data rows"
    dups="$(tail -n +2 "$SS" | cut -d, -f1 | sort | uniq -d | tr '\n' ' ')"
    [ -z "$dups" ] || note "repeated first-column IDs: $dups (legitimate for merged tech reps; confirm it is intended)"
  fi
  while read -r p; do
    [ -n "$p" ] || continue
    # bacass's R1/R2/LongFastQ columns legally hold http(s):// URLs (the pipeline's own CI
    # fixture uses raw GitHub URLs directly, not local paths) -- this loop otherwise treats
    # every '/'-bearing field as a local path and `[ -e ]` unconditionally fails a URL, which
    # made the mandatory preflight gate hard-fail every URL-backed bacass sheet regardless of
    # whether the run's own --input ever consumes it (Codex review, PR #41, round 4, P2:
    # reproduced "input MISSING" against the checked-in bacass CI-fixture reference sheet).
    # Existence of a remote URL is a network check, out of scope for this local, offline-safe
    # gate -- note it instead of failing it, same severity class as the "references nothing
    # from the store" note a few lines below.
    case "$p" in
      http://*|https://*|ftp://*) note "input is a remote URL, not checked for existence here: $p"; continue ;;
    esac
    if [ -e "$p" ]; then ok "input exists: $p"; else bad "input MISSING: $p"; fi
  done < <(tail -n +2 "$SS" | tr ',' '\n' | tr -d '"' | grep '/' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u)
else
  bad "missing $SS"
fi

# taxprofiler (and potentially a future pipeline) takes a SECOND csv, --databases, whose own
# db_path column is where the actual reference (e.g. a Kraken2 DB directory under $REFS) lives.
# The reference-store gate below (== references ==) only text-scans params.yaml/cmd.sh for a
# literal $REFS-anchored path -- on a taxprofiler run that path is one file removed, inside
# databases.csv, and invisible to a plain grep of params.yaml/cmd.sh. Without this block,
# preflight reported "this run references nothing from the store" and passed even with the
# Kraken2 DB entirely absent -- the failure would only surface mid-launch when the pipeline
# itself reads databases.csv (Codex review, PR #36). Generic on the param NAME, not hardcoded
# to taxprofiler, so any future pipeline with the same two-CSV shape is covered automatically.
DBCSV="$(grep -hoE '(^|[[:space:]])--?databases[[:space:]]+["'"'"']?[^"'"'"'[:space:]]+' "$RUNDIR/params.yaml" "$RUNDIR/cmd.sh" 2>/dev/null \
         | sed -E 's/^[[:space:]]*--?databases[[:space:]]+["'"'"']?//' | head -1 || true)"
if [ -z "$DBCSV" ] && [ -f "$RUNDIR/params.yaml" ]; then
  DBCSV="$(grep -E '^[[:space:]]*databases:' "$RUNDIR/params.yaml" | head -1 | sed -E 's/^[[:space:]]*databases:[[:space:]]*["'"'"']?//; s/["'"'"']?[[:space:]]*$//' || true)"
fi
# The value found above is TEXT from a shell script or a YAML file, not an evaluated shell
# expression -- `--databases "$RUNDIR/databases.csv"` (a legitimate, in-repo cmd.sh style, see
# runbook.md section 5's own template) leaves the literal string "$RUNDIR/databases.csv" in
# $DBCSV, which then never matches a real file. Expand the one variable this repo's cmd.sh
# templates actually use for this purpose. Not a general shell evaluator on purpose --
# `eval`-ing arbitrary cmd.sh/params.yaml content read from a run directory would execute
# whatever text is in there.
DBCSV="${DBCSV//\$\{RUNDIR\}/$RUNDIR}"
DBCSV="${DBCSV//\$RUNDIR/$RUNDIR}"
if [ -n "$DBCSV" ]; then
  echo "== databases csv =="
  if [ -f "$DBCSV" ]; then
    ok "found $DBCSV"
    # db_path BY HEADER COLUMN, not "any field containing a slash" -- schema_database.json's
    # own optional db_params column legitimately carries slash-bearing CLI args (e.g.
    # "--taxonomy /refs/taxonomy"), which a slash-grep would misreport as a broken db_path; the
    # same slash-grep also silently skips a genuinely missing bare (no-slash) db_path like
    # "kraken_db". Same colidx-by-header approach as scripts/check-samplesheet.sh.
    DBHDR="$(head -1 "$DBCSV")"
    DBPI="$(printf '%s' "$DBHDR" | awk -F, '{for(i=1;i<=NF;i++) if($i=="db_path"){print i; exit}}')"
    if [ -z "$DBPI" ]; then
      bad "$DBCSV has no db_path column (header: $DBHDR)"
    else
      DBROWS=$(tail -n +2 "$DBCSV" | awk -F, -v i="$DBPI" '$i!=""' | grep -c . || true)
      # A header-only databases.csv (0 data rows) reaches this block with DBPI found but the
      # process substitution below yielding nothing to iterate over -- no failure gets
      # recorded, and preflight would otherwise pass a run where every --run_<tool> flag is
      # silently a no-op for lack of any matching database row (Codex review, PR #36 round 7).
      [ "$DBROWS" -gt 0 ] || bad "$DBCSV has a db_path column but zero non-empty data rows -- every enabled --run_<tool> flag is a silent no-op with no database to use"
      while read -r p; do
        [ -n "$p" ] || continue
        # bootstrap/04-refs.sh's own do_fetch(), for a directory-mode (trailing-slash) manifest
        # row, `mkdir -p`s the empty destination BEFORE reporting it MISSING -- an empty dir
        # left by an interrupted or not-yet-run fetch is 04-refs.sh's own definition of
        # "absent", not merely `[ ! -e ]`. A plain `[ -e "$p" ]` here would accept that same
        # empty placeholder as a valid database and pass, only for Kraken2 to fail mid-launch
        # on a directory with no index in it (Codex review, PR #36 round 6). Match 04-refs.sh's
        # own OK/MISSING test: for a directory, require it to be non-empty; for a file, plain
        # existence is still correct.
        if [ -d "$p" ]; then
          if [ -n "$(ls -A "$p" 2>/dev/null)" ]; then ok "db_path exists: $p ($(ls -A "$p" | wc -l) entries)"
          else bad "db_path is an EMPTY directory: $p (referenced from $DBCSV -- bootstrap/04-refs.sh creates this placeholder before a fetch runs; run it, or fetch the database, before launch)"; fi
        elif [ -e "$p" ]; then ok "db_path exists: $p"
        else bad "db_path MISSING: $p (referenced from $DBCSV, not visible to a plain grep of params.yaml/cmd.sh)"; fi
      done < <(tail -n +2 "$DBCSV" | awk -F, -v i="$DBPI" '{print $i}' | tr -d '"' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u)
    fi
  else
    bad "--databases/params.yaml names $DBCSV, which does not exist"
  fi
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
  # fetchngs plans count "accessions", not "samples" -- the word this repo's fetchngs run plans
  # actually use (an accession list resolves to an unknown-in-advance number of runs/samples, so
  # "sample count" is the wrong noun for it). Only look for "accessions" on a fetchngs run: on
  # any other pipeline a plan can legitimately mention an accession total (e.g. "derived from a
  # 100-accession fetchngs pull") well before its own "Sample count: 20", and matching the first
  # one found would compare the wrong number against the sheet.
  if [ "$PIPE" = fetchngs ]; then
    planN="$(grep -oiE '([0-9]+[[:space:]]+accessions?|accessions?[[:space:]]*[:=][[:space:]]*[0-9]+)' "$PLAN" | head -1 | tr -dc '0-9' || true)"
  else
    planN="$(grep -oiE '([0-9]+[[:space:]]+samples?|samples?[[:space:]]*[:=][[:space:]]*[0-9]+)' "$PLAN" | head -1 | tr -dc '0-9' || true)"
  fi
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
# on the command line has no params.yaml at all (docs/examples/20260804-rnaseq-scer-verify is one),
# and this block used to skip it while printing "checked via cmd.sh instead" -- a check
# that did not exist anywhere in this script. Scan whichever of the two are present.
#
# COMMENTS ARE STRIPPED FIRST. A run record explains itself in prose, and that prose
# names reference paths that are deliberately NOT arguments. docs/examples/20260804-rnaseq-scer-verify
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
# AN ARRAY, not a space-joined string. The string form word-split on the caller's own path:
# with BIOINFO_RUNLOG under something like /mnt/c/Users/Jane Doe/... -- an ordinary Windows home
# -- sed received "/tmp/run", "dir", "with", "spaces/...' as four operands, read none of them,
# and left nref at 0. The gate then reported "this run references nothing from the store" and
# passed, so a missing reference sailed through on a legitimately configured host.
# (Caught in review of PR #18.)
refsrc=()
if [ -f "$RUNDIR/params.yaml" ]; then refsrc+=("$RUNDIR/params.yaml"); fi
if [ -f "$RUNDIR/cmd.sh" ];      then refsrc+=("$RUNDIR/cmd.sh"); fi
if [ "${#refsrc[@]}" -gt 0 ]; then
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
  done < <(sed 's/^[[:space:]]*#.*$//; s/[[:space:]]#.*$//' "${refsrc[@]}" \
           | sed -E "s#\\\$\\{?(BIOINFO_)?REFS\\}?/#${REFS_SED}/#g" \
           | grep -oE "(^|[^A-Za-z0-9_./-])${REFS_RE}[^\"' ]*" | sed -E 's#^[^/]*(/.*)#\1#' | sed 's/[,:]$//' | sort -u)
  if [ "$nref" -eq 0 ]; then
    if [ "$PIPE" = fetchngs ]; then
      ok "fetchngs touches no genome — no $REFS path expected (references/pipeline-selection.md §4.3)"
    else
      note "no $REFS path appears in params.yaml/cmd.sh outside comments — this run references nothing from the store"
    fi
  fi
else
  note "neither params.yaml nor cmd.sh present; reference paths not checked"
fi

echo "== concurrency =="
running="$(pgrep -fc 'nextflow.*run ' || true)"
if [ "${running:-0}" -eq 0 ]; then ok "no other nextflow run active"
else bad "$running nextflow process(es) already running — one heavy pipeline at a time on this host"; fi

printf '\npreflight: %d failure(s), %d warning(s)\n' "$fail" "$warn"
[ "$fail" -eq 0 ] || exit 1
