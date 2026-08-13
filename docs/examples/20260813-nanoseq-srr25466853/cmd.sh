#!/usr/bin/env bash
set -euo pipefail

RUNID=20260813-nanoseq-srr25466853
PIPE=nf-core/nanoseq
REV=3.1.0                                   # from config/pipelines.tsv
RUNDIR=/mnt/d/bioinfo-agent/runs/$RUNID
NXFDIR=${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID
TS=$(date +%Y%m%d-%H%M%S)

mkdir -p "$NXFDIR/work" "$NXFDIR/results" "$NXFDIR/reports"
cd "$NXFDIR"

nextflow -log "$NXFDIR/.nextflow.log" \
  run "$PIPE" \
    -r "$REV" \
    -profile docker \
    -params-file "$RUNDIR/params.yaml" \
    -c /mnt/d/bioinfo-agent/config/local.config \
    --outdir "$NXFDIR/results" \
    -work-dir "$NXFDIR/work" \
    -with-report   "$NXFDIR/reports/report.$TS.html" \
    -with-trace    "$NXFDIR/reports/trace.$TS.txt" \
    -with-timeline "$NXFDIR/reports/timeline.$TS.html" \
    -with-dag      "$NXFDIR/reports/dag.$TS.html" \
    -ansi-log false \
    -resume \
  2>&1 | tee "$NXFDIR/nextflow.stdout.log"
