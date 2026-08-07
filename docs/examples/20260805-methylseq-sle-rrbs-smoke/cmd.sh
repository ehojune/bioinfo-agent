#!/usr/bin/env bash
set -euo pipefail

RUNID=20260805-methylseq-sle-rrbs-smoke
PIPE=nf-core/methylseq
REV=3.0.0        # from config/pipelines.tsv
RUNDIR=/mnt/d/bioinfo-agent/runs/$RUNID
# Same derivation bin/preflight.sh uses to pick the work dir it checks (disk space, ext4-ness).
NXFDIR="${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID"
TS=$(date +%Y%m%d-%H%M%S)

# NXF_SYNTAX_PARSER=v1 — required on this host's installed Nextflow (26.04.6): the
# default v2 config parser rejects both local.config's `def X = ...` mixed with
# config blocks AND nf-core pipelines' own template `def check_max(obj, type) {...}`
# function in nextflow.config. env.sh carries this by default; kept explicit here too,
# same defense-in-depth as the other four pipelines' cmd.sh on this host.
export NXF_SYNTAX_PARSER=v1

mkdir -p "$NXFDIR/work" "$NXFDIR/results" "$NXFDIR/reports"
cd "$NXFDIR"   # launch dir MUST be ext4: .nextflow/cache lives here, resume depends on it

# --- First real methylseq run on this host ---
# --aligner bismark: the pipeline's OWN default at 3.0.0 (confirmed via --help), and the
# documented choice for small/RRBS data (pipeline-selection.md §4.5) -- bwameth is the
# WGS-scale choice, not needed at ~4M read pairs/sample. Passed explicitly anyway for
# documentation.
# --rrbs: MspI-digested library. Enables MspI-aware trimming AND auto-disables
# deduplication (confirmed by reading workflows/methylseq/main.nf:106,122 --
# `params.skip_deduplication || params.rrbs`); RRBS fragments start at fixed MspI cut
# sites, so apparent duplicates are real molecules, not PCR artefacts.
# --fasta explicit path, NOT --genome GRCh38: this run's investigation
# (plan.md "Reference store") found methylseq 3.0.0's own conf/igenomes.config defines
# params.genomes.GRCh38.{bismark,bismark_hisat2,bwameth,fasta_index} as AWS S3 URLs that
# this repo's genomes.config never aliased under those exact key names -- harmless for
# --fasta itself (that key does match) but would silently block index reuse via the
# compact form later. --igenomes_ignore kept on the command line regardless, as
# defense-in-depth against any iGenomes config leaking in at all.
# --save_reference: genomes/GRCh38/index/bismark/ does not exist yet -- build it this run.
nextflow -log "$NXFDIR/.nextflow.log" \
  run "$PIPE" \
    -r "$REV" \
    -profile docker \
    -c /mnt/d/bioinfo-agent/config/local.config \
    -c /mnt/d/bioinfo-agent/config/genomes.config \
    --igenomes_ignore \
    --fasta               /refs/genomes/GRCh38/fasta/GRCh38.fa \
    --aligner              bismark \
    --rrbs \
    --input                "$RUNDIR/samplesheet.csv" \
    --save_reference \
    --outdir               "$NXFDIR/results" \
    -work-dir              "$NXFDIR/work" \
    -with-report   "$NXFDIR/reports/report.$TS.html" \
    -with-trace    "$NXFDIR/reports/trace.$TS.txt" \
    -with-timeline "$NXFDIR/reports/timeline.$TS.html" \
    -ansi-log false \
    -resume \
  2>&1 | tee "$NXFDIR/nextflow.stdout.log"
echo "EXIT_CODE=${PIPESTATUS[0]}"
