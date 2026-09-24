# Fetch inputs for real-slice.sh: GIAB HG008 truth + GIABv3 reference, then chr13:82-86 Mb BAM slices.
set -euo pipefail
D=/work/data/hg008-somatic; mkdir -p $D && cd $D
B=https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab
T=$B/data_somatic/HG008/Liss_lab/analysis/NIST_HG008-T_somatic-smvar_DraftBenchmark_V0.3-20260425
for f in HG008-T_somatic_smvar_benchmark_v0.3_tumorvariants.vcf.gz HG008-T_somatic_smvar_benchmark_v0.3_tumorvariants.vcf.gz.tbi HG008-T_somatic_smvar_benchmark_v0.3_all.bed README.md; do
  [ -s $f ] || curl -fsSL -o $f $T/$f; done
echo TRUTH_DONE
R=GRCh38_GIABv3_no_alt_analysis_set_maskedGRC_decoys_MAP2K3_KMT2C_KCNJ18.fasta
[ -s $R ] || { curl -fsSL -o $R.gz $B/release/references/GRCh38/$R.gz && gunzip $R.gz; }
ls -la
echo FETCH_DONE
D=/work/data/hg008-somatic; cd $D
U=https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data_somatic/HG008/Liss_lab/PacBio_Revio_20240125
REG=chr13:82000000-86000000
printf 'chr13\t82000000\t86000000\n' > test_region.bed
for s in T_PacBio-HiFi-Revio_20240125_116x N-P_PacBio-HiFi-Revio_20240125_35x; do
  out=HG008-${s%%_*}.chr13_82-86Mb.bam
  [ -s $out.bai ] && continue
  /usr/bin/time -v docker run --rm -v $D:/d -w /d quay.io/biocontainers/samtools:1.24--h9dcdb79_1 \
    bash -c "samtools view -b -o $out $U/HG008-${s}_GRCh38-GIABv3.bam $REG && samtools index $out && rm -f *.bai.tmp" 2>&1 | grep -E "Elapsed|Maximum resident" || true
done
rm -f HG008-*GIABv3.bam.bai
ls -la
docker run --rm -v $D:/d -w /d quay.io/biocontainers/samtools:1.24--h9dcdb79_1 bash -c 'for b in HG008-*.chr13_82-86Mb.bam; do echo $b; samtools idxstats $b | awk "\$3>0"; samtools view -H $b | grep -c "^@SQ"; samtools view -H $b | grep "^@RG" | head -2; done'
echo SLICE_DONE
