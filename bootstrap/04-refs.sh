#!/usr/bin/env bash
# 04-refs.sh — materialise $BIOINFO_REFS from config/refs.manifest.tsv.
#
#   bash /mnt/d/bioinfo/bootstrap/04-refs.sh [--dry-run] [--force] [--quiet]
#                                            [--manifest PATH] [--refs PATH]
#
# The manifest is the source of truth. This script never invents a path and never
# guesses a source; it only enforces what the manifest already declares.
#
#   link   ln -s into the source. Zero copy. Sequential-read files only.
#   copy   materialise into ext4, skipped when size matches and the copy is not older.
#   build  a tool generates it. Parent dir is created; status NOT BUILT until it exists.
#   fetch  must be downloaded. Status MISSING with the manifest's hint.
#
# Exit code is non-zero ONLY when a link/copy SOURCE is absent — that is a broken
# manifest or a missing drive, and it is actionable. build and fetch gaps are the
# expected steady state on a fresh machine and must not fail the script, or 05-verify
# would never pass until someone downloaded 25 GB of VEP cache.
#
# CRLF guard — see 01-wsl-base.sh. Trailing `#` swallows this line's own CR.
if [ -z "${BIOINFO_CRLF_REEXEC:-}" ] && grep -q $'\r' "$0" 2>/dev/null; then export BIOINFO_CRLF_REEXEC=1; exec bash <(tr -d '\r' < "$0") "$@"; fi  # CRLF self-heal
set -euo pipefail

BIOINFO_HOME_V="${BIOINFO_HOME:-/mnt/d/bioinfo}"
REFS="${BIOINFO_REFS:-/refs}"
MANIFEST="$BIOINFO_HOME_V/config/refs.manifest.tsv"
DRY=0; FORCE=0; QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY=1 ;;
    --force)    FORCE=1 ;;
    --quiet|-q) QUIET=1 ;;
    --manifest) shift; MANIFEST="${1:-}" ;;
    --refs)     shift; REFS="${1:-}" ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
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
  [ "$DRY" -eq 1 ] || mkdir -p "$REFS/$d"
done

human() { awk -v b="${1:-0}" 'BEGIN{s="B KiB MiB GiB TiB";n=split(s,u," ");i=1;while(b>=1024&&i<n){b/=1024;i++}printf (i==1?"%d %s":"%.1f %s"), b, u[i]}'; }

n_ok=0; n_link=0; n_copy=0; n_stale=0; n_build=0; n_fetch=0; n_hard=0; n_parse=0
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

  IFS=$'\t' read -r std mode src note <<<"$line"
  std="${std#"${std%%[![:space:]]*}"}"; std="${std%"${std##*[![:space:]]}"}"
  mode="${mode#"${mode%%[![:space:]]*}"}"; mode="${mode%"${mode##*[![:space:]]}"}"
  src="${src#"${src%%[![:space:]]*}"}";   src="${src%"${src##*[![:space:]]}"}"
  note="${note:-}"

  # standard_path is relative to $REFS by definition. Anything absolute or with .. in it
  # is a malformed manifest, and following it would write outside the reference store.
  case "$std" in
    /*|*..*) row PARSE "$mode" "line $lineno" "standard_path must be relative and free of '..': $std"
             n_parse=$((n_parse+1)); continue ;;
    '')      row PARSE "$mode" "line $lineno" "empty standard_path"; n_parse=$((n_parse+1)); continue ;;
  esac

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

# ------------------------------------------------------------------ summary
total=$((n_ok+n_link+n_copy+n_stale+n_build+n_fetch+n_hard+n_parse))
say ""
say "[04-refs] $total rows: ok=$n_ok linked=$n_link copied=$n_copy stale=$n_stale not-built=$n_build fetch-missing=$n_fetch broken=$n_hard parse-errors=$n_parse"
[ "$n_copy" -gt 0 ] && say "[04-refs] bytes copied: $(human "$copied_bytes")"

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
