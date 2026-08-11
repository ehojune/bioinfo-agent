#!/usr/bin/env bash
# check-samplesheet.sh -- pre-flight validation for nf-core samplesheets.
#
#     check-samplesheet.sh [--deep] [--pipeline <name>] <samplesheet.csv>
#
# --pipeline enforces that pipeline's required columns. Without it only a
# sample-identifier column is required, so pass it whenever you know the target.
#
# If this dies with:  /usr/bin/env: 'bash\r': No such file or directory
# the file was checked out with CRLF from the NTFS side. Fix once:
#     sed -i 's/\r$//' check-samplesheet.sh
#
# Assumes unquoted CSV (no commas inside fields) -- which is what nf-core expects.

set -euo pipefail

DEEP=0
PIPELINE=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --deep)     DEEP=1; shift ;;
    --pipeline) PIPELINE="${2:-}"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
SHEET="${1:-}"
[[ -f "$SHEET" ]] || { echo "usage: $0 [--deep] [--pipeline <name>] <samplesheet.csv>" >&2; exit 2; }

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
# `|| true` on the grep: an empty or all-blank sheet makes it select zero lines and exit 1,
# which under `set -euo pipefail` killed the script right after the "file is empty" FAIL —
# the remaining checks and the PASS/FAILED summary never ran on exactly the degenerate input
# line 50 detects and means to report.
sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$SHEET" | { grep -v '^[[:space:]]*$' || true; } > "$TMP"

if [[ "$PIPELINE" == fetchngs ]]; then
  # fetchngs takes a HEADERLESS accession list (references/samplesheets.md) -- line 1 is a real
  # accession, not a column header. Treating it as one, as every other pipeline here does,
  # undercounts by one accession and prints an SRR/GSE id as if it were a header name. Measured
  # 20260810-fetchngs-citest: this block reported "9 data rows" against a real 10-accession file.
  NCOL=1
  NROW=$(wc -l < "$TMP")
  printf 'headerless accession list (no header row expected)\n'
  (( NROW > 0 )) && printf 'rows  %d accessions\n' "$NROW" || fail "no accessions (file empty after normalising)"

  # fetchngs's schema is a single unnamed column (assets/schema_input.json) -- a comma anywhere
  # in a line means an extra field the pipeline's own accession-regex check does not catch as
  # cleanly (it only rejects the WHOLE line if the id pattern fails, which a line like
  # "ERR1160846,unexpected" may still partially satisfy up to the comma). Catch it here instead
  # of letting a malformed line reach the pipeline.
  RAGGED=$(awk -F, 'NF!=1 {printf "line %d has %d fields; ", NR, NF}' "$TMP")
  [[ -z "$RAGGED" ]] && ok "all lines are single-field (one accession per line)" || fail "ragged rows: $RAGGED"

  # A single-field line still is not necessarily a valid accession -- "id", "sample", or a typo
  # would pass the field-count check above and this script would report PASS even though
  # fetchngs's own isSraId() (subworkflows/local/utils_nfcore_fetchngs_pipeline/main.nf) rejects
  # it and aborts the whole run before any download. Same pattern as assets/schema_input.json.
  # The pipeline itself reads --input with .splitCsv(header:false, sep:'', strip:true) -- strip
  # leading/trailing whitespace per line before matching, the same way, so " SRR15498316 " is not
  # flagged as invalid here only for the pipeline to accept it.
  ACCPAT='^(((SR|ER|DR)[APRSX])|(SAM(N|EA|D))|(PRJ(NA|EB|DB))|(GS[EM]))[0-9]+$'
  BADACC=$( (sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' "$TMP" | grep -nvE "$ACCPAT" || true) | sed 's/^/line /; s/:/ not a valid accession: /' | tr '\n' '; ')
  [[ -z "$BADACC" ]] && ok "all lines match a valid SRA/ENA/DDBJ/BioProject/BioSample/GEO accession" \
                     || fail "invalid accession(s): $BADACC"
else
  HDR=$(head -1 "$TMP")
  IFS=, read -r -a COLS <<< "$HDR"
  NCOL=${#COLS[@]}
  printf 'cols  %s  (%d)\n' "$HDR" "$NCOL"
  NROW=$(( $(wc -l < "$TMP") - 1 ))
  (( NROW > 0 )) && printf 'rows  %d data rows\n' "$NROW" || fail "no data rows (header only)"

  DUP=$(printf '%s\n' "${COLS[@]}" | sort | uniq -d | paste -sd, -)
  [[ -z "$DUP" ]] && ok "header names unique" || fail "duplicate header names: $DUP"

  RAGGED=$(awk -F, -v n="$NCOL" 'NR>1 && NF!=n {printf "line %d has %d fields; ", NR, NF}' "$TMP")
  [[ -z "$RAGGED" ]] && ok "all rows have $NCOL fields" || fail "ragged rows: $RAGGED"
fi

colidx() { awk -F, -v w="$1" 'NR==1{for(i=1;i<=NF;i++) if($i==w){print i; exit}}' "$TMP"; }
colvals(){ local i; i=$(colidx "$1"); [[ -n "$i" ]] || return 0; awk -F, -v i="$i" 'NR>1{print $i}' "$TMP"; }

# ---- 2b. required columns ---------------------------------------------------
# Column sets for the stocked nine. Revisions they were read at: config/pipelines.tsv.
case "$PIPELINE" in
  '')                    REQ='' ;;
  rnaseq)                REQ='sample fastq_1 strandedness' ;;
  sarek)                 REQ='patient sample' ;;                # plus one input column, below
  methylseq|scrnaseq)    REQ='sample fastq_1' ;;
  atacseq)               REQ='sample fastq_1 replicate' ;;
  chipseq)               REQ='sample fastq_1 replicate antibody control control_replicate' ;;
  cutandrun)             REQ='group replicate fastq_1 fastq_2 control' ;;   # paired-end only at 3.2.2
  differentialabundance) REQ='sample' ;;                        # or whatever --observations_id_col says
  fetchngs)              REQ='' ;;                              # headerless accession list, not a CSV
  ampliseq)              REQ='' ;;                              # two column forms; see below
  *) fail "--pipeline $PIPELINE is not stocked; see config/pipelines.tsv"; REQ='' ;;
esac

if [[ "$PIPELINE" == fetchngs ]]; then
  warn "fetchngs takes a headerless accession list; the column checks below do not apply to it"
elif [[ "$PIPELINE" == ampliseq ]]; then
  # assets/schema_input.json (2.18.0) accepts two column forms, checked here since the plain
  # AND-of-REQ check above can't express "one of two sets" -- same reason sarek's --step branch
  # gets its own follow-up check below rather than living in REQ.
  if [[ -n "$(colidx sampleID)" && -n "$(colidx forwardReads)" ]]; then
    ok "ampliseq required columns present (sampleID/forwardReads form)"
  elif [[ -n "$(colidx sample)" && -n "$(colidx fastq_1)" ]]; then
    ok "ampliseq required columns present (sample/fastq_1 form)"
  else
    fail "ampliseq needs sampleID+forwardReads, or sample+fastq_1"
  fi
elif [[ -n "$REQ" ]]; then
  MISS=''
  for C in $REQ; do [[ -n "$(colidx "$C")" ]] || MISS="$MISS $C"; done
  [[ -z "$MISS" ]] && ok "$PIPELINE required columns present" \
                   || fail "$PIPELINE is missing required column(s):$MISS"
  if [[ "$PIPELINE" == sarek ]]; then
    [[ -n "$(colidx fastq_1)$(colidx bam)$(colidx cram)$(colidx vcf)" ]] \
      || fail "sarek needs one of fastq_1 / bam / cram / vcf, matching --step"
  fi
elif [[ -z "$PIPELINE" ]]; then
  ID=''
  for C in sample patient group id; do [[ -z "$(colidx "$C")" ]] || { ID="$C"; break; }; done
  [[ -n "$ID" ]] && ok "sample-identifier column: $ID" \
                 || fail "no sample-identifier column (sample|patient|group|id); pass --pipeline <name> to check the full set"
fi

# ---- 3. path columns --------------------------------------------------------
for C in fastq_1 fastq_2 bam bai cram crai vcf table spring_1 spring_2 forwardReads reverseReads; do
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
# ampliseq's sampleID/forwardReads/reverseReads form carries the same mate-pair shape as
# fastq_1/fastq_2 -- fall back to it so this gate isn't silently skipped on that column set.
I1=$(colidx fastq_1); I2=$(colidx fastq_2)
if [[ -z "$I1" ]]; then I1=$(colidx forwardReads); I2=$(colidx reverseReads); fi
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
      C1=$( { gzip -cd < "$R1" 2>/dev/null || true; } | wc -l); C2=$( { gzip -cd < "$R2" 2>/dev/null || true; } | wc -l)
      (( C1 % 4 == 0 )) || fail "line count not divisible by 4: $R1 ($C1)"
      (( C1 == C2 )) || fail "mate record counts differ: $((C1/4)) vs $((C2/4))  ($R1)"
    fi
  done < <(awk -F, -v a="$I1" -v b="$I2" 'NR>1{print $a "\t" $b}' "$TMP")
  ok "mate orientation checked"
fi

# ---- 5. identifiers ---------------------------------------------------------
for C in sample group patient sampleID; do
  I=$(colidx "$C"); [[ -n "$I" ]] || continue
  BADID=$(colvals "$C" | grep -vE '^[A-Za-z][A-Za-z0-9_]{0,30}$' | sort -u | paste -sd, - || true)
  [[ -z "$BADID" ]] || warn "$C values outside ^[A-Za-z][A-Za-z0-9_]{0,30}\$ (R will rename these downstream): $BADID"
done

if [[ -n "$(colidx lane)" && -n "$(colidx patient)" ]]; then     # sarek FASTQ step
  D=$(awk -F, -v p="$(colidx patient)" -v s="$(colidx sample)" -v l="$(colidx lane)" \
        'NR>1{print $p"/"$s"/"$l}' "$TMP" | sort | uniq -d | paste -sd' ' -)
  [[ -z "$D" ]] && ok "patient/sample/lane triples unique" \
                || fail "duplicate patient/sample/lane (duplicate read groups): $D"
  NAKED=$(colvals lane | grep -cE '^[0-9]+$' || true)
  (( NAKED == 0 )) || warn "$NAKED lane values are bare integers; qualify with the flowcell (e.g. HKJL7DSX5.1) or two flowcells will collide"
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
  if [[ -n "$(colidx sample)" ]]; then
    M=$(awk -F, -v s="$(colidx sample)" -v t="$(colidx strandedness)" \
          'NR>1{k[$s","$t]=1} END{for(x in k){split(x,a,","); c[a[1]]++} for(y in c) if(c[y]>1) printf "%s ", y}' "$TMP")
    [[ -z "$M" ]] || fail "sample(s) with inconsistent strandedness across rows: $M"
  fi
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
PATHS=$( { for C in fastq_1 fastq_2 bam cram forwardReads reverseReads; do colvals "$C"; done; } | grep '^/' | sort -u || true )
if [[ -z "$PATHS" ]]; then
  printf 'size  nothing to size (no absolute fastq/bam/cram paths)\n'
else
  BYTES=$(printf '%s\n' "$PATHS" | { xargs -d '\n' stat -Lc %s 2>/dev/null || true; } \
          | awk '{s+=$1} END{print s+0}')
  printf 'size  %s of input referenced\n' "$(numfmt --to=iec --suffix=B "$BYTES")"
  echo  "      compare against free space on the work filesystem; refuse to start below 1.5x the estimate"
fi

(( ERR == 0 )) && echo "PASS  $SHEET" || echo "FAILED $SHEET"
exit "$ERR"
