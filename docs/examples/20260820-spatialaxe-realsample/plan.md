# Plan — 20260820-spatialaxe-realsample

Companion to `runs/20260820-spatialaxe-testprofile-procurement/plan.md` — read that first for
the pipeline evaluation, trust gate, schema drift findings, and scope rationale. This plan
covers only what's specific to the real-sample validation.

## Pipeline
nf-core/spatialaxe -r 1.0.1 (same pin, already confirmed against the trust gate and both
`-preview`/`-stub-run` in the companion procurement).

## Input
`Xenium_Prime_Mouse_Ileum_tiny_outs` — a real, published 10x Genomics Xenium Onboard Analysis
output bundle, fetched from `nf-core/test-datasets@spatialaxe`
(`Xenium_Prime_Mouse_Ileum_tiny_outs.tar.gz`, 5.56 MB compressed, `gh api
repos/nf-core/test-datasets/contents/...?ref=spatialaxe` confirmed `size: 5559286` before
download). Extracted to 18 MB (`du -sh`, measured, not estimated) at
`/work/scratch/spatialaxe-realdata/Xenium_Prime_Mouse_Ileum_tiny_outs`. Well under the ~10 GB
silent-download ceiling; no approval needed. Real `experiment.xenium` metadata inspected
directly: Xenium Mouse 5K Pan Tissue & Pathways Panel, fresh-frozen preservation, `num_cells:
23`, `transcripts_per_cell: 16`. All 16 of `workflows/spatialaxe.nf`'s own
`bundle_required_files` confirmed present one by one (not just directory existence) —
`scripts/check-samplesheet.sh --deep --pipeline spatialaxe` PASSES cleanly on this exact sheet.
This is genuinely small, real, published reference data — not the pipeline's own synthetic CI
fixture (which is a different, smaller-still bundle used only under `-profile test`).

`image` column left empty — the bundle's own `morphology.ome.tif` is used, matching the
pipeline's documented fallback.

## Mode / scope
`--mode coordinate` (explicit — a real, non-test-profile run has no `conf/test.config` to
default it). Same coordinate-mode path exercised by the test-profile gate:
`PROSEG → PROSEG2BAYSOR → XR-IMPORT_SEGMENTATION → SPATIALDATA → QC`. No other overrides.
Image-mode segmentation (Cellpose/StarDist) is out of scope — see the companion plan's resource
note (up to ~1 TB RSS for Cellpose CPU on a real full-size slide, per the pipeline's own README
table); this dataset is tiny (23 cells) but the tool choice itself is being validated for this
repo's stocked scope, not re-decided per dataset.

## Resources
Same pool as the test-profile run — 16 cores / 18 GB (`config/host.env`). No `conf/test.config`
resourceLimits override applies here (that file only activates under `-profile test`), so tasks
run under `config/local.config`'s own `resourceLimits` ceiling directly. Given the CI fixture's
Proseg task completed in seconds and this bundle (23 cells) is smaller in every dimension than
the CI fixture's own test bundle, no ceiling risk expected.

## Disk
`/` (ext4) had ~105 GB free after the test-profile gate (measured). Input is 18 MB; peak
work-dir size expected in the same few-tens-of-MB range as the test-profile gate (48 MB work /
41 MB results measured there). 1.5x estimate trivially satisfied.

## Estimate
Test-profile gate (same coordinate-mode path, similar-scale CI bundle) completed in ~3 minutes
wall clock with all container images already cached from evaluation. This real-sample bundle is
smaller (23 cells vs the CI fixture's own cell count) and uses the identical container set
(already cached) — expect a similar or shorter wall clock. Well under the 24-hour approval
threshold; no escalation needed. Launched via `tmux` per `runbook.md` §5 regardless.

## Bounded choices
- `Xenium_Prime_Mouse_Ileum_tiny_outs` chosen for its small size (18 MB extracted, 23 cells)
  and because it is 10x Genomics' and the pipeline's own documented example dataset, not for
  any biological property of the tissue.
- `--mode coordinate` (Proseg) — the only segmentation path this box's 18 GB pool can run on
  anything beyond a genuinely tiny bundle, per the resource note above. Image-mode
  (Cellpose/StarDist/XeniumRanger resegment) and Segger (GPU-only) are out of scope.

## Next steps
1. `bash bin/preflight.sh` for this run directory.
2. `bash scripts/check-samplesheet.sh --deep --pipeline spatialaxe samplesheet.csv` — already
   run ad hoc against this exact sheet during evaluation: PASSES cleanly.
3. `-preview` on the real (non-test) command.
4. Launch via `cmd.sh`/tmux, timed and measured.
5. QC verdict from the pipeline's own MultiQC (xenium-extra plugin) — no biological
   interpretation.
