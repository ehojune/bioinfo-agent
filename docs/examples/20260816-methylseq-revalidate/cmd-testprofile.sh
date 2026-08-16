#!/usr/bin/env bash
set -euo pipefail

RUNID=20260816-methylseq-revalidate-test
PIPE=nf-core/methylseq
REV=3.0.0
NXFDIR=${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID
TS=$(date +%Y%m%d-%H%M%S)

mkdir -p "$NXFDIR/work" "$NXFDIR/results" "$NXFDIR/reports"
cd "$NXFDIR"

export NXF_SYNTAX_PARSER=v1

nextflow -log "$NXFDIR/.nextflow.log" \
  run "$PIPE" \
    -r "$REV" \
    -profile test,docker \
    -c /mnt/d/bioinfo-agent/config/local.config \
    --outdir "$NXFDIR/results" \
    -work-dir "$NXFDIR/work" \
    -with-report   "$NXFDIR/reports/report.$TS.html" \
    -with-trace    "$NXFDIR/reports/trace.$TS.txt" \
    -ansi-log false \
    -resume \
  2>&1 | tee "$NXFDIR/nextflow.stdout.log"
echo "EXIT_CODE=${PIPESTATUS[0]}"
