# Run plan — 20260814-rnasplice-scer-gln3-ibutanol

**Pipeline** `nf-core/rnasplice` **-r 1.0.4** (new pin, this run adds the row to
`config/pipelines.tsv`). First run of this pipeline on this host — procurement, not a routine
analysis. Followed `skills/bioinfo-analyze/references/new-pipeline.md` sections 1-4.

## Why this pipeline, why this pin

`nf-core pipelines list` / `nextflow info nf-core/rnasplice`: latest release **1.0.4**, tagged,
pushed 2026-08-11, 68 stars. Released < 12 months ago (normal, no age penalty per §2.2). Not
archived. Under the `nf-core` org — trust gate satisfied. This is the first splicing-specific
pipeline stocked in this repo; `nf-core/rnaseq` (already stocked) quantifies gene/transcript
expression but does not compute PSI, splicing events, or differential splicing statistics.

## What this pipeline actually needs — measured, not assumed from `--help`

**Important schema-drift finding, not documented anywhere upstream I could find:** `--help`
(schema-derived) reports `aligner` default `star`, and `rmats`/`dexseq_exon`/`edger_exon`/
`dexseq_dtu`/`sashimi_plot` all default `false`. The pipeline's own `nextflow.config` (the file
Nextflow actually loads and which wins over the schema's stated defaults) sets `aligner =
'star_salmon'` and **all five of those flags to `true`**. Confirmed by reading
`nextflow.config` directly and by `nextflow run ... -preview`'s "differs from pipeline defaults"
summary, which lists `aligner: star_salmon`, `rmats: true`, `dexseq_exon: true`,
`edger_exon: true`, `dexseq_dtu: true`, `sashimi_plot: true` as the actual effective values
before any of my own flags are applied. **The unscoped default run is the full kitchen-sink
toolset** (STAR+Salmon alignment, rMATS, DEXSeq DEU, edgeR DEU, DEXSeq DTU, Miso sashimi plots,
SUPPA2) — not the light one `--help` alone would suggest. This must be stated explicitly because
relying on `--help`'s "false" defaults would have shipped a much heavier stocked configuration
than intended.

## Scope for this procurement — lightest combination that still exercises splicing detection

Stocked with:

- `--skip_alignment true` — skips STAR entirely (genome alignment, its BAMs, bigwig tracks).
  None of the tools I am keeping need it: `SUPPA_SALMON` runs off plain Salmon
  pseudo-alignment, not the STAR+Salmon combined path. Structurally, `--skip_alignment true`
  also gates OFF `rmats`/`dexseq_exon`/`edger_exon`/`dexseq_dtu`/`sashimi_plot` even though they
  default `true`, because every one of those subworkflows in `workflows/rnasplice.nf` is nested
  inside `if (!params.skip_alignment && ...)` blocks (lines 344-782, read directly).
- `--rmats false --dexseq_exon false --edger_exon false --dexseq_dtu false --sashimi_plot false`
  — set explicitly and redundantly with the point above, so the stocked configuration is
  self-documenting rather than relying on a structural side-effect of `--skip_alignment` that a
  future revision could change without warning.
- `--pseudo_aligner salmon` (default, kept) — Salmon quantification, the only input SUPPA2 needs.
- `--suppa true` (default, kept) — SUPPA2: event/isoform generation, per-event and per-isoform
  PSI, differential splicing (dPSI + significance) between contrast conditions. This is the
  splicing-detection core this procurement exercises.
- `--clusterevents_local_event false --clusterevents_isoform false` — SUPPA's DBSCAN clustering
  of significant events, default `true`. Disabled after a **real, reproducible failure**: on the
  nf-core CI test fixture (chrX toy dataset, 4-sample / 2-condition GBR-vs-YRI design), `CLUSTEREVENTS_IOI`/`_IOE`
  produce "Number of clustered events: 0/N ... Impossible to calculate silhouette score. Only 1
  cluster group identified." and then Nextflow reports a missing `*.clustvec` output file,
  failing the whole run (`completed=42 failed=4` before this flag was added; `completed=34
  failed=0` after — see Preflight below). This is a real edge-case bug in `suppa.py
  clusterEvents` when zero events survive the significance threshold on a small/sparse-signal
  dataset, not a stub artifact. Clustering is a downstream convenience layer on top of the PSI/
  dPSI numbers, not part of core detection, so it is out of scope rather than something to chase.
  Flagged here and in `config/pipelines.tsv`; **not fixed upstream, not worked around** — a
  dataset with more significant events might not hit this at all, but nothing this procurement
  ships depends on clustering succeeding.

Out of scope for this procurement, and why: **rMATS** (junction-read-based, needs STAR BAMs, a
separate detection method from SUPPA2 — redundant for "does splicing detection work at all"),
**DEXSeq DEU / edgeR DEU** (exon-usage counting, also needs STAR BAMs and htseq counting — a
second, heavier redundant method), **DEXSeq DTU** (differential transcript usage via DRIMSeq
filtering — Salmon-based, does not need STAR, but is a second statistical method beyond SUPPA2's
own DTU-equivalent `psiPerIsoform`/`diffSplice --isoform`, which SUPPA2 already covers),
**Miso sashimi plots** (visualization only, needs STAR BAMs).

## Intake

1. **Data.** Reused, not re-fetched: `/work/rawdata/20260807-rnaseq-scer-gln3-ibutanol-prep/`
   (ext4), 8 samples / 16 FASTQ files, 1.5 GB total, already on disk from
   `runs/20260807-rnaseq-scer-gln3-ibutanol`. No new download.
2. **Format/layout.** Paired-end Illumina FASTQ, gzipped, one pair per sample, ~75 bp/mate.
3. **Organism/build.** *Saccharomyces cerevisiae*, `R64-1-1` (Ensembl release-116 fasta +
   annotation build 63), already in `config/refs.manifest.tsv`, fasta+gtf both `OK`.
4. **Assay.** Bulk polyA RNA-seq. **Strandedness: `reverse`** for all 8 samples — not `auto`
   (rnasplice's samplesheet checker rejects `auto` outright, see `samplesheets.md`) — taken from
   the MEASURED value in `runs/20260807-rnaseq-scer-gln3-ibutanol/handoff.md` ("Strandedness:
   `auto` resolved to `reverse` for all 8, RSeQC and Salmon agree"), not re-inferred. This is a
   calibration from an equivalent prior run on the identical FASTQ files, not a guess.
5. **Actual question.** Does nf-core/rnasplice 1.0.4 run end to end, through the scoped
   SUPPA2-only path, on real paired-end data, with a real 2-condition contrast, producing
   measurable PSI/dPSI numbers. No biological interpretation of the isobutanol/`gln3Δ` splicing
   response is performed or implied.
6. **Design.** Reusing the prior run's 2×2 factorial (WT/`gln3Δ` × untreated/isobutanol × 2
   reps), but rnasplice's samplesheet uses a single `condition` column, not two factors — so this
   run treats the 2×2 as **4 conditions × 2 replicates**: `WT_ctrl`, `WT_ibuoh`, `gln3_ctrl`,
   `gln3_ibuoh`. One contrast: `WT_ibuoh` vs `WT_ctrl` (isobutanol response in wild type) — the
   lightest single comparison that exercises `SUPPA_SALMON:DIFFSPLICE_IOE`/`DIFFSPLICE_IOI`.
   n=2 per condition is the pipeline's own hard floor (see samplesheet note below) and is below
   the ≥3 the skill flags for a DE analysis I'd stand behind — noted, not hidden.
7. **Wall-clock tolerance.** CI-fixture measured run was ~4.5 min. This run is ~4× the samples,
   larger reads, no STAR (skipped) — estimated well under 1 h. Not a 24 h decision.
8. **What already exists.** FASTQ on disk (point 1). R64-1-1 fasta/gtf in the reference store.
   R64-1-1's STAR/Salmon indexes under `genomes/R64-1-1/index/{star,salmon}/` were built by
   `nf-core/rnaseq`'s own `PREPARE_GENOME`/`SALMON_INDEX`, which is a **different, unverified**
   transcript-fasta extraction path than rnasplice's own `GTF_GENE_FILTER` →
   `RSEM_PREPAREREFERENCE` → `SALMON_INDEX` chain. **Deliberately not reused** — pointing
   `--salmon_index` at rnaseq's index would assume format/decoy compatibility I have not
   verified, and the genome is 12 Mb (index builds in well under a minute), so there is no real
   cost to letting rnasplice build its own. rnasplice's build is NOT promoted into
   `config/refs.manifest.tsv` as a reusable standard path for this same reason — it is
   pipeline-specific, and mixing it up with rnaseq's index in a shared manifest row would be the
   exact mistake this note exists to avoid.
9. **Outputs.** `/work/nxf/20260814-rnasplice-scer-gln3-ibutanol/results/` (ext4), then rsynced
   to this run record per `runbook.md` §8.

## Reference store

`genomes/R64-1-1/fasta/genome.fa` OK. `genomes/R64-1-1/gtf/genes.gtf.gz` OK. No new manifest
rows needed — full reuse of the existing R64-1-1 entries, `--fasta`/`--gtf` form (not the
compact `--genome` alias, which is not defined for R64-1-1 in `config/genomes.config` anyway).

## Estimate

Anchor: this procurement's own CI-fixture run (`-profile test,docker`, this exact flag set,
4 samples, chrX toy genome): **4m34s wall** (21:22:44→21:27:12), work dir **1.3 GB**, results
**44 MB**, `completed=34 failed=0`.

This run: 8 samples (2×), real yeast genome (12 Mb vs toy ~2 Mb chrX slice, both trivial), ~1.5 GB
input FASTQ vs the CI fixture's few-MB toy reads. No STAR, no rMATS/DEXSeq/edgeR/sashimi in
either run (same scope). Salmon index build is the one genuinely bigger step (real annotation vs
toy).

- **Wall clock: 10-20 min.** Not a 24 h decision.
- **Peak disk: ~8 GB** on `/work` (Salmon indexes + per-sample quant dirs + trimmed FASTQ;
  no STAR BAMs to dominate the work dir this time, unlike the rnaseq run on the same data).
  Preflight invoked with `12` for the 1.5× gate → demands 18 GB free. `/` (ext4) has 187 GB free.
- **Cores/RAM: this host's actual pool is 16 cores / 18 GB** (`config/host.env`:
  `BIOINFO_MAX_CPUS=16 BIOINFO_MAX_MEMORY=18.GB` — this machine's `host.env` differs from the
  52 GB/40 GB figures the skill's generic environment section assumes; `host.env` is
  authoritative). Every task on a 12 Mb genome runs far below that ceiling regardless.

## Bounded choices

1. **Scope**: SUPPA2-only splicing detection (`--skip_alignment true`, rMATS/DEXSeq/edgeR/sashimi
   off, clustering off). Documented above and in `config/pipelines.tsv`. Undo: drop all six
   flags to get the pipeline's real (kitchen-sink) default.
2. **Strandedness fixed at `reverse`** for all 8 samples, taken from the prior rnaseq run's
   measured RSeQC/Salmon-agreement result, not re-inferred and not `auto` (which this pipeline's
   samplesheet checker rejects). Undo: none needed, this is a measured fact about the data.
3. **Single contrast**: `WT_ibuoh` vs `WT_ctrl`. The other 5 possible pairwise contrasts among
   the 4 conditions are not run. Undo: add rows to `contrasts.csv`.
4. **rnasplice builds its own Salmon/STAR-independent index rather than reusing rnaseq's
   R64-1-1 Salmon index** — described under Intake point 8. Undo: none needed, this is the safer
   default; reusing rnaseq's index would need its own verification pass first.
5. **8 of 8 samples used.** Nothing excluded, nothing subsampled.

## Real-run finding — added mid-run, 2026-08-14 (not known at plan-approval time)

The real (non-CI-fixture) launch hung for real: `SUPPA_SALMON:GENERATE_EVENTS_IOE` reached
"Done" in its own log (all 6 per-event-type `.ioe`/`.gtf` files written, `RI`/`SE`/`SS`/`MX`/
`AF`/`AL` all present but **header-only, zero rows** — yeast's local-splicing-event rate against
this annotation is essentially nil), then the process's SECOND shell command —
`modules/local/suppa_generateevents.nf`'s `awk 'FNR==1 && NR!=1 { while (/^seqname/) getline; }
1 {print}' *.ioe > events.ioe`, which strips repeated headers when concatenating the six
per-type files — spun at 99% CPU for 53 real minutes and never returned. Root cause: awk's
`getline` returns 0 at EOF without changing `$0`, so if a file's *only* line is the header being
matched, `while (/^seqname/) getline` never becomes false once it hits EOF — an unconditional
infinite loop, not merely slow. Killed the container by hand (`docker kill`), then reproduced
the identical hang in 5 seconds flat on two synthetic two-line (header-only) `.ioe` files outside
the pipeline entirely, confirming it is a real, deterministic awk bug in the pipeline's own
script, triggered whenever every event of some type is absent — not a fluke of this run's data,
not a stub/container artifact. Nextflow's own error-retry then relaunched the identical task
(deterministic input ⇒ deterministic re-hang), so the whole tmux session and its nextflow
process were killed and restarted rather than left to loop again.

**Fix applied**: `suppa_per_local_event: false` added to `params.yaml`, which structurally skips
`GENERATE_EVENTS_IOE` (gated by `if (suppa_per_local_event)` in `subworkflows/local/suppa.nf`,
confirmed by reading it) and everything downstream of it. The per-isoform SUPPA branch
(`GENERATE_EVENTS_IOI` → `DIFFSPLICE_IOI`, transcript-level PSI/dPSI) is unaffected and had
already completed successfully before this was found — its cached results carry over via
`-resume`. **This narrows the stocked scope further than planned above**: this procurement now
ships per-isoform (transcript-level) SUPPA2 splicing detection only, not per-local-event
(exon/intron-level SE/SS/MX/RI/AF/AL) detection, for organisms/annotations sparse enough to hit
this bug. Documented in `config/pipelines.tsv` as a real (not stub-only) finding, distinct from
the earlier `-stub-run`/CI-fixture waivers.

## Gates before launch

1. `bash bin/preflight.sh <rundir> 12`
2. `bash scripts/check-samplesheet.sh --deep --pipeline rnasplice samplesheet.csv` — already run
   during planning, PASS.
3. `-preview`, then `-stub-run` on the real command — both already run during pipeline
   evaluation (§2.4) on constructed test sheets against R64-1-1, not yet on the final
   samplesheet/contrasts pair; re-run on the real inputs before the real launch as the actual
   gate.
4. Launch via the mandatory `tmux` recipe, `references/runbook.md` §5.

## Approval

The task instruction that created this procurement explicitly authorizes autonomous execution of
ordinary procurement decisions (dataset choice, flag choices, doc content) without a check-in.
Nothing here crosses a rule that requires the user personally: no >24 h job, no new download at
all (data reused from disk), no sample exclusion, no design decision beyond what is stated above,
no writes outside `$BIOINFO_HOME`/`$BIOINFO_REFS`/`$BIOINFO_WORK`.
