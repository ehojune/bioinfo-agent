# spatialaxe

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** No registered stub waiver. Preview and the full-command stub must pass; missing upstream stubs can execute real work.
- **Evidence lookup:** [procurement record](evidence/spatialaxe.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** spatial transcriptomics QC and processing for 10x Genomics **Xenium** in-situ imaging
data — cell/nucleus segmentation (image-based via Cellpose/StarDist/XeniumRanger, or
coordinate/transcript-based via Proseg/Segger/Baysor), segmentation-free neighbourhood analysis
(Ficture/Baysor), transcript-to-cell assignment, and QC reporting (MultiQC's xenium-extra
plugin + off-target-probe-tracking). **FIRST spatial transcriptomics / imaging-based pipeline
stocked here** — a genuinely new domain. Input is an already-generated **Xenium Onboard
Analysis (XOA) output bundle** (a directory of parquet/zarr/h5/csv.gz/OME-TIFF files the
instrument's own onboard software produced), not raw sequencing reads in any FASTQ sense —
confirmed by reading `workflows/spatialaxe.nf` directly, not assumed from the pipeline's name.
`nf-core/spatialvi` (a different, Visium-based spatial pipeline) was considered and rejected:
only a `dev`-branch tag (0.1.0), no formal GitHub Release — fails this repo's trust gate
(`new-pipeline.md` §2.4).

**Not for, vs `nf-core/scrnaseq`:** scrnaseq (already stocked) quantifies per-cell gene
expression from droplet/well-based **dissociated** single cells — the tissue is disaggregated
before sequencing, so no spatial location survives; a cell's only "position" is which
droplet/well it landed in. spatialaxe quantifies per-cell gene expression **with real spatial
coordinates preserved on the original tissue**, derived from in-situ imaging (Xenium probes
hybridize and are imaged directly in an intact tissue section — every transcript and every
segmented cell carries an (x, y) micron position). scrnaseq has zero spatial/imaging component
at all; spatialaxe's entire pipeline (cell segmentation from a morphology image,
transcript-to-cell assignment on a coordinate plane, micron-region tiling/patching) has no
scrnaseq analogue whatsoever. Different question: "what genes does this dissociated cell
express" (scrnaseq) vs "what genes does this cell express **and where does it sit in the
tissue**" (spatialaxe). If the input is a 10x-format `.h5`/`.mtx` cell-by-gene matrix from a
droplet run (Chromium), that's scrnaseq. If the input is a Xenium bundle with cell/transcript
spatial coordinates, that's spatialaxe.

**Schema drift note — a genuinely new shape at this repo, not matching either prior pattern.**
`assets/schema_input.json` **is** wired in and **is** the live column-shape validator
(`subworkflows/local/utils_nfcore_spatialaxe_pipeline/main.nf:137` calls `samplesheetToList()`
directly against it) — same class as isoseq/bacass/viralrecon, unlike nanoseq/rnasplice where
the shipped schema is vestigial. **But the schema alone is not sufficient**, unlike every one of
those four prior cases: `workflows/spatialaxe.nf` (~lines 177-220) layers its own POST-STAGING
bundle-CONTENT check on top, via plain Groovy `error()` calls that enforce a fixed 16-entry
required-file list inside the `bundle` directory — something no JSON Schema keyword can express.
Confirmed by reading that block directly, not inferred from its existence.

**Minimum input:** `sample` + `bundle` (schema's only two `required[]` fields), `image` optional
(falls back to `morphology.ome.tif` inside `bundle` when omitted). **But `bundle` passing the
schema's `^\S+$` pattern check is nowhere near "usable input"** — it must resolve to a local,
already-extracted directory (a tarball URL only auto-stages under `-profile test`, gated by
`workflow.profile.contains('test')`) containing all 16 of `workflows/spatialaxe.nf`'s own
`bundle_required_files` (see `samplesheets.md` for the full itemized list) — a missing one
aborts before any process runs, with a message the schema layer never produces. See
`samplesheets.md` for the full column table and the exact required-file list.

**Parameters that matter:** `--mode` (`image`/`coordinate`/`segfree`/`preview`/`qc`, no
default — selects the whole processing path: `image` runs
`CELLPOSE→BAYSOR→XR-IMPORT_SEGMENTATION→SPATIALDATA→QC`, `coordinate` runs
`PROSEG→PROSEG2BAYSOR→XR-IMPORT_SEGMENTATION→SPATIALDATA→QC`, `segfree` runs
`BAYSOR_SEGFREE`, `preview` runs `BAYSOR_PREVIEW`, `qc` runs QC alone). `--method` further picks
a specific tool within a mode (`cellpose`/`xeniumranger`/`baysor`/`stardist` for image;
`proseg`/`baysor`/`segger` for coordinate; `baysor`/`ficture` for segfree). `--run_qc` (default
`true`) couples the QC layer onto any other mode. `--gene_panel` (defaults to the bundle's own
`gene_panel.json` when unset). No genome/reference parameters exist anywhere in
`nextflow_schema.json` — this pipeline does no alignment.

**Resource note that drove this procurement's scope, straight from the pipeline's own README
runtime table (measured by the pipeline authors, not by this procurement):** Cellpose on CPU
peaks at up to **1115 GB RSS** on a real full-size Xenium slide (554 GB even on GPU); Baysor
whole-image up to 650 GB; XeniumRanger resegment up to 60 GB; Segger needs a GPU for all three
of its steps. This box's Nextflow pool is 16 cores / 18 GB (`config/host.env`) — orders of
magnitude under what real, full-size image-mode segmentation needs. **Proseg (coordinate mode)
is by far the lightest tool in that table** (279 MB / 3.8 GB / 136 GB min/med/max RSS) and is
the only realistic choice for anything beyond a genuinely tiny bundle on this hardware.

**Reference-store paths:** none. spatialaxe consumes only the Xenium bundle's own pre-computed
transcript/cell/probe-panel data; there is no alignment step and no genome FASTA/GTF parameter.
No rows needed in `config/refs.manifest.tsv`.

**Known gaps / stub-run behaviour.** `-stub-run` on the CI `test` profile (`--mode coordinate`,
the profile's own default) **PASSES CLEANLY** at this pin:
`succeededCount=10 failedCount=0` (Nextflow's own `WorkflowStats`) — **no waiver needed, no 12th
documented departure**, same class as taxprofiler/raredisease/isoseq's minimap2 branch/bacass's
full-gate. First run took ~11.5 minutes wall clock, almost entirely first-pull time for two
container images (`quay.io/nf-core/xeniumranger:4.0`, 3.78 GB; a Wave-built MultiQC
xenium-extra-plugin variant, ~3 GB) — the 10 stub tasks themselves completed in 21.2 seconds
combined once the images were cached.

**The mandatory full `-profile test,docker` gate** (`new-pipeline.md` §2.4(c)) — see
`estimates.md` and the procurement `plan.md`/`handoff.md` for the complete measured writeup.

**Key outputs (coordinate mode, this procurement's stocked scope):**
`coordinate/proseg/preset/cell-polygons.geojson.gz` (2D cell polygons), `expected-counts.csv.gz`
(cell-by-gene count matrix), `cell-metadata.csv.gz` (centroids/volume), `coordinate/
proseg2baysor/xr-cell-polygons.geojson` + `xr-transcript-metadata.csv` (stitched, XeniumRanger-
importable format), `multiqc/multiqc_report.html` (aggregated, xenium-extra-plugin sections),
`opt/stat/*.tsv` (off-target-probe-tracking summary stats).

**QC verdict checklist (measured, no biological interpretation):** cell/nucleus count from the
bundle's own `metrics_summary.csv`/`experiment.xenium` (`num_cells`), transcripts-per-cell and
genes-per-cell from the same, fraction of transcripts assigned to a cell
(`fraction_transcripts_assigned`), Proseg's own per-cell transcript-assignment probability
summary, and MultiQC's xenium-extra QC sections (segmentation/assignment metrics aggregated
across whatever tool ran). None of these are tissue-architecture or cell-type-identity claims.

**Scope of this procurement — lightest real configuration.** Test-profile run left entirely at
`conf/test.config`'s own defaults (`--mode coordinate`, no other overrides) — no hand-picked
tool combination. Real-sample run used the same coordinate-mode default. Image-mode segmentation
(Cellpose/StarDist/XeniumRanger resegment) and Segger (GPU-only) are explicitly **out of scope**
this procurement, per the resource note above.

**Real-sample run:** see `estimates.md`/`handoff.md` for the complete measured numbers
(`Xenium_Prime_Mouse_Ileum_tiny_outs`, a real 10x-published "tiny_outs" Xenium bundle, 23 MB
extracted, 23 cells — found on `nf-core/test-datasets@spatialaxe`, well under the ~10 GB silent-
download ceiling).
