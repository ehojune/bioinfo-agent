# differentialabundance

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** [Exact stub conditions](stubs/differentialabundance.md) — read before Step 4; match every predicate.
- **Evidence lookup:** [procurement record](evidence/differentialabundance.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** taking a feature × sample count matrix plus a sample metadata table plus a contrast
definition, and producing DESeq2 (or limma) results tables, normalised matrices, QC/exploratory
plots, a self-contained HTML report, and optionally a ShinyNGS app bundle.

**Not for:** producing counts. Not for anything with fewer than two replicates per group
([selection boundaries](../selection-boundaries.md)).
Not for single-cell differential expression — the model is wrong for that data. Not for GSEA
beyond the GSEA module it wraps; pathway interpretation is the user's job.

**Minimum input** — three files:

1. `--matrix` — the **raw** count matrix, `star_salmon/salmon.merged.gene_counts.tsv`, paired with
   `--transcript_length_matrix star_salmon/salmon.merged.gene_lengths.tsv`. **Resolved 2026-08-10**
   (run `20260810-differentialabundance-gln3-ibutanol`, first run of this pipeline on this host):
   confirmed against the pipeline's own `conf/test.config`, which exercises exactly this pair in
   CI, and against `workflows/differentialabundance.nf`'s `ch_transcript_lengths` channel, which
   feeds `DESEQ2_NORM`/`DESEQ2_DIFFERENTIAL` directly. Do **not** substitute
   `salmon.merged.gene_counts_length_scaled.tsv` for the raw matrix — that is a different,
   untested input shape; the raw-matrix-plus-length-matrix pair is the one this pipeline's own
   test suite runs. See `references/samplesheets.md`'s differentialabundance section for detail.
2. `--input` — observations/samplesheet CSV. Must contain one row per matrix **column**, with a
   sample-id column matching the matrix header exactly, plus the condition columns you will
   contrast on. The rnaseq samplesheet works as a base; add the metadata columns.
3. `--contrasts` — contrasts CSV:

| column | meaning |
|---|---|
| `id` | name for this comparison, used in output filenames |
| `variable` | column in the observations file |
| `reference` | the level treated as baseline (denominator) |
| `target` | the level compared against it (numerator) |
| `blocking` | optional; covariates to include in the design, e.g. `batch` |

A `target` vs `reference` fold change is read as "target relative to reference". Get this backwards
and every sign in the report is inverted.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `-profile docker,rnaseq` | | the `rnaseq` profile sets the matrix/feature defaults for count data |
| `--gtf` | store path | supplies gene symbols and biotypes; without it results are bare Ensembl IDs |
| `--study_name` | short slug | ends up all over the report |
| `--differential_min_fold_change` / `--differential_max_qval` | | thresholds used for the report's called-significant sets, not for the underlying stats |
| `--shinyngs_build_app` | off unless asked | it is a large extra output |

**Reference-store paths:**

```
$BIOINFO_REFS/genomes/GRCh38/gtf/genes.gtf.gz    annotation only; no FASTA, no index
```

**Key outputs**, confirmed on disk at 1.5.0 (`20260810-differentialabundance-gln3-ibutanol`):
`tables/differential/<contrast_id>.deseq2.results.tsv` (full) and
`tables/differential/<contrast_id>.deseq2.results_filtered.tsv` (post `--differential_min_fold_change`/
`--differential_max_qval`, one per contrast), `tables/processed_abundance/all.{normalised_counts,vst}.tsv`,
`tables/annotation/genes.anno.tsv`, `plots/{qc,exploratory,differential}/`, `other/deseq2/` (size
factors, `.rds` objects), and `report/<study_name>.html` (self-contained, plus a `.zip` bundle) —
**no MultiQC**, confirmed by `qc-interpretation.md` §1.

**QC verdict checklist:** does the PCA separate by the contrast variable or by a nuisance variable;
is the dispersion fit sane; how many genes pass independent filtering; is the p-value histogram
flat-with-a-spike (good) or U-shaped/humped (model misspecified).
