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

# Every check that fails bumps FAIL; the script exits non-zero at the end if any did, so an
# unattended run cannot report a pass it did not earn (PR #57 Codex review).
FAIL=0
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

nf() { # name pipeline args... -> nextflow exit code (output in $R/<name>.out)
  local n=$1 p=$2; shift 2
  nextflow -q -log $R/$n.nflog run $p -stub-run -profile docker -c $R/clamp.config --fasta $R/in/ref.fa \
    --outdir $R/out_$n -work-dir $R/work_$n "$@" > $R/$n.out 2>&1
}
run() { # a run that must succeed
  local n=$1 rc; nf "$@"; rc=$?; echo "$n exit=$rc"
  [ "$rc" = 0 ] || { fail "$n exited $rc"; tail -5 $R/$n.out; }
}
expect() { # label got want
  [ "$2" = "$3" ] && echo "  ok: $1 = $2" || fail "$1 = $2 (expected $3)"
}
tree_of() { (cd $R/out_$1 && find . -type f | grep -v '^./pipeline_info/' | sort); ls $R/out_$1/pipeline_info | sed 's/-[0-9]\{8\}-[0-9]\{6\}\./-TS./' | sort; }

run base   $BASE --input germ.csv
run new    $NEW  --input germ.csv
diff <(tree_of base) <(tree_of new) > tree.diff && echo "REGRESSION germline tree identical ($(tree_of new | wc -l) entries)" || { fail "germline tree differs from base"; cat tree.diff; }

run label  $NEW  --input germ.csv --run_label ds1
tree_of label | grep -E 'multiqc|timeline|trace' | head

run both   $NEW  --input germ.csv --somatic_input som.csv
echo "-- somatic outputs (both):"; (cd out_both && find . -path '*deepsomatic*' -type f | sort)
grep -c 'CHECK_BAM' work_both/../both.nflog >/dev/null; grep -oE "Submitted process > CHECK_BAM \([^)]*\)" both.nflog | sort | uniq -c | sort -rn | head -3
echo "CHECK_BAM tasks: $(grep -c 'Submitted process > CHECK_BAM' both.nflog)  DEEPSOMATIC tasks: $(grep -c 'Submitted process > DEEPSOMATIC' both.nflog)"
# 5 germline BAMs + 5 distinct somatic BAMs (the shared normal once); 3 pairs
expect "both CHECK_BAM" "$(grep -c 'Submitted process > CHECK_BAM' both.nflog)" 10
expect "both DEEPSOMATIC" "$(grep -c 'Submitted process > DEEPSOMATIC' both.nflog)" 3

run somonly $NEW --somatic_input som.csv
echo "somonly: CHECK_BAM $(grep -c 'Submitted process > CHECK_BAM' somonly.nflog) DEEPSOMATIC $(grep -c 'Submitted process > DEEPSOMATIC' somonly.nflog) PBMM2 $(grep -c 'PBMM2' somonly.nflog) MULTIQC $(grep -c 'Submitted process > MULTIQC' somonly.nflog)"
expect "somonly CHECK_BAM" "$(grep -c 'Submitted process > CHECK_BAM' somonly.nflog)" 5
expect "somonly DEEPSOMATIC" "$(grep -c 'Submitted process > DEEPSOMATIC' somonly.nflog)" 3
expect "somonly PBMM2" "$(grep -c 'Submitted process > PBMM2' somonly.nflog)" 0

# --deepsomatic_customized_model: checkpoint prefix (companions staged as a directory) and SavedModel dir.
# The DEEPSOMATIC stub records the exact flag a real run would pass (same dsModelArg() as the script).
mkdir -p in/ckpt; touch in/ckpt/model.ckpt.index in/ckpt/model.ckpt.data-00000-of-00001 in/ckpt/example_info.json
ds_dir() { for d in $R/work_$1/*/*; do [ -f $d/deepsomatic.model_arg.txt ] && { echo $d; return; }; done; }
model_flag() { # run-name want — fails on a missing DEEPSOMATIC task, so "" == "" cannot pass by accident
  local d; d=$(ds_dir $1)
  [ -n "$d" ] || { fail "$1: no DEEPSOMATIC task recorded a model flag"; return; }
  expect "$1 model flag" "$(cat $d/deepsomatic.model_arg.txt)" "$2"
}
run ckpt $NEW --somatic_input som.csv --deepsomatic_customized_model $R/in/ckpt/model.ckpt
model_flag ckpt "--customized_model=ckpt/model.ckpt"
d=$(ds_dir ckpt)
[ -n "$d" ] && [ -e "$d/ckpt/model.ckpt.index" ] && [ -e "$d/ckpt/model.ckpt.data-00000-of-00001" ] \
  && echo "  ok: checkpoint companions staged" || fail "ckpt: companions not staged in ${d:-<no DEEPSOMATIC task>}"
run savedmodel $NEW --somatic_input som.csv --deepsomatic_customized_model $R/in/ckpt
model_flag savedmodel "--customized_model=ckpt"
model_flag somonly ""

# germline-only settings must not block a somatic-only run (PR #57 Codex review round 2), and a
# somatic-only setting must not block a germline-only run (round 3)
run somskip $NEW --somatic_input som.csv --skip_deepvariant true
run germtonly $NEW --input germ.csv --deepsomatic_model PACBIO_TUMOR_ONLY

# The agent's mandatory samplesheet gate (scripts/check-samplesheet.sh --pipeline pacbio-hifi-wgs)
# must accept a valid pair sheet and reject the bad ones (round 3). The gate refuses empty files,
# so this fixture uses non-empty stand-ins; Tlink.bam is a symlink to T.bam (same file, new name).
CS=${BIOINFO_HOME:-/mnt/d/bioinfo-agent}/scripts/check-samplesheet.sh
mkdir -p in/cs; for f in T N T2; do echo x > in/cs/$f.bam; echo x > in/cs/$f.bam.bai; done
ln -sf $R/in/cs/T.bam in/cs/Tlink.bam; echo x > in/cs/Tlink.bam.bai
H=pair_id,tumor_sample,tumor_bam,tumor_index,normal_sample,normal_bam,normal_index
C=$R/in/cs
printf '%s\np1,T,%s/T.bam,%s/T.bam.bai,N,%s/N.bam,%s/N.bam.bai\np2,T2,%s/T2.bam,%s/T2.bam.bai,N,%s/N.bam,%s/N.bam.bai\n' "$H" $C $C $C $C $C $C $C $C > cs_ok.csv
printf '%s\np1,T,%s/T.bam,%s/T.bam.bai,N,%s/N.bam,%s/N.bam.bai\np1,T2,%s/T2.bam,%s/T2.bam.bai,N,%s/N.bam,%s/N.bam.bai\n' "$H" $C $C $C $C $C $C $C $C > cs_dup.csv
printf '%s\np1,T,%s/T.bam,%s/T.bam.bai,T,%s/N.bam,%s/N.bam.bai\n' "$H" $C $C $C $C > cs_samename.csv
printf '%s\np1,T,%s/T.bam,%s/T.bam.bai,N,%s/Tlink.bam,%s/Tlink.bam.bai\n' "$H" $C $C $C $C > cs_symlink.csv
printf '%s\np1,T,%s/T.bam,%s/T.idx.bai,N,%s/N.bam,%s/N.bam.bai\n' "$H" $C $C $C $C > cs_badidx.csv
bash $CS --pipeline pacbio-hifi-wgs cs_ok.csv > cs_ok.out 2>&1 && echo "  ok: samplesheet gate accepts a valid pair sheet" \
  || { fail "samplesheet gate rejected a valid pair sheet"; tail -8 cs_ok.out; }
for b in dup samename symlink badidx; do
  bash $CS --pipeline pacbio-hifi-wgs cs_$b.csv > cs_$b.out 2>&1 && { fail "samplesheet gate accepted cs_$b.csv"; tail -5 cs_$b.out; } \
    || echo "  ok: samplesheet gate rejects cs_$b.csv"
done
grep -A3 'Submitted process > DEEPSOMATIC' somonly.nflog | head -0
for d in work_somonly/*/*; do [ -f $d/.command.sh ] && grep -q run_deepsomatic $d/.command.sh 2>/dev/null && { ls $d/tumor $d/normal; }; done 2>/dev/null | head

# negative cases: each must fail at parse time with the quoted message
# must exit non-zero AND print the expected message (a pass on either alone is not a rejection)
neg() {
  local n=$1 pat=$2 rc; shift 2; nf $n $NEW "$@"; rc=$?
  if [ "$rc" != 0 ] && grep -q -- "$pat" $R/$n.out; then echo "  NEG $n OK"
  else fail "NEG $n (exit=$rc, message '$pat' $(grep -q -- "$pat" $R/$n.out && echo present || echo absent))"; tail -5 $R/$n.out; fi
}
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
neg badmodel "neither a directory nor a checkpoint prefix" --somatic_input som.csv --deepsomatic_customized_model $R/in/nope.ckpt
neg phaseconflict "conflicts with --skip_deepvariant" --input germ.csv --skip_deepvariant true
ln -sf $R/in/T.bam in/Tlink.bam; touch in/Tlink.bam.bai
awk -F, -v r=$R 'BEGIN{OFS=","} NR==2{$6=r"/in/Tlink.bam"; $7=r"/in/Tlink.bam.bai"} {print}' som.csv > symlink.csv
neg symlink "are the same file" --somatic_input symlink.csv
if [ "$FAIL" = 0 ]; then echo STUB_DONE; else echo "STUB_FAILED ($FAIL check(s))"; exit 1; fi
