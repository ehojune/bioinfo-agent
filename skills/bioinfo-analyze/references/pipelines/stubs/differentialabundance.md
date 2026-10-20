# differentialabundance: exact stub gate

Read only for this pipeline, after [common stub isolation](../../runbook.md#4-preview-then-stub).
This is a partial gate at the documented revision, never permission to waive another error.
Re-check the pin in `config/pipelines.tsv`; a version change requires fresh evidence.

**`nf-core/differentialabundance` 1.5.0, `-stub-run`, and `--gtf`.** First run of this pipeline on
this host, 2026-08-10 (`20260810-differentialabundance-gln3-ibutanol`). With the documented,
default input shape (`--gtf`, not `--features`), the DAG is
`GUNZIP_GTF → GTF_TO_TABLE → VALIDATOR → ...`. `GTF_TO_TABLE`'s stub block is a bare
`touch genes.anno.tsv` — it does not write a header or any rows — and `VALIDATOR` (module
`r-shinyngs`, script `validate_fom_components.R`) is not itself stubbed, so under `-stub-run` it
runs for real against that empty file and dies in `read.table()` with
`Error ... no lines available in input`. This is the same shape as the rnaseq
`strandedness: auto` case in its stub card (a real script fed a deliberately-empty stub upstream output) but
it is **not** a waived exception, because there is a clean workaround rather than a guaranteed
failure: the workflow reads features from `--features` *instead of* `--gtf` when both would
otherwise be derived from it (`workflows/differentialabundance.nf`, the `if (params.features) …
else if (params.gtf) … GTF_TO_TABLE(...)` branch), and `--features` skips `GTF_TO_TABLE` entirely.

```bash
# Stub-only substitute — the REAL run keeps --gtf, exactly as planned. Derive a small, genuinely
# non-empty feature table from the matrix itself (gene_id + gene_name columns are enough for the
# stub to validate against); do not hand-write one, and do not point --gtf at anything but the
# real reference.
STUBDIR=$STUBROOT/features-substitute      # NOT $STUBROOT/main -- that is the failed --gtf attempt;
mkdir -p "$STUBDIR"                        # reusing it would union this pass's outputs with the
                                            # failed one's, same rule as the rnaseq case in its stub card
MATRIX=$(grep -m1 '^matrix:' "$RUNDIR/params.yaml" | sed -E 's/^matrix:[[:space:]]*//; s/[[:space:]]+#.*$//' \
  | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")
# grep anchored to `^matrix:` picks the KEY, not any line merely containing the substring "matrix"
# elsewhere (e.g. transcript_length_matrix:). The first sed removes only the `matrix:` prefix and
# any trailing ` #comment` -- splitting on EVERY colon (an earlier version of this line did, via
# `awk -F':'`) truncates a path that legitimately contains one, such as `s3://bucket/counts.tsv`,
# to `s3`. The second sed strips one layer of YAML quoting (matrix: "/path" or matrix: '/path');
# left in place, `cut -f1,2 "$MATRIX"` fails to open a filename literally prefixed with a quote.
# Does not handle escaped quotes inside the path itself -- this repo's own params.yaml files never
# quote paths (see any existing runs/*/params.yaml), so an unquoted path remains the common case.
# `cut` below needs a coreutils-openable path (local ext4/drvfs), not a remote URI -- true of
# every --matrix this repo has ever passed (always an rnaseq run's own results/ output on
# $BIOINFO_WORK). The s3:// example above is there ONLY to prove the colon-splitting bug is
# fixed, not because this repo stages matrices from object storage; if that ever changes, stage
# the remote file locally first and point $MATRIX at the local copy.
cut -f1,2 "$MATRIX" > "$STUBDIR/stub_features.tsv"
sed "s#^gtf:.*#features: $STUBDIR/stub_features.tsv#" "$RUNDIR/params.yaml" > "$STUBDIR/stub_params.yaml"
# ... then run the -stub-run invocation with -params-file "$STUBDIR/stub_params.yaml" instead of
# $RUNDIR/params.yaml, and the usual --outdir/-work-dir pointed at $STUBDIR.
```

**Partial gate, same as the strandedness case**: this substitution means the stub never exercises
`GUNZIP_GTF`/`GTF_TO_TABLE` against the real `--gtf`, and `VALIDATOR` sees synthetic feature
metadata rather than what the real GTF conversion produces. Verified clean end to end with the
substitution (`completed=12 failed=0`, all downstream processes including `DESEQ2_DIFFERENTIAL`,
`SHINYNGS_APP`, `RMARKDOWNNOTEBOOK`, `MAKE_REPORT_BUNDLE` reached). The real run, using the real
`--gtf`, is what actually proves `GUNZIP_GTF`/`GTF_TO_TABLE` against real reference data — treat
`VALIDATOR`'s first real-run pass as the gate for that branch, same discipline as the rnaseq case.
