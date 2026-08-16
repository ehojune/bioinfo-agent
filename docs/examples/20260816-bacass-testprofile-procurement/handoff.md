# Run 20260816-bacass-testprofile-procurement — nf-core/bacass -r 2.6.1 — COMPLETE

**Inputs**       2 samples (3 rows, ID `ERR044595` repeated across two read pairs — the
                 pipeline's own CI re-sequencing-merge fixture), short-read paired-end,
                 samplesheet: `/mnt/d/bioinfo-agent/runs/20260816-bacass-testprofile-procurement/samplesheet.csv`
                 (comma-delimited reference copy of the CI fixture's content, converted from
                 the pipeline's own tab-delimited `.tsv` per Codex review round 6 — not actually
                 consumed at launch, `-profile test` supplies its own `--input` via
                 `conf/test.config`, but now passes both mandatory gates cleanly on its own)
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
- Converted the samplesheet.csv committed to this run dir from the pipeline's own tab-delimited
  CI fixture to comma-delimited (same content, same URLs) after Codex review round 6 pointed
  out that a `.csv`-named file which is not actually comma-parseable fails both mandatory gates
  regardless of whether `cmd.sh` consumes it — SKILL.md makes both gates mandatory "before
  launch" with no carve-out for a reference-only sheet. The comma-delimited format requirement
  itself is documented in `config/pipelines.tsv`.

## Known gaps
- `bin/preflight.sh`'s generic local-path existence check (`[ -e "$p" ]` against every
  `/`-bearing field) previously hard-failed any comma-delimited bacass sheet using bacass's
  legal `http(s)://` URL values — fixed in this PR (Codex review round 4) to recognize and note
  (not fail) remote URLs instead of treating them as missing local files; verified against a
  synthetic comma-delimited URL sheet and against this run dir's own (now comma-delimited)
  samplesheet.csv, which passes both `check-samplesheet.sh` and `preflight.sh` cleanly
  (0 failures each).
- Long-read/hybrid assembly, Bakta/DFAST/Liftoff annotation, Kraken2/KmerFinder contamination
  screening not exercised this procurement — see `config/pipelines.tsv` and
  `pipeline-selection.md` §4.17 for the full out-of-scope list.

## Next step for you
See `runs/20260816-bacass-srr2589044-realsample/handoff.md` for the real-sample assembly/QC
numbers this procurement's stocked configuration produces.

No biological interpretation is included, by design.
