# mag

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** [Exact stub conditions](stubs/mag.md) — read before Step 4; match every predicate.
- **Evidence lookup:** [procurement record](evidence/mag.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** shotgun metagenome sequencing (short-read Illumina, long-read ONT/PacBio, or hybrid)
→ read QC/host removal → assembly (MEGAHIT and/or SPAdes for short reads; Flye/MetaMDBG for
long reads) → binning (MetaBAT2, MaxBin2, CONCOCT, SemiBin2, COMEBin, MetaBinner — pick a
subset, see below) → bin QC (BUSCO/CheckM/CheckM2/GUNC) → taxonomic classification of bins
(GTDB-Tk) and/or contigs (CAT/BAT via CAT_pack, geNomad for viral) → per-bin gene
prediction/annotation (Prodigal, Prokka).

**Not for:** amplicon sequencing (that is `nf-core/ampliseq`, `references/pipelines/ampliseq.md` — no primer trimming or
ASV/OTU calling here). Not for read-level taxonomic profiling without assembly, binning, or
MAGs (that is `nf-core/taxprofiler`, `references/pipelines/taxprofiler.md` — lighter-weight, and the right choice when the
question is "what taxa and how much of each", not "recover genomes"). Assembly and binning
are compute- and disk-heavy
relative to the other stocked pipelines — a single real short-read sample with genuine
community diversity should be expected to need far more wall clock and disk than
`references/estimates.md`'s current row shows, which is a **floor** measurement from an
unusually shallow real sample (see below), not a typical case.

**Minimum input:** `--input samplesheet.csv` — `assets/schema_input.json` requires
`sample`+`group` on every row, plus `short_reads_1` and/or `long_reads` per row (with
`short_reads_platform`/`long_reads_platform` required alongside whichever read type is
present — all four constraints are **per-row**, not per-sheet; see
`references/samplesheets.md`'s mag section for the empirical confirmation).
`scripts/check-samplesheet.sh --pipeline mag` validates the required columns, the per-row
dependent-required constraints, and the `sample`+`run` composite-key uniqueness.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--skip_gtdbtk` | `true` unless the user explicitly wants GTDB-Tk and approves the download | the pipeline's *default* `--gtdb_db` is a measured 60.8 GB tarball (`curl -sI` on the default URL) — an unapproved download well over this repo's ~10 GB no-ask threshold |
| `--skip_spades` / `--skip_megahit` | pick at least one; both run by default | running both assemblers roughly doubles assembly wall clock for a comparison this repo's validation runs have not needed |
| `--skip_concoct` / `--skip_comebin` / `--skip_metabinner` | bound the binner set for a time-conscious run | the pipeline's own `conf/test.config` disables these three in CI for exactly this reason; mirror that discipline for a real run unless the user wants the full binner comparison |
| `--busco_db_lineage` | `auto` (default) unless reproducibility across runs matters | auto-selection downloads its own dataset per run rather than reusing a pinned one |
| `--host_fasta` / `--host_genome` | only if the sample has host contamination to remove (e.g. human gut metagenome) | off by default; phiX removal is separately on by default and uses a bundled reference, no download needed |

**Reference-store paths:** none required for a default run — phiX removal uses a reference
bundled in the pipeline's own `assets/`. If the user later wants GTDB-Tk, CheckM, or a
pinned BUSCO lineage reused across runs, those become `fetch`-mode `config/refs.manifest.tsv`
rows at that point (none added by this procurement — no run so far has needed one).

**Known gaps, both read directly from the pinned clone's source, not guessed:**

- `-stub-run` fails at `CATPACK_DB_UNTAR`/`BUSCO_UNTAR` — an upstream-in-mag module patch
  (`modules/nf-core/untar/untar.diff`) that updates the `script:` block's output variable but
  not the `stub:` block. Only fires when a `.tar.gz` reference DB is supplied (CAT/BUSCO/
  CheckM/geNomad); the test profile does this deliberately for small fixture DBs, a default
  real run does not. **5th documented departure**, `references/runbook.md` §4.
- Separately, and more consequentially: **20 of mag's 23 local modules carry no `stub:`
  block at all**, including the ones that actually run the phiX/host-removal Bowtie2 step and
  the binning-prep mapping/QUAST steps. Under Nextflow's no-stub fallback, these run their
  real `script:` against upstream stub placeholders and crash for real, in a chain that no
  finite set of stub-only substitutions clears. `-preview` is the pre-launch gate that
  actually works past `SHORTREAD_PREPROCESSING`; the real command is what proves the rest.
  See `runs/20260812-mag-drr027580-realsample/plan.md` for the full evidence chain.

**Key outputs:** per-sample/per-assembler contigs (`Assembly/`), per-binner bins
(`GenomeBinning/<binner>/bins/`), bin depth/coverage summaries, bin QC reports (BUSCO/CheckM
TSVs when enabled), GTDB-Tk/CAT taxonomy assignments when enabled, Prokka/Prodigal
annotations per bin, MultiQC.

**QC verdict checklist:** contig count and N50/length distribution from QUAST; bin count per
binner and per-bin completeness/contamination from whichever of BUSCO/CheckM/CheckM2 was
enabled; **zero bins is a legitimate, silent-looking outcome** — the pipeline exits 0 whether
or not any binner found anything to bin, so check `GenomeBinning/*/bins/` is non-empty before
reporting a run as having produced MAGs. **No formal QC band exists yet** — one real run so
far (`runs/20260812-mag-drr027580-realsample/`, DRR027580, 436K read pairs, 74 contigs all
< 1500 bp, zero bins from any binner) establishes only that the pipeline runs correctly on
real data end to end; it does not establish what a normal contig-count/bin-count range looks
like, because the sample itself was too shallow to bin. A real run against an actual
higher-diversity metagenome is what would start that band.
