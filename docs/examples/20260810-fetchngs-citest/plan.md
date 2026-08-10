# Run plan — 20260810-fetchngs-citest

## Why this run

First execution of `nf-core/fetchngs` on this host. No prior run record exists in
`$BIOINFO_RUNLOG` for fetchngs, so this establishes the working convention (accession-list
format, params, reference-store-free) for the next person/agent to reuse.

## Pipeline + revision

`nf-core/fetchngs -r 1.12.0` — pinned in `config/pipelines.tsv`, note: "input semantics changed
in 1.11/1.12".

Schema re-derived this run (not trusted from doc memory):
- `nextflow pull nf-core/fetchngs -r 1.12.0` — clean, resolved `8ec2d934f9` (no stale-cache issue
  encountered; `NXF_ASSETS` had no prior fetchngs clone).
- `nextflow run nf-core/fetchngs -r 1.12.0 --help` — confirmed `--nf_core_pipeline` accepts
  `rnaseq | atacseq | viralrecon | taxprofiler` at this pin (matches
  `references/pipeline-selection.md` §4.3 exactly).
- `assets/schema_input.json` — single unnamed string column, pattern
  `^(((SR|ER|DR)[APRSX])|(SAM(N|EA|D))|(PRJ(NA|EB|DB))|(GS[EM]))(\d+)$`.
- `subworkflows/local/utils_nfcore_fetchngs_pipeline/main.nf` — `--input` is read with
  `.splitCsv(header:false, sep:'', strip:true)`, and every line is checked against the id
  pattern via `isSraId()`. **This resolves the UNVERIFIED note in `references/samplesheets.md`:
  a header row is not tolerated — a literal `id` line does not match the accession pattern, so
  `isSraId()` raises "Mixture of ids provided via --input" and the run aborts before download.**
  Confirmed, not assumed; will fix the doc after this run.

## Sample count / input

10 accessions — nf-core's own official CI smoke-test list for this pin (fetched live from
`conf/test.config`'s referenced URL,
`test-datasets@2732b911c/testdata/v1.12.0/sra_ids_test.csv`), copied verbatim into
`runs/20260810-fetchngs-citest/samplesheet.csv`. Deliberately reused rather than invented, so the
first local run exercises the same accession-family mix nf-core's CI already exercises (SRA run,
ENA run, DDBJ run x2, more SRA runs, one GEO sample, one GEO series) — this is the most informative
small smoke test available, not an arbitrary pick.

Bounded choice: `GSE214215` is a study-level accession and expands to every run underneath at
resolve time; kept because it is nf-core's own curated CI fixture (built to be small enough for
GitHub Actions runners) rather than a study I picked myself. If it expands further than expected,
the ENA resolution step will show it before any FASTQ downloads — I will report actual size before
the download step proceeds if it looks large.

## Reference build

None. fetchngs touches no genome — confirmed against pipeline-selection.md §4.3 ("Reference-store
paths: none") and against the pipeline source: no `--genome`/`--fasta` param in `--help` output.

## Chaining

`--nf_core_pipeline rnaseq` + `--nf_core_rnaseq_strandedness auto` — makes fetchngs also emit an
rnaseq-ready downstream samplesheet, so this run additionally exercises the samplesheet-generation
path (the part of fetchngs most reference docs flag as GEO-metadata-fragile). Not launching rnaseq
itself — out of scope for "run fetchngs for the first time."

## Estimate

Download-bound, per `references/estimates.md` §1.1. This is nf-core's own CI fixture, sized for
GitHub Actions runners (limited disk, minutes-scale jobs) — expect low tens of MB to low hundreds
of MB total, well under 1 GB. Budgeted conservatively at 5 GB peak disk (`≈1.05x downloaded bytes`
per the estimates table) to leave headroom for `GSE214215`'s expansion being larger than assumed.
Wall clock: bandwidth + ENA/SRA metadata lookups, expect well under 1 h.

Peak disk estimate for preflight: **5 GB** → preflight requires ≥ 7.5 GB free on ext4. Actual free:
416 GB. No concern.

## Bounded choices

- `--download_method ftp` (default) — fastest, no toolkit needed; falls back would be `sratools`.
- `--nf_core_pipeline rnaseq` + `strandedness auto` — adds the downstream-samplesheet exercise;
  changes no data, only which extra files get written under `<outdir>/samplesheet/`.
- Reused nf-core's own CI accession list rather than picking my own accessions — named above.

## What is missing / must be verified during the run

- GEO (GSE/GSM) handling: `references/pipeline-selection.md` flagged this as UNVERIFIED across
  releases. This run's list contains one GSM and one GSE, so it settles it empirically.
- `scripts/check-samplesheet.sh`'s file-hygiene section treats line 1 as a header even when
  `--pipeline fetchngs` is passed (it only special-cases the *required-column* check, not the
  BOM/CRLF/"header names unique"/row-count block above it) — row count reported will likely be off
  by one relative to actual accession count. Will confirm at preflight step and file a doc/script
  fix if reproduced.

## Launch

Through `tmux`, runbook.md §5, mandatory regardless of expected short duration.
