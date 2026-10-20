# ampliseq

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** [Exact stub conditions](stubs/ampliseq.md) — read before Step 4; match every predicate.
- **Evidence lookup:** [procurement record](evidence/ampliseq.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** 16S/18S rRNA or ITS amplicon sequencing → primer trimming (cutadapt), denoising into ASVs
(DADA2), dual taxonomic classification (DADA2 + QIIME2), alpha/beta diversity (Shannon, Faith's
PD, observed features; Bray-Curtis, Jaccard, weighted/unweighted UniFrac; PCoA + PERMANOVA via
`QIIME2_DIVERSITY_ADONIS`), phyloseq/TreeSummarizedExperiment export.

**Not for:** shotgun metagenomics (no assembly, no functional profiling, no primer trimming
of amplicon reads — that is `nf-core/mag` for assembly+binning, `references/pipelines/mag.md`, or
`nf-core/taxprofiler` for read-level taxonomic profiling without assembly, `references/pipelines/taxprofiler.md`). Not for
downstream community-composition
statistics beyond what QIIME2's own diversity module computes — modeling, ordination beyond PCoA,
and cross-study comparison are the user's work.

**Minimum input:** `--input samplesheet.csv` — `assets/schema_input.json` accepts two forms:
`sampleID`+`forwardReads`(+`reverseReads`), or `sample`+`fastq_1`(+`fastq_2`); reverse read
optional for single-end amplicon designs. `scripts/check-samplesheet.sh --pipeline ampliseq`
validates both forms.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--FW_primer` / `--RV_primer` | assay-specific (e.g. 515F/806R for V4 16S) | wrong primer = cutadapt discards nearly everything at the trimming step |
| `--trunclenf` / `--trunclenr` | read-length- and quality-profile-specific | DADA2 truncation length; too short loses taxonomic resolution, too long keeps low-quality tail bases that inflate the error model |
| `--dada_ref_taxonomy` / `--qiime_ref_taxonomy` | e.g. `gtdb=R07-RS207`, `greengenes85` | nf-core-curated names, not raw URLs; the `PREPTAX` subworkflow resolves and downloads these itself |
| `--ref_taxonomy_storage` | `/refs/ampliseq/tax-db` on this host | persistent cache across runs — without it, every run re-downloads the taxonomy DB |
| `--metadata` | a metadata TSV, `sampleID` (or `sample`) plus grouping columns | required for the diversity/PERMANOVA branch; without it `QIIME2_DIVERSITY_ADONIS` is skipped entirely |

**Reference-store paths:**

```
$BIOINFO_REFS/ampliseq/tax-db/    fetch mode — the pipeline's own PREPTAX subworkflow populates
                                   this, not bootstrap/04-refs.sh (same as every other fetch row,
                                   the manifest only reports presence)
```

Set `--ref_taxonomy_storage /refs/ampliseq/tax-db` so the download is paid once, not every run.

**Known gap:** `-stub-run` crashes at `CUTADAPT_BASIC` on an upstream nf-core/modules bug — see
`references/runbook.md` §4, 4th documented stub departure. `-preview` is the only pre-launch gate.

**Key outputs:** ASV table + representative sequences, dual taxonomy assignments, alpha/beta
diversity artifacts (`.qza`/`.qzv`), phyloseq/TreeSummarizedExperiment RDS, `overall_summary.tsv`
(per-sample read attrition through every filtering stage), MultiQC.

**QC verdict checklist:** per-sample read retention through cutadapt → DADA2 filtering → merging →
chimera removal → length/SSU filtering → taxonomy filtering (`overall_summary.tsv` has all of it);
diversity/PERMANOVA completion for each grouping variable in `--metadata`. **No real-sample QC
band exists yet** — `references/qc-interpretation.md` has no §3.7 for amplicon. Two runs exist so
far: the 4-sample CI fixture (`runs/20260810-ampliseq-testprofile-procurement/`) and one real,
ungrouped clinical sample (`runs/20260811-ampliseq-drr033717-realsample/`, DRR033717, cutadapt
56.1% pass). Neither establishes a band on its own — the CI fixture isn't real data, and one
ungrouped sample has no cohort to set a range against, and never exercised the diversity/
PERMANOVA branch at all (`--metadata` needs ≥2 samples). Report retention percentages as
measurements, not against a threshold, until a real **multi-sample** run with `--metadata` does
that work.
