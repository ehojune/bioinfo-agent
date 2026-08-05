#!/usr/bin/env bash
set -euo pipefail

RUNID=20260805-scrnaseq-skin-cd3
PIPE=nf-core/scrnaseq
REV=2.7.1        # from config/pipelines.tsv
RUNDIR=/mnt/d/bioinfo-agent/runs/$RUNID
# Same derivation bin/preflight.sh uses to pick the work dir it checks (disk space, ext4-ness).
# A literal /work/nxf/$RUNID here would silently diverge from that check on any host that sets
# BIOINFO_WORK or NXF_WORKROOT -- preflight would gate one tree while Nextflow writes another.
NXFDIR="${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID"

# NXF_SYNTAX_PARSER=v1 — required on this host's installed Nextflow (26.04.6), same
# reason as the rnaseq runs: the default v2 config parser rejects local.config's
# `def X = ...` statements mixed with config blocks.
export NXF_SYNTAX_PARSER=v1

mkdir -p "$NXFDIR/work" "$NXFDIR/results"
cd "$NXFDIR"   # launch dir MUST be ext4: .nextflow/cache lives here, resume depends on it

# --- First real scrnaseq run on this host ---
# --aligner star (STARsolo): NOT the pipeline default (alevin) -- deliberate bounded
# choice, see plan.md. STAR index for GRCh38 does not exist yet; --save_reference
# writes it into this run's results dir for reuse.
# --protocol 10XV3: measured directly from R1 length (28bp = 16bp CB + 12bp UMI) in
# SOURCE.md, not left to --protocol auto.
# Explicit --fasta/--gtf (build-named alias paths), NOT the compact --genome GRCh38
# form: DISCOVERED DURING THIS RUN'S -stub-run that the compact form does not resolve
# fasta/gtf for scrnaseq 2.7.1 (getGenomeAttribute() returns null even though
# genomes.config's params.genomes.GRCh38.{fasta,gtf} are set and the identical
# mechanism works for nf-core/rnaseq 3.18.0 on this host). See plan.md "Discovered
# this run" for the full diagnosis. --igenomes_ignore stays on the command line, not
# in a -c file, per genomes.config's documented reason.
nextflow -log "$NXFDIR/.nextflow.log" \
  run "$PIPE" \
    -r "$REV" \
    -profile docker \
    -c /mnt/d/bioinfo-agent/config/local.config \
    -c /mnt/d/bioinfo-agent/config/genomes.config \
    --igenomes_ignore \
    --fasta          /refs/genomes/GRCh38/fasta/GRCh38.fa \
    --gtf            /refs/genomes/GRCh38/gtf/GRCh38.gtf.gz \
    --aligner        star \
    --protocol       10XV3 \
    --input          "$RUNDIR/samplesheet.csv" \
    --save_reference \
    --outdir         "$NXFDIR/results" \
    -work-dir        "$NXFDIR/work" \
    -ansi-log false \
    -resume \
  2>&1 | tee "$NXFDIR/nextflow.stdout.log"
echo "EXIT_CODE=${PIPESTATUS[0]}"
