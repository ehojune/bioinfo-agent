# Run 20260820-spatialaxe-realsample — nf-core/spatialaxe -r 1.0.1 — COMPLETE

**Inputs**       1 sample, `Xenium_Prime_Mouse_Ileum_tiny_outs` (real, published 10x Genomics
                 Xenium Onboard Analysis bundle, `nf-core/test-datasets@spatialaxe`, 23 cells
                 per its own `experiment.xenium`), samplesheet:
                 `/mnt/d/bioinfo-agent/runs/20260820-spatialaxe-realsample/samplesheet.csv`
**Reference**    None (no genome/alignment step in this pipeline)
**Command**      `/mnt/d/bioinfo-agent/runs/20260820-spatialaxe-realsample/cmd.sh`
**Wall clock**   2m23s            **Peak disk**  27 MB work-dir     **Cores/RAM used** up to 12 / 38 GB (sum across 2 concurrent tasks; peak single-process RSS 1.1 GB, pool ceiling 16 cpu/18 GB per task never approached)
**Results**      `/work/nxf/20260820-spatialaxe-realsample/results`   (26 MB)     **MultiQC**  `results/coordinate/multiqc/{raw_bundle,redefined_bundle}/*_multiqc_report.html`
**Work dir**     `/work/nxf/20260820-spatialaxe-realsample/work`  — RETAINED, do not delete, -resume depends on it

## QC verdict
PASS — pipeline executed correctly end to end on real 10x Genomics Xenium data. All 9 tasks
completed successfully; no threshold was set to fail this run against, since this is the first
run of this pipeline on real data on this box and no prior baseline exists.

| sample | tasks completed | tasks failed | fraction_transcripts_assigned | median_transcripts_per_cell | segmented_cell_imported_count | verdict |
|---|---|---|---|---|---|---|
| xenium_prime_mouse_ileum | 9 | 0 | 0.702 | 44 | 9 | PASS |

Thresholds applied: none (first real run, task-completion pass/fail only; no established
per-metric threshold for this pipeline yet). Measured values above are the pipeline's own
`metrics_summary.csv` output after Proseg-based coordinate re-segmentation via XeniumRanger
import — a different segmentation method from the bundle's own original XOA onboard-analysis
cell count (`num_cells: 23` in the input bundle's `experiment.xenium`), so the two numbers are
not directly comparable; both are measured facts about two different segmentation runs on the
same tissue, not a claim that one is more correct than the other.

## Bounded choices I made
- `Xenium_Prime_Mouse_Ileum_tiny_outs` chosen for its small size (18 MB extracted, 23 cells) and
  because it is 10x Genomics' and the pipeline's own documented example dataset, not for any
  biological property of the tissue. Undo: any other Xenium bundle in the standard 16-file
  format would substitute directly.
- `--mode coordinate` (Proseg) — the only segmentation path this box's 18 GB pool can run
  confidently, per the pipeline's own README resource table (Cellpose CPU up to 1115 GB RSS on
  a real full-size slide). Undo: re-run with `--mode image --method cellpose` on hardware with a
  GPU or far more RAM.

## Known gaps
- Image-mode segmentation (Cellpose/StarDist/XeniumRanger resegment) and Segger (GPU-only) are
  entirely unexercised — out of scope for this procurement, see `pipeline-selection.md` §4.19.
- `--gene_panel`, `--reference_annotations`, `--gene_synonyms`, `offtarget_probe_tracking`, and
  every tiling/patching parameter were left at their defaults — not individually validated.
- Only one bundle, one organism (mouse ileum), one panel (Xenium Mouse 5K Pan Tissue & Pathways)
  tested. No statement is made about how these numbers would look on a different tissue, panel,
  or a real full-size slide.
- `sample` ID uniqueness behaviour is untested at this pin (single-row sheet this run) — see
  `samplesheets.md`.

## Next step for you
Review `results/coordinate/multiqc/redefined_bundle/MultiQC-Post-Xeniumranger-import-
segmentation-Run_multiqc_report.html` for the aggregated xenium-extra QC sections. If a larger
real dataset or image-mode segmentation is wanted next, that needs a GPU or a much larger memory
budget than this box's 18 GB pool — flag that explicitly before attempting it here.

No biological interpretation is included, by design.
