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
  raredisease)           REQ='sample sex phenotype case_id' ;;              # plus fastq_1/spring_1/bam, below
  nanoseq)               REQ='group replicate' ;;                          # plus input_file/fasta/gtf shape, below
  rnasplice)              REQ='sample fastq_1 strandedness condition' ;;    # fastq_2 header required but value may be empty (SE) -- see below
  isoseq)                REQ='sample' ;;                                   # bam+pbi (isoseq entrypoint) or reads (map entrypoint) -- see below
  bacass)                REQ='ID' ;;                                       # R1/R2/LongFastQ/Fast5/GenomeSize all optional at schema level -- see below
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
  if [[ "$PIPELINE" == raredisease ]]; then
    # schema_input.json's `sample` pattern is ^\S+$ -- whitespace makes it fail schema
    # validation even though it is nonempty and would otherwise only draw the generic
    # identifier check's WARN, not a FAIL (Codex review, PR #37, round 4: same shape as the
    # bam/bai/fastq_1/fastq_2 whitespace gaps fixed above).
    SMPI=$(colidx sample)
    if [[ -n "$SMPI" ]]; then
      BADSMP=$(awk -F, -v i="$SMPI" 'NR>1 && $i ~ /[[:space:]]/ {print NR-1}' "$TMP" | paste -sd' ' -)
      [[ -z "$BADSMP" ]] && ok "raredisease: sample values contain no whitespace" \
                         || fail "raredisease: sample value(s) contain whitespace (schema pattern ^\\S+\$): $BADSMP"
    fi
    # assets/schema_input.json (3.1.2): items.anyOf requires dependentRequired{lane:[fastq_1]}
    # OR dependentRequired{lane:[spring_1]} -- i.e. if `lane` has a value, fastq_1 or spring_1
    # must too -- plus a separate dependentRequired{bam:[bai]}. There is no schema-level
    # requirement that EVERY row carry fastq_1/spring_1/bam (a bam-only sheet has no `lane`
    # column at all, so the anyOf's dependentRequired is vacuously satisfied) -- confirmed via
    # -preview (2026-08-12) that a bam/bai-only sheet with no lane/fastq_1/spring_1 columns
    # validates cleanly. A header-only check is not enough here: a mixed sheet can have the
    # bam column present and still leave individual rows with bam/spring_1/fastq_1 all empty
    # -- the schema accepts that row too (Codex review, PR #37, same shape as the taxprofiler
    # gap fixed in PR #36) -- so check per row, not just per column family.
    F1I=$(colidx fastq_1); SPI=$(colidx spring_1); BMI=$(colidx bam); BAI=$(colidx bai)
    if [[ -z "$F1I$SPI$BMI" ]]; then
      fail "raredisease: sheet has none of fastq_1/spring_1/bam columns at all -- no read source"
    else
      NOSRC=$(awk -F, -v f1="${F1I:-0}" -v sp="${SPI:-0}" -v ba="${BMI:-0}" \
                'NR>1 && (f1==0||$f1=="") && (sp==0||$sp=="") && (ba==0||$ba=="") {print NR-1}' \
                "$TMP" | paste -sd' ' -)
      [[ -z "$NOSRC" ]] && ok "raredisease: every row has fastq_1/spring_1/bam" \
                        || fail "raredisease: row(s) with NEITHER fastq_1 NOR spring_1 NOR bam (schema accepts this silently -- pipeline has no read source for that row): $NOSRC"
    fi
    # dependentRequired{bam:[bai]} is a per-ROW value dependency, not a per-column one
    # (Codex review, PR #37, round 2): a `bai` header with an empty cell on the very row that
    # has a `bam` value previously passed because the old check only compared column
    # presence. Flag any row whose `bam` cell is nonempty but whose `bai` cell is empty or
    # whose `bai` column is altogether absent.
    if [[ -n "$BMI" ]]; then
      NOBAI=$(awk -F, -v bm="$BMI" -v ba="${BAI:-0}" \
                'NR>1 && $bm!="" && (ba==0||$ba=="") {print NR-1}' \
                "$TMP" | paste -sd' ' -)
      [[ -z "$NOBAI" ]] && ok "raredisease: every bam row has a bai" \
                        || fail "raredisease: row(s) with bam but no bai (schema dependentRequired bam->bai): $NOBAI"
    fi
    # dependentRequired{lane:[fastq_1]} OR dependentRequired{lane:[spring_1]}: a nonempty
    # `lane` cell on a row requires fastq_1 OR spring_1 on THAT row -- a nonempty `bam` cell
    # does NOT satisfy it (Codex review, PR #37, round 3): a bam-backed row that also happens
    # to carry a lane value still needs fastq_1/spring_1, and the earlier "has a read source"
    # check treated bam as sufficient regardless of lane, missing this case.
    LNI=$(colidx lane)
    if [[ -n "$LNI" ]]; then
      NOLANESRC=$(awk -F, -v ln="$LNI" -v f1="${F1I:-0}" -v sp="${SPI:-0}" \
                    'NR>1 && $ln!="" && (f1==0||$f1=="") && (sp==0||$sp=="") {print NR-1}' \
                    "$TMP" | paste -sd' ' -)
      [[ -z "$NOLANESRC" ]] && ok "raredisease: every lane row has fastq_1/spring_1" \
                            || fail "raredisease: row(s) with lane but neither fastq_1 nor spring_1 (schema dependentRequired lane->[fastq_1|spring_1]): $NOLANESRC"
    fi
    # sex/phenotype are closed integer enums here, NOT the generic XX/XY/NA the section-6 check
    # assumes -- override that check's blind spot for this pipeline rather than let it WARN on
    # every valid raredisease row.
    if [[ -n "$(colidx sex)" ]]; then
      B=$(colvals sex | grep -vE '^(0|1|2|other)$' | sort -u | paste -sd, - || true)
      [[ -z "$B" ]] && ok "raredisease sex values valid (0/1/2/other)" \
                    || fail "raredisease: bad sex value (schema enum 0/1/2/other): $B"
    fi
    if [[ -n "$(colidx phenotype)" ]]; then
      B=$(colvals phenotype | grep -vE '^[012]$' | sort -u | paste -sd, - || true)
      [[ -z "$B" ]] && ok "raredisease phenotype values valid (0/1/2)" \
                    || fail "raredisease: bad phenotype value (schema enum 0/1/2): $B"
    fi
    # schema_input.json declares "uniqueEntries": ["case_id"] but places the keyword INSIDE
    # `items`, not at the array's own top level (contrast the array-level placement nf-schema's
    # own docs and other pipelines here, e.g. mag/taxprofiler, use). nf-schema's
    # UniqueEntriesEvaluator.evaluate() short-circuits to success whenever the node it is
    # asked to validate is not itself an array (`if (!node.array) return success`) -- and a
    # keyword nested under `items` is evaluated once per OBJECT element, never against the
    # array. Confirmed empirically (nextflow -preview, 2026-08-12): a 5-row sheet with the
    # SAME case_id on every row (the pipeline's own assets/samplesheet.csv -- a legitimate
    # multi-lane single-sample case) validates cleanly, and so does a sheet with two fully
    # IDENTICAL rows (same sample/lane/fastq/case_id twice). This constraint is a dead no-op
    # as authored at this pin -- do NOT flag repeated case_id here; that is the pipeline's
    # normal, intended shape (one case_id per family/case, shared across every member's row).
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
    # nothing for the pipeline to actually profile. FAIL, not warn: a mixed sheet where only
    # SOME rows are empty would otherwise still print PASS overall (Codex review, PR #36) --
    # the pipeline schedules nothing for that row and an automated/warning-tolerant launch
    # would silently drop a sample with no launch-time error anywhere.
    F1I=$(colidx fastq_1); F2I=$(colidx fastq_2); FAI=$(colidx fasta)
    if [[ -z "$F1I$F2I$FAI" ]]; then
      fail "taxprofiler: sheet has none of fastq_1/fastq_2/fasta columns at all -- nothing to profile"
    else
      # ${VAR:-0}, not `$(colidx X || echo 0)` -- colidx exits 0 with EMPTY stdout when the
      # column is absent (it never actually fails), so the `||` form silently never fires and
      # awk receives an empty string, not "0"; awk then does a STRING compare of "" against
      # numeric 0 for f1==0, which is false, so a genuinely-missing column was never flagged
      # (caught only by hand-testing a two-column-family mixed sheet, not by any single-family
      # sheet -- fixed after Codex review, PR #36, flagged the row-level check as too weak,
      # though this exact bug was found independently while addressing that finding).
      NOREADS=$(awk -F, -v f1="${F1I:-0}" -v f2="${F2I:-0}" -v fa="${FAI:-0}" \
                'NR>1 && (f1==0||$f1=="") && (f2==0||$f2=="") && (fa==0||$fa=="") {print NR-1}' \
                "$TMP" | paste -sd' ' -)
      [[ -z "$NOREADS" ]] && ok "taxprofiler: every row has fastq_1/fastq_2 and/or fasta" \
                          || fail "taxprofiler: row(s) with NEITHER fastq_1/fastq_2 NOR fasta (schema accepts this silently -- pipeline has nothing to profile for that row): $NOREADS"
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
      # `grep -v '^$'` exits 1 (no match) when EVERY value in this column is empty -- e.g. a
      # supported single-end/long-read sheet with fastq_2 present but blank on every row.
      # Under `set -euo pipefail` that unguarded exit 1 aborted the whole checker right here,
      # silently, with no FAIL/PASS message at all (Codex review, PR #36, P1: reproduced with a
      # one-row OXFORD_NANOPORE sheet with an empty fastq_2 column). `|| true` tolerates the
      # no-match case the same way this file already does elsewhere (e.g. the `B=... || true`
      # pattern in the enum checks above).
      D=$(colvals "$C" | { grep -v '^$' || true; } | sort | uniq -d | paste -sd' ' -)
      [[ -z "$D" ]] && ok "taxprofiler $C values unique" \
                    || fail "taxprofiler: duplicate $C value(s) (schema rejects unconditionally): $D"
    done
  fi
  if [[ "$PIPELINE" == nanoseq ]]; then
    # nanoseq's assets/schema_input.json (3.1.0) describes sample/fastq_1/fastq_2 -- but grep
    # across every workflows/subworkflows/modules/*.nf in the pinned clone for
    # schema_input/validateParameters/nf-schema/nf-validation returns NOTHING (confirmed
    # 2026-08-13): that file is never referenced anywhere and is vestigial from the nf-core
    # template. The samplesheet actually enforced is validated at runtime by the pipeline's own
    # bundled `bin/check_samplesheet.py` (invoked via the SAMPLESHEET_CHECK module) against a
    # completely different header: group,replicate,barcode,input_file,fasta,gtf. Every check in
    # this block mirrors that script's actual logic line for line, not the unused JSON schema.
    GI=$(colidx group); RI=$(colidx replicate); FI=$(colidx input_file)
    BI=$(colidx barcode); FAI=$(colidx fasta); GTI=$(colidx gtf)

    # MIN_COLS=3: check_samplesheet.py requires at least 3 of the 6 RECOGNISED columns
    # (group,replicate,barcode,input_file,fasta,gtf) populated per row -- counting every field
    # in the row (Codex review, PR #38) would let an extra, unrecognised column (a typo'd
    # header, or a stray column check_samplesheet.py itself would never see) satisfy the count
    # even though none of the six real fields is populated. Sum only over the indices of the
    # six recognised names that are actually present in this header; a header missing one of
    # them simply contributes nothing to that row's count, same as check_samplesheet.py itself
    # (which hardcodes exactly six columns and never sees an extra one at all).
    MINCOLS=$(awk -F, -v g="${GI:-0}" -v r="${RI:-0}" -v b="${BI:-0}" -v f="${FI:-0}" -v fa="${FAI:-0}" -v gt="${GTI:-0}" '
      NR>1{
        c=0
        if (g!=0 && $g!="") c++
        if (r!=0 && $r!="") c++
        if (b!=0 && $b!="") c++
        if (f!=0 && $f!="") c++
        if (fa!=0 && $fa!="") c++
        if (gt!=0 && $gt!="") c++
        if (c<3) print NR-1
      }' "$TMP" | paste -sd' ' -)
    [[ -z "$MINCOLS" ]] && ok "nanoseq: every row has >=3 populated recognised columns (check_samplesheet.py MIN_COLS)" \
                        || fail "nanoseq: row(s) with <3 populated recognised columns (group/replicate/barcode/input_file/fasta/gtf): $MINCOLS"

    # replicate must be a bare integer (check_samplesheet.py: replicate.isdigit()).
    if [[ -n "$RI" ]]; then
      BADREP=$(awk -F, -v i="$RI" 'NR>1 && $i !~ /^[0-9]+$/ {print NR-1}' "$TMP" | paste -sd' ' -)
      [[ -z "$BADREP" ]] && ok "nanoseq: replicate values are bare integers" \
                         || fail "nanoseq: non-integer/empty replicate value(s) on row(s): $BADREP"
    fi

    # barcode, when given, must ALSO be a bare integer -- zero-padded to barcodeNN internally.
    if [[ -n "$BI" ]]; then
      BADBC=$(awk -F, -v i="$BI" 'NR>1 && $i!="" && $i !~ /^[0-9]+$/ {print NR-1}' "$TMP" | paste -sd' ' -)
      [[ -z "$BADBC" ]] && ok "nanoseq: barcode values are bare integers (or empty)" \
                        || fail "nanoseq: non-integer barcode value(s) on row(s): $BADBC"
    fi

    # group: check_samplesheet.py rejects any group entry containing a literal space.
    if [[ -n "$GI" ]]; then
      BADGRP=$(awk -F, -v i="$GI" 'NR>1 && $i ~ / / {print NR-1}' "$TMP" | paste -sd' ' -)
      [[ -z "$BADGRP" ]] && ok "nanoseq: group values contain no spaces" \
                         || fail "nanoseq: group value(s) contain a space on row(s): $BADGRP"
    fi

    # All input_file entries must share ONE extension family across the WHOLE sheet
    # (check_samplesheet.py: "All input files must have the same extension!"). Per-row
    # suffix/existence checks happen in section 3 below (input_file added to that column list).
    if [[ -n "$FI" ]]; then
      EXTS=$(awk -F, -v i="$FI" 'NR>1 && $i!=""{
               if ($i ~ /\.fastq\.gz$/) print "fastq.gz";
               else if ($i ~ /\.fq\.gz$/) print "fq.gz";
               else if ($i ~ /\.bam$/) print "bam";
               else if ($i !~ /\.fastq\.gz$|\.fq\.gz$|\.bam$/) print "other/dir"
             }' "$TMP" | sort -u)
      NEXT=$(printf '%s\n' "$EXTS" | grep -c . || true)
      (( NEXT <= 1 )) && ok "nanoseq: all input_file entries share one extension family" \
                      || fail "nanoseq: mixed input_file extensions across rows (pipeline requires all-same): $(printf '%s' "$EXTS" | paste -sd, -)"
    fi

    # replicate ids per group must run 1..N with no gaps and no repeats
    # (check_samplesheet.py: "Same replicate id provided multiple times!" /
    # "Replicate ids must start with 1..<num_replicates>!").
    if [[ -n "$GI" && -n "$RI" ]]; then
      DUPREP=$(awk -F, -v g="$GI" -v r="$RI" 'NR>1{k=$g"/"$r; if(k in seen) print k; seen[k]=1}' "$TMP" | paste -sd' ' -)
      [[ -z "$DUPREP" ]] && ok "nanoseq: group/replicate pairs unique" \
                         || fail "nanoseq: duplicate group/replicate pair(s): $DUPREP"
      GAPS=$(awk -F, -v g="$GI" -v r="$RI" '
        NR>1{ n[$g]++; if($r+0>max[$g]) max[$g]=$r+0 }
        END{ for (grp in n) if (n[grp]!=max[grp]) printf "%s ", grp }' "$TMP")
      [[ -z "$GAPS" ]] && ok "nanoseq: replicate ids run 1..N per group with no gaps" \
                       || fail "nanoseq: group(s) whose replicate ids are not a contiguous 1..N run: $GAPS"
    fi
  fi
  if [[ "$PIPELINE" == rnasplice ]]; then
    # nf-core/rnasplice 1.0.4: assets/schema_input.json exists but (same class of finding as
    # nanoseq) is NOT referenced by any .nf file at this pin -- grepped workflows/subworkflows/
    # modules for schema_input/validateParameters/nf-validation and found nothing wired to it
    # for the fastq source. The samplesheet actually enforced (source=fastq, the only source this
    # procurement stocks) is the pipeline's own bin/check_samplesheet_fastq.py, invoked via the
    # local SAMPLESHEET_CHECK module. Every check below mirrors that script's RowChecker methods.
    #
    # required_columns there is a HEADER-presence set of {sample,fastq_1,fastq_2,strandedness,
    # condition} -- fastq_2's header must exist even though its per-row VALUE may be empty for
    # single-end (RowChecker._validate_second only checks format when non-empty). $REQ above
    # covers sample/fastq_1/strandedness/condition (value non-empty enforced); fastq_2 header
    # presence is checked here on its own, the same asymmetry rnaseq's REQ already carries.
    if [[ -z "$(colidx fastq_2)" ]]; then
      fail "rnasplice: missing fastq_2 column header (required even for single-end rows -- check_samplesheet_fastq.py's required_columns set)"
    else
      ok "rnasplice: fastq_2 header present"
    fi

    # strandedness: check_samplesheet_fastq.py's OWN enum is {unstranded,forward,reverse} --
    # NOT the {auto,forward,reverse,unstranded} the generic section-6 check below allows for
    # rnaseq/other pipelines. 'auto' is a real, common rnaseq value (this repo's own rnaseq runs
    # use it) that rnasplice's samplesheet checker rejects outright with "unrecognized value" --
    # confirmed by reading bin/check_samplesheet_fastq.py._validate_strandedness_value directly.
    # Override the generic check for this pipeline rather than let it pass 'auto' through.
    STI=$(colidx strandedness)
    if [[ -n "$STI" ]]; then
      B=$(colvals strandedness | grep -vE '^(unstranded|forward|reverse)$' | sort -u | paste -sd, - || true)
      [[ -z "$B" ]] && ok "rnasplice strandedness values valid (unstranded/forward/reverse; 'auto' is NOT accepted here)" \
                    || fail "rnasplice: bad strandedness value ('auto' rejected by check_samplesheet_fastq.py; must be unstranded/forward/reverse): $B"
    fi

    # condition: check_samplesheet_fastq.py._validate_condition_value applies
    # re.search("^(([A-Za-z]|[.][._A-Za-z])[._A-Za-z0-9]*)|[.]$", value) -- and re.search is a
    # PARTIAL match: neither alternative is fully anchored (the first has no trailing $, the
    # second has no leading ^), so the real check is far looser than "the whole value matches
    # this grammar" (Codex review, PR #39 round 2, caught a first attempt at mirroring this that
    # WAS fully ^...$-anchored and therefore still too strict -- e.g. it rejected "a-bad" and
    # "1.", which the real un-anchored regex accepts). Verified directly against Python's
    # re.search on a dozen cases (a-bad, .foo-bar, 1., 1bad, 1bad., _bad, _bad., a, ., WT_ctrl,
    # 9, xyz!!!) before writing this: the value passes if it STARTS with a letter (any suffix
    # whatsoever, since the character-class tail can match zero characters and re.search does
    # not require consuming the rest of the string), OR STARTS with a dot followed by a
    # letter/dot/underscore (same "any suffix" caveat), OR ENDS with a literal dot (matches
    # anywhere via the un-anchored-at-start `[.]$` alternative, regardless of what precedes it).
    # It rejects only a value satisfying none of those three -- in practice just about anything
    # not starting with a digit/underscore/symbol AND not ending in a dot.
    CDI=$(colidx condition)
    if [[ -n "$CDI" ]]; then
      BADCOND=$(colvals condition | grep -vE '^[A-Za-z]|^\.[._A-Za-z]|\.$' | sort -u | paste -sd, - || true)
      [[ -z "$BADCOND" ]] && ok "rnasplice condition values syntactically valid" \
                          || fail "rnasplice: condition value(s) not accepted by the pipeline's condition regex (must start with a letter, start with a dot+letter/dot/underscore, or end with a dot): $BADCOND"

      # check_condition_replicates() LOOKS like it enforces "every condition needs >=2 rows",
      # and check_samplesheet(file_in, file_out) calls it -- but it is DEAD CODE at this pin.
      # check_samplesheet() calls it as check_condition_replicates(reader) AFTER the preceding
      # `for i, row in enumerate(reader): ...` loop has already fully consumed that same
      # csv.DictReader iterator; check_condition_replicates() then does
      # `[row["condition"] for row in samplesheet]` over the exhausted iterator, gets an empty
      # list, and `all(v > 1 for k, v in Counter([]).items())` is vacuously True (nothing to
      # iterate) -- so the assertion never fires, for any input. Empirically confirmed
      # 2026-08-14 via `-stub-run` (SAMPLESHEET_CHECK has no stub: block, so this runs for
      # real): a 3-row sheet with one condition value appearing on only one row passed
      # SAMPLESHEET_CHECK cleanly and produced a `samplesheet.valid.csv` with that singleton
      # condition intact -- no CRITICAL, no exit 1, nothing. WARN, not FAIL: the documented
      # constraint is real (and matters for the DOWNSTREAM SUPPA/DEXSeq/edgeR contrasts, which
      # need >=2 replicates per condition to produce a meaningful comparison), but nothing in
      # the pipeline at this pin will stop a run that violates it.
      SINGLETONS=$(colvals condition | sort | uniq -c | awk '$1==1{print $2}' | paste -sd' ' -)
      [[ -z "$SINGLETONS" ]] && ok "rnasplice: every condition has >=2 rows" \
                             || warn "rnasplice: condition(s) with only 1 row: $SINGLETONS -- check_condition_replicates() is DEAD CODE at 1.0.4 (reader exhausted before it runs, confirmed via -stub-run) so the pipeline will NOT reject this at samplesheet-check time; a singleton condition will still break any contrast/DE step that needs replicates"
    fi

    # validate_unique_samples(): the actual key is the (sample, fastq_1) PAIR, not sample alone
    # -- repeating a sample name across DIFFERENT fastq_1 values is the pipeline's supported
    # multi-run-per-sample shape (rows get auto-suffixed _T1/_T2/...). Only a duplicated
    # (sample, fastq_1) pair is a hard error. This must override, not stack with, the generic
    # section-5 "repeated sample ids" WARN below, which would otherwise mischaracterise a
    # legitimate multi-run sample as merely worth a second look.
    SMI=$(colidx sample); F1I=$(colidx fastq_1)
    if [[ -n "$SMI" && -n "$F1I" ]]; then
      DUPPAIR=$(awk -F, -v s="$SMI" -v f="$F1I" 'NR>1{print $s"\t"$f}' "$TMP" | sort | uniq -d | paste -sd';' -)
      [[ -z "$DUPPAIR" ]] && ok "rnasplice: (sample, fastq_1) pairs unique (validate_unique_samples)" \
                          || fail "rnasplice: duplicate (sample, fastq_1) pair -- validate_unique_samples() aborts the run: $DUPPAIR"
    fi
  fi
  if [[ "$PIPELINE" == isoseq ]]; then
    # nf-core/isoseq 2.0.0: unlike nanoseq/rnasplice, assets/schema_input.json IS the
    # authoritative validator here -- samplesheetToList(params.input, ...schema_input.json)
    # is called directly from subworkflows/local/utils_nfcore_isoseq_pipeline/main.nf, no
    # bundled bin/check_samplesheet*.py sits in front of it (confirmed by reading that file
    # and grepping bin/ for a samplesheet script -- none exists). Only `sample` is in the
    # schema's required[]; bam/pbi/reads are each optional at the schema level but every row
    # must carry the pair matching whichever --entrypoint the RUN uses (a param, not a sheet
    # column) -- 'isoseq' (default) wants bam+pbi populated and reads='None'; 'map' wants
    # reads populated and bam=pbi='None'. The CSV alone cannot say which entrypoint a row is
    # for, so this block checks internal consistency (every row is unambiguously isoseq-shaped
    # or map-shaped) rather than a fixed column requirement.
    BMI=$(colidx bam); PBI=$(colidx pbi); RDI=$(colidx reads)
    if [[ -z "$BMI$PBI$RDI" ]]; then
      fail "isoseq: sheet has none of bam/pbi/reads columns -- no read source for either entrypoint"
    else
      # schema patterns are all `^\S+...$` -- whitespace anywhere fails validation even when
      # the suffix matches (Codex review, PR #40, round 1, P2: same shape as the bam/bai/fastq
      # whitespace gaps fixed on raredisease in PR #37 -- checked here up front so the suffix
      # checks below never see a value that should already have failed).
      for FLD in "$BMI:bam" "$PBI:pbi" "$RDI:reads"; do
        IDX="${FLD%%:*}"; NAME="${FLD##*:}"
        [[ -n "$IDX" ]] || continue
        WS=$(awk -F, -v i="$IDX" 'NR>1 && $i ~ /[[:space:]]/ {print NR-1}' "$TMP" | paste -sd' ' -)
        [[ -z "$WS" ]] || fail "isoseq: $NAME value(s) contain whitespace (schema pattern ^\\S+... forbids it) on row(s): $WS"
      done
      # schema patterns: bam ^\S+\.bam$|^None$ ; pbi ^\S+\.bam\.pbi$|^None$ ; reads ^\S+\.fa\.gz$|^None$
      # An EMPTY cell in a present column is not a valid value under either branch of the
      # pattern -- only an exact 'None' or a matching path satisfies it -- so the awk condition
      # must NOT exclude $i=="" from BAD (Codex review, PR #40, round 2, P1: the previous
      # `$i!=""` guard silently treated a blank cell the same as 'None' here, and the shape
      # check below also reads blank as unset, so a sheet with all source headers present but
      # an unused cell left blank instead of literally 'None' printed PASS).
      if [[ -n "$BMI" ]]; then
        BAD=$(awk -F, -v i="$BMI" 'NR>1 && $i!="None" && $i !~ /\.bam$/ {print NR-1}' "$TMP" | paste -sd' ' -)
        [[ -z "$BAD" ]] && ok "isoseq: bam values match .bam or 'None'" \
                        || fail "isoseq: bam value(s) not matching ^\\S+\\.bam\$ or the literal 'None' (schema pattern -- an empty cell does not satisfy either branch) on row(s): $BAD"
      fi
      if [[ -n "$PBI" ]]; then
        BAD=$(awk -F, -v i="$PBI" 'NR>1 && $i!="None" && $i !~ /\.bam\.pbi$/ {print NR-1}' "$TMP" | paste -sd' ' -)
        [[ -z "$BAD" ]] && ok "isoseq: pbi values match .bam.pbi or 'None'" \
                        || fail "isoseq: pbi value(s) not matching ^\\S+\\.bam\\.pbi\$ or the literal 'None' (schema pattern -- a plain samtools .bai does NOT satisfy this, and neither does an empty cell) on row(s): $BAD"
      fi
      if [[ -n "$RDI" ]]; then
        BAD=$(awk -F, -v i="$RDI" 'NR>1 && $i!="None" && $i !~ /\.fa\.gz$/ {print NR-1}' "$TMP" | paste -sd' ' -)
        [[ -z "$BAD" ]] && ok "isoseq: reads values match .fa.gz or 'None'" \
                        || fail "isoseq: reads value(s) not matching ^\\S+\\.fa\\.gz\$ or the literal 'None' (schema pattern -- must be the FLNC output of the isoseq entrypoint, not raw CCS/HiFi reads, and an empty cell does not satisfy either branch) on row(s): $BAD"
      fi
      # bam/pbi must appear together (both real, or both 'None') on every row -- a row with a
      # real bam but pbi='None' (or vice versa) passes the two pattern checks above individually
      # but PBCCS will fail at runtime for want of an index.
      if [[ -n "$BMI" && -n "$PBI" ]]; then
        MISMATCH=$(awk -F, -v b="$BMI" -v p="$PBI" \
          'NR>1 { bset=($b!="" && $b!="None"); pset=($p!="" && $p!="None"); if (bset!=pset) print NR-1 }' \
          "$TMP" | paste -sd' ' -)
        [[ -z "$MISMATCH" ]] && ok "isoseq: bam and pbi are both set or both 'None' on every row" \
                             || fail "isoseq: row(s) with bam set but pbi 'None' (or vice versa) -- PBCCS needs both together: $MISMATCH"
        # PBCCS discovers the PacBio index as the BAM's own sidecar (<bam>.pbi) -- a real pbi
        # value that is merely SET but points at an unrelated file (e.g. bam=/data/a.bam,
        # pbi=/data/b.bam.pbi) passes every check above yet fails at runtime, since the pipeline
        # stages `pbi` under its own basename, not renamed to match `bam` (Codex review, PR #40,
        # round 5, P1). Require pbi == bam + '.pbi' exactly whenever both are real.
        NAMEMISMATCH=$(awk -F, -v b="$BMI" -v p="$PBI" \
          'NR>1 { bv=$b; pv=$p; bset=(bv!="" && bv!="None"); pset=(pv!="" && pv!="None");
                  if (bset && pset && pv != bv".pbi") print NR-1 }' \
          "$TMP" | paste -sd' ' -)
        [[ -z "$NAMEMISMATCH" ]] && ok "isoseq: pbi filename matches its row's bam + .pbi" \
                                 || fail "isoseq: row(s) where pbi is not exactly <bam>.pbi -- PBCCS looks for the index as the BAM's own sidecar, a differently-named pbi is not found at runtime: $NAMEMISMATCH"
      fi
      # Every row must resolve to EXACTLY ONE complete source shape (bam+pbi both real, XOR
      # reads real), and every row in the sheet must resolve to the SAME shape -- --entrypoint
      # is a single run-wide param, not a per-row choice, so a sheet mixing bam/pbi-shaped rows
      # with reads-shaped rows, or a row with neither shape complete (e.g. all three columns
      # 'None', or a bam-only row with no pbi column at all), means at least one row cannot
      # supply the entrypoint the run actually uses and would silently fail or be skipped
      # (Codex review, PR #40, round 1, P1: the previous version only checked bam/pbi
      # PAIRWISE-consistency and bam+reads co-occurrence -- it never required a row to have a
      # complete shape at all, nor that the whole sheet agree on one).
      SHAPES=$(awk -F, -v b="${BMI:-0}" -v p="${PBI:-0}" -v r="${RDI:-0}" \
        'NR>1 {
           bset = (b!=0 && $b!="" && $b!="None")
           pset = (p!=0 && $p!="" && $p!="None")
           rset = (r!=0 && $r!="" && $r!="None")
           bp = (bset && pset)
           if (bp && rset) { print NR-1":both"; next }
           if (bp)         { print NR-1":isoseq"; next }
           if (rset)       { print NR-1":map"; next }
           print NR-1":none"
         }' "$TMP")
      BADROWS=$(printf '%s\n' "$SHAPES" | awk -F: '$2=="none" || $2=="both" {print}' | paste -sd' ' -)
      MIXED=$(printf '%s\n' "$SHAPES" | awk -F: '$2=="isoseq"||$2=="map" {print $2}' | sort -u | wc -l)
      if [[ -n "$BADROWS" ]]; then
        fail "isoseq: row(s) with neither a complete bam+pbi pair nor reads, or with both set (must be exactly one source shape per row): $BADROWS"
      elif [[ "$MIXED" -gt 1 ]]; then
        MIXROWS=$(printf '%s\n' "$SHAPES" | paste -sd' ' -)
        fail "isoseq: sheet mixes bam/pbi-shaped rows with reads-shaped rows -- --entrypoint is one run-wide choice, not per-row: $MIXROWS"
      else
        ok "isoseq: every row has exactly one complete source shape, consistent across the sheet"
      fi
    fi
  fi
  if [[ "$PIPELINE" == bacass ]]; then
    # nf-core/bacass 2.6.1: assets/schema_input.json IS the live validator here --
    # subworkflows/local/utils_nfcore_bacass_pipeline/main.nf:105 calls samplesheetToList()
    # straight against it, no bundled bin/check_samplesheet*.py in the clone (bin/ holds only
    # csv_to_yaml.py/find_common_reference.py/kmerfinder_summary.py/multiqc_to_custom_csv.py --
    # none a samplesheet validator). Only `ID` is in required[]; R1/R2/LongFastQ/Fast5/GenomeSize
    # are each individually optional (anyOf accepts an empty string OR the literal 'NA' OR a
    # matching value) -- confirmed empirically via -preview (2026-08-16): a row with R1=R2=
    # LongFastQ=Fast5='NA' (no read source of ANY kind) VALIDATES CLEANLY, completed=0 failed=0,
    # no error -- the same class of schema gap as taxprofiler/mag/raredisease's "no read source"
    # rows, checked explicitly below since the schema alone will not catch it.
    #
    # ID uniqueness: schema_input.json declares "unique": false on ID explicitly, and the
    # pipeline's OWN CI fixture (bacass_short_reseq.tsv) repeats ID=ERR044595 across two
    # different R1/R2 pairs as its normal, working re-sequencing-merge shape -- confirmed
    # empirically via -preview (2026-08-16, a synthetic duplicate-ID sheet: completed=0
    # failed=0, no error). Do not FAIL or WARN on a repeated ID here; that would
    # mischaracterise the pipeline's own intended and exercised shape as a problem.
    IDI=$(colidx ID); R1I=$(colidx R1); R2I=$(colidx R2); LFI=$(colidx LongFastQ)
    F5I=$(colidx Fast5); GSI=$(colidx GenomeSize)

    # ID: schema pattern is ^\S+$ -- whitespace fails validation even though ID is otherwise
    # free-form and non-empty (Codex review, PR #41, round 1, P2: IDI was collected but never
    # actually checked here, and the generic section-5 identifier loop only covers
    # sample/group/patient/sampleID, not the uppercase ID column bacass actually uses -- a
    # whitespace-bearing ID previously passed this checker only to be rejected by nf-schema).
    if [[ -n "$IDI" ]]; then
      BADID=$(awk -F, -v i="$IDI" 'NR>1 && $i ~ /[[:space:]]/ {print NR-1}' "$TMP" | paste -sd' ' -)
      [[ -z "$BADID" ]] && ok "bacass: ID values contain no whitespace (schema pattern ^\\S+\$)" \
                        || fail "bacass: ID value(s) contain whitespace (schema pattern ^\\S+\$ forbids it) on row(s): $BADID"
    fi

    # column-value checks: whitespace anywhere fails the schema's \S+-based patterns even when
    # the suffix/shape otherwise matches (same shape as raredisease/isoseq's whitespace gaps).
    # 'NA' and '' are the two schema-legal "not supplied" spellings for R1/R2/LongFastQ/Fast5;
    # anything else must match that column's own suffix/shape pattern.
    #
    # The pattern is passed through awk's -v, which -- like a string literal in an awk program
    # -- runs its own backslash-escape processing on the VALUE (Codex review, PR #41, round 1,
    # P2): an unrecognised escape such as \. is silently reduced to a bare . (a wildcard, not a
    # literal dot), so `\.f(ast)?q\.gz$` arrived inside awk as `.f(ast)?q.gz$` and something like
    # "https://x/aXfastqYgz" wrongly matched and passed. Doubling the backslashes here
    # (`\\.` -> awk's -v unescaping turns `\\` into a single `\`, yielding the literal `\.` the
    # regex actually needs) round-trips correctly -- verified by re-running the same negative
    # case below after this fix.
    bacass_field_check() {
      local col="$1" idx="$2" pattern="$3" label="$4"
      [[ -n "$idx" ]] || return 0
      local ws bad
      ws=$(awk -F, -v i="$idx" 'NR>1 && $i!="" && $i ~ /[[:space:]]/ {print NR-1}' "$TMP" | paste -sd' ' -)
      if [[ -n "$ws" ]]; then
        fail "bacass: $col value(s) contain whitespace (schema pattern forbids it) on row(s): $ws"
        return
      fi
      bad=$(awk -F, -v i="$idx" -v pat="$pattern" \
              'NR>1 && $i!="" && $i!="NA" && $i !~ pat {print NR-1}' "$TMP" | paste -sd' ' -)
      [[ -z "$bad" ]] && ok "bacass: $col values match $label or NA/empty" \
                      || fail "bacass: $col value(s) not matching $label, empty, or the literal 'NA' on row(s): $bad"
    }
    bacass_field_check R1 "$R1I" '\\.f(ast)?q\\.gz$' '.fq.gz/.fastq.gz'
    bacass_field_check R2 "$R2I" '\\.f(ast)?q\\.gz$' '.fq.gz/.fastq.gz'
    bacass_field_check LongFastQ "$LFI" '\\.f(ast)?q\\.gz$' '.fq.gz/.fastq.gz'
    # Fast5: a path to a directory of FAST5 files (used for long-read polishing). Beyond the
    # absolute-path shape check, verify local paths actually exist and (for a directory) are
    # non-empty -- otherwise a nonexistent path like /definitely/not/here previously passed as
    # PASS here only to fail once the pipeline tries to consume it (Codex review, PR #41,
    # round 1, P2). Same existence/non-empty-directory pattern as nanoseq's input_file check.
    if [[ -n "$F5I" ]]; then
      while IFS= read -r P; do
        [[ -n "$P" && "$P" != "NA" ]] || continue
        if [[ "$P" != /* ]]; then
          fail "Fast5: not an absolute path or the literal 'NA': $P"
          continue
        fi
        if [[ -d "$P" ]]; then
          [[ -n "$(find -L "$P" -mindepth 1 -type f -print -quit 2>/dev/null)" ]] \
            || fail "Fast5: directory has no files: $P"
        elif [[ -e "$P" ]]; then
          [[ -r "$P" ]] || fail "Fast5: not readable: $P"
        else
          fail "Fast5: path does not exist: $P"
        fi
      done < <(awk -F, -v i="$F5I" 'NR>1{print $i}' "$TMP")
      ok "Fast5: local absolute paths checked for existence/readability"
    fi
    if [[ -n "$GSI" ]]; then
      bad=$(awk -F, -v i="$GSI" 'NR>1 && $i!="" && $i!="NA" && $i !~ /^[0-9]+\.[0-9]+m$/ {print NR-1}' "$TMP" | paste -sd' ' -)
      [[ -z "$bad" ]] && ok "bacass: GenomeSize values match \\d+.\\d+m or NA/empty" \
                      || fail "bacass: GenomeSize value(s) not matching \\d+.\\d+m (e.g. '2.8m'), empty, or 'NA' on row(s): $bad -- a bare decimal with no trailing 'm' (e.g. '2.8') additionally mismatches the schema's expected STRING type, not just the pattern"
    fi

    # R1/R2/LongFastQ: schema URLs are legal (the pipeline's own CI fixture uses raw GitHub
    # URLs, confirmed by reading conf/test.config's resolved bacass_short_reseq.tsv), so unlike
    # every other stocked pipeline's path columns, a bare http(s):// value here is NOT a
    # relative-path mistake and must not be flagged as one. Existence/readability is only
    # checkable for local absolute paths; a URL's reachability is a network check, out of scope
    # for this static gate.
    for FLD in "$R1I:R1" "$R2I:R2" "$LFI:LongFastQ"; do
      IDX="${FLD%%:*}"; NAME="${FLD##*:}"
      [[ -n "$IDX" ]] || continue
      while IFS= read -r P; do
        [[ -n "$P" && "$P" != "NA" ]] || continue
        case "$P" in
          http://*|https://*) : ;;
          /*)
            [[ -r "$P" ]] || fail "$NAME: not readable: $P"
            [[ -s "$P" ]] || fail "$NAME: zero bytes: $P"
            # R1/R2/LongFastQ are handled in this bacass-specific loop, not section 3's generic
            # path-columns loop (they are not in that loop's fixed column-name list at all), so
            # without this they never got the gzip-magic/`--deep gzip -t` integrity check every
            # other pipeline's FASTQ columns get -- reproduced a PASS from `--deep --pipeline
            # bacass` against a plain-text file merely NAMED `*.fastq.gz` (Codex review, PR #41,
            # round 3, P2). Same check as section 3's `*.gz` case, applied here too.
            if [[ -r "$P" && -s "$P" ]]; then
              case "$P" in
                *.fastq|*.fq)
                  fail "$NAME: uncompressed FASTQ: $P (schema pattern requires .gz)" ;;
                *.gz)
                  if [[ "$(head -c2 "$P" | od -An -tx1 | tr -d ' ')" != "1f8b" ]]; then
                    fail "$NAME: not a gzip stream: $P"
                  elif (( DEEP )); then
                    gzip -t "$P" 2>/dev/null || fail "$NAME: gzip integrity / truncated: $P"
                  fi ;;
              esac
            fi
            ;;
          *) fail "$NAME: not an absolute path, http(s):// URL, or 'NA': $P" ;;
        esac
      done < <(awk -F, -v i="$IDX" 'NR>1{print $i}' "$TMP")
    done

    # No read source at all: the schema accepts an all-NA/all-empty row (confirmed above), but
    # the pipeline has nothing to assemble for it regardless of --assembly_type. FAIL, matching
    # the taxprofiler/mag/raredisease "no read source" pattern -- this is a per-row check, not a
    # per-column one, since a sheet can have the R1/LongFastQ columns present with only some
    # rows actually empty.
    #
    # This checker has no way to see --assembly_type -- it is a pipeline-wide run param, not a
    # sheet column, and this script only ever sees the CSV. The generic "R1 or LongFastQ"
    # check below is therefore necessarily loose: it passed a LongFastQ-only sheet even though
    # this REPO's only stocked bacass configuration is assembly_type: short
    # (config/pipelines.tsv), which needs R1 specifically and ignores LongFastQ entirely
    # (confirmed by reading workflows/bacass.nf's assembly_type-gated channel construction) --
    # a LongFastQ-only sheet run against this repo's stocked flags has NO usable read input at
    # all, not merely a degraded one (Codex review, PR #41, round 5, P2: reproduced PASS with
    # `ID,LongFastQ` and a valid URL). Enforce R1 specifically, matching the actual scope this
    # repo runs -- if a future procurement extends stocked scope to long/hybrid, this check
    # needs revisiting alongside that scope change, not left silently over-strict.
    if [[ -n "$R1I" ]]; then
      NOSRC=$(awk -F, -v r1="$R1I" 'NR>1 && ($r1==""||$r1=="NA") {print NR-1}' "$TMP" | paste -sd' ' -)
      [[ -z "$NOSRC" ]] && ok "bacass: every row has R1 populated (this repo's stocked assembly_type: short needs it)" \
                        || fail "bacass: row(s) with R1 empty/NA -- this repo's stocked configuration is assembly_type: short, which needs R1 regardless of LongFastQ: $NOSRC"
    else
      fail "bacass: sheet has no R1 column at all -- this repo's stocked configuration is assembly_type: short, which needs R1 (a LongFastQ-only sheet has no usable read source under that scope)"
    fi

    # R2 without R1: short-read mate pairing implies R1 must also be set whenever R2 is. An
    # R1-less sheet (R2 + LongFastQ present, no R1 header at all) previously skipped this check
    # entirely -- LongFastQ satisfied the earlier "has a read source" test, so an orphaned R2
    # with no possible mate reported PASS (Codex review, PR #41, round 2, P2). A missing R1
    # column means EVERY populated R2 value is orphaned by construction, not something that
    # needs a per-row R1 value to compare against.
    if [[ -n "$R2I" ]]; then
      if [[ -z "$R1I" ]]; then
        BADPAIR=$(awk -F, -v r2="$R2I" 'NR>1 && $r2!="" && $r2!="NA" {print NR-1}' "$TMP" | paste -sd' ' -)
      else
        BADPAIR=$(awk -F, -v r1="$R1I" -v r2="$R2I" \
                    'NR>1 && $r2!="" && $r2!="NA" && ($r1==""||$r1=="NA") {print NR-1}' \
                    "$TMP" | paste -sd' ' -)
      fi
      [[ -z "$BADPAIR" ]] && ok "bacass: no row has R2 set without R1" \
                          || fail "bacass: row(s) with R2 set but R1 empty/NA or the R1 column absent entirely (short-read mate pairing needs both): $BADPAIR"
    fi
  fi
elif [[ -z "$PIPELINE" ]]; then
  ID=''
  for C in sample patient group id; do [[ -z "$(colidx "$C")" ]] || { ID="$C"; break; }; done
  [[ -n "$ID" ]] && ok "sample-identifier column: $ID" \
                 || fail "no sample-identifier column (sample|patient|group|id); pass --pipeline <name> to check the full set"
fi

# ---- 3. path columns --------------------------------------------------------
# fasta: taxprofiler-only column, added here (not earlier) so the loop below actually
# validates it -- previously absent from this list entirely (Codex review, PR #36): a
# fasta-only taxprofiler sheet pointing at a nonexistent/relative/zero-byte/wrong-suffix path
# reported PASS, because this loop is what does path-exists/suffix/gzip checking and `fasta`
# was never in it.
for C in fastq_1 fastq_2 fasta bam bai cram crai vcf table spring_1 spring_2 forwardReads reverseReads short_reads_1 short_reads_2 long_reads input_file gtf pbi reads; do
  # input_file and gtf are nanoseq-specific column NAMES, not universal path columns like
  # fastq_1/fasta/bam -- another pipeline's samplesheet (e.g. differentialabundance's free-form
  # observations table) can legitimately use either name for an ordinary metadata variable with
  # no filesystem meaning at all (Codex review, PR #38, round 2: an `input_file` column holding
  # a batch label would otherwise be rejected here as "relative path"). Only apply this loop's
  # path semantics to them when the target pipeline actually is nanoseq. pbi/reads are the same
  # shape of isoseq-specific column name (a `reads` header on some other pipeline's sheet is
  # ordinary metadata, not a path).
  if [[ ( "$C" == input_file || "$C" == gtf ) && "$PIPELINE" != nanoseq ]]; then continue; fi
  if [[ ( "$C" == pbi || "$C" == reads ) && "$PIPELINE" != isoseq ]]; then continue; fi
  I=$(colidx "$C"); [[ -n "$I" ]] || continue
  N=0
  while IFS= read -r P; do
    [[ -n "$P" ]] || continue
    N=$((N+1))
    # isoseq's bam/pbi/reads columns use the literal string 'None' as "not applicable to the
    # entrypoint this row is for" (schema patterns above accept it explicitly) -- it is not a
    # relative path typo and must not be flagged as one, unlike every other pipeline's path
    # columns where a bare word in a path column IS a mistake.
    if [[ "$PIPELINE" == isoseq && ( "$C" == bam || "$C" == pbi || "$C" == reads ) && "$P" == "None" ]]; then
      continue
    fi
    if [[ "$P" != /* ]]; then
      fail "$C: relative path '$P' (resolves against the launch dir, not the sheet)"; continue
    fi
    # nanoseq's input_file may legitimately be a run DIRECTORY (fast5+fastq for nanopolish),
    # not a file -- `-r`/`-s` both accept a readable, non-empty directory, so this falls
    # through to the per-column case below cleanly rather than needing a separate branch here.
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
        # raredisease's schema pattern is ^\S+\.f(ast)?q\.gz$ -- whitespace anywhere in the
        # path fails validation even if the suffix matches (Codex review, PR #37, round 4,
        # same shape as the bam/bai whitespace gap fixed the round before). Other pipelines'
        # fastq columns are not confirmed to share the same \S+ requirement, so this is
        # raredisease-scoped, matching the bam/bai checks above.
        if [[ "$PIPELINE" == raredisease && ( "$C" == fastq_1 || "$C" == fastq_2 ) && "$P" =~ [[:space:]] ]]; then
          fail "$C: contains whitespace (schema pattern ^\\S+\\.f(ast)?q\\.gz\$ forbids it): $P"
          continue
        fi
        if [[ ! "$P" =~ \.f(ast)?q\.gz$ ]]; then
          fail "$C: does not match the required .f(ast)?q.gz suffix: $P"
          continue
        fi ;;
      fasta)
        if [[ "$PIPELINE" == nanoseq ]]; then
          # bin/check_samplesheet.py (the validator nanoseq actually runs -- see the block
          # above) accepts PLAIN, non-gzipped .fasta/.fa as well as .fasta.gz/.fa.gz; gzip is
          # optional here, unlike taxprofiler's `fasta` column below which requires it.
          if [[ ! "$P" =~ \.(fasta|fa)(\.gz)?$ ]]; then
            fail "$C: does not match the required .fa/.fasta/.fa.gz/.fasta.gz suffix (nanoseq): $P"
            continue
          fi
        # schema_input.json's own pattern is `\.(fasta|fas|fna|fa)\.gz?$` (only the trailing
        # "z" optional, not the whole ".gz" -- almost certainly an authoring typo upstream),
        # but empirically confirmed via -preview (2026-08-12) that a plain, non-gzipped `.fa`
        # is REJECTED ("does not match regular expression") -- the schema behaves as
        # gzip-required in practice regardless of what the literal regex appears to allow.
        # Enforce the same real-world requirement here.
        elif [[ ! "$P" =~ \.(fasta|fas|fna|fa)\.gz$ ]]; then
          fail "$C: does not match the required .(fasta|fas|fna|fa).gz suffix: $P"
          continue
        fi ;;
      input_file)
        if [[ "$PIPELINE" == nanoseq ]]; then
          if [[ -d "$P" ]]; then
            # `-s` above only proves the DIRECTORY ENTRY itself is nonzero size (true for
            # virtually every directory, empty or not -- Codex review, PR #38): it does not
            # establish the directory actually contains any fast5/fastq content. An empty
            # run-directory input previously passed this loop with no further check at all.
            # `-L` (follow symlinks): plain `find` uses `-P` by default and does not descend
            # through $P itself if $P is a symlink to a directory -- a symlinked run directory
            # with real fastq/fast5 content underneath previously reported "no files" (Codex
            # review, PR #38, round 2). No `-maxdepth`: this check exists to reject an EMPTY
            # directory, not to impose an assumed layout depth -- a real ONT run directory can
            # legitimately nest content deeper than 3 levels (Codex review, PR #38, round 3).
            [[ -n "$(find -L "$P" -mindepth 1 -type f -print -quit 2>/dev/null)" ]] \
              || fail "$C: directory has no files within 3 levels (fast5/fastq run dir expected): $P"
          elif [[ ! "$P" =~ \.(fastq\.gz|fq\.gz|bam)$ ]]; then
            fail "$C: does not match .fastq.gz/.fq.gz/.bam and is not an existing directory: $P"
            continue
          fi
        fi ;;
      gtf)
        if [[ "$PIPELINE" == nanoseq && ! "$P" =~ \.gtf(\.gz)?$ ]]; then
          fail "$C: does not match the required .gtf or .gtf.gz suffix: $P"
          continue
        fi ;;
      bam)
        # raredisease's schema_input.json (3.1.2) requires the literal `^\S+\.bam$` pattern
        # (Codex review, PR #37, round 2) -- a readable file under a swapped/wrong suffix
        # (e.g. a `.bai` path in the `bam` column) previously passed this loop with only a
        # readability check and was only rejected by the pipeline itself at preflight. `\S+`
        # also means no whitespace ANYWHERE in the path, not just the suffix (Codex review,
        # PR #37, round 3) -- a path containing a space matched the suffix-only regex but
        # fails the schema's actual pattern.
        if [[ "$PIPELINE" == raredisease ]]; then
          if [[ "$P" =~ [[:space:]] ]]; then
            fail "$C: contains whitespace (schema pattern ^\\S+\\.bam\$ forbids it): $P"
            continue
          fi
          if [[ ! "$P" =~ \.bam$ ]]; then
            fail "$C: does not match the required .bam suffix (schema_input.json pattern ^\\S+\\.bam\$): $P"
            continue
          fi
        fi ;;
      bai)
        if [[ "$PIPELINE" == raredisease ]]; then
          if [[ "$P" =~ [[:space:]] ]]; then
            fail "$C: contains whitespace (schema pattern ^\\S+\\.bai\$ forbids it): $P"
            continue
          fi
          if [[ ! "$P" =~ \.bai$ ]]; then
            fail "$C: does not match the required .bai suffix (schema_input.json pattern ^\\S+\\.bai\$): $P"
            continue
          fi
        fi ;;
      spring_1|spring_2)
        # schema_input.json's pattern for both SPRING columns is ^\S+\.spring$ (Codex review,
        # PR #37, round 5) -- previously only readability/size were checked here, so a
        # readable non-.spring file, or a .spring path containing whitespace, both passed.
        if [[ "$PIPELINE" == raredisease ]]; then
          if [[ "$P" =~ [[:space:]] ]]; then
            fail "$C: contains whitespace (schema pattern ^\\S+\\.spring\$ forbids it): $P"
            continue
          fi
          if [[ ! "$P" =~ \.spring$ ]]; then
            fail "$C: does not match the required .spring suffix (schema_input.json pattern ^\\S+\\.spring\$): $P"
            continue
          fi
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
# bacass uses uppercase R1/R2 -- without this fallback, a local paired bacass sheet only got
# readability/gzip-integrity checks from the bacass-specific loop above, never the
# header-orientation/mate-count checks below (Codex review, PR #41, round 7, P2: reproduced a
# PASS with Casava read-2 content placed in R1 and read-1 content in R2). $R1/$R2 values of
# 'NA' or a URL simply fail the `-r` readability test below and are skipped, same as any other
# pipeline's unreadable/remote mate value -- this only activates for local, readable pairs.
if [[ -z "$I1" && "$PIPELINE" == bacass ]]; then I1=$(colidx R1); I2=$(colidx R2); fi
if [[ -n "$I1" && -n "$I2" ]]; then
  while IFS=$'\t' read -r R1 R2; do
    [[ -n "$R2" && -r "$R1" && -r "$R2" ]] || continue
    P1=$(gzip -cd < "$R1" 2>/dev/null | head -2 || true)
    P2=$(gzip -cd < "$R2" 2>/dev/null | head -2 || true)
    H1=${P1%%$'\n'*}; S1=${P1#*$'\n'}
    H2=${P2%%$'\n'*}; S2=${P2#*$'\n'}
    # Legacy pre-Casava headers carry the mate number as a /1 or /2 suffix on the read NAME
    # itself (e.g. "@read1/1" vs "@read1/2"), rather than in a separate Casava-style
    # " 1:N:0:..." field -- comparing the raw first token therefore reported "mate names
    # differ" on a perfectly valid legacy-format pair (Codex review, PR #41, round 8, P2: this
    # generic check pre-dates bacass but was only newly exercised once bacass got routed
    # through it in round 7's fix; strip a trailing /1 or /2 before comparing, same as any
    # standard fastq-pairing tool does).
    N1=${H1%% *}; N2=${H2%% *}
    # Capture the legacy /1,/2 suffix BEFORE stripping it for the name comparison -- stripping
    # both independently makes "@read/2" and "@read/1" compare equal on name alone, which
    # would silently accept a genuinely swapped legacy-format pair (Codex review, PR #42,
    # round 1, P2: the Casava-field check below cannot recover this, since it only warns
    # "non-Casava headers" for a /1,/2-style name and never inspects the suffix itself).
    LSUF1=""; LSUF2=""
    case "$N1" in */1) LSUF1=1 ;; */2) LSUF1=2 ;; esac
    case "$N2" in */1) LSUF2=1 ;; */2) LSUF2=2 ;; esac
    N1=${N1%/[12]}; N2=${N2%/[12]}
    [[ "$N1" == "$N2" ]] \
      || fail "mate names differ on record 1: ${H1%% *} vs ${H2%% *}  ($R1)"
    if [[ -n "$LSUF1" && -n "$LSUF2" ]]; then
      case "$LSUF1/$LSUF2" in
        1/2) : ;;
        2/1) fail "R1/R2 SWAPPED (legacy /1,/2 mate suffix): $R1 holds read 2 and $R2 holds read 1" ;;
        *)   fail "legacy mate suffix pair is not 1/2 (got $LSUF1/$LSUF2 on $R1/$R2) -- both mates claim the same read number" ;;
      esac
    fi
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
elif [[ "$PIPELINE" == ampliseq || "$PIPELINE" == mag || "$PIPELINE" == taxprofiler || "$PIPELINE" == rnasplice ]]; then
  : # already checked as a hard FAIL, correctly, in the pipeline-specific branch above -- this
    # generic branch's WARN ("merged as technical replicates") is the wrong severity here and
    # would be a redundant, softer second message for the same row (rnasplice's real key is the
    # (sample, fastq_1) pair, not sample alone -- checked above)
elif [[ -n "$(colidx sample)" ]]; then
  D=$(colvals sample | sort | uniq -d | paste -sd' ' -)
  [[ -z "$D" ]] && ok "sample ids unique" \
                || warn "repeated sample ids (merged as technical replicates -- intentional?): $D"
fi

# ---- 6. enums ---------------------------------------------------------------
if [[ "$PIPELINE" != rnasplice && -n "$(colidx strandedness)" ]]; then
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
if [[ "$PIPELINE" != raredisease && -n "$(colidx sex)" ]]; then
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
# spring_1/spring_2 added (Codex review, PR #37, round 6): a raredisease sheet using only
# SPRING archives (which can hold the entire WGS input, same order of size as fastq/bam) was
# previously invisible to this loop entirely, printing "nothing to size" and skipping the
# 1.5x free-space gate below.
# input_file is a nanoseq-specific column name, not a universal path column (same reasoning as
# section 3's loop) -- an absolute-looking value in a non-nanoseq sheet's `input_file` column
# (e.g. a differentialabundance observations table using that name for ordinary metadata) is not
# a filesystem input and must not be sized or stat'd here (Codex review, PR #38, round 3: this
# unconditional collection still fed such a value into the du/stat loop below even after section
# 3 stopped path-validating it).
IFCOL=''; [[ "$PIPELINE" == nanoseq ]] && IFCOL='input_file'
ISOCOL=''; [[ "$PIPELINE" == isoseq ]] && ISOCOL='pbi reads'
# bacass's R1/R2/LongFastQ/Fast5 are frequently URLs (the pipeline's own CI fixture uses raw
# GitHub URLs), which the `grep '^/'` filter below already excludes on its own -- only a LOCAL
# absolute-path bacass sheet contributes to the footprint here, same as every other pipeline.
BACOL=''; [[ "$PIPELINE" == bacass ]] && BACOL='R1 R2 LongFastQ Fast5'
PATHS=$( { for C in fastq_1 fastq_2 fasta bam cram spring_1 spring_2 forwardReads reverseReads short_reads_1 short_reads_2 long_reads $IFCOL $ISOCOL $BACOL; do colvals "$C"; done; } | grep '^/' | sort -u || true )
if [[ -z "$PATHS" ]]; then
  printf 'size  nothing to size (no absolute fastq/bam/cram/spring paths)\n'
else
  # nanoseq's input_file may be a directory (fast5+fastq run dir) -- `stat -Lc %s` on a
  # directory reports only the directory-entry size (a few KB), not its contents, which
  # severely understates the referenced footprint for exactly the input type that is most
  # likely to be large (Codex review, PR #38). Size directories recursively with `du -sb`
  # and plain files with `stat`, rather than running every path through `stat` alike.
  BYTES=0
  while IFS= read -r P; do
    [[ -n "$P" ]] || continue
    if [[ -d "$P" ]]; then
      # `-D` (dereference-args): GNU du defaults to NOT following a symlink given directly on
      # its command line, so a symlinked run directory (the supported case fixed above) was
      # sized as just the symlink itself -- a handful of bytes, not its target's real content
      # (Codex review, PR #38, round 3, measured: a 1 MiB target reported as 24 B).
      SZ=$( { du -Dsb "$P" 2>/dev/null || true; } | awk '{print $1}')
    else
      SZ=$(stat -Lc %s "$P" 2>/dev/null || true)
    fi
    BYTES=$(( BYTES + ${SZ:-0} ))
  done <<< "$PATHS"
  printf 'size  %s of input referenced\n' "$(numfmt --to=iec --suffix=B "$BYTES")"
  echo  "      compare against free space on the work filesystem; refuse to start below 1.5x the estimate"
fi

(( ERR == 0 )) && echo "PASS  $SHEET" || echo "FAILED $SHEET"
exit "$ERR"
