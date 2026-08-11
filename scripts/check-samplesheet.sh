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
  mag)                   REQ='sample group' ;;                  # plus short_reads_1 or long_reads, below
  taxprofiler)           REQ='sample run_accession instrument_platform' ;;  # fastq_1/fastq_2/fasta NOT in schema's required[] -- see below
  *) fail "--pipeline $PIPELINE is not stocked; see config/pipelines.tsv"; REQ='' ;;
esac

if [[ "$PIPELINE" == fetchngs ]]; then
  warn "fetchngs takes a headerless accession list; the column checks below do not apply to it"
elif [[ "$PIPELINE" == ampliseq ]]; then
  # assets/schema_input.json (2.18.0) accepts two column forms, checked here since the plain
  # AND-of-REQ check above can't express "one of two sets" -- same reason sarek's --step branch
  # gets its own follow-up check below rather than living in REQ.
  HAS_LEGACY=$([[ -n "$(colidx sampleID)$(colidx forwardReads)$(colidx reverseReads)" ]] && echo 1 || echo 0)
  HAS_STD=$([[ -n "$(colidx sample)$(colidx fastq_1)$(colidx fastq_2)" ]] && echo 1 || echo 0)
  if [[ "$HAS_LEGACY" == 1 && "$HAS_STD" == 1 ]]; then
    # schema_input.json's oneOf carries a `not: anyOf` on the other family's names for exactly
    # this reason -- confirmed empirically (nextflow -preview) that mixing them is a hard schema
    # failure, not just an nf-core style preference this checker could let slide.
    fail "ampliseq: mixed legacy (sampleID/forwardReads/reverseReads) and standardized (sample/fastq_1/fastq_2) columns -- the schema rejects this outright, pick one family"
  elif [[ "$HAS_LEGACY" == 1 && -n "$(colidx sampleID)" && -n "$(colidx forwardReads)" ]]; then
    ok "ampliseq required columns present (sampleID/forwardReads form)"
  elif [[ "$HAS_STD" == 1 && -n "$(colidx sample)" && -n "$(colidx fastq_1)" ]]; then
    ok "ampliseq required columns present (sample/fastq_1 form)"
  else
    fail "ampliseq needs sampleID+forwardReads, or sample+fastq_1"
  fi
  # schema_input.json's allOf enforces uniqueEntries on "sample" AND separately on "sampleID" --
  # confirmed empirically (nextflow -preview on a same-sample-different-run sheet: "Detected
  # duplicate entries: [sample:S1]") that this is a per-field constraint, NOT a sample+run
  # composite key. "run" tags which sequencing batch a row's error model belongs to; it does not
  # license repeating a sample/sampleID value. Every ampliseq ID column must be FAIL, not the
  # generic branch's WARN below, which exists for pipelines where repeated IDs across lanes are
  # an intentional, supported merge.
  for C in sample sampleID; do
    I=$(colidx "$C"); [[ -n "$I" ]] || continue
    D=$(colvals "$C" | sort | uniq -d | paste -sd' ' -)
    [[ -z "$D" ]] && ok "ampliseq $C values unique" \
                  || fail "ampliseq: duplicate $C value(s) (schema rejects unconditionally, regardless of run): $D"
  done
elif [[ -n "$REQ" ]]; then
  MISS=''
  for C in $REQ; do [[ -n "$(colidx "$C")" ]] || MISS="$MISS $C"; done
  [[ -z "$MISS" ]] && ok "$PIPELINE required columns present" \
                   || fail "$PIPELINE is missing required column(s):$MISS"
  # Column PRESENCE is necessary but not sufficient: every stocked pipeline's schema also
  # requires a non-empty VALUE on every row for its required columns, and a header that
  # exists with an empty cell on some row previously passed this gate silently (Codex review,
  # PR #35, mag's `sample` column specifically -- the same gap applies to every pipeline using
  # $REQ, not only mag, so fixed here rather than in the mag-only branch).
  if [[ -z "$MISS" ]]; then
    EMPTYCOLS=''
    for C in $REQ; do
      I=$(colidx "$C")
      bad=$(awk -F, -v i="$I" 'NR>1 && $i=="" {print NR-1}' "$TMP" | paste -sd, -)
      [[ -z "$bad" ]] || EMPTYCOLS="$EMPTYCOLS $C(row:$bad)"
    done
    [[ -z "$EMPTYCOLS" ]] && ok "$PIPELINE required column values all non-empty" \
                          || fail "$PIPELINE required column(s) empty on some row(s):$EMPTYCOLS"
  fi
  if [[ "$PIPELINE" == sarek ]]; then
    [[ -n "$(colidx fastq_1)$(colidx bam)$(colidx cram)$(colidx vcf)" ]] \
      || fail "sarek needs one of fastq_1 / bam / cram / vcf, matching --step"
  fi
  if [[ "$PIPELINE" == mag ]]; then
    # schema_input.json (5.5.0): anyOf short_reads_1 / long_reads; short_reads_2 requires
    # short_reads_1; short_reads_1 requires short_reads_platform; long_reads requires
    # long_reads_platform. Empirically confirmed via -preview (2026-08-12): uniqueEntries
    # [sample, run] is a COMPOSITE key -- same sample with different run values passes
    # (the pipeline's own multirun test fixture does exactly this), same sample+run
    # duplicated, or same sample with run omitted entirely on both rows, both fail.
    [[ -n "$(colidx short_reads_1)$(colidx long_reads)" ]] \
      || fail "mag needs short_reads_1 and/or long_reads"
    # dependentRequired in schema_input.json is a PER-ROW value constraint, not a column-
    # presence one -- empirically confirmed via -preview: a row with the long_reads column
    # present in the header but empty for that row validates fine as long as
    # short_reads_1/short_reads_platform are populated. Check actual values per row, not
    # whether the column exists.
    mag_row_check() {
      local want="$1" need="$2" label="$3"
      local wi ni; wi=$(colidx "$want"); ni=$(colidx "$need")
      [[ -n "$wi" ]] || return 0
      local bad
      bad=$(awk -F, -v w="$wi" -v n="${ni:-0}" \
            'NR>1 && $w!="" && (n==0 || $n=="") {print NR-1}' "$TMP" | paste -sd' ' -)
      [[ -z "$bad" ]] || fail "mag: row(s) with $want but no $need (row $label): $bad"
    }
    mag_row_check short_reads_2 short_reads_1 "short_reads_2 requires short_reads_1"
    mag_row_check short_reads_1 short_reads_platform "short_reads_1 requires short_reads_platform"
    mag_row_check long_reads long_reads_platform "long_reads requires long_reads_platform"
    # anyOf short_reads_1/long_reads is also per row, not per sheet.
    S1I=$(colidx short_reads_1); LRI=$(colidx long_reads)
    if [[ -n "$S1I" || -n "$LRI" ]]; then
      bad=$(awk -F, -v s="${S1I:-0}" -v l="${LRI:-0}" \
            'NR>1 && (s==0 || $s=="") && (l==0 || $l=="") {print NR-1}' "$TMP" | paste -sd' ' -)
      [[ -z "$bad" ]] && ok "mag: every row has short_reads_1 and/or long_reads" \
                      || fail "mag: row(s) with neither short_reads_1 nor long_reads: $bad"
    fi
    if [[ -n "$(colidx run)" ]]; then
      D=$(awk -F, -v s="$(colidx sample)" -v r="$(colidx run)" 'NR>1{print $s"/"$r}' "$TMP" \
          | sort | uniq -d | paste -sd' ' -)
      [[ -z "$D" ]] && ok "mag sample/run pairs unique" \
                    || fail "mag: duplicate sample/run pair (uniqueEntries composite key): $D"
    else
      # No `run` column at all: every row's implicit run is the same missing value, so
      # uniqueEntries[sample, run] collapses to sample-only uniqueness -- confirmed
      # empirically (nextflow -preview on two S1 rows, no run column: "Detected duplicate
      # entries: [sample:S1]"). Without this branch two same-`sample` rows with no `run`
      # column passed silently (Codex review, PR #35) because the generic identifier check
      # below only WARNs ("merged as technical replicates"), which is correct for pipelines
      # that support that merge but wrong for mag, where the schema hard-rejects it.
      D=$(colvals sample | sort | uniq -d | paste -sd' ' -)
      [[ -z "$D" ]] && ok "mag sample values unique (no run column)" \
                    || fail "mag: duplicate sample value(s) with no run column (uniqueEntries [sample,run] collapses to sample alone): $D"
    fi
  fi
  if [[ "$PIPELINE" == taxprofiler ]]; then
    # schema_input.json (2.0.1) required[] is ONLY sample/run_accession/instrument_platform --
    # fastq_1, fastq_2, fasta are all optional at the schema level. Empirically confirmed via
    # -preview (2026-08-12): a row with none of fastq_1/fastq_2/fasta VALIDATES CLEANLY (no
    # error, completed=0 failed=0) -- the schema alone will not catch a metadata-only row with
    # nothing for the pipeline to actually profile. Warn, don't fail: this checker cannot know
    # whether that is a deliberate placeholder row.
    if [[ -z "$(colidx fastq_1)$(colidx fastq_2)$(colidx fasta)" ]]; then
      fail "taxprofiler: sheet has none of fastq_1/fastq_2/fasta columns at all -- nothing to profile"
    else
      NOREADS=$(awk -F, -v f1="$(colidx fastq_1 || echo 0)" -v f2="$(colidx fastq_2 || echo 0)" \
                     -v fa="$(colidx fasta || echo 0)" \
                'NR>1 && (f1==0||$f1=="") && (f2==0||$f2=="") && (fa==0||$fa=="") {print NR-1}' \
                "$TMP" | paste -sd' ' -)
      [[ -z "$NOREADS" ]] || warn "taxprofiler: row(s) with NEITHER fastq_1/fastq_2 NOR fasta (schema accepts this silently -- pipeline has nothing to profile for that row): $NOREADS"
    fi
    # instrument_platform is a closed enum in schema_input.json.
    if [[ -n "$(colidx instrument_platform)" ]]; then
      B=$(colvals instrument_platform | grep -vE '^(ABI_SOLID|BGISEQ|CAPILLARY|COMPLETE_GENOMICS|DNBSEQ|HELICOS|ILLUMINA|ION_TORRENT|LS454|OXFORD_NANOPORE|PACBIO_SMRT)$' | sort -u | paste -sd, - || true)
      [[ -z "$B" ]] && ok "taxprofiler instrument_platform values valid" \
                    || fail "taxprofiler: bad instrument_platform (schema enum): $B"
    fi
    # uniqueEntries [sample, run_accession] -- empirically confirmed COMPOSITE (2026-08-12,
    # same shape as mag's [sample,run]): same sample with a different run_accession passes,
    # same sample+run_accession pair repeated fails. run_accession is REQUIRED (unlike mag's
    # optional `run`), so there is no "collapses to sample alone" branch to worry about here.
    if [[ -n "$(colidx sample)" && -n "$(colidx run_accession)" ]]; then
      D=$(awk -F, -v s="$(colidx sample)" -v r="$(colidx run_accession)" 'NR>1{print $s"/"$r}' "$TMP" \
          | sort | uniq -d | paste -sd' ' -)
      [[ -z "$D" ]] && ok "taxprofiler sample/run_accession pairs unique" \
                    || fail "taxprofiler: duplicate sample/run_accession pair (uniqueEntries composite key): $D"
    fi
    # uniqueEntries [fastq_1], [fastq_2], [fasta] are each SEPARATE per-field constraints in
    # schema_input.json (not folded into the composite above) -- empirically confirmed: two
    # rows with different sample/run_accession but the SAME fastq_1 path both fail schema
    # validation ("Detected duplicate entries: [fastq_1:...]"). A shared input file across two
    # sheet rows is therefore always a hard error here, unlike mag/rnaseq where reusing a FASTQ
    # path across rows is unremarkable.
    for C in fastq_1 fastq_2 fasta; do
      I=$(colidx "$C"); [[ -n "$I" ]] || continue
      D=$(colvals "$C" | grep -v '^$' | sort | uniq -d | paste -sd' ' -)
      [[ -z "$D" ]] && ok "taxprofiler $C values unique" \
                    || fail "taxprofiler: duplicate $C value(s) (schema rejects unconditionally): $D"
    done
  fi
elif [[ -z "$PIPELINE" ]]; then
  ID=''
  for C in sample patient group id; do [[ -z "$(colidx "$C")" ]] || { ID="$C"; break; }; done
  [[ -n "$ID" ]] && ok "sample-identifier column: $ID" \
                 || fail "no sample-identifier column (sample|patient|group|id); pass --pipeline <name> to check the full set"
fi

# ---- 3. path columns --------------------------------------------------------
for C in fastq_1 fastq_2 bam bai cram crai vcf table spring_1 spring_2 forwardReads reverseReads short_reads_1 short_reads_2 long_reads; do
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
    # FASTQ-only columns: the schemas for these columns (rnaseq/ampliseq/mag, confirmed
    # against schema_input.json at each pin) require an exact `.f(ast)?q.gz` suffix, not
    # merely "ends in .gz" -- a `.gz`-suffixed non-FASTQ file (e.g. a mistakenly-pointed
    # `.txt.gz`) previously fell through the case below with no suffix check at all and
    # reported PASS. bam/bai/cram/crai/vcf/table/spring_* legitimately use other suffixes
    # and are NOT in this list.
    case "$C" in
      fastq_1|fastq_2|forwardReads|reverseReads|short_reads_1|short_reads_2|long_reads)
        if [[ ! "$P" =~ \.f(ast)?q\.gz$ ]]; then
          fail "$C: does not match the required .f(ast)?q.gz suffix: $P"
          continue
        fi ;;
    esac
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
if [[ -z "$I1" ]]; then I1=$(colidx short_reads_1); I2=$(colidx short_reads_2); fi
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
elif [[ "$PIPELINE" == ampliseq || "$PIPELINE" == mag || "$PIPELINE" == taxprofiler ]]; then
  : # already checked as a hard FAIL, correctly, in the pipeline-specific branch above -- this
    # generic branch's WARN ("merged as technical replicates") is the wrong severity here and
    # would be a redundant, softer second message for the same row
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
if [[ "$PIPELINE" == mag ]]; then
  # schema_input.json (5.5.0): fixed enums on both platform columns. Empty values are fine
  # (dependentRequired is checked separately, section 2b above) -- only a NON-empty value
  # outside the enum is a schema violation.
  if [[ -n "$(colidx short_reads_platform)" ]]; then
    B=$(colvals short_reads_platform | grep -vE '^(ILLUMINA|BGISEQ|LS454|ION_TORRENT|DNBSEQ|ELEMENT|ULTIMA|VELA_DIAGNOSTICS|GENAPSYS|GENEMIND|TAPESTRI)?$' | sort -u | paste -sd, - || true)
    [[ -z "$B" ]] && ok "mag short_reads_platform values valid" || fail "mag: bad short_reads_platform: $B"
  fi
  if [[ -n "$(colidx long_reads_platform)" ]]; then
    B=$(colvals long_reads_platform | grep -vE '^(OXFORD_NANOPORE|OXFORD_NANOPORE_HQ|PACBIO_CLR|PACBIO_HIFI)?$' | sort -u | paste -sd, - || true)
    [[ -z "$B" ]] && ok "mag long_reads_platform values valid" || fail "mag: bad long_reads_platform: $B"
  fi
fi

# ---- 7. footprint -----------------------------------------------------------
PATHS=$( { for C in fastq_1 fastq_2 bam cram forwardReads reverseReads short_reads_1 short_reads_2 long_reads; do colvals "$C"; done; } | grep '^/' | sort -u || true )
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
