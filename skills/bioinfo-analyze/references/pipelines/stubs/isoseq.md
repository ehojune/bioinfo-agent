# isoseq: exact stub gate

Read only for this pipeline, after [common stub isolation](../../runbook.md#4-preview-then-stub).
This is a partial gate at the documented revision, never permission to waive another error.
Re-check the pin in `config/pipelines.tsv`; a version change requires fresh evidence.

**`nf-core/isoseq`, `-stub-run`, and `ULTRA_INDEX` — a true waiver, upstream shared-module
stub-coverage gap, confined to a branch this repo does not stock.** Confirmed 2026-08-14
(`20260814-isoseq-alz-chr19`) against this pin's `2.0.0`, **only when run with the CI test
profile's own `aligner: ultra`**. `modules/nf-core/gnu/sort/main.nf`'s `stub:` block does
`touch ${output_file}` — an empty placeholder GTF — and `modules/nf-core/ultra/index/main.nf`
has **no** `stub:` block at all (confirmed by reading it directly), so it runs for real against
that empty GTF and crashes: `gffutils.exceptions.EmptyInputError: No lines parsed -- was an
empty file provided?`. `completed=12 failed=1`. No substitute-input workaround possible, same
reasoning as ampliseq/nanoseq/rnasplice. **Waived, 8th documented departure** — `-preview`
(clean) is the pre-launch gate for the `ultra` branch specifically. **This procurement's own
stocked config (`aligner: minimap2`) needs no waiver at all**: `-stub-run` on that exact flag
set passes cleanly on both the CI test data (`completed=11 failed=0`) and the real command
(`completed=81 failed=0`) — same class of clean pass as taxprofiler/raredisease, not a waiver.
**Separately** (not a stub artifact, found on the real run): the pipeline's own default
`--chunk 40` against a small (531-ZMW) input produced 29/40 empty per-chunk
`GSTAMA_COLLAPSE` outputs and crashed `GSTAMA_MERGE` (`tama_merge.py`, `IndexError: list index
out of range` reading an empty bed) — fixed with `--chunk 5` (matching `conf/test.config`'s own
value for the identical bam) and a `-resume` relaunch. **Also separately, a real (non-stub) bug
affecting every configuration**: `workflows/isoseq.nf`'s own `MULTIQC(...)` call passes bare,
non-`.collect()`'d `channel.empty()` for two of the module's plain `path` inputs, so `MULTIQC`
is invoked zero times regardless of flags — no MultiQC report is ever produced at this pin. See
`references/pipelines/isoseq.md` and `config/pipelines.tsv` for the full writeup on all three
findings.
