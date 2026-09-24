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
echo "NF_EXIT=$? wall_s=$(( $(date +%s) - start ))"
cat $R/results/pipeline_info/trace-*.txt | cut -f4,5,9,10,11,12 | column -t
O=$R/results/HG008-T/PacBio/HG008-T_vs_N-P.PacBio_Revio_20240125/03_VCF
docker run --rm -v $O:/o -v $D:/t -w /o quay.io/biocontainers/bcftools:1.24--h118bc1c_2 bash -c '
v=deepsomatic/HG008-T.HG008-T_vs_N-P.PacBio_Revio_20240125.GRCh38.deepsomatic.vcf.gz
echo "NAF header: $(bcftools view -h $v | grep ID=NAF, | cut -c1-40)"
echo "FILTER counts:"; bcftools query -f "%FILTER\n" $v | sort | uniq -c
echo "split: snv=$(bcftools view -H SNV_deepsomatic/*.snv.vcf.gz | wc -l) indel=$(bcftools view -H INDEL_deepsomatic/*.indel.vcf.gz | wc -l)"
bcftools view -f PASS -Oz -o /tmp/pass.vcf.gz $v && tabix /tmp/pass.vcf.gz
bcftools view -R /t/test_region.bed -Oz -o /tmp/truth.vcf.gz /t/HG008-T_somatic_smvar_benchmark_v0.3_tumorvariants.vcf.gz && tabix /tmp/truth.vcf.gz
echo "truth in window: $(bcftools view -H /tmp/truth.vcf.gz | wc -l)  PASS calls: $(bcftools view -H /tmp/pass.vcf.gz | wc -l)"
bcftools isec -c none -n=2 -w1 /tmp/pass.vcf.gz /tmp/truth.vcf.gz 2>/dev/null | grep -vc "^#" | sed "s/^/PASS matching truth (pos+allele): /"
echo "matched VAF (tumor):"; bcftools isec -c none -n=2 -w1 /tmp/pass.vcf.gz /tmp/truth.vcf.gz 2>/dev/null | bcftools query -f "[%VAF]\n" | sort -g | awk "{a[NR]=\$1} END{print \"n=\"NR\" min=\"a[1]\" median=\"a[int((NR+1)/2)]\" max=\"a[NR]}"
'
echo REAL_DONE
