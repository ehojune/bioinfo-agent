# Run 20260812-taxprofiler-testprofile-procurement — nf-core/taxprofiler -r 2.0.1 — COMPLETE

**Purpose**    `new-pipeline.md` §2.4(b)/(c)/§2.8 step 1: `-stub-run` then full `-profile test`
execution as part of procuring nf-core/taxprofiler into this repo's stocked set.
**Inputs**     Pipeline's own bundled CI fixture (`nf-core/test-datasets`,
`taxprofiler/samplesheet.csv` + `taxprofiler/database_v2.1.csv`), not staged locally.
**Reference**  No `$BIOINFO_REFS` involvement. Toy databases for all 14 profilers (Kraken2,
Bracken, KrakenUniq, Centrifuge, DIAMOND, Kaiju, MALT, MetaPhlAn, ganon, sylph, KMCP, Melon,
metacache) fetched by the test profile itself from `nf-core/test-datasets`, not pre-staged.
**Command**    scratch invocations, not a run-record `cmd.sh` (see `plan.md`)
**Wall clock**   stub-run: not separately timed (short); full test profile: **24m 34s**
(04:12:26 launch to `Pipeline completed successfully` 04:37:00, `.nextflow.log`)
**Peak disk**  stub-run work dir 688 MB; full test-profile work dir **4.0 GB**, published
results **551 MB**
**Cores/RAM used**  pool ceiling (18 cores / 40 GB) available
**Results**      `/work/scratch/test-taxprofiler/` (scratch, not copied into the run record —
CI-fixture output, superseded by the real-sample run's results)
**MultiQC**  `/work/scratch/test-taxprofiler/multiqc/multiqc_report.html`
**Work dir**     `/work/scratch/test-taxprofiler-work/` and `/work/scratch/stub-taxprofiler-run2-work/`
— scratch, not under the run-record retention discipline (no real data, no `-resume` value
worth preserving past this procurement)

## QC verdict

PASS — both gates passed clean, no waiver needed.

- **`-stub-run -profile test,docker`**: `completed=176 failed=0 cached=0`. All modules with a
  `stub:` block exercised across all 14 profilers, the full preprocessing/host-removal/
  run-merging/standardisation/Krona DAG. No crash, no waiver.
- **Full `-profile test,docker`**: `completed=179 failed=0 cached=0`. Every one of the 14
  profilers ran for real against its own toy database and produced real (if CI-fixture-scale)
  output. One benign WARN during the run: `Sample ERR3201952 has an empty report file. Will
  not be processed by SYLPHTAX_TAXPROF` — expected behaviour on a toy long-read fixture with a
  correspondingly-toy sylph taxonomy file, not a defect.

This is the first of the three microbiome pipelines stocked in this repo (ampliseq, mag,
taxprofiler) where `-stub-run` did not need a waiver — ampliseq's `CUTADAPT_BASIC` gap and
mag's `UNTAR`/`CATPACK_DB_UNTAR` gap both required one; taxprofiler's shipped `stub:` coverage
is complete enough to trust as a genuine pre-launch gate on its own, not just a partial one
superseded by `-preview`.

## Bounded choices

- Used the pipeline's own `-profile test` parameters verbatim — a procurement validation run,
  not a scientific analysis. No parameters overridden.

## Stub-run finding (procurement-relevant)

No waiver needed. `-stub-run` on `-profile test,docker` completed `176/176` tasks with
`failed=0`. Contrast with `config/pipelines.tsv`'s ampliseq (4th documented departure,
`CUTADAPT_BASIC` upstream stub bug) and mag (5th documented departure, `UNTAR`/
`CATPACK_DB_UNTAR` output_dir-in-script-not-stub bug) rows — taxprofiler needed neither.
`skills/bioinfo-analyze/references/runbook.md` §4's departure count stays at five; no sixth
entry added by this procurement.

## Real-sample run

See `runs/20260812-taxprofiler-drr027580-realsample/handoff.md` — the required next step of
`new-pipeline.md` §2.8, completed the same day, DRR027580 (the same sample already staged for
mag's own real-sample validation), single tool (Kraken2) against a real 8 GB-capped standard
Kraken2 database.

No biological interpretation is included, by design.
