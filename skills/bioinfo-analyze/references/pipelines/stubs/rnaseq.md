# rnaseq: exact stub gate

Read only for this pipeline, after [common stub isolation](../../runbook.md#4-preview-then-stub).
This is a partial gate at the documented revision, never permission to waive another error.
Re-check the pin in `config/pipelines.tsv`; a version change requires fresh evidence.

**`strandedness: auto` and `-stub-run`, and why two stubs cover less than one whole run.**
`getSalmonInferredStrandedness()` does `new JsonSlurper().parseText(json_file.text)` on salmon's
`lib_format_counts.json`, and `SALMON_QUANT`'s stub block emits that file empty, so the parse
throws. Confirmed at rnaseq 3.18.0 on 2026-08-07.

**This one failure is a waived exception to "a failed stub is a real failure", and is confined to the conditions below.** With `strandedness: auto` the first stub is *guaranteed* to exit nonzero
regardless of how correct your run is — there is nothing to fix and re-stubbing changes nothing.
Waiving it is only legitimate because it is identifiable rather than merely tolerated: the waiver
applies **only** when the error is exactly `Text must not be null or empty` raised from
`fastq_qc_trim_filter_setstrandedness/main.nf`, **and** the tasks before it all exited 0, **and**
the concrete-strandedness stub below then passes clean. Any other error, any earlier task failure,
or a concrete stub that does not pass, and the ordinary rule applies in full: fix it, re-stub,
do not launch.

The second stub is a **copy** of the samplesheet whose `strandedness` column is a concrete value;
`auto` stays in the real one. Both halves of the command matter: the source is in `$RUNDIR` (you
are `cd`'d into `$NXFDIR`, so a bare `samplesheet.csv` is not there), and `--input` must be
overridden on the command line — `$RUNDIR/params.yaml` carries the real, `auto` samplesheet and
the params file wins otherwise, so without the override this fails at the same parse. It also
gets its own `$STUBDIR`, per runbook section 4:

```bash
STUBDIR=$STUBROOT/concrete-strand          # NOT the same tree as the auto attempt
mkdir -p "$STUBDIR"
sed 's/,auto$/,reverse/' "$RUNDIR/samplesheet.csv" > "$STUBDIR/samplesheet.stub.csv"
# ... then re-run the -stub-run invocation in runbook section 4 with the new $STUBDIR, plus:
#   --input "$STUBDIR/samplesheet.stub.csv"
```

**That is a partial gate, not an equivalent one, and the difference is not cosmetic.** The subworkflow branches on `meta.strandedness == 'auto'` and feeds only the
`auto_strand` branch into `FASTQ_SUBSAMPLE_FQ_SALMON`, so a concrete value leaves that branch
empty and the inference path — the one that failed — is never entered. Measured on the two stub
runs of `20260807-rnaseq-scer-gln3-ibutanol`, comparing `Submitted process` lines:

| stub | covers | does not reach |
|---|---|---|
| `auto` (fails) | `FQ_SUBSAMPLE`, `SALMON_INDEX`, `SALMON_QUANT` — the inference branch **is** entered and wired | everything downstream; it dies at the parse, 56 tasks in |
| concrete value | `STAR_ALIGN` → `TXIMETA_TXIMPORT` → `SE_*` → `DESEQ2_QC` → `MULTIQC`, 110 tasks | `FQ_SUBSAMPLE` and `SALMON_INDEX` never submit at all |

So run **both**, and know what neither gives you: the join of
`FASTQ_SUBSAMPLE_FQ_SALMON.out` back onto `auto_strand` and the strandedness assignment itself
are exercised for the first time by the real run. Treat the first real sample to clear
`FASTQ_SUBSAMPLE_FQ_SALMON` as the gate for that branch, and check the inferred value in
MultiQC's strand-check table rather than assuming a passing stub covered it.

A stub run that fails is a launch that would have failed after burning real hours. Fix, re-stub,
then launch.
