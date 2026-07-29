#!/usr/bin/env bash
# check-samplesheet.sh -- pre-flight validation for nf-core samplesheets.
#
# If this dies with:  /usr/bin/env: 'bash\r': No such file or directory
# the file was checked out with CRLF from the NTFS side. Fix once:
#     sed -i 's/\r$//' check-samplesheet.sh
#
# Assumes unquoted CSV (no commas inside fields) -- which is what nf-core expects.

set -euo pipefail

DEEP=0
[[ "${1:-}" == "--deep" ]] && { DEEP=1; shift; }
SHEET="${1:-}"
[[ -f "$SHEET" ]] || { echo "usage: $0 [--deep] <samplesheet.csv>" >&2; exit 2; }

ERR=0
ok()   { printf 'ok    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; ERR=1; }

# ---- 1. file-level hygiene, on the ORIGINAL bytes ---------------------------
if [[ "$(head -c3 "$SHEET" | od -An -tx1 | tr -d ' ')" == "efbbbf" ]]; then
  fail "UTF-8 BOM (Excel export); the first header becomes '<BOM>sample', not 'sample'"
  echo  "      fix: sed -i '1s/^\\xEF\\xBB\\xBF//' \"$SHEET\""
else ok "no BOM"; fi

if grep -qU $'\r' "$SHEET"; then
  fail "CRLF line endings; trailing CR is glued onto the last column"
  echo  "      fix: sed -i 's/\\r\$//' \"$SHEET\""
else ok "LF line endings"; fi

if LC_ALL=C grep -qP '[^\x09\x20-\x7E]' "$SHEET"; then
  fail "non-ASCII bytes (Korean filenames, smart quotes, NBSP):"
  LC_ALL=C grep -nP '[^\x09\x20-\x7E]' "$SHEET" | head -5 | sed 's/^/      /'
else ok "ASCII only"; fi

[[ -s "$SHEET" ]] || fail "file is empty"

# ---- 2. normalise a working copy -------------------------------------------
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$SHEET" | grep -v '^[[:space:]]*$' > "$TMP"

HDR=$(head -1 "$TMP")
IFS=, read -r -a COLS <<< "$HDR"
NCOL=${#COLS[@]}
printf 'cols  %s  (%d)\n' "$HDR" "$NCOL"
printf 'rows  %d data rows\n' "$(( $(wc -l < "$TMP") - 1 ))"

DUP=$(printf '%s\n' "${COLS[@]}" | sort | uniq -d | paste -sd, -)
[[ -z "$DUP" ]] && ok "header names unique" || fail "duplicate header names: $DUP"

RAGGED=$(awk -F, -v n="$NCOL" 'NR>1 && NF!=n {printf "line %d has %d fields; ", NR, NF}' "$TMP")
[[ -z "$RAGGED" ]] && ok "all rows have $NCOL fields" || fail "ragged rows: $RAGGED"

colidx() { awk -F, -v w="$1" 'NR==1{for(i=1;i<=NF;i++) if($i==w){print i; exit}}' "$TMP"; }
colvals(){ local i; i=$(colidx "$1"); [[ -n "$i" ]] && awk -F, -v i="$i" 'NR>1{print $i}' "$TMP"; }

# ---- 3. path columns --------------------------------------------------------
for C in fastq_1 fastq_2 bam bai cram crai vcf table spring_1 spring_2; do
  I=$(colidx "$C"); [[ -n "$I" ]] || continue
  N=0
  while IFS= read -r P; do
    [[ -n "$P" ]] || continue
    N=$((N+1))
    if [[ "$P" != /* ]]; then
      fail "$C: relative path '$P' (resolves against the launch dir, not the sheet)"; continue
    fi
    if [[ ! -r "$P" ]]; then fail "$C: not readable: $P"; continue; fi
    if [[ ! -s "$P" ]]; then fail "$C: zero bytes: $P"; continue; fi
    case "$P" in
      *.fastq|*.fq)
        fail "$C: uncompressed FASTQ: $P (schema pattern requires .gz)" ;;
      *.gz)
        if [[ "$(head -c2 "$P" | od -An -tx1 | tr -d ' ')" != "1f8b" ]]; then
          fail "$C: not a gzip stream: $P"
        elif (( DEEP )); then
          gzip -t "$P" 2>/dev/null || fail "$C: gzip integrity / truncated: $P"
        fi ;;
    esac
  done < <(awk -F, -v i="$I" 'NR>1{print $i}' "$TMP")
  ok "$C: $N paths checked$( (( DEEP )) && echo ' (deep)' || true )"
done
(( DEEP )) || warn "truncated .gz files are NOT detected without --deep"

# ---- 4. mate orientation and pairing (fastq only, skipped for bam/cram input) --
I1=$(colidx fastq_1); I2=$(colidx fastq_2)
if [[ -n "$I1" && -n "$I2" ]]; then
  while IFS=$'\t' read -r R1 R2; do
    [[ -n "$R2" && -r "$R1" && -r "$R2" ]] || continue
    P1=$(gzip -cd < "$R1" 2>/dev/null | head -2 || true)
    P2=$(gzip -cd < "$R2" 2>/dev/null | head -2 || true)
    H1=${P1%%$'\n'*}; S1=${P1#*$'\n'}
    H2=${P2%%$'\n'*}; S2=${P2#*$'\n'}
    [[ "${H1%% *}" == "${H2%% *}" ]] \
      || fail "mate names differ on record 1: ${H1%% *} vs ${H2%% *}  ($R1)"
    F1=${H1#* }; F2=${H2#* }
    case "${F1%%:*}/${F2%%:*}" in
      1/2) : ;;
      2/1) fail "R1/R2 SWAPPED: $R1 holds read 2 and $R2 holds read 1" ;;
      *)   warn "non-Casava headers; mate order not verifiable for $R1" ;;
    esac
    L1=${#S1}; L2=${#S2}
    (( L1 > 0 && L2 > 0 && L1 > L2 * 2 )) \
      && warn "fastq_1 read is much longer than fastq_2 (${L1} vs ${L2} bp) -- for 10x that means the reads are swapped" \
      || true
    if (( DEEP )); then
      C1=$(gzip -cd < "$R1" | wc -l); C2=$(gzip -cd < "$R2" | wc -l)
      (( C1 % 4 == 0 )) || fail "line count not divisible by 4: $R1 ($C1)"
      (( C1 == C2 )) || fail "mate record counts differ: $((C1/4)) vs $((C2/4))  ($R1)"
    fi
  done < <(awk -F, -v a="$I1" -v b="$I2" 'NR>1{print $a "\t" $b}' "$TMP")
  ok "mate orientation checked"
fi

# ---- 5. identifiers ---------------------------------------------------------
for C in sample group patient; do
  I=$(colidx "$C"); [[ -n "$I" ]] || continue
  BADID=$(colvals "$C" | grep -vE '^[A-Za-z][A-Za-z0-9_]{0,30}$' | sort -u | paste -sd, - || true)
  [[ -z "$BADID" ]] || warn "$C values outside ^[A-Za-z][A-Za-z0-9_]{0,30}\$ (R will rename these downstream): $BADID"
done

if [[ -n "$(colidx lane)" && -n "$(colidx patient)" ]]; then     # sarek FASTQ step
  D=$(awk -F, -v p="$(colidx patient)" -v s="$(colidx sample)" -v l="$(colidx lane)" \
        'NR>1{print $p"/"$s"/"$l}' "$TMP" | sort | uniq -d | paste -sd' ' -)
  [[ -z "$D" ]] && ok "patient/sample/lane triples unique" \
                || fail "duplicate patient/sample/lane (duplicate read groups): $D"
elif [[ -n "$(colidx patient)" && -n "$(colidx sample)" ]]; then  # sarek restart step
  D=$(awk -F, -v p="$(colidx patient)" -v s="$(colidx sample)" \
        'NR>1{print $p"/"$s}' "$TMP" | sort | uniq -d | paste -sd' ' -)
  [[ -z "$D" ]] && ok "patient/sample pairs unique" \
                || fail "duplicate patient/sample: $D"
elif [[ -n "$(colidx sample)" ]]; then
  D=$(colvals sample | sort | uniq -d | paste -sd' ' -)
  [[ -z "$D" ]] && ok "sample ids unique" \
                || warn "repeated sample ids (merged as technical replicates -- intentional?): $D"
fi

# ---- 6. enums ---------------------------------------------------------------
if [[ -n "$(colidx strandedness)" ]]; then
  B=$(colvals strandedness | grep -vE '^(auto|forward|reverse|unstranded)$' | sort -u | paste -sd, - || true)
  [[ -z "$B" ]] && ok "strandedness values valid" || fail "bad strandedness: $B"
fi
if [[ -n "$(colidx status)" ]]; then
  B=$(colvals status | grep -vE '^[01]?$' | sort -u | paste -sd, - || true)
  [[ -z "$B" ]] && ok "status values valid" || fail "bad status (must be 0 or 1): $B"
fi
if [[ -n "$(colidx sex)" ]]; then
  B=$(colvals sex | grep -vE '^(XX|XY|NA)?$' | sort -u | paste -sd, - || true)
  [[ -z "$B" ]] && ok "sex values valid" || warn "unexpected sex values: $B"
fi

# ---- 7. footprint -----------------------------------------------------------
BYTES=$( { for C in fastq_1 fastq_2 bam cram; do colvals "$C"; done \
           | grep '^/' | sort -u | xargs -r -d '\n' stat -Lc %s 2>/dev/null; } \
         | awk '{s+=$1} END{print s+0}' || echo 0 )
printf 'size  %s of input referenced\n' "$(numfmt --to=iec --suffix=B "$BYTES")"
echo  "      compare against free space on the work filesystem; refuse to start below 1.5x the estimate"

(( ERR == 0 )) && echo "PASS  $SHEET" || echo "FAILED $SHEET"
exit "$ERR"
