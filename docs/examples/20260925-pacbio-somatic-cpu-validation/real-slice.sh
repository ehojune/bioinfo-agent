#!/usr/bin/env bash
# Real CPU test: HG008-T 116x vs HG008-N-P 35x (GIAB PacBio_Revio_20240125, GRCh38-GIABv3),
# chr13:82-86 Mb slice, DeepSomatic PACBIO tumor-normal via --somatic_input only.
set -uo pipefail
NEW=${BIOINFO_HOME:-/mnt/d/bioinfo-agent}/pipelines/pacbio-hifi-wgs
D=/work/data/hg008-somatic
R=/work/scratch/pbwgs-somatic-real
mkdir -p $R && cd $R
printf 'process { resourceLimits = [cpus: 16, memory: 24.GB] }\n' > clamp.config
cat > pairs.csv <<EOF
pair_id,tumor_sample,tumor_bam,tumor_index,normal_sample,normal_bam,normal_index
HG008-T_vs_N-P.PacBio_Revio_20240125,HG008-T,$D/HG008-T.chr13_82-86Mb.bam,$D/HG008-T.chr13_82-86Mb.bam.bai,HG008-N-P,$D/HG008-N-P.chr13_82-86Mb.bam,$D/HG008-N-P.chr13_82-86Mb.bam.bai
EOF
start=$(date +%s)
nextflow -log $R/real.nflog run $NEW -profile docker -c clamp.config \
  --somatic_input pairs.csv \
  --fasta $D/GRCh38_GIABv3_no_alt_analysis_set_maskedGRC_decoys_MAP2K3_KMT2C_KCNJ18.fasta \
  --ref_name GRCh38 --deepsomatic_regions $D/test_region.bed \
  --outdir $R/results -work-dir $R/work -ansi-log false -resume
nf_rc=$?
echo "NF_EXIT=$nf_rc wall_s=$(( $(date +%s) - start ))"
# Stop here on a failed run — the checks below would only describe stale or missing outputs, and the
# script must not end with REAL_DONE / exit 0 after a failure (PR #57 Codex review).
[ "$nf_rc" = 0 ] || { echo "REAL_FAILED: nextflow exited $nf_rc"; exit "$nf_rc"; }
tr=$(ls -t $R/results/pipeline_info/trace-*.txt 2>/dev/null | head -1)
[ -s "$tr" ] || { echo "REAL_FAILED: no trace file under $R/results/pipeline_info"; exit 1; }
cut -f4,5,9,10,11,12 "$tr" | column -t || { echo "REAL_FAILED: could not read $tr"; exit 1; }
O=$R/results/HG008-T/PacBio/HG008-T_vs_N-P.PacBio_Revio_20240125/03_VCF
# Each value is captured in its own assignment: under set -e a failing bcftools then stops the script,
# which an `echo "$(...)"` would hide (PR #57 Codex review). A count of zero is a result, not a failure.
docker run --rm -v $O:/o -v $D:/t -w /o quay.io/biocontainers/bcftools:1.24--h118bc1c_2 bash -c '
set -eo pipefail
v=deepsomatic/HG008-T.HG008-T_vs_N-P.PacBio_Revio_20240125.GRCh38.deepsomatic.vcf.gz
[ -s "$v" ] || { echo "missing $v"; exit 1; }
naf=$(bcftools view -h $v | grep ID=NAF,)
echo "NAF header: ${naf:0:40}"
echo "FILTER counts:"; bcftools query -f "%FILTER\n" $v | sort | uniq -c
snv=$(bcftools view -H SNV_deepsomatic/*.snv.vcf.gz | wc -l)
indel=$(bcftools view -H INDEL_deepsomatic/*.indel.vcf.gz | wc -l)
echo "split: snv=$snv indel=$indel"
bcftools view -f PASS -Oz -o /tmp/pass.vcf.gz $v && tabix /tmp/pass.vcf.gz
bcftools view -R /t/test_region.bed -Oz -o /tmp/truth.vcf.gz /t/HG008-T_somatic_smvar_benchmark_v0.3_tumorvariants.vcf.gz && tabix /tmp/truth.vcf.gz
nt=$(bcftools view -H /tmp/truth.vcf.gz | wc -l); np=$(bcftools view -H /tmp/pass.vcf.gz | wc -l)
echo "truth in window: $nt  PASS calls: $np"
bcftools isec -c none -n=2 -w1 /tmp/pass.vcf.gz /tmp/truth.vcf.gz > /tmp/match.vcf
nm=$(grep -vc "^#" /tmp/match.vcf || true)
echo "PASS matching truth (pos+allele): $nm"
echo "matched VAF (tumor):"; bcftools query -f "[%VAF]\n" /tmp/match.vcf | sort -g | awk "{a[NR]=\$1} END{print \"n=\"NR\" min=\"a[1]\" median=\"a[int((NR+1)/2)]\" max=\"a[NR]}"
'
chk_rc=$?
[ "$chk_rc" = 0 ] || { echo "REAL_FAILED: output checks exited $chk_rc"; exit "$chk_rc"; }
echo REAL_DONE
