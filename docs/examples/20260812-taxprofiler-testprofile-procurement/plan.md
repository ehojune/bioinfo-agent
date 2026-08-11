# Plan — nf-core/taxprofiler procurement: -stub-run and full -profile test

RUNID: 20260812-taxprofiler-testprofile-procurement

## What this is

`new-pipeline.md` §2.4(b)/(c) and §2.8 step 1: the pipeline's own `-stub-run` and full
`-profile test,docker` gates, as part of procuring nf-core/taxprofiler into this repo's
stocked set. No real data used here — the pipeline's own bundled CI fixture
(`nf-core/test-datasets`, `taxprofiler/samplesheet.csv` + `database_v2.1.csv`), fetched by the
test profile itself, not staged locally.

## Pin

nf-core/taxprofiler -r 2.0.1. Confirmed via `nextflow info nf-core/taxprofiler` and GitHub API
(`archived: false`, `pushed_at: 2026-08-07`, release `2.0.1` published `2026-06-15`, 189 stars)
— not archived, actively maintained, latest release <2 months old at procurement time.

## Command

```bash
nextflow run nf-core/taxprofiler -r 2.0.1 -profile test,docker -stub-run \
  --outdir /work/scratch/stub-taxprofiler-run2 \
  -work-dir /work/scratch/stub-taxprofiler-run2-work

nextflow run nf-core/taxprofiler -r 2.0.1 -profile test,docker \
  --outdir /work/scratch/test-taxprofiler \
  -work-dir /work/scratch/test-taxprofiler-work
```

Both launched directly (not via the run-record `cmd.sh`/tmux shape) since this is a scratch
procurement smoke test, not a scientific run against real data — same precedent as ampliseq's
and mag's own test-profile procurement runs.

## Estimate

No prior measurement for this pipeline on this host. `-profile test` turns on nearly the full
14-profiler roster against toy CI databases (see `conf/test.config`); expected tens of minutes,
low single-digit GB peak disk, well inside every approval threshold.

## Bounded choices

None beyond the pipeline's own `-profile test` defaults — this is a procurement smoke test, not
a scientific run.

## Approval

Auto mode / autonomous procurement task — proceeding per the user's explicit instruction; well
under every escalation threshold.
