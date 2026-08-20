#!/usr/bin/env bash
# E2E-B: HG002 chr20:1-3Mb slice through the full pacbio-hifi-wgs chain (as actually run).
set -euo pipefail

BIOINFO_HOME=${BIOINFO_HOME:-/mnt/d/bioinfo-agent}
RUNDIR=/work/scratch/pbwgs-e2eb

# resourceLimits clamp for this host's 24-core/31GB WSL VM
printf 'process { resourceLimits = [cpus: 16, memory: 24.GB] }\n' > "$RUNDIR/e2e.config"

nextflow -log "$RUNDIR/b.nflog" run "$BIOINFO_HOME"/pipelines/pacbio-hifi-wgs \
  -profile docker \
  -c "$RUNDIR/e2e.config" \
  --input  "$RUNDIR/ss.csv" \
  --fasta  /work/staging/pbwgs-e2e/chr20.fa \
  --ref_name GRCh38_chr20 \
  --clair3_model hifi_sequel2 \
  --outdir "$RUNDIR/results" \
  -work-dir "$RUNDIR/work" \
  -ansi-log false \
  -resume
