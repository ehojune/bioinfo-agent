# scrnaseq

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** No registered stub waiver. Preview and the full-command stub must pass; missing upstream stubs can execute real work.
- **Evidence lookup:** [procurement record](evidence/scrnaseq.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** droplet and plate single-cell RNA → cell × gene count matrices in MTX and `.h5ad`, with
per-sample QC. Supports alevin/simpleaf, kallisto|bustools, STARsolo, and Cell Ranger.

**Not for:** downstream single-cell analysis — no clustering, no annotation, no integration, no DE.
That is the user's scanpy/Seurat work and it starts where this pipeline stops. Not for spatial. Not
for single-cell ATAC or multiome (different pipelines). Not for Smart-seq2 plate data without
thought — that data is bulk-like per well and `nf-core/rnaseq` is often the better fit.

**Minimum input:** `--input samplesheet.csv` — columns in `references/samplesheets.md`. For 10x the
barcode read is `fastq_1` and the cDNA read is `fastq_2`; get this backwards and you get near-zero
cells with no obvious error.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--aligner` | `star` (STARsolo) or `simpleaf`/`alevin` | avoids the Cell Ranger licensing/container problem <!-- UNVERIFIED: whether the current revision ships a usable cellranger container or requires the user to build one under the 10x EULA. Check the pipeline's usage docs before promising cellranger. --> |
| `--protocol` | `10XV3` / `10XV2` / `auto` | wrong chemistry = wrong barcode whitelist = no cells |
| `--star_feature` | `GeneFull` for **single-nucleus** | nuclei are intron-dominated; counting exons only discards most of the signal. Read [selection boundaries](../selection-boundaries.md) |
| `--expected_cells` | per sample | affects the emptyDrops/knee cutoff |
| `--skip_emptydrops` | when you want the raw matrix and will filter yourself | |

RAM: STARsolo on a human index needs ~40 GB. One sample at a time on this host.

**Reference-store paths:**

```
$BIOINFO_REFS/genomes/GRCh38/fasta/genome.fa
$BIOINFO_REFS/genomes/GRCh38/gtf/genes.gtf.gz
$BIOINFO_REFS/genomes/GRCh38/index/star/         build mode — shared with rnaseq
```

**Key outputs:** per-sample raw and filtered matrices (MTX triplet), `.h5ad` conversions, per-tool
QC, MultiQC.

**QC verdict checklist:** estimated cells vs expected, median genes and UMIs per cell, fraction of
reads in cells, sequencing saturation, mitochondrial fraction distribution, ambient RNA signal.
Bands: `references/qc-interpretation.md` §3.6. Report these; do not decide which cells are "real"
for the user.
