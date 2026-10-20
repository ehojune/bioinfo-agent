# Selection boundaries and ambiguity

Read when two routes fit, an assay is unsupported, or the requested endpoint exceeds a pipeline.

## 7. This is the wrong tool

The mis-selections that actually happen, and what to do instead.

| Wrong choice | Why it is wrong | Instead |
|---|---|---|
| **sarek, when the question is expression** | "Find what is different between these samples" with RNA input is a quantification problem, not a variant problem. Sarek will happily align RNA reads with bwa and produce a garbage call set | rnaseq → differentialabundance |
| **rnaseq for 3'-tag / QuantSeq / Lexogen libraries** | The library has one fragment per transcript at the 3' end. Salmon/RSEM effective-length correction assumes full-length coverage, so TPM and length-scaled counts are systematically wrong | Use rnaseq for alignment and QC only; discard the TPM outputs; count per gene with featureCounts and do **no** length normalisation. Or skip the pipeline. Either way, say which you did |
| **rnaseq for single-cell FASTQ** | No barcode or UMI demultiplexing; you get one "sample" that is a pool of thousands of cells | scrnaseq |
| **scrnaseq for single-**nucleus** without adjusting** | Nuclear RNA is intron-dominated. Exon-only counting throws away most reads and produces implausibly low genes-per-cell | scrnaseq with `--aligner star --star_feature GeneFull` (or Cell Ranger with introns included) |
| **atacseq for footprinting** | The pipeline has no footprinting step at all. It gives peaks, not TF occupancy | atacseq for peaks and filtered BAMs, then TOBIAS/HINT-ATAC separately. Tell the user this is a second, unstocked stage |
| **atacseq or chipseq expecting a finished differential analysis** | The DESeq2 step in these pipelines is exploratory QC, not a contrast-driven test | Take the consensus count matrix onward (§5.4), or hand it to the user |
| **chipseq for CUT&RUN/CUT&Tag** | It will run and produce peaks. You lose spike-in normalisation, SEACR, and the low-background assumptions CUT&RUN peak calling relies on | cutandrun |
| **cutandrun with `--normalisation_mode Spikein` and no spike-in** | Scale factors computed from a handful of stray E. coli reads. Silently wrong, not an error | `CPM`, and say the data has no spike-in |
| **differentialabundance without replicates** | DESeq2 cannot estimate dispersion from n=1 per group. Minimum is 2; 3 is the working minimum for anything you would write up | Refuse to produce p-values. Report fold changes only, labelled as descriptive, and tell the user the design does not support inference |
| **differentialabundance on TPM** | The model expects counts. TPM violates its assumptions | `salmon.merged.gene_counts.tsv` |
| **methylseq with `bismark` on 30× human WGBS** | Not wrong, but it will run for days on this box | `--aligner bwameth` |
| **RRBS without `--rrbs`** | Deduplication is applied, and RRBS fragments are duplicates by construction. Most of the library is discarded | `--rrbs` |
| **sarek `--genome GATK.GRCh38`** | Bypasses the reference store, triggers a large iGenomes download, and hardcodes a name that is not the store's | `--genome null` plus explicit store paths |
| **Any pipeline with `--work-dir` on /mnt/d** | 5–10× slower, and Windows filesystem semantics break some staging | ext4, always |
| **WES without `--wes --intervals`** | Coverage QC is computed genome-wide over a capture library. Every metric is meaningless | Get the capture BED from the user. If they cannot supply it, say the QC will be unreliable |

## 8. Ambiguity protocol

Before choosing, the technician must be able to answer all of these. If any is unknown, **ask
before running**, not after.

**Always:**

1. Organism and genome build. Is hg38 acceptable, or is there a reason to use KOREF1?
2. Library kit and chemistry, by name. This determines strandedness, UMI handling, adapter
   trimming, and clipping. "RNA-seq" is not a kit name.
3. Read layout: single or paired, read length, and whether samples span multiple lanes or runs
   that must be merged.
4. Experimental design: groups, n per group, and any batch/covariate structure. A design with n=1
   per group changes what is deliverable.
5. The actual deliverable. A count matrix, a statistics table, a VCF, a peak set, or a BAM for
   something downstream — these are four different endpoints.
6. Time and disk budget, and where the outputs must ultimately live.

**Assay-specific:**

- RNA-seq: poly-A, ribo-depleted, or 3'-tag? Total RNA including small RNA?
- WGS/WES: exome capture BED? Tumour–normal pairing? Sample sex? Related individuals (joint
  calling)? Is a panel of normals available?
- Methylation: WGBS, RRBS, EM-seq, or PBAT? Conversion spike-in present?
- ChIP/CUT&RUN: which target? Narrow or broad mark? Input/IgG control present? Spike-in?
- Single-cell: cells or nuclei? Which 10x chemistry version? Expected cell count? Hashing or
  CITE-seq features in the same library?

**When two pipelines are both defensible, ask rather than choose:**

| Ambiguity | The question that resolves it |
|---|---|
| rnaseq vs scrnaseq | Droplet/plate single-cell, or bulk? Smart-seq2 plate data is often better through rnaseq |
| chipseq vs cutandrun | Which protocol was actually run at the bench, and is there a spike-in? |
| sarek germline vs a rare-disease pipeline | Is this a research cohort or a diagnostic-style single-family analysis with ranking and repeat expansions? |
| methylseq `bismark` vs `bwameth` | Is the priority runtime or matching a previously published bismark-based analysis? |
| differentialabundance vs handing over the matrix | Does the user want the pipeline's DESeq2 defaults, or do they intend to model it themselves? |
| GRCh38 vs GRCh38gatk | Expression/chromatin → GRCh38. Variant calling → GRCh38gatk. If a downstream catalog or cohort forces a build, that wins |
| Full ExpansionHunter catalog vs disease subset | Screening known pathogenic loci, or genome-wide discovery? Runtime differs by more than an order of magnitude |

**Escalate rather than proceed when:** the estimate exceeds 24 h; free disk is below 1.5× the
estimate; a required reference is in `fetch` mode and absent; the design has no replication; or the
request implies a biological interpretation rather than a QC verdict.

## 10. Handoff

Whatever was selected and run, the handoff says exactly this and nothing more:

1. Pipeline, revision, and the full command as executed.
2. Where the outputs are, and which specific files a downstream step should read.
3. The QC verdict: per-metric numbers, and pass / marginal / fail per sample. No biology.
4. Every bounded choice made along the way — top-N cutoffs, `--min_reps_consensus`, catalog subset,
   samples skipped, dedup on or off, which count matrix was passed onward.
5. What is still missing or was not run, and what it would cost.

Interpreting what the results mean biologically is the user's job. Saying "sample 4 has 38% mito
reads and a TSS enrichment of 3.1, which is below the usual threshold" is the technician's job.
Saying "therefore this condition has more open chromatin" is not.
