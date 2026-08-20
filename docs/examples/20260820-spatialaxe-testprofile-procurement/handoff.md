# Run 20260820-spatialaxe-testprofile-procurement — nf-core/spatialaxe -r 1.0.1 — COMPLETE

**Inputs**       1 sample, 10x Xenium Onboard Analysis bundle (CI test fixture, auto-fetched via
                 UNTAR from a test-profile-only tar.gz URL), samplesheet:
                 `/mnt/d/bioinfo-agent/runs/20260820-spatialaxe-testprofile-procurement/samplesheet.csv`
**Reference**    None (no genome/alignment step in this pipeline)
**Command**      `/mnt/d/bioinfo-agent/runs/20260820-spatialaxe-testprofile-procurement/cmd.sh`
**Wall clock**   3m2s            **Peak disk**  48 MB work-dir     **Cores/RAM used** up to 12 / 38 GB (sum across 2 concurrent tasks; per-task pool ceiling 16 cpu/18 GB never exceeded)
**Results**      `/work/nxf/20260820-spatialaxe-testprofile-procurement/results`   (41 MB)     **MultiQC**  `results/coordinate/multiqc/{raw_bundle,redefined_bundle}/*_multiqc_report.html`
**Work dir**     `/work/nxf/20260820-spatialaxe-testprofile-procurement/work`  — RETAINED, do not delete, -resume depends on it

## QC verdict
PASS — this is a validation run on the pipeline's own CI fixture; the purpose was confirming the
1.0.1 pin runs cleanly end to end (both `-stub-run` and the mandatory full test-profile gate),
not evaluating tissue-specific QC on synthetic test data. All 10 tasks completed successfully.

| sample | tasks completed | tasks failed | verdict |
|---|---|---|---|
| test_run | 10 | 0 | PASS |

Thresholds applied: none (CI-fixture-scale gate run, pass/fail on task completion, per
`new-pipeline.md` §2.4(c)).

## Bounded choices I made
- Ran the CI test profile entirely unmodified (`--mode coordinate`, no other overrides) —
  matches this repo's own "first, unmodified validation" convention for a new pipeline.
- No reference-store rows added — this pipeline needs no reference genome.

## Known gaps
- `-stub-run` on this exact flag set **PASSES CLEANLY** (`succeededCount=10 failedCount=0`) —
  explicitly noting this because every prior new pipeline procurement in this repo (10 of them
  since ampliseq) has hit at least one waived stub-coverage departure; this one did not.
- Image-mode segmentation (Cellpose/StarDist/XeniumRanger resegment) and Segger (GPU-only) are
  entirely unexercised by this procurement — see `pipeline-selection.md` §4.19 for the resource
  rationale (Cellpose CPU up to 1115 GB RSS on a real slide, far beyond this box's 18 GB pool).
- MultiQC's own xenium-extra plugin report content was not read in detail for this CI-fixture
  run (synthetic data, nothing to report on beyond confirming the report renders) — see the
  companion real-sample run's handoff for real numbers.

## Next step for you
Companion real-sample run at `runs/20260820-spatialaxe-realsample/handoff.md` has the measured
QC numbers on real (if tiny) 10x Genomics data. Review that handoff next; this one exists to
confirm the pin is sound, not to report biology.

No biological interpretation is included, by design.
