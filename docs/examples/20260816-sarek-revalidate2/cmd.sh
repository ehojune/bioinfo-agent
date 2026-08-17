#!/usr/bin/env bash
set -euo pipefail

RUNID=20260816-sarek-revalidate2
PIPE=nf-core/sarek
REV=3.5.1   # per config/pipelines.tsv -- pin unchanged since the 2026-08-10 revalidation
RUNDIR=/mnt/d/bioinfo-agent/runs/$RUNID
NXFDIR=/work/nxf/$RUNID

export NXF_SYNTAX_PARSER=v1   # belt-and-suspenders; bootstrap/03-nextflow.sh also exports it

mkdir -p "$NXFDIR/work" "$NXFDIR/results"
cd "$NXFDIR"   # launch dir MUST be ext4: .nextflow/cache lives here, resume depends on it

nextflow -log "$NXFDIR/.nextflow.log" \
  run "$PIPE" \
    -r "$REV" \
    -profile docker \
    -c /mnt/d/bioinfo-agent/config/local.config \
    -c /mnt/d/bioinfo-agent/config/genomes.config \
    -c "$RUNDIR/genome-override.config" \
    --igenomes_ignore \
    --step variant_calling \
    --tools haplotypecaller \
    --skip_tools baserecalibrator,haplotypecaller_filter \
    --fasta     /refs/genomes/GRCh38gatk/fasta/genome.fa \
    --fasta_fai /refs/genomes/GRCh38gatk/fasta/genome.fa.fai \
    --dict      /refs/genomes/GRCh38gatk/fasta/genome.dict \
    --input     "$RUNDIR/samplesheet.csv" \
    --outdir    "$NXFDIR/results" \
    -work-dir   "$NXFDIR/work" \
    -ansi-log false \
    -resume \
  2>&1 | tee "$NXFDIR/nextflow.stdout.log"
