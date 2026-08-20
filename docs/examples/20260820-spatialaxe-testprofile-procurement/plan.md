# Plan — 20260820-spatialaxe-testprofile-procurement

## Pipeline
nf-core/spatialaxe -r 1.0.1 (latest stable; releases confirmed via
`gh api repos/nf-core/spatialaxe/releases`: 1.0.1 published 2026-08-06, 1.0.0 published
2026-06-17, no draft/prerelease flags on either; repo not archived, org `nf-core`, 45 GitHub
stars, `pushed_at` 2026-08-18 — well inside the "<12 months: normal" age band). Trust gate
(`new-pipeline.md` §2.4) confirmed: nf-core org, exact release tag `1.0.1` (never dev/master),
not archived. `nextflowVersion = '!>=25.04.0'` in the pipeline manifest — this box runs
Nextflow 26.04.6, compatible.

**FIRST spatial transcriptomics / imaging-based pipeline stocked here.** Genuinely new domain:
every prior RNA-level pipeline (rnaseq, rnasplice, isoseq, scrnaseq) is dissociated-cell or bulk
sequencing with no spatial coordinate information at all. Input is 10x Genomics **Xenium** (an
in-situ imaging platform, not a FASTQ-based sequencing assay) — confirmed from the README
("A pipeline for spatialomics 10x Xenium In Situ data") and from reading `workflows/
spatialaxe.nf` directly: the pipeline consumes an already-generated **Xenium Onboard Analysis
(XOA) output bundle** (a directory of parquet/zarr/h5/csv.gz/OME-TIFF files XOA itself produced
on the instrument) plus an optional morphology OME-TIFF image — not raw sequencing reads in any
FASTQ sense. `nf-core/spatialvi` (Visium-based, a different spatial platform) was considered and
explicitly **rejected**: only a `dev`-branch tag (0.1.0), no formal GitHub Release — fails this
repo's own trust-gate rule (`new-pipeline.md` §2.4, "never dev, master or main").

## Why spatialaxe, not scrnaseq — a genuinely different question
**vs `nf-core/scrnaseq`** (already stocked): scrnaseq quantifies per-cell gene expression from
droplet/well-based **dissociated** single cells — the tissue is disaggregated before
sequencing, so no spatial location survives; a cell's only "position" is which droplet/well it
happened to land in. spatialaxe quantifies per-cell gene expression **with real spatial
coordinates preserved**, derived from **in-situ imaging** (Xenium probes hybridize and are
imaged directly in intact tissue sections) — every transcript and every segmented cell carries
an (x, y) position on the original tissue. scrnaseq has zero spatial/imaging component at all;
spatialaxe's entire pipeline (cell segmentation from a morphology image, transcript-to-cell
assignment on a coordinate plane, tiling/patching by micron regions) has no scrnaseq analogue.
Different question: "what genes does this dissociated cell express" (scrnaseq) vs "what genes
does this cell express **and where does it sit in the tissue**" (spatialaxe).

## Schema drift check performed this run
`assets/schema_input.json` (columns `sample`/`bundle`/`image`, required=[`sample`,`bundle`])
**IS the live validator** for column shape: `subworkflows/local/
utils_nfcore_spatialaxe_pipeline/main.nf:137` calls
`channel.fromList(samplesheetToList(input, "${projectDir}/assets/schema_input.json"))`
directly, no bundled `bin/check_samplesheet*.py` in the clone.

**BUT the schema is not sufficient on its own** — a genuinely new finding, a different shape
from every prior "schema not authoritative" case (nanoseq/rnasplice) here, because THIS schema
*is* wired in, it is just incomplete. `workflows/spatialaxe.nf` (~lines 177-220) layers its own
POST-STAGING bundle-content validation on top, via plain Groovy `error()` calls the JSON schema
cannot express: a fixed 16-entry `bundle_required_files` list
(`cell_boundaries.csv.gz`/`.parquet`, `cell_feature_matrix.h5`/`.zarr.zip`,
`cells.csv.gz`/`.parquet`/`.zarr.zip`, `experiment.xenium`, `gene_panel.json`,
`metrics_summary.csv`, `morphology.ome.tif`, `morphology_focus/`,
`nucleus_boundaries.csv.gz`/`.parquet`, `transcripts.parquet`/`.zarr.zip`) that every row's
`bundle` directory must contain, checked via `bundle_path.resolve(check).exists()` — any one
missing aborts the run immediately with "Missing required file(s) in xenium bundle", a
Groovy-layer error, not a schema validation message. Confirmed by reading that block directly.

**ALSO load-bearing:** the pipeline's own `assets/samplesheet.csv` (what `-profile test`
resolves `--input` to) sets `bundle` to a **tar.gz URL**
(`https://raw.githubusercontent.com/nf-core/test-datasets/spatialaxe/xenium_bundle.tar.gz`),
auto-fetched and extracted via the bundled `UNTAR` module — but that path **only fires
`if (workflow.profile.contains('test'))`** (confirmed by reading `workflows/spatialaxe.nf`
~line 136). On any real (non-test-profile) run, `bundle` MUST already be an extracted, local,
readable **directory** on disk containing the 16-file list above; a tarball URL there is never
staged outside `-profile test` and the bundle-exists check fails hard. `scripts/
check-samplesheet.sh --pipeline spatialaxe` enforces this real-run shape (local directory +
all 16 files present) and separately WARNs (not FAILs, since it is legitimate under
`-profile test`) on a bare URL.

## Scope — lightest combination first, matching this run
This run is the **unmodified CI test-profile fixture** (`-profile test,docker`, no param
overrides) — `conf/test.config` sets `--input assets/samplesheet.csv --mode coordinate`, i.e.
the coordinate-based (transcripts-only, no Cellpose/StarDist image segmentation) path:
`PROSEG -> PROSEG2BAYSOR -> XR-IMPORT_SEGMENTATION -> SPATIALDATA -> QC`. `--mode` has five
values (`image`/`coordinate`/`segfree`/`preview`/`qc`) and `--method` further selects a specific
tool within a mode (`cellpose`/`xeniumranger`/`baysor`/`stardist` for image;
`proseg`/`baysor`/`segger` for coordinate; `baysor`/`ficture` for segfree) — this run takes
whatever the CI fixture's own defaults resolve to, not a hand-picked combination, since the
purpose of this run is validating the pin itself, not exercising every tool.

**Resource note driving all later scope choices (from the pipeline's own README runtime
table):** Cellpose on CPU peaks at up to **1115 GB RSS** on a real full-size Xenium slide (554
GB even on GPU); Baysor whole-image up to 650 GB; XeniumRanger resegment up to 60 GB. This
box's Nextflow pool is 16 cores / 18 GB (`BIOINFO_MAX_CPUS`/`BIOINFO_MAX_MEMORY`,
`config/host.env`) — orders of magnitude under what a real, full-size Xenium slide needs for
image-mode segmentation. Proseg (coordinate mode, the CI/real-sample path both runs) is by far
the lightest tool in the table (279 MB / 3.8 GB / 136 GB min/med/max RSS) and is the only
segmentation method with a realistic chance of completing on this box's pool for anything
beyond a genuinely tiny dataset.

## Containers
Resolves through both `quay.io/nf-core/*` (XeniumRanger, a 10x proprietary-tool container,
3.78 GB, `quay.io/nf-core/xeniumranger:4.0`) and `community.wave.seqera.io` (Wave-built,
on-demand — MultiQC's own xenium-extra-plugin variant, ~3 GB). Both pulled cleanly this run;
no quay.io tag-retirement or Wave build failure observed. First-pull cost is real: the
XeniumRanger image alone took ~6 minutes to pull+extract on this box's network during the
`-stub-run` below.

## Resources
Standard nf-core process labels (`process_single` through `process_xl`, `process_high_memory`)
in `conf/base.config`, clamped by this box's actual pool — **16 cores / 18 GB**
(`BIOINFO_MAX_CPUS=16`, `BIOINFO_MAX_MEMORY=18.GB`) via `config/local.config`'s
`resourceLimits`. `conf/test.config` itself further clamps to `cpus:4, memory:8.GB, time:2.h`
for the CI fixture specifically — trivially inside the pool.

## Reference genomes
**None required.** spatialaxe works entirely from the Xenium bundle's own pre-computed
transcript/cell/probe data and gene panel (`gene_panel.json`, an XOA-generated probe panel
definition, not a reference genome) — there is no alignment step and no genome FASTA/GTF
parameter anywhere in `nextflow_schema.json`. No new rows needed in
`config/refs.manifest.tsv`; will note this explicitly as a no-op, same pattern as bacass/
raredisease-intervals-only.

## Disk
`/` (ext4, `/dev/sdd` mount, also where `/work` lives) has **116 GB free** at time of writing
(measured `df -h /`, materially less than the ~955 GB the skill's generic orientation figures
assume — this box's actual number governs, not the general guidance). CI test-profile fixture
(`xenium_bundle.tar.gz`) is a few MB; the two heavy container images together are ~7 GB
one-time. Estimated peak work-dir size for the CI fixture run: well under 5 GB (a handful of
tiny CSV/parquet/geojson intermediates from a 23-region test bundle, no image-mode
segmentation exercised). 1.5x estimate is trivially satisfied by 116 GB free.

## Real-sample candidate — found and used
Searched the pipeline's own test-datasets branch (`nf-core/test-datasets@spatialaxe`, via
`gh api repos/nf-core/test-datasets/contents/?ref=spatialaxe`) rather than assuming none
exists, given imaging-platform raw data is typically large/proprietary. Found
**`Xenium_Prime_Mouse_Ileum_tiny_outs.tar.gz`** (5.56 MB compressed, 23 MB extracted) — the
exact real 10x Genomics "tiny_outs" bundle referenced in the pipeline's own
`assets/example_samplesheet.csv`. Downloaded and inspected directly (not assumed): a genuine,
complete Xenium Onboard Analysis output bundle (real `experiment.xenium` metadata: Xenium
Mouse 5K Pan Tissue & Pathways Panel, fresh-frozen mouse ileum, `num_cells: 23`,
`transcripts_per_cell: 16`) carrying all 16 files `workflows/spatialaxe.nf`'s own
`bundle_required_files` check requires — confirmed present one by one, not just directory
existence. Well under the ~10 GB silent-download ceiling; no approval needed. This is real,
published 10x reference data, not a synthetic CI fixture, and at 23 cells is small enough that
even Proseg's coordinate-mode path should complete in well under an hour on this box's pool —
see the companion real-sample run directory for the actual measured numbers.

## Estimate
No prior spatialaxe run on this machine (`$BIOINFO_RUNLOG` has no spatialaxe entries —
checked). Per scale-up discipline (`new-pipeline.md` §2.8): CI test profile first, then a real
sample if a small one can be found (it was), extrapolate/escalate only if warranted. `-preview`
and `--help` both resolve in seconds. `-stub-run` on this pin took ~11.5 minutes wall clock —
almost entirely first-pull time for the two container images (XeniumRanger 3.78 GB +
MultiQC-xenium-extra ~3 GB), not actual task compute (`succeededCount=10, failedCount=0,
succeedDuration=21.2s` per Nextflow's own workflow stats — the 10 tasks themselves took 21
seconds combined). The full (non-stub) test-profile gate below reuses those now-cached images
and is expected to run in single-digit minutes. Both runs launched via `tmux` per
`runbook.md` §5 regardless of this short expected duration, per the standing rule. Well under
the 24-hour approval threshold either way; no escalation needed.

## Bounded choices
- CI test-profile run left entirely at `conf/test.config`'s own defaults (`--mode coordinate`,
  whatever `--method`/segmentation-tool choice that resolves to) — no overrides, matching this
  repo's own "first, unmodified validation" convention for a new pipeline's test-profile gate.
- Real-sample dataset (`Xenium_Prime_Mouse_Ileum_tiny_outs`) chosen for its small size (23 MB,
  23 cells) and because it is the pipeline's own documented example dataset, not for any
  biological property of the tissue.
- Image-mode segmentation (Cellpose/StarDist) explicitly OUT OF SCOPE this procurement — the
  pipeline's own published resource table shows those tools needing up to ~1 TB RSS on a real
  full-size slide, far beyond this box's 18 GB pool; only coordinate-mode (Proseg, by far the
  lightest tool per that same table) is exercised.

## Next steps
1. `bash bin/preflight.sh` for this run directory.
2. `bash scripts/check-samplesheet.sh --deep --pipeline spatialaxe samplesheet.csv`.
3. `-preview`, then `-stub-run` on `-profile test,docker` — already run ad hoc against this
   exact pin/samplesheet during evaluation (§2.4b): **passes cleanly**, `succeededCount=10
   failedCount=0` — no waiver needed, no 12th documented departure.
4. Full (non-stub) `-profile test,docker` via `cmd.sh`/tmux — the mandatory gate.
5. Real-sample run (own run directory, `Xenium_Prime_Mouse_Ileum_tiny_outs`), launched via
   tmux, timed and measured.
6. QC verdict from the pipeline's own MultiQC (Xenium-extra plugin) + OPT off-target-probe
   report — no biological interpretation.
7. Stock the deliverable files, PR, `@codex review` loop, merge.
