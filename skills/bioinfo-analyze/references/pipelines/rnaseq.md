# rnaseq

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** [Exact stub conditions](stubs/rnaseq.md) — read before Step 4; match every predicate.
- **Evidence lookup:** [procurement record](evidence/rnaseq.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** bulk RNA-seq from FASTQ to a gene- and transcript-level count matrix, with read trimming,
alignment, quantification, strandedness inference, and a full QC bundle (FastQC, RSeQC, Qualimap,
dupRadar, Preseq, MultiQC).

**Not for:** differential expression (it produces counts, not statistics — chain to
differentialabundance). Not for single-cell. Not for 3'-tag/QuantSeq libraries without the caveats
in [selection boundaries](../selection-boundaries.md). Not for RNA variant calling — it has no GATK RNA path. Not for de novo transcript
assembly; StringTie runs but the pipeline is reference-guided and quantifies against the supplied
GTF.

**Minimum input** — `--input samplesheet.csv`. Columns, strandedness values, and the kit → value
mapping: `references/samplesheets.md`.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--aligner` | `star_salmon` | default; gives BAMs *and* counts. `star_rsem` is slower for no gain here. `hisat2` only if RAM is the binding constraint |
| `--pseudo_aligner` | `salmon` | optional second quantification; cheap once the index exists |
| `--gencode` | set it | **the store's GTF is GENCODE v50.** Without this flag transcript IDs are parsed wrong and salmon/RSEM counts are corrupted |
| `--save_reference` | on the first run | writes the STAR/salmon index into the store so the ~1 h, ~40 GB build happens once |
| `--star_index` / `--salmon_index` | store paths | on every subsequent run |
| `--trimmer` | `fastp` | faster than trim_galore here |
| `--remove_ribo_rna` | only for ribo-depleted libraries with visible rRNA carryover | SortMeRNA is expensive |
| `--with_umi` | only if the kit has UMIs | needs `--umitools_extract_method` / `--umitools_bc_pattern` too |
| `--skip_bigwig` | when nobody will open a browser track | saves real disk |

**Reference-store paths:**

```
$BIOINFO_REFS/genomes/GRCh38/fasta/GRCh38.fa        alias of fasta/genome.fa — NOT the canonical name, see below
$BIOINFO_REFS/genomes/GRCh38/gtf/GRCh38.gtf.gz       alias of gtf/genes.gtf.gz — ditto
$BIOINFO_REFS/genomes/GRCh38/index/star/        (build mode — absent until first --save_reference run)
$BIOINFO_REFS/genomes/GRCh38/index/salmon/      (build mode — same)
$BIOINFO_REFS/genomes/GRCh38/bed/genes.bed      (optional, --gene_bed; RSeQC otherwise derives it)
```

Use `GRCh38`, not `GRCh38gatk`. The GATK analysis set is for variant calling; the GENCODE GTF is
matched to UCSC hg38.

**Pass the alias, not `fasta/genome.fa`/`gtf/genes.gtf.gz` directly.** rnaseq's own
`workflows/rnaseq/main.nf` sets `is_aws_igenome=true` whenever `--fasta`/`--gtf`'s basename is
literally `genome.fa`/`genes.gtf` — which the canonical path always is, by this store's design —
and that routes a fresh-index run onto a STAR-2.6.1d-only legacy path that segfaults outright on
at least one host this repo runs on. `genomes.config`'s `genomes.GRCh38.fasta`/`.gtf` already
point at the alias (`bootstrap/04-refs.sh` maintains it automatically), so `--genome GRCh38` is
safe as documented in `genomes.config` section 2; if you write `--fasta`/`--gtf` out explicitly
instead, use the alias paths above, not the ones this table used to list.

**Key outputs:**

```
<outdir>/star_salmon/salmon.merged.gene_counts.tsv                 raw counts  → differentialabundance
<outdir>/star_salmon/salmon.merged.gene_counts_length_scaled.tsv   tximport length-scaled counts
<outdir>/star_salmon/salmon.merged.gene_tpm.tsv                    TPM — for looking at, not for DESeq2
<outdir>/star_salmon/salmon.merged.gene_counts.rds                 SummarizedExperiment
<outdir>/star_salmon/<sample>/                                     per-sample BAM + index
<outdir>/multiqc/star_salmon/multiqc_report.html                   the QC verdict lives here
```

**QC verdict checklist** (report these; do not interpret the biology): % uniquely mapped, % rRNA,
% duplication and whether dupRadar shows it is expression-dependent, 5'/3' bias from RSeQC,
strandedness agreement between declared and inferred, library size spread, and the PCA in the
MultiQC report showing whether samples group by condition or by batch. Bands:
`references/qc-interpretation.md` §3.1.
