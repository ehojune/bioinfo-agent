#!/usr/bin/env bash
set -euo pipefail

RUNID=20260806-chipseq-vsmc-h3k27me3-smoke
PIPE=nf-core/chipseq
REV=2.1.0        # from config/pipelines.tsv
RUNDIR=/mnt/d/bioinfo-agent/runs/$RUNID
# Same derivation bin/preflight.sh uses to pick the work dir it checks (disk space, ext4-ness).
NXFDIR="${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID"

# NXF_SYNTAX_PARSER=v1 -- required on this host's installed Nextflow: the default v2
# config parser rejects both local.config's `def X = ...` mixed with config blocks AND
# nf-core pipelines' own template `check_max()` function in nextflow.config. Same
# defense-in-depth as every other pipeline's cmd.sh on this host.
export NXF_SYNTAX_PARSER=v1

mkdir -p "$NXFDIR/work" "$NXFDIR/results"
cd "$NXFDIR"   # launch dir MUST be ext4: .nextflow/cache lives here, resume depends on it

# --- First real chipseq run on this host ---
# Explicit --fasta/--gtf/--bowtie2_index/--blacklist/--gene_bed, NOT --genome GRCh38:
# the compact form was tested this run (-stub-run) and found to auto-populate
# bwa_index/star_index from genomes.config's GRCh38 block, which nf-schema's
# exists:true validation then fails on because neither index is built for this
# FASTA -- regardless of which --aligner is actually selected. blacklist is not
# populated by the compact form either way. See plan.md.
# --aligner bowtie2: NOT the pipeline default (bwa) -- reuses the bowtie2 index the
# prior atacseq run (20260805-atacseq-gbr-lcl-smoke) built and promoted to the store.
# --macs_gsize plain decimal (2700000000), NOT 2.7e9 -- nf-schema rejects scientific
# notation for this Number param (confirmed pitfall, applies here same as atacseq).
# No --narrow_peak: H3K27me3 is a broad mark, pipeline default (broad, cutoff 0.1) is
# correct as-is.
# --min_reps_consensus 1 (pipeline default): 2 real biological replicates exist but
# read depth is shallow; kept lenient rather than risk an empty consensus purely from
# depth. See plan.md.
nextflow -log "$NXFDIR/.nextflow.log" \
  run "$PIPE" \
    -r "$REV" \
    -profile docker \
    -c /mnt/d/bioinfo-agent/config/local.config \
    -c /mnt/d/bioinfo-agent/config/genomes.config \
    --igenomes_ignore \
    --fasta               /refs/genomes/GRCh38/fasta/GRCh38.fa \
    --gtf                 /refs/genomes/GRCh38/gtf/GRCh38.gtf.gz \
    --bowtie2_index        /refs/genomes/GRCh38/index/bowtie2 \
    --blacklist            /refs/genomes/GRCh38/bed/blacklist.bed \
    --gene_bed             /refs/genomes/GRCh38/bed/genes.bed \
    --aligner              bowtie2 \
    --macs_gsize           2700000000 \
    --min_reps_consensus   1 \
    --input                "$RUNDIR/samplesheet.csv" \
    --outdir               "$NXFDIR/results" \
    -work-dir              "$NXFDIR/work" \
    -ansi-log false \
    -resume \
  2>&1 | tee "$NXFDIR/nextflow.stdout.log"
echo "EXIT_CODE=${PIPESTATUS[0]}"
