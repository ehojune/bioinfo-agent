#!/usr/bin/env bash
set -euo pipefail

RUNID=20260816-rnaseq-revalidate
PIPE=nf-core/rnaseq
REV=3.18.0        # from config/pipelines.tsv
RUNDIR=/mnt/d/bioinfo-agent/runs/$RUNID
NXFDIR="${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID"

export NXF_SYNTAX_PARSER=v1

mkdir -p "$NXFDIR/work" "$NXFDIR/results"
cd "$NXFDIR"   # launch dir MUST be ext4: .nextflow/cache lives here, resume depends on it

# Periodic re-verification run (see plan.md). Indexes already exist on disk this time
# (/refs/genomes/R64-1-1/index/{star,salmon}), so --star_index/--salmon_index overrides
# from the 2026-08-04 run are not needed -- if the pre-built paths were stale, -stub-run/
# -preview below would have caught it before this real launch.
nextflow -log "$NXFDIR/.nextflow.log" \
  run "$PIPE" \
    -r "$REV" \
    -profile docker \
    -c /mnt/d/bioinfo-agent/config/local.config \
    -c /mnt/d/bioinfo-agent/config/genomes.config \
    --igenomes_ignore \
    --genome         R64-1-1 \
    --input          "$RUNDIR/samplesheet.csv" \
    --outdir         "$NXFDIR/results" \
    -work-dir        "$NXFDIR/work" \
    -ansi-log false \
    -resume \
  2>&1 | tee "$NXFDIR/nextflow.stdout.log"
echo "EXIT_CODE=${PIPESTATUS[0]}"
