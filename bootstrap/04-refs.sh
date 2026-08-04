#!/usr/bin/env bash
# 04-refs.sh — materialise $BIOINFO_REFS from config/refs.manifest.tsv.
#
#   bash /mnt/d/bioinfo-agent/bootstrap/04-refs.sh [--dry-run] [--force] [--quiet]
#                                            [--manifest PATH] [--refs PATH]
#                                            [--verify] [--hash STANDARD_PATH]
#
# The manifest is the source of truth. This script never invents a path and never
# guesses a source; it only enforces what the manifest already declares.
#
#   link   ln -s into the source. Zero copy. Sequential-read files only.
#   copy   materialise into ext4, skipped when size matches and the copy is not older.
#   build  a tool generates it. Parent dir is created; status NOT BUILT until it exists.
#   fetch  must be downloaded. Status MISSING with the manifest's hint.
#
# Integrity. The manifest carries an OPTIONAL sha256 as its 5th column. The default run
# never hashes anything — size and mtime only, so a 3 GB BWT is not re-read every time.
#
#   --verify              hash every row that carries a digest; non-zero on any mismatch
#   --hash STANDARD_PATH  hash one materialised file and write the digest into its
#                         blank cell. Refuses to overwrite a digest that is already there.
#
# Exit code is non-zero ONLY when a link/copy SOURCE is absent — that is a broken
# manifest or a missing drive, and it is actionable. build and fetch gaps are the
# expected steady state on a fresh machine and must not fail the script, or 05-verify
# would never pass until someone downloaded 25 GB of VEP cache.
#
# CRLF guard — see 01-wsl-base.sh. Trailing `#` swallows this line's own CR.
if [ -z "${BIOINFO_CRLF_REEXEC:-}" ] && grep -q $'\r' "$0" 2>/dev/null; then export BIOINFO_CRLF_REEXEC=1; exec bash <(tr -d '\r' < "$0") "$@"; fi  # CRLF self-heal
set -euo pipefail

# config/host.env — per-machine overrides, sourced before the defaults so the values
# here are genuine fallbacks. `|| true`: an unquoted value there must not stop the run.
HOST_ENV="${BIOINFO_HOME:-/mnt/d/bioinfo-agent}/config/host.env"
. "$(dirname "$0")/lib/host-env.sh"      # parses; never executes host.env
load_host_env "$HOST_ENV"

BIOINFO_HOME_V="${BIOINFO_HOME:-/mnt/d/bioinfo-agent}"
REFS="${BIOINFO_REFS:-/refs}"
MANIFEST="$BIOINFO_HOME_V/config/refs.manifest.tsv"
DRY=0; FORCE=0; QUIET=0
RUNMODE=copy            # copy | verify | hash
HASH_TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY=1 ;;
    --force)    FORCE=1 ;;
    --quiet|-q) QUIET=1 ;;
    --manifest) shift; MANIFEST="${1:-}" ;;
    --refs)     shift; REFS="${1:-}" ;;
    --verify)   RUNMODE=verify ;;
    --hash)     RUNMODE=hash; shift; HASH_TARGET="${1:-}" ;;
    -h|--help)  sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf '[04-refs] FATAL: %s\n' "$*" >&2; exit 1; }

[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

case "$REFS" in
  /mnt/*) die "BIOINFO_REFS=$REFS is on drvfs. The reference store must be on ext4." ;;
esac

if [ ! -d "$REFS" ]; then
  mkdir -p "$REFS" 2>/dev/null || die "cannot create $REFS. As root:  install -d -o $USER -g $USER $REFS"
fi
[ -w "$REFS" ] || die "$REFS is not writable by $USER. As root:  chown -R $USER:$USER $REFS"

# Standard skeleton. Present regardless of what the manifest happens to list, because
# the pipeline configs reference these cache dirs by name whether or not a row exists.
for d in genomes catalogs cache cache/nf-assets cache/containers cache/vep cache/snpeff cache/igenomes; do
  [ "$DRY" -eq 1 ] || [ "$RUNMODE" != copy ] || mkdir -p "$REFS/$d"
done

human() { awk -v b="${1:-0}" 'BEGIN{s="B KiB MiB GiB TiB";n=split(s,u," ");i=1;while(b>=1024&&i<n){b/=1024;i++}printf (i==1?"%d %s":"%.1f %s"), b, u[i]}'; }

# ------------------------------------------------------------------ sha256 column
# The digest is the manifest's 5th column. Recognised in the note column too, by shape,
# so a manifest that orders note and sha256 the other way round still verifies.
is_sha256() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0-9a-fA-F]*) return 1 ;; esac
  return 0
}
digest_of() {   # $1=note $2=sha  ->  the digest, or nothing
  local f
  for f in "${1:-}" "${2:-}"; do
    is_sha256 "$f" && { printf '%s' "$f"; return 0; }
  done
  printf ''
}
sha_of() { sha256sum "$1" | awk '{print $1}'; }

# ------------------------------------------------------------------ --hash
# Fills one blank digest cell. Deliberately one path per invocation: a bulk "hash
# everything" would bake in whatever is on disk right now, which is the opposite of
# what a manifest digest is for.
if [ "$RUNMODE" = hash ]; then
  [ -n "$HASH_TARGET" ] || die "--hash needs a standard_path (column 1 of the manifest)"
  HDEST="$REFS/$HASH_TARGET"
  [ -f "$HDEST" ] || die "not a regular file, nothing to hash: $HDEST"
  [ -w "$MANIFEST" ] || die "manifest is not writable: $MANIFEST"
  HGOT="$(sha_of "$HDEST")"
  HTMP="$MANIFEST.hash.$$"
  : > "$HTMP"
  found=0
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw//$'\r'/}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in ''|'#'*) printf '%s\n' "$line" >> "$HTMP"; continue ;; esac
    IFS=$'\t' read -r std mode src note sha <<<"$line"
    if [ "$std" != "$HASH_TARGET" ]; then printf '%s\n' "$line" >> "$HTMP"; continue; fi
    found=1
    if [ -n "$(digest_of "${note:-}" "${sha:-}")" ]; then
      rm -f "$HTMP"
      die "$HASH_TARGET already carries a digest. Check it with --verify; blank the cell by hand to replace it."
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$std" "$mode" "$src" "${note:-}" "$HGOT" >> "$HTMP"
  done < "$MANIFEST"
  [ "$found" -eq 1 ] || { rm -f "$HTMP"; die "no manifest row with standard_path: $HASH_TARGET"; }
  mv -f "$HTMP" "$MANIFEST"
  say "[04-refs] $HASH_TARGET"
  say "[04-refs] sha256 $HGOT  written to $MANIFEST"
  exit 0
fi

n_ok=0; n_link=0; n_copy=0; n_stale=0; n_build=0; n_fetch=0; n_hard=0; n_parse=0
n_vok=0; n_vbad=0; n_vskip=0
copied_bytes=0
declare -a HARD_MISSING=()

row() {
  # STATUS  MODE  STANDARD_PATH  DETAIL
  [ "$QUIET" -eq 1 ] && return 0
  printf '%-9s %-6s %-54s %s\n' "$1" "$2" "$3" "${4:-}"
}

say ""
say "[04-refs] manifest : $MANIFEST"
say "[04-refs] refs root: $REFS  ($(df -Pk "$REFS" | awk 'NR==2{print $4}' | awk '{printf "%.0f GiB free", $1/1048576}'))"
[ "$DRY" -eq 1 ] && say "[04-refs] DRY RUN — nothing will be created"
say ""
row STATUS MODE STANDARD_PATH DETAIL
row ------ ---- ------------- ------

avail_bytes() { df -Pk "$1" | awk 'NR==2{print $4*1024}'; }

do_link() {
  local std="$1" src="$2" dest="$REFS/$1"
  if [ ! -e "$src" ]; then
    row MISSING link "$std" "source absent: $src"
    n_hard=$((n_hard+1)); HARD_MISSING+=("$std  <- $src")
    return 0
  fi
  if [ -L "$dest" ]; then
    if [ "$(readlink "$dest")" = "$src" ]; then
      if [ -e "$dest" ]; then row OK link "$std"; n_ok=$((n_ok+1))
      else row STALE link "$std" "symlink correct but target unreadable"; n_stale=$((n_stale+1)); fi
      return 0
    fi
    row LINKED link "$std" "repointed from $(readlink "$dest")"
    [ "$DRY" -eq 1 ] || { rm -f "$dest"; mkdir -p "$(dirname "$dest")"; ln -s "$src" "$dest"; }
    n_link=$((n_link+1)); return 0
  fi
  if [ -e "$dest" ]; then
    # A real file sits where the manifest wants a symlink. Do not silently delete data.
    if [ "$FORCE" -eq 1 ]; then
      row LINKED link "$std" "--force: replaced a real file with the symlink"
      [ "$DRY" -eq 1 ] || { rm -rf "$dest"; ln -s "$src" "$dest"; }
      n_link=$((n_link+1))
    else
      row STALE link "$std" "a real file is here, symlink expected — inspect, then re-run with --force"
      n_stale=$((n_stale+1))
    fi
    return 0
  fi
  row LINKED link "$std" "-> $src"
  [ "$DRY" -eq 1 ] || { mkdir -p "$(dirname "$dest")"; ln -s "$src" "$dest"; }
  n_link=$((n_link+1))
}

do_copy() {
  local std="$1" src="$2" dest="$REFS/$1"
  if [ ! -e "$src" ]; then
    row MISSING copy "$std" "source absent: $src"
    n_hard=$((n_hard+1)); HARD_MISSING+=("$std  <- $src")
    return 0
  fi
  local ssize smt dsize dmt
  ssize=$(stat -c %s "$src"); smt=$(stat -c %Y "$src")

  if [ -f "$dest" ] && [ ! -L "$dest" ]; then
    dsize=$(stat -c %s "$dest"); dmt=$(stat -c %Y "$dest")
    # cp -p below preserves mtime, so an untouched copy compares equal. The >= keeps
    # a locally-regenerated file from being clobbered on every run.
    if [ "$ssize" = "$dsize" ] && [ "$dmt" -ge "$smt" ]; then
      row OK copy "$std" "$(human "$dsize")"
      n_ok=$((n_ok+1)); return 0
    fi
    row STALE copy "$std" "size/mtime differ — recopying"
    n_stale=$((n_stale+1))
  elif [ -L "$dest" ]; then
    row STALE copy "$std" "symlink found where a real copy is required — replacing"
    n_stale=$((n_stale+1))
    [ "$DRY" -eq 1 ] || rm -f "$dest"
  fi

  if [ "$DRY" -eq 1 ]; then
    row COPIED copy "$std" "would copy $(human "$ssize")"
    n_copy=$((n_copy+1)); copied_bytes=$((copied_bytes+ssize)); return 0
  fi

  mkdir -p "$(dirname "$dest")"
  local avail; avail=$(avail_bytes "$(dirname "$dest")")
  # 10% headroom: a copy that fills the volume leaves a truncated index that looks
  # valid to ls and blows up hours into an alignment.
  if [ "$avail" -lt $(( ssize + ssize / 10 )) ]; then
    row MISSING copy "$std" "insufficient space: need $(human "$ssize"), have $(human "$avail")"
    n_hard=$((n_hard+1)); HARD_MISSING+=("$std  (no space)")
    return 0
  fi

  # temp + mv so an interrupted copy never leaves a plausible-looking partial file
  local tmp="$dest.part.$$"
  cp -p "$src" "$tmp"
  mv -f "$tmp" "$dest"
  row COPIED copy "$std" "$(human "$ssize")"
  n_copy=$((n_copy+1)); copied_bytes=$((copied_bytes+ssize))
}

do_verify() {
  local std="$1" want="$2" dest="$REFS/$1" got
  if [ -z "$want" ]; then
    row SKIP verify "$std" "no sha256 in the manifest"; n_vskip=$((n_vskip+1)); return 0
  fi
  if [ ! -f "$dest" ]; then
    row ABSENT verify "$std" "not materialised yet — run 04-refs.sh with no flags"
    n_vskip=$((n_vskip+1)); return 0
  fi
  got="$(sha_of "$dest")"
  if [ "$got" = "$want" ]; then
    row OK verify "$std"; n_vok=$((n_vok+1))
  else
    row MISMATCH verify "$std" "want $want"
    n_vbad=$((n_vbad+1)); HARD_MISSING+=("$std  sha256 want $want got $got")
  fi
}

do_build() {
  local std="$1" hint="$2" dest="$REFS/$1"
  case "$std" in
    */)
      if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        row OK build "$std" "$(ls -A "$dest" | wc -l) entries"; n_ok=$((n_ok+1)); return 0
      fi
      [ "$DRY" -eq 1 ] || mkdir -p "$dest"
      ;;
    *)
      if [ -e "$dest" ]; then row OK build "$std"; n_ok=$((n_ok+1)); return 0; fi
      [ "$DRY" -eq 1 ] || mkdir -p "$(dirname "$dest")"
      ;;
  esac
  row "NOT BUILT" build "$std" "$hint"
  n_build=$((n_build+1))
}

do_fetch() {
  local std="$1" hint="$2" dest="$REFS/$1"
  case "$std" in
    */)
      if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        row OK fetch "$std" "$(ls -A "$dest" | wc -l) entries"; n_ok=$((n_ok+1)); return 0
      fi
      [ "$DRY" -eq 1 ] || mkdir -p "$dest"
      ;;
    *)
      if [ -e "$dest" ]; then row OK fetch "$std"; n_ok=$((n_ok+1)); return 0; fi
      [ "$DRY" -eq 1 ] || mkdir -p "$(dirname "$dest")"
      ;;
  esac
  row MISSING fetch "$std" "$hint"
  n_fetch=$((n_fetch+1))
}

# ------------------------------------------------------------------ parse + dispatch
lineno=0
declare -A SEEN_MOUNT=()
while IFS= read -r raw || [ -n "$raw" ]; do
  lineno=$((lineno+1))
  line="${raw//$'\r'/}"                      # CRLF manifests: drop CRs anywhere
  trimmed="${line#"${line%%[![:space:]]*}"}" # left-trim for the comment test
  case "$trimmed" in ''|'#'*) continue ;; esac

  case "$line" in
    *$'\t'*) : ;;
    *) row PARSE '?' "line $lineno" "no TAB separator — columns must be tab-delimited"
       n_parse=$((n_parse+1)); continue ;;
  esac

  IFS=$'\t' read -r std mode src note sha <<<"$line"
  std="${std#"${std%%[![:space:]]*}"}"; std="${std%"${std##*[![:space:]]}"}"
  mode="${mode#"${mode%%[![:space:]]*}"}"; mode="${mode%"${mode##*[![:space:]]}"}"
  src="${src#"${src%%[![:space:]]*}"}";   src="${src%"${src##*[![:space:]]}"}"
  note="${note:-}"
  sha="${sha:-}"; sha="${sha#"${sha%%[![:space:]]*}"}"; sha="${sha%"${sha##*[![:space:]]}"}"

  # standard_path is relative to $REFS by definition. Anything absolute or with .. in it
  # is a malformed manifest, and following it would write outside the reference store.
  case "$std" in
    /*|*..*) row PARSE "$mode" "line $lineno" "standard_path must be relative and free of '..': $std"
             n_parse=$((n_parse+1)); continue ;;
    '')      row PARSE "$mode" "line $lineno" "empty standard_path"; n_parse=$((n_parse+1)); continue ;;
  esac

  # --verify hashes what is already in $REFS and never looks at a source, so the mount
  # warning and the mode dispatch below are both irrelevant to it.
  if [ "$RUNMODE" = verify ]; then
    do_verify "$std" "$(digest_of "$note" "$sha")"
    continue
  fi

  # One warning per missing drvfs mount, not one per row.
  case "$src" in
    /mnt/*)
      mp="/mnt/$(printf '%s' "${src#/mnt/}" | cut -d/ -f1)"
      if [ -z "${SEEN_MOUNT[$mp]:-}" ]; then
        SEEN_MOUNT[$mp]=1
        mountpoint -q "$mp" 2>/dev/null || warn "[04-refs] WARNING: $mp is not mounted — every source under it will report MISSING"
      fi
      ;;
  esac

  case "$mode" in
    link)  do_link  "$std" "$src" ;;
    copy)  do_copy  "$std" "$src" ;;
    build) do_build "$std" "${src:-no hint in manifest}" ;;
    fetch) do_fetch "$std" "${src:-no hint in manifest}" ;;
    *)     row PARSE "$mode" "line $lineno" "unknown mode (expect link|copy|build|fetch)"
           n_parse=$((n_parse+1)) ;;
  esac
done < "$MANIFEST"

# ------------------------------------------------------------------ rnaseq iGenomes-heuristic alias
# nf-core/rnaseq's workflows/rnaseq/main.nf sets is_aws_igenome=true purely by comparing
# basenames to the literal strings "genome.fa" / "genes.gtf" -- not by path, not by any
# parameter. This store intentionally normalises every build to exactly those basenames (see
# reference-store.md), so every build this script materialises trips that heuristic and gets
# silently routed onto a STAR-2.6.1d-only legacy path. Confirmed segfaulting unconditionally
# on this host's CPU (run 20260803-rnaseq-scer-la-tolerant, see that run's handoff.md).
#
# Fix: maintain a second symlink per build, alongside the canonical file, named after the
# build itself. Purely additive -- the canonical genome.fa/genes.gtf.gz paths, and every other
# pipeline reading them (sarek's BWA index prefix matching, etc.), are untouched.
# genomes.config's fasta/gtf params are repointed at this alias directly (not a separate
# fasta_alias/gtf_alias param) so BOTH invocation forms in that file's section 2 -- explicit
# --fasta/--gtf, and the compact --genome <key> form that reads params.genomes.<key>.fasta/.gtf
# through the pipeline's own getGenomeAttribute() -- resolve to the safe name automatically.
#
# Same collision policy as do_link() above: a real (non-symlink) file already at the alias
# path is someone's data, not ours to delete, so it is reported STALE and left alone unless
# --force is given -- ln -sf must never be used here unguarded.
n_alias=0
do_alias() {   # $1=alias_path $2=target_basename $3=label (for row output)
  local alias="$1" target="$2" label="$3"
  if [ -L "$alias" ]; then
    [ "$(readlink "$alias")" = "$target" ] && return 0   # already correct, no row needed
    row LINKED alias "$label" "repointed from $(readlink "$alias")"
    [ "$DRY" -eq 1 ] || ln -sf "$target" "$alias"
    n_alias=$((n_alias+1)); return 0
  fi
  if [ -e "$alias" ]; then
    if [ "$FORCE" -eq 1 ]; then
      row LINKED alias "$label" "--force: replaced a real file with the alias symlink"
      [ "$DRY" -eq 1 ] || { rm -f "$alias"; ln -s "$target" "$alias"; }
      n_alias=$((n_alias+1))
    else
      row STALE alias "$label" "a real file is here, alias symlink expected — inspect, then re-run with --force"
      n_stale=$((n_stale+1))
    fi
    return 0
  fi
  row LINKED alias "$label" "-> $target"
  [ "$DRY" -eq 1 ] || ln -s "$target" "$alias"
  n_alias=$((n_alias+1))
}
if [ "$RUNMODE" = copy ]; then
  for fa in "$REFS"/genomes/*/fasta/genome.fa; do
    [ -e "$fa" ] || continue
    build="$(basename "$(dirname "$(dirname "$fa")")")"
    do_alias "$(dirname "$fa")/$build.fa" genome.fa "genomes/$build/fasta/$build.fa"
  done
  for gtf in "$REFS"/genomes/*/gtf/genes.gtf.gz; do
    [ -e "$gtf" ] || continue
    build="$(basename "$(dirname "$(dirname "$gtf")")")"
    do_alias "$(dirname "$gtf")/$build.gtf.gz" genes.gtf.gz "genomes/$build/gtf/$build.gtf.gz"
  done
fi

# ------------------------------------------------------------------ summary
if [ "$RUNMODE" = verify ]; then
  say ""
  say "[04-refs] verify: ok=$n_vok mismatched=$n_vbad skipped=$n_vskip (no digest, or not materialised) parse-errors=$n_parse"
  if [ "$n_vbad" -gt 0 ] || [ "$n_parse" -gt 0 ]; then
    warn ""
    warn "[04-refs] FAILED — content does not match the manifest digest:"
    i=1
    for h in "${HARD_MISSING[@]:-}"; do
      [ -n "$h" ] || continue
      warn "   $i. $h"; i=$((i+1))
    done
    warn ""
    warn "   A mismatch means the file changed after the digest was recorded. Re-copy from"
    warn "   the manifest SOURCE, or confirm the new content and re-record the digest."
    exit 1
  fi
  say "[04-refs] OK"
  exit 0
fi

total=$((n_ok+n_link+n_copy+n_stale+n_build+n_fetch+n_hard+n_parse))
say ""
say "[04-refs] $total rows: ok=$n_ok linked=$n_link copied=$n_copy stale=$n_stale not-built=$n_build fetch-missing=$n_fetch broken=$n_hard parse-errors=$n_parse"
[ "$n_copy" -gt 0 ] && say "[04-refs] bytes copied: $(human "$copied_bytes")"
[ "$n_alias" -gt 0 ] && say "[04-refs] rnaseq iGenomes-heuristic aliases (re)created: $n_alias"

if [ "$n_build" -gt 0 ] || [ "$n_fetch" -gt 0 ]; then
  say "[04-refs] NOT BUILT / fetch-MISSING rows are expected on a fresh machine. Genuinely absent today:"
  say "          sequence .dict for both builds; STAR / salmon / bismark indexes;"
  say "          the GATK resource bundle (dbsnp, known_indels, gnomAD af-only); VEP or snpEff cache."
  say "          Indexes come free with the first --save_reference run of the relevant pipeline."
fi

if [ "$n_hard" -gt 0 ] || [ "$n_parse" -gt 0 ]; then
  warn ""
  warn "[04-refs] FAILED — link/copy sources missing or manifest malformed:"
  i=1
  for h in "${HARD_MISSING[@]:-}"; do
    [ -n "$h" ] || continue
    warn "   $i. $h"; i=$((i+1))
  done
  warn ""
  warn "   Fix by editing the SOURCE column of $MANIFEST and re-running. Do not edit"
  warn "   pipeline configs — they only ever see the standard paths."
  exit 1
fi

say "[04-refs] OK"
exit 0
