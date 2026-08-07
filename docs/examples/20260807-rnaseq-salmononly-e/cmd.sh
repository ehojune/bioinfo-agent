#!/usr/bin/env bash
set -euo pipefail
RUNID=20260807-rnaseq-salmononly-e
PIPE=nf-core/rnaseq
REV=3.18.0        # from config/pipelines.tsv
REPO="${BIOINFO_HOME:-/mnt/d/bioinfo-agent}"
RUNDIR=$REPO/runs/$RUNID

# WORK DIR ON /mnt/e. The repo forbids this and preflight refuses it; the reason it gives is
# speed. The previous attempt (20260807-rnaseq-testprofile-e) showed the reason is harder than
# that: STAR died with
#   could not create FIFO file ... SOLUTION: ... Windows partitions FAT, NTFS ...
# drvfs has no FIFOs, so STAR cannot run there at all. This run tests whether the pseudo-aligner
# path, which does not use FIFOs, completes on drvfs — the only route to an end-to-end run while
# the distro's VHDX sits on a full C:.
export NXF_WORKROOT=/mnt/e/nxf
NXFDIR=$NXF_WORKROOT/$RUNID
export NXF_SYNTAX_PARSER=v1

mkdir -p "$NXFDIR/work" "$NXFDIR/results"
cd "$NXFDIR"
nextflow -log "$NXFDIR/.nextflow.log" \
  run "$PIPE" -r "$REV" \
    -profile test,docker \
    -c "$REPO/config/local.config" \
    --skip_alignment \
    --pseudo_aligner salmon \
    --outdir  "$NXFDIR/results" \
    -work-dir "$NXFDIR/work" \
    -ansi-log false -resume \
  2>&1 | tee "$NXFDIR/nextflow.stdout.log"
echo "EXIT_CODE=${PIPESTATUS[0]}"
