# nanoseq: exact stub gate

Read only for this pipeline, after [common stub isolation](../../runbook.md#4-preview-then-stub).
This is a partial gate at the documented revision, never permission to waive another error.
Re-check the pin in `config/pipelines.tsv`; a version change requires fresh evidence.

**`nf-core/nanoseq`, `-stub-run`, and `SAMTOOLS_IDXSTATS`/`SAMTOOLS_FLAGSTAT` — a true waiver,
upstream shared-module stub-coverage gap, same shape as the ampliseq case in its stub card.** Confirmed
2026-08-13 (`20260813-nanoseq-srr25466853`) against this pin's `3.1.0`. Both the CI `test` profile
and this procurement's own real command fail identically (`completed=24 failed=4` /
`completed=13 failed=2`), always at `BAM_STATS_SAMTOOLS:SAMTOOLS_IDXSTATS`/`SAMTOOLS_FLAGSTAT`
(`"failed to read header for ... .sorted.bam"`). Read the modules directly:
`modules/nf-core/samtools/sort/main.nf` HAS a `stub:` block (writes a header-less, touch'd empty
`.bam`), but `modules/nf-core/samtools/idxstats/main.nf` and `.../flagstat/main.nf` have **no**
`stub:` block at all — under `-stub-run` those two run for real against the fake empty BAM and
correctly refuse to read it, no substitute-input workaround possible (the crash is in reading the
stub's own placeholder output, not in anything this repo's config controls). **Waived, 6th
documented departure** — `-preview` (clean) is the pre-launch gate; the real command is what
actually proves this pipeline, `SAMTOOLS_STATS` (which does have a stub block) succeeds cleanly in
the same run.
