# methylseq: exact stub gate

Read only for this pipeline, after [common stub isolation](../../runbook.md#4-preview-then-stub).
This is a partial gate at the documented revision, never permission to waive another error.
Re-check the pin in `config/pipelines.tsv`; a version change requires fresh evidence.

**`nf-core/methylseq`, `-stub-run`, and `BISMARK_SUMMARY` — a true waiver, upstream module
authoring bug, same shape as bacass's `UNICYCLER` (the failing process's own stub script is
malformed, not a downstream-reads-an-empty-placeholder gap).** First observed 2026-08-05
(`20260805-methylseq-sle-rrbs-smoke`, real samplesheet) but not written down at the time;
reconfirmed and documented 2026-08-16 (`20260816-methylseq-revalidate`) against this pin's
`3.0.0`, on **both** the CI `-profile test,docker` config and the real RRBS samplesheet.
`modules/nf-core/bismark/summary/main.nf` declares `input: val(bam)` — always a list, since this
process collects every sample's BAM into one call (`script:` correctly uses `${bam.join(' ')}`)
— but its `stub:` block reads:
```
def prefix = task.ext.prefix ?: "${bam.baseName()}"
```
`.baseName()` is not a method on `nextflow.util.ArrayBag`, so the stub errors unconditionally
regardless of sample count or input shape: `No signature of method:
nextflow.util.ArrayBag.baseName() is applicable for argument types: () values: []`. Every
upstream process (FASTQC through BISMARK_REPORT) succeeds first — `completed=25 failed=0` before
the crash on the real samplesheet's 2-sample stub, `completed=9 failed=0` on the 4-sample CI
fixture. No substitute-input workaround possible, same reasoning as bacass's `UNICYCLER`. The
real (non-stub) script path is unaffected — confirmed by a full `-profile test,docker` run
(`completed=36 failed=0`, `BISMARK_SUMMARY` and `MULTIQC` both succeed) and a real-sample
`-resume` run, both 2026-08-16. **Waived, 10th documented departure** — same as every prior case,
this waives `-stub-run` only, not `-preview`: run `-preview` against the real command and real
samplesheet as usual (it resolves params and the DAG without executing anything, so it is
unaffected by this stub-mode-only bug and stays the pre-launch gate exactly as it does for
bacass's `UNICYCLER` case in its stub card); the full non-stub `-profile test,docker` run is what then
proves the pipeline actually executes, per `new-pipeline.md` §2.4c.
See the [methylseq card](../methylseq.md) for the full writeup.
