#!/usr/bin/env bash
# Exact commands used to (re)build every input hap-py-accuracy.md depends on, so the
# validation can be reproduced after /work/scratch and /work/staging get reclaimed again
# (they are ext4 scratch, not committed, and this host runs at ~90% disk usage).
#
# Three independent artifacts, each idempotent to re-run:
#   1. chr20-only GRCh38 reference          -> /work/staging/pbwgs-e2e/chr20.fa(.fai)
#   2. HG002 chr20:1-3Mb HiFi FASTQ input    -> /work/staging/pbwgs-e2e/hg002.chr20_1_3M.hifi.fastq.gz
#   3. GIAB HG002 NISTv4.2.1 truth set, region-restricted -> /work/staging/pbwgs-happy/
#
# After running this, reproduce the pipeline run with this folder's own cmd.sh (adjust
# RUNDIR if reusing a different scratch path), then re-run hap.py per hap-py-accuracy.md's
# "Method" section against the fresh caller VCFs.
set -euo pipefail

# ---------------------------------------------------------------------------------------
# 1. chr20-only reference, extracted from this host's standard GRCh38 fasta (chr-prefixed,
#    UCSC-style -- $BIOINFO_REFS/genomes/GRCh38/fasta/genome.fa on this host, which links to
#    /mnt/d/Research/references/hg38.fa per config/refs.manifest.tsv).
mkdir -p /work/staging/pbwgs-e2e
docker run --rm -v /mnt/d/Research/references:/refsrc:ro -v /work/staging/pbwgs-e2e:/out \
  quay.io/biocontainers/samtools:1.21--h50ea8bc_0 \
  bash -c "samtools faidx /refsrc/hg38.fa chr20 > /out/chr20.fa && samtools faidx /out/chr20.fa"

# ---------------------------------------------------------------------------------------
# 2. HG002 chr20:1-3,000,000 HiFi reads, htslib S3/https range-fetch (no full-file download)
#    from the same aligned BAM E2E-B used -- GIAB's official chemistry2/GRCh38 pbmm2 BAM.
#    NOTE (raised in codex review, PR #50): this method selects reads that a PRIOR alignment
#    already placed in chr20:1-3Mb. It tests caller accuracy on an alignment-pre-selected
#    read subset, not the full unaligned-FASTQ-to-calls chain -- reads originating in this
#    interval but mismapped/unmapped by that prior alignment are absent from the input before
#    this pipeline's own pbmm2 step ever sees them. See hap-py-accuracy.md's "Reading these
#    numbers" section for the caveat this implies.
GIAB_BAM_URL="https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/HG002_NA24385_son/PacBio_CCS_15kb_20kb_chemistry2/GRCh38/HG002.SequelII.merged_15kb_20kb.pbmm2.GRCh38.haplotag.10x.bam"
# `-o pipefail` INSIDE this bash -c: without it, a failed/truncated remote fetch or a killed
# `samtools fastq` would still let `gzip` exit 0 on whatever partial bytes it received, so the
# outer script's own pipefail (line 14) would not catch it and a rerun could silently
# benchmark a partial/empty FASTQ.
docker run --rm -v /work/staging/pbwgs-e2e:/out quay.io/biocontainers/samtools:1.21--h50ea8bc_0 \
  bash -c "set -o pipefail; samtools view -b '$GIAB_BAM_URL' chr20:1-3000000 | samtools fastq - | gzip > /out/hg002.chr20_1_3M.hifi.fastq.gz"
# Must be exactly 11,004 reads (44,016 fastq lines / 4) -- matches the original E2E-B
# extraction exactly; fail loudly rather than silently proceeding on a partial fetch.
n_reads=$(( $(zcat /work/staging/pbwgs-e2e/hg002.chr20_1_3M.hifi.fastq.gz | wc -l) / 4 ))
if [ "$n_reads" -ne 11004 ]; then
  echo "ERROR: expected 11,004 reads in the chr20:1-3Mb extraction, got $n_reads" >&2
  exit 1
fi

# ---------------------------------------------------------------------------------------
# 3. GIAB HG002 NISTv4.2.1 truth set (GRCh38, chr-prefixed), restricted to chr20:1-3,000,000.
#    Total download ~169 MB (disclosed and run without further approval per repo's <10GB rule).
mkdir -p /work/staging/pbwgs-happy
cd /work/staging/pbwgs-happy
BASE="https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/AshkenazimTrio/HG002_NA24385_son/NISTv4.2.1/GRCh38"
curl -sS --max-time 300 -o truth.vcf.gz "$BASE/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz"
curl -sS --max-time 120 -o truth.vcf.gz.tbi "$BASE/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz.tbi"
curl -sS --max-time 120 -o truth_confident.bed "$BASE/HG002_GRCh38_1_22_v4.2.1_benchmark_noinconsistent.bed"
# md5 recorded at time of this validation (2026-08-20/21) -- re-check on re-download in case
# GIAB republishes the release:
#   dc750b3807d4af1f7ffec852e9c2f771  truth.vcf.gz
#   121e2975fb3ff0317ae6a684d0ce6f2f  truth.vcf.gz.tbi
#   97265e922a97c69a0391cf3f92a89b8b  truth_confident.bed

awk -F'\t' '$1=="chr20" && $2 < 3000000' truth_confident.bed \
  | awk -F'\t' 'BEGIN{OFS="\t"} {if($3>3000000) $3=3000000; print}' \
  > confident_chr20_1_3M.bed

docker run --rm -v /work/staging/pbwgs-happy:/d quay.io/biocontainers/bcftools:1.21--h8b25389_0 \
  bash -c "bcftools view -r chr20:1-3000000 -Oz -o /d/truth_chr20_1_3M.vcf.gz /d/truth.vcf.gz && bcftools index -t /d/truth_chr20_1_3M.vcf.gz"

# ---------------------------------------------------------------------------------------
# 4. Provision cmd.sh's RUNDIR. cmd.sh (this folder) hardcodes RUNDIR=/work/scratch/pbwgs-e2eb
#    and reads "$RUNDIR/ss.csv" + writes "$RUNDIR/e2e.config" -- neither the directory nor
#    ss.csv exist until this step; the only committed samplesheet is this folder's own
#    samplesheet.csv, one directory up from where cmd.sh expects it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNDIR=/work/scratch/pbwgs-e2eb            # must match cmd.sh's RUNDIR
mkdir -p "$RUNDIR"
cp "$SCRIPT_DIR/samplesheet.csv" "$RUNDIR/ss.csv"

echo "Inputs ready: /work/staging/pbwgs-e2e/{chr20.fa,hg002.chr20_1_3M.hifi.fastq.gz}, /work/staging/pbwgs-happy/{truth_chr20_1_3M.vcf.gz,confident_chr20_1_3M.bed}, $RUNDIR/ss.csv"
echo "Next: bash '$SCRIPT_DIR/cmd.sh', then bash '$SCRIPT_DIR/run-happy.sh' $RUNDIR"
