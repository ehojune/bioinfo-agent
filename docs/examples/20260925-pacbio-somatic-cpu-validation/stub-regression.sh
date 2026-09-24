#!/usr/bin/env bash
# Stub regression for pacbio-hifi-wgs: baseline (HEAD) vs new, plus somatic stub + negative cases.
set -uo pipefail
NEW=${BIOINFO_HOME:-/mnt/d/bioinfo-agent}/pipelines/pacbio-hifi-wgs
: "${BASE_TAR:?git archive <base-commit> pipelines/pacbio-hifi-wgs -o base.tar, then export BASE_TAR}"
R=/work/scratch/pbwgs-somatic-stub
rm -rf $R; mkdir -p $R/in $R/base && cd $R
tar -xf "$BASE_TAR" -C $R/base
BASE=$R/base/pipelines/pacbio-hifi-wgs
printf 'process { resourceLimits = [cpus: 16, memory: 24.GB] }
' > $R/clamp.config

touch in/ref.fa in/m1.subreads.bam in/m1.subreads.bam.pbi in/m2.hifi_reads.bam in/m3.fastq.gz \
      in/al.bam in/al.bam.bai in/al2.bam in/clr.subreads.bam \
      in/T.bam in/T.bam.bai in/N.bam in/N.bam.bai in/T2.bam in/T2.bai
mkdir -p in/tdir in/ndir; touch in/tdir/same.bam in/tdir/same.bam.bai in/ndir/same.bam in/ndir/same.bam.bai
cat > germ.csv <<EOF
sample,dataset,input_type,file,index
S1,sub,subreads,$R/in/m1.subreads.bam,$R/in/m1.subreads.bam.pbi
S1,sub,hifi_bam,$R/in/m2.hifi_reads.bam,
S2,fq,hifi_fastq,$R/in/m3.fastq.gz,
S3,al,aligned_bam,$R/in/al.bam,$R/in/al.bam.bai
S4,al2,aligned_bam,$R/in/al2.bam,
S5,clr,clr_subreads,$R/in/clr.subreads.bam,
EOF
cat > som.csv <<EOF
pair_id,tumor_sample,tumor_bam,tumor_index,normal_sample,normal_bam,normal_index
pairA,TUM,$R/in/T.bam,$R/in/T.bam.bai,NOR,$R/in/N.bam,$R/in/N.bam.bai
pairB,TUM2,$R/in/T2.bam,$R/in/T2.bai,NOR,$R/in/N.bam,$R/in/N.bam.bai
pairC,TUM3,$R/in/tdir/same.bam,$R/in/tdir/same.bam.bai,NOR3,$R/in/ndir/same.bam,$R/in/ndir/same.bam.bai
EOF

run() { # name pipeline args...
  local n=$1 p=$2; shift 2
  nextflow -q -log $R/$n.nflog run $p -stub-run -profile docker -c $R/clamp.config --fasta $R/in/ref.fa \
    --outdir $R/out_$n -work-dir $R/work_$n "$@" > $R/$n.out 2>&1
  local rc=$?; echo "$n exit=$rc"; return 0
}
tree_of() { (cd $R/out_$1 && find . -type f | grep -v '^./pipeline_info/' | sort); ls $R/out_$1/pipeline_info | sed 's/-[0-9]\{8\}-[0-9]\{6\}\./-TS./' | sort; }

run base   $BASE --input germ.csv
run new    $NEW  --input germ.csv
diff <(tree_of base) <(tree_of new) > tree.diff && echo "REGRESSION germline tree identical ($(tree_of new | wc -l) entries)" || { echo "REGRESSION DIFF:"; cat tree.diff; }

run label  $NEW  --input germ.csv --run_label ds1
tree_of label | grep -E 'multiqc|timeline|trace' | head

run both   $NEW  --input germ.csv --somatic_input som.csv
echo "-- somatic outputs (both):"; (cd out_both && find . -path '*deepsomatic*' -type f | sort)
grep -c 'CHECK_BAM' work_both/../both.nflog >/dev/null; grep -oE "Submitted process > CHECK_BAM \([^)]*\)" both.nflog | sort | uniq -c | sort -rn | head -3
echo "CHECK_BAM tasks: $(grep -c 'Submitted process > CHECK_BAM' both.nflog)  DEEPSOMATIC tasks: $(grep -c 'Submitted process > DEEPSOMATIC' both.nflog)"

run somonly $NEW --somatic_input som.csv
echo "somonly: CHECK_BAM $(grep -c 'Submitted process > CHECK_BAM' somonly.nflog) DEEPSOMATIC $(grep -c 'Submitted process > DEEPSOMATIC' somonly.nflog) PBMM2 $(grep -c 'PBMM2' somonly.nflog) MULTIQC $(grep -c 'Submitted process > MULTIQC' somonly.nflog)"
grep -A3 'Submitted process > DEEPSOMATIC' somonly.nflog | head -0
for d in work_somonly/*/*; do [ -f $d/.command.sh ] && grep -q run_deepsomatic $d/.command.sh 2>/dev/null && { ls $d/tumor $d/normal; }; done 2>/dev/null | head

# negative cases: each must fail at parse time with the quoted message
neg() { local n=$1 pat=$2; shift 2; run $n $NEW "$@"; grep -q -- "$pat" $R/$n.out && echo "  NEG $n OK" || { echo "  NEG $n FAILED"; tail -5 $R/$n.out; }; }
sed 's#T2.bai#T2.idx.bai#' som.csv > bad_idx.csv; touch in/T2.idx.bai
neg badidx "must be named" --somatic_input bad_idx.csv
sed 's#pairB#pairA#' som.csv > dup.csv
neg duppair "repeats pair_id" --somatic_input dup.csv
awk -F, 'BEGIN{OFS=","} NR==2{$4=""} {print}' som.csv > noidx.csv
neg noidx "tumor_index is required" --somatic_input noidx.csv
neg tonly "tumor-only models" --somatic_input som.csv --deepsomatic_model PACBIO_TUMOR_ONLY
neg noinput "and/or --somatic_input"
neg badlabel "must match" --input germ.csv --run_label 'a/b'
awk -F, 'BEGIN{OFS=","} NR==2{$5="TUM"} {print}' som.csv > samename.csv
neg samename "are both" --somatic_input samename.csv
echo STUB_DONE
