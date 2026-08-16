# Run 20260816-methylseq-revalidate — nf-core/methylseq -r 3.0.0 — COMPLETE

Re-verification of the `methylseq` pin (`config/pipelines.tsv`: 3.0.0) after 8 intervening
pipeline procurements touched shared infrastructure. Not new stocking; no design decisions
re-litigated.

**Inputs**       (a) pipeline's own `-profile test` fixture, 4 synthetic samples; (b) real
RRBS re-check reusing `runs/20260805-methylseq-sle-rrbs-smoke/samplesheet.csv` (2 samples,
PRJNA484966, HC660_SM/SLE497_SM), FASTQs still on disk at
`/work/rawdata/20260805-methylseq-sle-rrbs-prep/` (untouched, no re-download)
**Reference**    GRCh38 via `$BIOINFO_REFS`, explicit `--fasta`. Bismark index still **not**
promoted to `$BIOINFO_REFS` (unchanged known gap from the precedent run — reused directly from
the precedent's own intact work dir instead)
**Command**      `runs/20260816-methylseq-revalidate/cmd-testprofile.sh`,
`runs/20260816-methylseq-revalidate/cmd-realsample.sh`
**Wall clock**   test-profile run: ~8 min (36/36 processes, includes container pulls + a
minutes-scale bismark index build on the tiny CI genome). Real-sample resume: seconds
(cache hit, 16/17 processes cached, only MULTIQC re-ran)
**Peak disk**    test-profile run: ~1 GB new. Real-sample run: <5 MB new (regenerated MultiQC
report only); reused the precedent's existing 36 GB work+results tree unchanged
**Results**      test-profile: `/work/nxf/20260816-methylseq-revalidate-test/results/` (~1 GB).
Real-sample: `/work/nxf/20260805-methylseq-sle-rrbs-smoke/results/` (unchanged from precedent,
20 GB, MultiQC regenerated 2026-08-16 17:34)
**MultiQC**      `/work/nxf/20260816-methylseq-revalidate-test/results/multiqc/multiqc_report.html`
(test-profile); `/work/nxf/20260805-methylseq-sle-rrbs-smoke/results/multiqc/bismark/multiqc_report.html`
(real-sample, regenerated)
**Work dir**     both RETAINED, do not delete, `-resume` depends on them

## What was checked (new-pipeline.md §2.4, escalating)

1. **`nextflow config`/`--help`** — re-pulled 3.0.0 (already up to date), `--help --show_hidden`
   confirms `--aligner` default is still `bismark`, `--rrbs` still present, no param drift.
   `schema_input.json` unchanged: `sample`+`fastq_1` required, `fastq_2`/`genome` optional.
   `nextflow config ... -flat` confirms `genomes.config`'s GRCh38 `bismark`/`bwameth`/
   `fasta_index` keys (added by the precedent run's PR #13) still resolve correctly in the
   merged config.
2. **`-stub-run`, `-profile test,docker`** — fails at `BISMARK_SUMMARY` with
   `No signature of method: nextflow.util.ArrayBag.baseName()`. **Reproduced the exact same
   failure, at the exact same process, in the precedent run's own stub log
   (`runs/20260805-methylseq-sle-rrbs-smoke/stub/stub.nextflow.log`) — this is a pre-existing
   upstream bug in nf-core/methylseq 3.0.0's own bundled `bismark/summary` module stub block
   (`${bam.baseName()}` called on a list), present since the pin was made and never written
   down until this run.** Not a regression from the 8 intervening procurements; not fixable in
   this repo (vendored pipeline code). Documented in
   `skills/bioinfo-analyze/references/pipeline-selection.md` §4.5 so it is not mistaken for a
   new break on the next methylseq run.
3. **Full non-stub `-profile test,docker` run — the gate — run in full, not skipped.**
   36/36 processes succeeded, including `BISMARK_SUMMARY` and `MULTIQC` (confirming the stub
   bug does not reach the real script path, which uses `bam.join(' ')` correctly).
4. **`scripts/check-samplesheet.sh --pipeline methylseq`** — branch (`methylseq|scrnaseq)
   REQ='sample fastq_1'`) unchanged by any of the 8 intervening procurements; still matches
   3.0.0's schema exactly. Ran it against the reused real-sample samplesheet: passes.

## Real-sample re-check (scope decision)

Per the task's proportionality guidance, did not launch a fresh WGS-scale WGBS run (8-45 h).
Reused the precedent's own real RRBS FASTQs and samplesheet, relaunched with `-resume` against
the precedent's intact work dir. Full cache hit: 16 of 17 processes served from cache, only
`MULTIQC` re-ran (nothing else needed recomputing). This confirms — cheaply — that the pin,
current shared config (`local.config`, `genomes.config`), container resolution, and the
resume/cache mechanism itself all still work correctly on this host, which is what an
infrastructure revalidation needs to show; it does not by itself re-prove bismark alignment
correctness (unchanged since 2026-08-05, not touched by this run).

## QC verdict

**PASS (infrastructure re-check) — no new interpretation.** The regenerated
`bismark_summary_report.txt` and MultiQC numbers are byte-identical to the precedent's, as
expected from a full cache hit (nothing re-aligned):

| Metric | HC660_SM | SLE497_SM | Matches precedent (2026-08-05)? |
|---|---|---|---|
| Mapping efficiency | 71.93% | 70.85% | Yes, exact |
| Total reads | 3,771,579 | 3,929,728 | Yes, exact |
| Duplication (dedup) | not run (RRBS correctly skips it) | not run | Yes, exact |

The precedent's PASS WITH CAVEATS verdict (conversion-proxy/global-mCpG bands mismatched for
RRBS vs the WGBS-calibrated bands in `qc-interpretation.md` §3.3, M-bias WARN at R1 position 1)
stands unchanged — this run did not recompute it since the underlying alignment/extraction did
not rerun. See `runs/20260805-methylseq-sle-rrbs-smoke/handoff.md` for that full table.

Test-profile run: synthetic CI fixture, no biologically meaningful QC (E. coli + human subsample
toy data) — used only to confirm the pipeline executes cleanly, not for a QC verdict.

## Bounded choices made

- **Reused the precedent's real RRBS dataset and its intact work dir via `-resume`**, rather than
  downloading new real data or launching a fresh WGS-scale run — proportionate to "does the pin
  still work," not a new study.
- **No upgrade off `3.0.0`** considered, despite 4.0.0/4.1.0/4.2.0 existing upstream — out of
  scope for a revalidation.
- **Documented, did not patch, the `BISMARK_SUMMARY` stub bug** — it is nf-core's own vendored
  module code; a local patch to a pinned pipeline's bundled modules would itself be an
  unreviewed, silent deviation from the pipeline as shipped.

## Known gaps (unchanged from the precedent, re-confirmed still true)

- Bismark index for GRCh38 still not promoted to `$BIOINFO_REFS/genomes/GRCh38/index/bismark/`
  (still `[!] build` in `refs.manifest.tsv`) — a run without an intact prior work dir would pay
  the ~1h9m build again.
- `bwameth` index: still not built by any run on this host (`refs.manifest.tsv`, unchanged).
- No RRBS-specific QC bands in `qc-interpretation.md` §3.3 — still only WGBS bands stated.
- `--genome GRCh38 --igenomes_ignore` compact form for methylseq: the precedent's caveat (does
  not reliably discover a promoted bismark index) was not re-investigated this run — out of
  scope, still standing.

## Repo changes this run

- `skills/bioinfo-analyze/references/pipeline-selection.md` §4.5 — added the `BISMARK_SUMMARY`
  stub-bug note (documentation only, no behavior change).
- `.claude-plugin/plugin.json` / `.claude-plugin/marketplace.json` — version bumped 0.4.1 → 0.4.2
  (packaged skill file touched).
- No fixes to `scripts/check-samplesheet.sh`, `config/refs.manifest.tsv`, or `config/genomes.config`
  were needed — all re-verified clean against the current repo state.

## Next step for you

Nothing blocking. If methylseq becomes a recurring workload: (1) promote the bismark index from
`runs/20260805-methylseq-sle-rrbs-smoke`'s `results/bismark/reference_genome/` into
`$BIOINFO_REFS` to stop paying the rebuild cost, and (2) consider adding RRBS-specific QC bands
to `qc-interpretation.md` §3.3 rather than reporting against the WGBS bands with a caveat every
time.
