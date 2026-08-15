# Run 20260816-bacass-testprofile-procurement — nf-core/bacass -r 2.6.1 — COMPLETE

**Inputs**       2 samples (3 rows, ID `ERR044595` repeated across two read pairs — the
                 pipeline's own CI re-sequencing-merge fixture), short-read paired-end,
                 samplesheet: `/mnt/d/bioinfo-agent/runs/20260816-bacass-testprofile-procurement/samplesheet.csv`
                 (tab-delimited reference copy of the CI fixture; not actually consumed —
                 `-profile test` supplies its own `--input` via `conf/test.config`)
**Reference**    none (de novo assembly, no reference genome used)
**Command**      `/mnt/d/bioinfo-agent/runs/20260816-bacass-testprofile-procurement/cmd.sh`
**Wall clock**   ~13m8s (08:18:18 - 08:31:26)   **Peak disk**  work dir 1.3 GB, results 123 MB
**Cores/RAM used** clamped to 4 cpu/15 GB by `conf/test.config`'s own `resourceLimits`
**Results**      `/mnt/d/bioinfo-agent/runs/20260816-bacass-testprofile-procurement/results` (121 MB)
                 **MultiQC**  `results/multiqc/multiqc_report.html`
**Work dir**     `/work/nxf/20260816-bacass-testprofile-procurement/work` — RETAINED, do not
                 delete, `-resume` depends on it

## QC verdict
PASS — mandatory `new-pipeline.md` §2.4 gate. All three escalating tests run: (a) `nextflow
config`/`--help` clean, (b) `-stub-run` on `-profile test,docker` fails at `UNICYCLER` (waived,
9th documented departure — upstream module authoring bug, see `runbook.md` §4), (c) the full
non-stub `-profile test,docker` run completed cleanly, `completed=17 failed=0`. This run exists
to validate the pipeline mechanics on this host, not to produce a scientifically meaningful
assembly (CI fixture reads are a 1M-read subsample) — no per-sample QC table below; see the
real-sample run's handoff for measured assembly/annotation QC numbers.

## Bounded choices I made
- Ran `-stub-run` first (failed at `UNICYCLER`, a genuine upstream module bug: its `stub:` block
  hardcodes `cat ""`), then confirmed the full test-profile gate passes clean before treating the
  stub failure as waivable — order matters here, per SKILL.md.
- Did not modify the samplesheet.csv committed to this run dir to be comma-delimited (it is a
  reference copy of the pipeline's own tab-delimited CI fixture, undisturbed); the actual
  comma-delimited format requirement for a real `.csv`-named samplesheet is documented in
  `config/pipelines.tsv` and exercised on the real-sample run instead.

## Known gaps
- `bin/preflight.sh`'s generic samplesheet checks assume comma-delimited CSV and local
  filesystem paths; this run dir's tab-delimited, URL-based reference samplesheet.csv produces
  3 expected FAILs there ("input MISSING") that do not reflect a real problem — cmd.sh never
  passes `--input` for this run, `-profile test` supplies its own. Not fixed in preflight.sh
  (out of this procurement's scope); documented here instead.
- Long-read/hybrid assembly, Bakta/DFAST/Liftoff annotation, Kraken2/KmerFinder contamination
  screening not exercised this procurement — see `config/pipelines.tsv` and
  `pipeline-selection.md` §4.17 for the full out-of-scope list.

## Next step for you
See `runs/20260816-bacass-srr2589044-realsample/handoff.md` for the real-sample assembly/QC
numbers this procurement's stocked configuration produces.

No biological interpretation is included, by design.
