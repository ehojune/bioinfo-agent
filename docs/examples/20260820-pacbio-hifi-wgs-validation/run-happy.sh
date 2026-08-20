#!/usr/bin/env bash
# hap.py invocations used for hap-py-accuracy.md. Run after prepare-happy-inputs.sh and a
# pipeline run (this folder's cmd.sh, pointed at a RUNDIR of your choice) have produced:
#   - /work/staging/pbwgs-happy/{truth_chr20_1_3M.vcf.gz, confident_chr20_1_3M.bed}
#   - /work/staging/pbwgs-e2e/chr20.fa
#   - <RUNDIR>/results/HG002/PacBio/chem2_chr20slice/03_VCF/{deepvariant,clair3}/*.vcf.gz
set -euo pipefail

RUNDIR=${1:?"usage: run-happy.sh <pipeline RUNDIR, e.g. /work/scratch/pbwgs-happy-rerun>"}
QDIR="$RUNDIR/results/HG002/PacBio/chem2_chr20slice/03_VCF"
OUTDIR="$RUNDIR/happy"
mkdir -p "$OUTDIR/deepvariant" "$OUTDIR/clair3"

docker run --rm \
  -v /work/staging/pbwgs-happy:/truth:ro \
  -v /work/staging/pbwgs-e2e:/ref:ro \
  -v "$QDIR":/query:ro \
  -v "$OUTDIR":/out \
  jmcdani20/hap.py:v0.3.12 /opt/hap.py/bin/hap.py \
  /truth/truth_chr20_1_3M.vcf.gz \
  /query/deepvariant/HG002.chem2_chr20slice.GRCh38_chr20.deepvariant.vcf.gz \
  -f /truth/confident_chr20_1_3M.bed \
  -r /ref/chr20.fa \
  -o /out/deepvariant/happy \
  --engine=vcfeval

docker run --rm \
  -v /work/staging/pbwgs-happy:/truth:ro \
  -v /work/staging/pbwgs-e2e:/ref:ro \
  -v "$QDIR":/query:ro \
  -v "$OUTDIR":/out \
  jmcdani20/hap.py:v0.3.12 /opt/hap.py/bin/hap.py \
  /truth/truth_chr20_1_3M.vcf.gz \
  /query/clair3/HG002.chem2_chr20slice.GRCh38_chr20.clair3.vcf.gz \
  -f /truth/confident_chr20_1_3M.bed \
  -r /ref/chr20.fa \
  -o /out/clair3/happy \
  --engine=vcfeval

echo "Summaries: $OUTDIR/{deepvariant,clair3}/happy.summary.csv"
