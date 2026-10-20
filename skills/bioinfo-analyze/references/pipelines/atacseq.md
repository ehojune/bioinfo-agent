# atacseq

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** No registered stub waiver. Preview and the full-command stub must pass; missing upstream stubs can execute real work.
- **Evidence lookup:** [procurement record](evidence/atacseq.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** ATAC-seq → filtered alignments, per-sample and consensus peak sets, a consensus-peak count
matrix, bigWigs, and ATAC-specific QC (fragment-size distribution, TSS enrichment, mitochondrial
fraction) via ataqv.

**Not for:** **footprinting.** There is no TOBIAS/HINT-ATAC step. Not for motif enrichment
(peak *annotation* via HOMER is not motif discovery). Not for a finished differential-accessibility
analysis — it runs a DESeq2 *QC* step (PCA and sample clustering), not a contrast-driven DA
analysis. Not for single-cell ATAC.

**Minimum input:** `--input samplesheet.csv` — columns in `references/samplesheets.md`.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--aligner` | `bowtie2` | the ATAC convention. **Confirmed 2026-08-05 (atacseq 2.1.2): the pipeline's own default is `bwa`, not `bowtie2`** — this is a bounded choice you make explicitly, not the tool defaulting your way. `chromap` is much faster if you accept its filtering behaviour |
| `--read_length` | actual read length | selects the matching index/mappability settings |
| `--macs_gsize` | `2700000000` for human — **plain decimal, not `2.7e9`** | wrong gsize silently distorts every peak call. Confirmed 2026-08-05 (atacseq 2.1.2): nf-schema's number-type validation rejects scientific-notation CLI strings outright (`expected type: Number, found: String (2.7e9)`), which fails the run before anything executes — not a silent distortion this time, but still worth getting right on the first `-stub-run` rather than the second |
| `--blacklist` | ENCODE hg38 blacklist v2 | confirmed bundled at `assets/blacklists/v2.0/hg38-blacklist.v2.bed` (atacseq 2.1.2); byte-identical to the store's own `genomes/GRCh38/bed/blacklist.bed` (added 2026-08-05, see [reference history](evidence/reference-store-history.md)) — not having one leaves a ring of artefact peaks |
| `--mito_name` | `chrM` | must match the FASTA. UCSC hg38 uses `chrM`. Getting this wrong means mito reads are never removed and the library looks far better than it is |
| `--min_reps_consensus` | 1 or 2 | how many replicates a peak must appear in to enter the consensus set. **This is a bounded choice — state it in the handoff** |

**Reference-store paths:**

```
$BIOINFO_REFS/genomes/GRCh38/fasta/genome.fa
$BIOINFO_REFS/genomes/GRCh38/gtf/genes.gtf.gz
$BIOINFO_REFS/genomes/GRCh38/index/bowtie2/      manifest row present (build mode) — index itself absent until a --save_reference run builds it
$BIOINFO_REFS/genomes/GRCh38/bed/blacklist.bed   recorded 2026-08-05; verify current manifest dry-run
```

**Key outputs:** `<aligner>/merged_library/macs2/narrow_peak/` per-sample peaks, the consensus peak
BED and SAF, the featureCounts consensus count matrix (**this is the matrix that feeds
differentialabundance**), bigWigs, deepTools plots, ataqv HTML, MultiQC.

**QC verdict checklist:** TSS enrichment score, fraction of reads in peaks, mitochondrial read
fraction, nucleosomal laddering in the fragment-size histogram, library complexity, and peak counts
consistent across replicates. Bands: `references/qc-interpretation.md` §3.4.
