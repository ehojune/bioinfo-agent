#!/usr/bin/env bash
set -euo pipefail

# Re-verification re-launch of the ORIGINAL 20260805-methylseq-sle-rrbs-smoke run: same
# revision, same samples, same reference, same work dir -- -resume against the intact
# cache to confirm the pin still executes cleanly under the CURRENT repo state (8
# intervening procurements later), not to reprocess from scratch.
RUNID=20260805-methylseq-sle-rrbs-smoke
PIPE=nf-core/methylseq
REV=3.0.0
ORIGRUNDIR=/mnt/d/bioinfo-agent/runs/20260805-methylseq-sle-rrbs-smoke
NXFDIR=${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID
TS=$(date +%Y%m%d-%H%M%S)

mkdir -p "$NXFDIR/work" "$NXFDIR/results" "$NXFDIR/reports"
cd "$NXFDIR"

export NXF_SYNTAX_PARSER=v1

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
    --input                "$ORIGRUNDIR/samplesheet.csv" \
    --save_reference \
    --outdir               "$NXFDIR/results" \
    -work-dir              "$NXFDIR/work" \
    -with-report   "$NXFDIR/reports/report.revalidate.$TS.html" \
    -with-trace    "$NXFDIR/reports/trace.revalidate.$TS.txt" \
    -ansi-log false \
    -resume \
  2>&1 | tee "$NXFDIR/nextflow.stdout.revalidate.log"
echo "EXIT_CODE=${PIPESTATUS[0]}"
