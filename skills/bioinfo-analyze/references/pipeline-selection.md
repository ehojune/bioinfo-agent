# Pipeline selection

Turning "here is my data, here is what I want" into one specific `nextflow run` command.

Read this before writing any samplesheet. The cost of picking the wrong pipeline is not a wasted
command — it is twelve hours of compute and a set of numbers that look plausible and are wrong.

---

## 0. Revision pinning — read this first

**nf-core samplesheet columns and parameter names drift between releases.** Every schema in this
document was written against a specific revision, named in the table below. Treat them as a
starting hypothesis, not truth. Re-derive before the first run of any pipeline you have not run on
this host before:

```bash
# 1. what revisions exist
nextflow info nf-core/<pipeline>

# 2. the parameter surface of the revision you intend to run
nextflow run nf-core/<pipeline> -r <rev> --help
nextflow run nf-core/<pipeline> -r <rev> --help --show_hidden

# 3. the authoritative samplesheet schema (this is the file the pipeline actually validates against)
cat "$NXF_ASSETS/nf-core/<pipeline>/assets/schema_input.json"

# 4. human-readable rendering of both
nf-core pipelines schema docs nf-core/<pipeline>
```

`$NXF_ASSETS` is `$BIOINFO_REFS/cache/nf-assets` on this host, so the clone is on ext4 and
`schema_input.json` is a local read. If the clone is absent, `nextflow pull nf-core/<pipeline>
-r <rev>` first.

| Pipeline | Revision this doc was written against | Confidence |
|---|---|---|
| `nf-core/rnaseq` | 3.14.0 | schema stable across 3.1x |
| `nf-core/differentialabundance` | 1.4.0 | params moved between 1.2 → 1.4 |
| `nf-core/fetchngs` | 1.12.0 | input semantics changed in 1.11/1.12 |
| `nf-core/sarek` | 3.4.0 | per-step schemas stable across 3.x |
| `nf-core/methylseq` | 2.6.0 | 3.0 is a template rewrite — re-derive |
| `nf-core/atacseq` | 2.1.2 | stable |
| `nf-core/chipseq` | 2.0.0 | samplesheet changed 1.x → 2.x |
| `nf-core/cutandrun` | 3.2.2 | stable |
| `nf-core/scrnaseq` | 2.5.1 | aligner-specific params churn |

<!-- UNVERIFIED: these are the newest revisions the author is confident exist. Newer releases are
     likely. Confirm with `nextflow info nf-core/<pipeline>` and prefer the newest release that is
     not a release-candidate. -->

Always pass `-r <rev>` explicitly. A bare `nextflow run nf-core/rnaseq` silently pins to whatever
happens to be cached in `$NXF_ASSETS`, which makes the run unreproducible and makes `-resume`
across days behave unpredictably.

---

## 1. The decision procedure

Answer these four in order. Most selections fall out of the first two.

1. **What molecule was sequenced, and by what assay?** RNA, DNA, bisulfite-converted DNA,
   transposase-fragmented chromatin, immunoprecipitated chromatin, nuclease-released chromatin.
2. **What is the deliverable?** A count matrix. A statistics table. A VCF. A peak set. A BAM for
   something else to consume. This decides whether one pipeline suffices or two must be chained.
3. **Where does the data live?** On disk already, or behind an SRA/ENA/GEO accession.
4. **Is the requested analysis inside the pipeline's ceiling?** See §4 and §6. Many requests are a
   pipeline *plus* downstream work the pipeline does not do.

If step 1 or 2 cannot be answered from what the user said, stop and ask. §7 lists the questions.

---

## 2. Primary decision table

| Data / assay | Analysis goal | Pipeline | Chain |
|---|---|---|---|
| Bulk RNA-seq FASTQ (poly-A or ribo-depleted) | gene/transcript counts, QC | `nf-core/rnaseq` | terminal, or → differentialabundance |
| Bulk RNA-seq FASTQ | differential expression between groups | `nf-core/rnaseq` **then** `nf-core/differentialabundance` | two runs, always |
| Existing count matrix (any origin) | differential expression | `nf-core/differentialabundance` | standalone |
| SRA / ENA / GEO accessions | get the FASTQs + a valid samplesheet | `nf-core/fetchngs` | → rnaseq / atacseq / etc. |
| Germline WGS or WES FASTQ | SNV + indel VCF per sample | `nf-core/sarek` | `--tools haplotypecaller` |
| Germline WGS, multiple related samples | joint-called cohort VCF | `nf-core/sarek` | `--joint_germline` |
| Tumour–normal pairs | somatic SNV/indel/CNV | `nf-core/sarek` | `--tools mutect2,strelka,manta,ascat` |
| Tumour-only | somatic-ish calls | `nf-core/sarek` | `--tools mutect2` + PoN — see §4.4 caveat |
| WGBS / RRBS / EM-seq | per-CpG methylation calls | `nf-core/methylseq` | terminal |
| ATAC-seq | peaks + consensus count matrix | `nf-core/atacseq` | → differentialabundance (see §5.4) |
| ChIP-seq with input control | peaks + consensus counts | `nf-core/chipseq` | → differentialabundance |
| CUT&RUN / CUT&Tag | peaks with spike-in normalisation | `nf-core/cutandrun` | terminal |
| Droplet single-cell RNA (10x, Drop-seq) | cell × gene matrix, h5ad | `nf-core/scrnaseq` | → scanpy/Seurat (user's work) |
| Single-**nucleus** RNA | cell × gene matrix | `nf-core/scrnaseq` **with intron counting** | see §4.9 |
| Short-read STR / repeat expansion | repeat genotypes | **no stocked pipeline** | see §6 |
| PacBio HiFi tandem repeats | TRGT genotypes | **no stocked pipeline** | see §6 |
| Anything else | — | procure on demand | see `references/new-pipeline.md` |

Ties and near-ties are resolved in §7.

---

## 3. Host constraints that shape every invocation

24 logical cores, 63.5 GB RAM, one node, Docker engine inside WSL2. There is no scheduler and no
second machine. Consequences:

- **Resource caps must be set or Nextflow will request more than exists** and processes will queue
  forever or get OOM-killed. Modern nf-core revisions use `process.resourceLimits`; older ones use
  `--max_cpus` / `--max_memory` / `--max_time`. `config/local.config` sets whichever applies —
  always pass `-c "$BIOINFO_HOME/config/local.config"`. Do not hand-tune caps per run.
  <!-- UNVERIFIED: the max_* → resourceLimits cutover landed with the nf-core tools 3.x template.
       Confirm which one your chosen revision honours via `--help --show_hidden`. -->
- **Reserve headroom.** Cap at ~22 cpus / ~56 GB, not 24 / 63.5. Windows, the WSL VM, and Docker
  itself need the remainder, and a hard OOM inside WSL2 can take the whole distro down.
- **`-work-dir` must be on ext4.** Never `/mnt/d`, never `/mnt/c`. drvfs is 5–10× slower and
  Nextflow work directories are the most I/O-hostile thing on the machine. Use a path inside the
  distro; `--outdir` likewise, then copy the finished deliverable out to `/mnt/d` at the end.
- **C: is 74 GB free — never target it for anything.** D: (2.2 TB) and the 955 GB inside the VHDX
  are the real storage.
- **One heavy run at a time.** A STAR index build peaks near 40 GB RAM. Anything else running
  concurrently will lose.
- `-profile docker`. Images cache in `/var/lib/docker`, which is already on the D:-backed VHDX.
- **Never start a job estimated over 24 h without explicit user approval.** Never start when free
  disk is under 1.5× the estimate.

Every command in this document elides the constant preamble:

```bash
export BIOINFO_HOME=/mnt/d/bioinfo
export BIOINFO_REFS=/refs
export NXF_ASSETS="$BIOINFO_REFS/cache/nf-assets"

nextflow run nf-core/<pipeline> -r <rev> \
  -profile docker \
  -c "$BIOINFO_HOME/config/local.config" \
  -work-dir "$WORK" \
  --outdir "$OUT" \
  -resume
```

`-resume` on every invocation after the first. Never delete a work directory — it is the only thing
that makes `-resume` possible.

---

## 4. Per-pipeline reference

Each entry: purpose, non-purpose, minimum input, the parameters that actually matter here, the
reference-store paths consumed, and the outputs a downstream step will read.

### 4.1 `nf-core/rnaseq`

**For:** bulk RNA-seq from FASTQ to a gene- and transcript-level count matrix, with read trimming,
alignment, quantification, strandedness inference, and a full QC bundle (FastQC, RSeQC, Qualimap,
dupRadar, Preseq, MultiQC).

**Not for:** differential expression (it produces counts, not statistics — chain to
differentialabundance). Not for single-cell. Not for 3'-tag/QuantSeq libraries without the caveats
in §5.2. Not for RNA variant calling — it has no GATK RNA path. Not for de novo transcript
assembly; StringTie runs but the pipeline is reference-guided and quantifies against the supplied
GTF.

**Minimum input** — `--input samplesheet.csv`:

| column | notes |
|---|---|
| `sample` | rows sharing a `sample` value are merged as technical replicates / multiple lanes |
| `fastq_1` | required |
| `fastq_2` | empty for single-end |
| `strandedness` | `forward` \| `reverse` \| `unstranded` \| `auto` |

`auto` makes the pipeline infer strandedness with Salmon and flag disagreements in MultiQC. Use it
unless the library kit is documented; then set it explicitly and let `auto`'s check catch a lie.
Typical: Illumina TruSeq Stranded mRNA → `reverse`. Lexogen QuantSeq FWD → `forward`.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--aligner` | `star_salmon` | default; gives BAMs *and* counts. `star_rsem` is slower for no gain here. `hisat2` only if RAM is the binding constraint |
| `--pseudo_aligner` | `salmon` | optional second quantification; cheap once the index exists |
| `--gencode` | set it | **the store's GTF is GENCODE v50.** Without this flag transcript IDs are parsed wrong and salmon/RSEM counts are corrupted |
| `--save_reference` | on the first run | writes the STAR/salmon index into the store so the ~1 h, ~40 GB build happens once |
| `--star_index` / `--salmon_index` | store paths | on every subsequent run |
| `--trimmer` | `fastp` | faster than trim_galore on 22 cores |
| `--remove_ribo_rna` | only for ribo-depleted libraries with visible rRNA carryover | SortMeRNA is expensive |
| `--with_umi` | only if the kit has UMIs | needs `--umitools_extract_method` / `--umitools_bc_pattern` too |
| `--skip_bigwig` | when nobody will open a browser track | saves real disk |

**Reference-store paths:**

```
$BIOINFO_REFS/genomes/GRCh38/fasta/genome.fa
$BIOINFO_REFS/genomes/GRCh38/gtf/genes.gtf.gz
$BIOINFO_REFS/genomes/GRCh38/index/star/        (build mode — absent until first --save_reference run)
$BIOINFO_REFS/genomes/GRCh38/index/salmon/      (build mode — same)
$BIOINFO_REFS/genomes/GRCh38/bed/genes.bed      (optional, --gene_bed; RSeQC otherwise derives it)
```

Use `GRCh38`, not `GRCh38gatk`. The GATK analysis set is for variant calling; the GENCODE GTF is
matched to UCSC hg38.

**Key outputs:**

```
<outdir>/star_salmon/salmon.merged.gene_counts.tsv                 raw counts  → differentialabundance
<outdir>/star_salmon/salmon.merged.gene_counts_length_scaled.tsv   tximport length-scaled counts
<outdir>/star_salmon/salmon.merged.gene_tpm.tsv                    TPM — for looking at, not for DESeq2
<outdir>/star_salmon/salmon.merged.gene_counts.rds                 SummarizedExperiment
<outdir>/star_salmon/<sample>/                                     per-sample BAM + index
<outdir>/multiqc/star_salmon/multiqc_report.html                   the QC verdict lives here
```

**QC verdict checklist** (report these; do not interpret the biology): % uniquely mapped (expect
>70% for good human poly-A), % rRNA, % duplication and whether dupRadar shows it is
expression-dependent, 5'/3' bias from RSeQC, strandedness agreement between declared and inferred,
library size spread, and the PCA in the MultiQC report showing whether samples group by condition
or by batch.

### 4.2 `nf-core/differentialabundance`

**For:** taking a feature × sample count matrix plus a sample metadata table plus a contrast
definition, and producing DESeq2 (or limma) results tables, normalised matrices, QC/exploratory
plots, a self-contained HTML report, and optionally a ShinyNGS app bundle.

**Not for:** producing counts. Not for anything with fewer than two replicates per group (§5.5).
Not for single-cell differential expression — the model is wrong for that data. Not for GSEA
beyond the GSEA module it wraps; pathway interpretation is the user's job.

**Minimum input** — three files:

1. `--matrix` — the count matrix. From rnaseq: `star_salmon/salmon.merged.gene_counts.tsv`.
   <!-- UNVERIFIED: whether to prefer salmon.merged.gene_counts.tsv (raw, tximport "no" scaling) or
        salmon.merged.gene_counts_length_scaled.tsv for DESeq2 is a real judgement call and the
        nf-core docs example has used both. Confirm against the -r you run, and say in the run plan
        which one you used. -->
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

**Key outputs:** `tables/differential/*.deseq2.results.tsv` (one per contrast),
`tables/processed/` normalised matrices, `plots/` (PCA, MA, volcano, clustering), and the report
HTML. <!-- UNVERIFIED: exact output subdirectory names shifted between 1.2 and 1.4; confirm with
`ls` after the stub run rather than promising paths in advance. -->

**QC verdict checklist:** does the PCA separate by the contrast variable or by a nuisance variable;
is the dispersion fit sane; how many genes pass independent filtering; is the p-value histogram
flat-with-a-spike (good) or U-shaped/humped (model misspecified).

### 4.3 `nf-core/fetchngs`

**For:** resolving public accessions to FASTQ files plus metadata plus a samplesheet already
shaped for the next pipeline. Handles SRA/ENA/DDBJ run and study accessions and GEO series.

**Not for:** anything with controlled access (dbGaP, EGA) — those need their own clients and
credentials. Not for downloading BAM/CRAM from ENA. Not a substitute for reading the paper's
methods: it retrieves whatever metadata the submitter uploaded, which is frequently wrong about
strandedness and sometimes wrong about pairing.

**Minimum input:** `--input ids.csv` — a file with one accession per line (`SRRxxxxxxx`,
`SRXxxxxxxx`, `SRPxxxxxx`, `PRJNAxxxxxx`, `GSExxxxxx`, `GSMxxxxxxx`).
<!-- UNVERIFIED: GEO (GSE/GSM) handling has been reworked more than once and at least one release
     deprecated part of it. Confirm with `nextflow run nf-core/fetchngs -r <rev> --help` before
     promising GSE support. -->

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--nf_core_pipeline` | `rnaseq` \| `atacseq` \| `taxprofiler` \| `viralrecon` | **this is the whole point of the chain** — it emits a samplesheet with that pipeline's columns |
| `--nf_core_rnaseq_strandedness` | `auto` | seeds the strandedness column; do not trust submitter metadata |
| `--download_method` | `ftp` first | `aspera` is faster when it works; `sratools` is the fallback and the slowest |

**Reference-store paths:** none. This pipeline touches no genome.

**Key outputs:**

```
<outdir>/fastq/                                 the reads
<outdir>/samplesheet/samplesheet.csv            feed directly to the next pipeline's --input
<outdir>/samplesheet/id_mappings.csv            accession → sample name, keep this
<outdir>/metadata/                              full ENA/SRA metadata records
```

**Before chaining, always open `samplesheet.csv` and check it.** Sample names derived from
accessions are opaque; group assignment is not in there; and single-vs-paired can be mis-declared.
Editing this file by hand is normal and expected.

**Disk warning:** this is the one pipeline whose footprint is entirely outside your control. A
40-sample human RNA-seq study is 200–400 GB of FASTQ. A WGS study is terabytes. Estimate from the
ENA record before starting, and check free space against 1.5×.

### 4.4 `nf-core/sarek`

**For:** DNA short-read variant calling. FASTQ → aligned CRAM → germline and/or somatic SNVs,
indels, SVs, CNVs → annotated VCF. WGS and WES. Tumour–normal and tumour-only. Multi-sample joint
germline genotyping.

**Not for:** expression of any kind. Not for RNA variant calling (no STAR 2-pass / SplitNCigarReads
path). Not for repeat expansions or STR genotyping — **see §6, this matters for this user.** Not
for de novo assembly. Not for long reads. Not for methylation.

**Minimum input** — the samplesheet schema is **per-`--step`**. This is the single most common
source of sarek failures.

`--step mapping` (from FASTQ):

| column | notes |
|---|---|
| `patient` | subject id; groups samples for tumour–normal and joint calling |
| `sample` | sample id, unique within patient |
| `lane` | required when a sample spans lanes; forms the read group |
| `fastq_1`, `fastq_2` | reads |
| `sex` | `XX` \| `XY` \| `NA` — affects ploidy and ASCAT |
| `status` | `0` = normal, `1` = tumour |

`--step variant_calling` (from CRAM): `patient,sample,status,sex,cram,crai`.
`--step recalibrate`: adds a `table` column.
`--step annotate`: `patient,sample,vcf`.

**You rarely need to write these by hand.** Sarek writes ready-made restart samplesheets into
`<outdir>/csv/` — `mapped.csv`, `markduplicates.csv`, `markduplicates_no_table.csv`,
`recalibrated.csv`, `variantcalled.csv`. Point the next `--step` at the matching one.
<!-- UNVERIFIED: exact filenames in <outdir>/csv/ vary slightly by revision and by which steps ran.
     `ls <outdir>/csv/` rather than assuming. -->

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--step` | as above | restart point; see §5.3 |
| `--tools` | `haplotypecaller` germline; `mutect2,strelka,manta` somatic; add `ascat`/`cnvkit` for CNV; `snpeff` or `vep` to annotate | **empty `--tools` = preprocessing only**, which is exactly what you want before an STR caller |
| `--wes` + `--intervals <capture.bed>` | for exomes | without the capture BED, WES coverage QC and calling are both wrong |
| `--joint_germline` | cohorts | GenomicsDBImport + joint genotyping; much heavier than per-sample |
| `--skip_tools baserecalibrator` | **when the GATK bundle is absent** | BQSR needs dbsnp + known_indels; see below |
| `--genome null` + explicit refs | always here | do **not** use `--genome GATK.GRCh38`; it triggers a large iGenomes download and bypasses the store |
| `--save_output_as_bam` | when a downstream tool cannot read CRAM | HipSTR in particular — §6 |

**Reference-store paths:**

```
$BIOINFO_REFS/genomes/GRCh38gatk/fasta/genome.fa
$BIOINFO_REFS/genomes/GRCh38gatk/fasta/genome.fa.fai
$BIOINFO_REFS/genomes/GRCh38gatk/fasta/genome.dict           MISSING — build mode
$BIOINFO_REFS/genomes/GRCh38gatk/index/bwa/                  present (copied to ext4)
$BIOINFO_REFS/genomes/GRCh38gatk/gatkbundle/dbsnp.vcf.gz     MISSING — fetch mode
$BIOINFO_REFS/genomes/GRCh38gatk/gatkbundle/known_indels.vcf.gz        MISSING — fetch
$BIOINFO_REFS/genomes/GRCh38gatk/gatkbundle/germline_resource.vcf.gz   MISSING — fetch (mutect2)
$BIOINFO_REFS/cache/vep/  or  $BIOINFO_REFS/cache/snpeff/    MISSING — fetch, ~25 GB for VEP
```

**Say this in the run plan, out loud, before starting:** the sequence dictionary does not exist
(two minutes: `gatk CreateSequenceDictionary`), and the GATK resource bundle does not exist (a real
multi-GB download). Without the bundle you can still map and mark duplicates; you cannot BQSR, and
HaplotypeCaller/Mutect2 will be running without their standard resources. Discovering this twelve
hours into a run is the failure mode this paragraph exists to prevent.

Tumour-only Mutect2 without a panel of normals produces a call set dominated by artefacts and
germline leakage. If the user asks for tumour-only, say so and ask whether a PoN exists.

**Key outputs:**

```
<outdir>/preprocessing/markduplicates/<sample>/<sample>.md.cram    ← the input for STR callers
<outdir>/preprocessing/recalibrated/<sample>/<sample>.recal.cram
<outdir>/variant_calling/<tool>/<sample>/*.vcf.gz
<outdir>/annotation/<tool>/<sample>/*.ann.vcf.gz
<outdir>/reports/                                                  mosdepth, samtools, bcftools stats
<outdir>/csv/*.csv                                                 restart samplesheets
```

**QC verdict checklist:** mean and fold-80 coverage from mosdepth, % duplicates, % properly paired,
insert-size distribution, contamination if estimated, Ti/Tv of the germline call set (~2.0–2.1 WGS,
~2.8–3.0 WES), het/hom ratio, and whether the declared `sex` matches chrX/chrY coverage.

### 4.5 `nf-core/methylseq`

**For:** bisulfite and enzymatic-conversion sequencing → per-cytosine methylation calls. WGBS,
RRBS, EM-seq, PBAT, NOMe-seq.

**Not for:** array data (EPIC/450k — completely different pipeline, not nf-core). Not for
differential methylation testing; it produces per-cytosine calls, and DMR/DMC calling is downstream
work. Not for long-read 5mC (that comes off the basecaller, not from an aligner). Not for
hydroxymethylation deconvolution without oxBS/ACE-seq pairs, which the pipeline does not model.

**Minimum input:** `--input samplesheet.csv` with `sample,fastq_1,fastq_2`.
<!-- UNVERIFIED: methylseq 3.0 is a template rewrite and may have added columns (e.g. a per-sample
     genome column). Re-derive from assets/schema_input.json for any 3.x revision. -->

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--aligner` | `bwameth` for human WGS-scale; `bismark` for small/RRBS | bismark on 30× human WGBS is punishing on a single 24-core node. bwameth + MethylDackel is materially faster |
| `--rrbs` | RRBS libraries | enables MspI-aware trimming and disables deduplication (which is invalid for RRBS) |
| `--em_seq` | NEBNext EM-seq | sets the end-clipping the protocol requires <!-- UNVERIFIED: exact clip values (believed 8 bp at both ends of both reads); confirm via --help --show_hidden --> |
| `--clip_r1/--clip_r2/--three_prime_clip_r1/--three_prime_clip_r2` | protocol-dependent | if the kit is not one of the presets, set these manually — M-bias plots will tell you what is needed |
| `--save_reference` | first run | the bismark index build is expensive and there is no index in the store yet |
| `--cytosine_report` | only if genome-wide per-cytosine output is needed | it is large |

**Reference-store paths:**

```
$BIOINFO_REFS/genomes/GRCh38/fasta/genome.fa
$BIOINFO_REFS/genomes/GRCh38/index/bismark/     build mode — absent, first run pays for it
```

bwameth needs its own index. There is no manifest row for it — see §8.

**Key outputs:** per-sample `*.bismark.cov.gz` (or MethylDackel `*.bedGraph`), splitting reports,
deduplicated BAMs, M-bias plots, MultiQC.

**QC verdict checklist:** bisulfite conversion efficiency (from lambda/pUC19 spike-in if present,
otherwise from non-CpG methylation — expect >99%), duplication rate, M-bias plots flat across the
read (if not, clipping is wrong and the run should be redone), mean CpG coverage, and number of
CpGs at ≥5× and ≥10×.

### 4.6 `nf-core/atacseq`

**For:** ATAC-seq → filtered alignments, per-sample and consensus peak sets, a consensus-peak count
matrix, bigWigs, and ATAC-specific QC (fragment-size distribution, TSS enrichment, mitochondrial
fraction) via ataqv.

**Not for:** **footprinting.** There is no TOBIAS/HINT-ATAC step. Not for motif enrichment
(peak *annotation* via HOMER is not motif discovery). Not for a finished differential-accessibility
analysis — it runs a DESeq2 *QC* step (PCA and sample clustering), not a contrast-driven DA
analysis. Not for single-cell ATAC.

**Minimum input:** `--input samplesheet.csv` with `sample,fastq_1,fastq_2,replicate`.
<!-- UNVERIFIED: confirm the replicate column against assets/schema_input.json for the revision you
     run; the 1.x → 2.x transition changed how replicates are encoded in this family of pipelines. -->

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--aligner` | `bowtie2` | the ATAC convention; `chromap` is much faster if you accept its filtering behaviour |
| `--read_length` | actual read length | selects the matching index/mappability settings |
| `--macs_gsize` | `2.7e9` for human | wrong gsize silently distorts every peak call |
| `--blacklist` | ENCODE hg38 blacklist | the pipeline ships blacklists under `assets/blacklists/`; not having one leaves a ring of artefact peaks <!-- UNVERIFIED: confirm the bundled filename in $NXF_ASSETS/nf-core/atacseq/assets/blacklists/ --> |
| `--mito_name` | `chrM` | must match the FASTA. UCSC hg38 uses `chrM`. Getting this wrong means mito reads are never removed and the library looks far better than it is |
| `--min_reps_consensus` | 1 or 2 | how many replicates a peak must appear in to enter the consensus set. **This is a bounded choice — state it in the handoff** |

**Reference-store paths:**

```
$BIOINFO_REFS/genomes/GRCh38/fasta/genome.fa
$BIOINFO_REFS/genomes/GRCh38/gtf/genes.gtf.gz
$BIOINFO_REFS/genomes/GRCh38/index/bowtie2/      no manifest row yet — see §8
$BIOINFO_REFS/genomes/GRCh38/bed/blacklist.bed   no manifest row yet — see §8
```

**Key outputs:** `<aligner>/merged_library/macs2/narrow_peak/` per-sample peaks, the consensus peak
BED and SAF, the featureCounts consensus count matrix (**this is the matrix that feeds
differentialabundance**), bigWigs, deepTools plots, ataqv HTML, MultiQC.

**QC verdict checklist:** TSS enrichment score (>5 acceptable, >10 good for human), fraction of
reads in peaks, mitochondrial read fraction (<20% desirable; Omni-ATAC much lower), nucleosomal
laddering in the fragment-size histogram, library complexity, and peak counts consistent across
replicates.

### 4.7 `nf-core/chipseq`

**For:** ChIP-seq with input/IgG controls → peaks (narrow or broad), consensus peak set and count
matrix, bigWigs, and ChIP QC (cross-correlation, FRiP, fingerprint plots).

**Not for:** CUT&RUN or CUT&Tag if you want spike-in normalisation or SEACR — use cutandrun (§5.6).
Not for ChIP without any control unless you accept substantially worse peak calls. Not for
differential binding as a finished product (same limitation as atacseq).

**Minimum input:** `--input samplesheet.csv`. Columns in 2.x are
`sample,fastq_1,fastq_2,antibody,control` — with an additional `control_replicate` in some 2.x
revisions, and control rows themselves leaving `antibody`/`control` empty.
<!-- UNVERIFIED: the exact 2.x column set (whether `replicate` and `control_replicate` are present)
     is the single thing to check before writing this samplesheet. Read
     $NXF_ASSETS/nf-core/chipseq/assets/schema_input.json. Do not guess. -->

**Parameters that matter here:** `--narrow_peak` vs broad (default is broad in some revisions —
check; TFs want narrow, H3K27me3/H3K36me3 want broad), `--macs_gsize 2.7e9`, `--blacklist`,
`--read_length`, `--aligner bwa|bowtie2`, `--min_reps_consensus`.

**Reference-store paths:** same set as atacseq (§4.6).

**Key outputs:** same shape as atacseq — per-sample peaks, consensus BED + count matrix, bigWigs,
MultiQC with phantompeakqualtools metrics.

**QC verdict checklist:** NSC/RSC from cross-correlation, FRiP, fingerprint plot separation between
ChIP and input, peak count and its consistency across replicates, duplication rate.

### 4.8 `nf-core/cutandrun`

**For:** CUT&RUN and CUT&Tag → peaks called with SEACR and/or MACS2, spike-in normalised coverage
tracks, consensus peaks, an IGV session, and a reporting deck of QC plots.

**Not for:** conventional ChIP-seq (use chipseq — the normalisation model differs). Not for ATAC.
Not for experiments with no IgG control if you intend to use SEACR's control mode.

**Minimum input:** `--input samplesheet.csv` with `group,replicate,fastq_1,fastq_2,control` —
note this family uses `group`/`replicate`, **not** `sample`, which is a frequent copy-paste error
when moving from an atacseq samplesheet.
<!-- UNVERIFIED: confirm against assets/schema_input.json for the revision you run. -->

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--peakcaller` | `seacr` or `seacr,macs2` | order matters: the first listed is used for the consensus/reporting |
| `--normalisation_mode` | `Spikein` if a spike-in was used, else `CPM` | declaring `Spikein` with no spike-in reads produces garbage scale factors |
| `--spikein_genome` | E. coli K12 by default | if the experiment used a different carrier, override |
| `--use_control` / `--igg_scale_factor` | with IgG | controls how the IgG track is subtracted |
| `--dedup_target_reads` | usually **off** for CUT&RUN | high-efficiency CUT&RUN produces genuine duplicate fragments; deduplicating them throws away signal. This is a real judgement call — state which way you went |
| `--consensus_peak_mode` | `group` | `all` collapses across the whole experiment |

**Reference-store paths:**

```
$BIOINFO_REFS/genomes/GRCh38/fasta/genome.fa
$BIOINFO_REFS/genomes/GRCh38/gtf/genes.gtf.gz
$BIOINFO_REFS/genomes/GRCh38/index/bowtie2/        no manifest row yet — see §8
$BIOINFO_REFS/genomes/ECOLI_K12/fasta/genome.fa    no manifest row yet — see §8
$BIOINFO_REFS/genomes/ECOLI_K12/index/bowtie2/     no manifest row yet — see §8
```

By default the pipeline will fetch the spike-in genome itself. On this host, prefer adding it to
the store so the run is offline-reproducible.

**Key outputs:** SEACR/MACS2 peak BEDs per group, consensus peaks, normalised bigWigs, the
`igv_session.xml`, the reporting HTML, MultiQC.

**QC verdict checklist:** spike-in read fraction and the resulting scale factors (wildly divergent
factors across samples means the spike-in was not added consistently), FRiP, peak counts per group,
IgG background level, duplication.

### 4.9 `nf-core/scrnaseq`

**For:** droplet and plate single-cell RNA → cell × gene count matrices in MTX and `.h5ad`, with
per-sample QC. Supports alevin/simpleaf, kallisto|bustools, STARsolo, and Cell Ranger.

**Not for:** downstream single-cell analysis — no clustering, no annotation, no integration, no DE.
That is the user's scanpy/Seurat work and it starts where this pipeline stops. Not for spatial. Not
for single-cell ATAC or multiome (different pipelines). Not for Smart-seq2 plate data without
thought — that data is bulk-like per well and `nf-core/rnaseq` is often the better fit.

**Minimum input:** `--input samplesheet.csv` with `sample,fastq_1,fastq_2`, optionally
`expected_cells`. The barcode read is `fastq_1` and the cDNA read is `fastq_2` for 10x — get this
backwards and you will get near-zero cells with no obvious error.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--aligner` | `star` (STARsolo) or `simpleaf`/`alevin` | avoids the Cell Ranger licensing/container problem <!-- UNVERIFIED: whether the current revision ships a usable cellranger container or requires the user to build one under the 10x EULA. Check the pipeline's usage docs before promising cellranger. --> |
| `--protocol` | `10XV3` / `10XV2` / `auto` | wrong chemistry = wrong barcode whitelist = no cells |
| `--star_feature` | `GeneFull` for **single-nucleus** | nuclei are intron-dominated; counting exons only discards most of the signal. This is the snRNA adjustment (§5.7) |
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
Report these; do not decide which cells are "real" for the user.

---

## 5. Chaining patterns

### 5.1 fetchngs → rnaseq

```bash
# 1. retrieve
nextflow run nf-core/fetchngs -r 1.12.0 ... \
  --input ids.csv \
  --nf_core_pipeline rnaseq \
  --nf_core_rnaseq_strandedness auto \
  --outdir "$OUT/fetch"

# 2. INSPECT AND EDIT. Do not skip this.
#    - sample names are accessions; rename to something a human can read
#    - add the condition/group columns the study actually has (they are not in SRA metadata)
#    - verify single vs paired end matches reality
column -s, -t "$OUT/fetch/samplesheet/samplesheet.csv" | less -S

# 3. run
nextflow run nf-core/rnaseq -r 3.14.0 ... \
  --input "$OUT/fetch/samplesheet/samplesheet.csv" \
  --outdir "$OUT/rnaseq"
```

The `--nf_core_pipeline rnaseq` flag is what makes the samplesheet drop-in compatible. Without it
you get a generic samplesheet and have to reshape it by hand.

### 5.2 rnaseq → differentialabundance

```bash
nextflow run nf-core/differentialabundance -r 1.4.0 \
  -profile docker,rnaseq \
  -c "$BIOINFO_HOME/config/local.config" \
  --input  samples_with_metadata.csv \
  --contrasts contrasts.csv \
  --matrix "$OUT/rnaseq/star_salmon/salmon.merged.gene_counts.tsv" \
  --gtf    "$BIOINFO_REFS/genomes/GRCh38/gtf/genes.gtf.gz" \
  --outdir "$OUT/da"
```

Three things break this chain, in order of frequency:

1. **Column names in the matrix header do not match the sample ids in `--input`.** They must match
   exactly, including case. Check with `head -1` on the matrix against `cut -d, -f1` on the input.
2. **The contrast `variable` is not a column in `--input`.**
3. **`reference` / `target` levels are spelled differently** than the values in the metadata column.

Validate all three before launching. It costs ten seconds and saves a failed run.

### 5.3 sarek step restarts

Sarek is designed to be re-entered. The pattern is: run a step, take the CSV it wrote, feed it to
the next step with a **new `--outdir`**.

```bash
# preprocessing only — no callers. This is the STR-prep path (§6).
nextflow run nf-core/sarek -r 3.4.0 ... \
  --step mapping --skip_tools baserecalibrator \
  --input samplesheet.csv --outdir "$OUT/sarek_map"

# later: call germline variants from the CRAMs already produced
nextflow run nf-core/sarek -r 3.4.0 ... \
  --step variant_calling --tools haplotypecaller \
  --input "$OUT/sarek_map/csv/markduplicates_no_table.csv" \
  --outdir "$OUT/sarek_hc"

# later still: annotate an existing VCF without recalling anything
nextflow run nf-core/sarek -r 3.4.0 ... \
  --step annotate --tools vep \
  --input "$OUT/sarek_hc/csv/variantcalled.csv" \
  --outdir "$OUT/sarek_annot"
```

`--step` restart and `-resume` solve different problems. `-resume` reuses cached tasks within a
logically identical run. `--step` starts a *different* run from an intermediate file. Use `-resume`
when a run crashed; use `--step` when you are deliberately adding a stage. Never use `--step` as a
substitute for `-resume` after a crash — you will lose the cache and redo work.

### 5.4 atacseq / chipseq → differentialabundance

The consensus-peak featureCounts matrix from atacseq or chipseq is a feature × sample count matrix
and DESeq2 works on it. You can feed it to differentialabundance, but:

- do **not** use `-profile rnaseq` — its defaults assume gene features and a GTF-derived annotation;
- supply the consensus peak annotation as the features file instead of `--gtf`;
- the reported "genes" are peaks, so every label in the report needs reinterpreting.

<!-- UNVERIFIED: the exact combination of --features / --features_type / --observations_type that
     makes peak-level input work cleanly. Stub-run it and inspect before committing. -->

This is a defensible shortcut, not the pipeline's designed path. Say so in the handoff.

### 5.5 What does not chain

There is no supported chain from methylseq, cutandrun, or scrnaseq into differentialabundance.
Differential methylation, differential CUT&RUN binding, and single-cell DE all need models the
pipeline does not implement. Hand off the per-cytosine calls / peaks / h5ad and stop there.

---

## 6. STR and repeat expansion — the honest answer

This is the user's actual research area, and it is the largest gap in the stocked set.

**No stocked nf-core pipeline genotypes tandem repeats.** In particular:

- **`nf-core/sarek` does not call repeat expansions.** Its `--tools` list covers SNV/indel callers,
  SV callers (Manta, TIDDIT), and CNV callers (ASCAT, CNVkit, ControlFREEC). None of them is an STR
  genotyper. Manta may emit a breakend near a very large expansion; that is a hint, not a genotype,
  and it will not give you a repeat count.
- ExpansionHunter, HipSTR, and TRGT all have to be run **outside** the nf-core pipeline, against
  the catalogs already in the reference store.

### 6.1 The working pattern for short-read STRs (ExpansionHunter / HipSTR)

Two stages. Stage one is nf-core; stage two is not.

**Stage 1 — get analysis-ready alignments out of sarek, calling nothing:**

```bash
nextflow run nf-core/sarek -r 3.4.0 \
  -profile docker -c "$BIOINFO_HOME/config/local.config" \
  --step mapping \
  --skip_tools baserecalibrator \
  --genome null \
  --fasta     "$BIOINFO_REFS/genomes/GRCh38gatk/fasta/genome.fa" \
  --fasta_fai "$BIOINFO_REFS/genomes/GRCh38gatk/fasta/genome.fa.fai" \
  --dict      "$BIOINFO_REFS/genomes/GRCh38gatk/fasta/genome.dict" \
  --bwa       "$BIOINFO_REFS/genomes/GRCh38gatk/index/bwa/" \
  --input samplesheet.csv --outdir "$OUT/sarek_map" \
  -work-dir "$WORK" -resume
```

Empty `--tools` means preprocessing only. `--skip_tools baserecalibrator` is what makes this run
possible without the missing GATK bundle — and BQSR is not needed for repeat genotyping anyway.
Output: `<outdir>/preprocessing/markduplicates/<sample>/<sample>.md.cram`.

If all you want is a BAM, sarek is heavyweight for the job — `bwa mem | samtools sort` plus
`samtools markdup` gets you there faster. Sarek buys you read-group handling, lane merging,
mosdepth/samtools QC, and a reproducible provenance record. For a one-off, skip it. For anything
that will be written up, use it.

**Stage 2 — the STR caller, run directly, per sample, outside Nextflow:**

```bash
# ExpansionHunter — targeted, catalog-driven, the standard short-read choice
ExpansionHunter \
  --reads         "$CRAM" \
  --reference     "$BIOINFO_REFS/genomes/GRCh38gatk/fasta/genome.fa" \
  --variant-catalog "$BIOINFO_REFS/catalogs/str/eh_catalog.disease.GRCh38.json" \
  --sex           male \
  --output-prefix "$RUNDIR/${SAMPLE}.eh"
```

```bash
# HipSTR — genome-wide panel, population-scale STR genotyping
HipSTR \
  --bams    "$BAM" \
  --fasta   "$BIOINFO_REFS/genomes/GRCh38/fasta/genome.fa" \
  --regions "$BIOINFO_REFS/catalogs/str/hipstr.GRCh38.bed" \
  --str-vcf "$RUNDIR/${SAMPLE}.hipstr.vcf.gz"
```

<!-- UNVERIFIED: HipSTR's CRAM support has historically been unreliable; if it errors, re-run sarek
     with --save_output_as_bam or convert with `samtools view -T <fasta> -b`. Confirm against the
     HipSTR version you install. -->

Catalog/reference build must agree. Both `eh_catalog.*.GRCh38.json` and `hipstr.GRCh38.bed` in the
store are hg38 with `chr`-prefixed contigs, and both `GRCh38` and `GRCh38gatk` are chr-prefixed on
the primary chromosomes, so either FASTA works — but **use the same FASTA the BAM was aligned
against**, not merely a compatible one.

Two catalogs are available for ExpansionHunter: `eh_catalog.disease.GRCh38.json` (the known
pathogenic loci — fast, this is what a clinical-style screen wants) and
`eh_catalog.GRCh38.json` (the full catalog — much slower, genome-wide discovery). Choosing the
disease subset is a **bounded choice**: say so explicitly in the handoff.

### 6.2 TRGT is long-read only

TRGT genotypes tandem repeats from **PacBio HiFi** reads. It is not applicable to Illumina short
reads, and there is no short-read mode. If the user has Illumina WGS and asks for TRGT, the correct
answer is "TRGT needs HiFi reads; for this data the equivalent is ExpansionHunter" — not an attempt
to make it work.

```bash
trgt genotype \
  --genome  "$BIOINFO_REFS/genomes/GRCh38/fasta/genome.fa" \
  --repeats "$BIOINFO_REFS/catalogs/str/trgt_pathogenic.GRCh38.bed" \
  --reads   "$HIFI_BAM" \
  --output-prefix "$RUNDIR/${SAMPLE}.trgt"
```

The HiFi BAM must be aligned with pbmm2 or minimap2 with HiFi presets, and TRGT expects the
per-read tags HiFi alignments carry. No stocked pipeline produces that alignment; sarek's bwa path
will not do.

### 6.3 If a pipeline is wanted anyway

`nf-core/raredisease` is the pipeline most likely to cover short-read repeat expansions in the
nf-core ecosystem — it is built for clinical rare-disease WGS and is understood to include
ExpansionHunter with Stranger annotation alongside SNV/SV calling.
<!-- UNVERIFIED: confirm that raredisease includes expansionhunter + stranger in the revision you
     would run: `nextflow run nf-core/raredisease -r <rev> --help | grep -i -e expansion -e stranger`
     and check the pipeline's output docs. Do not promise this before checking. -->

If the user wants it, that is a procurement request — follow `references/new-pipeline.md`. Do not
add it to the stocked set casually: raredisease has a substantial reference-file appetite
(its own catalogs, ranking models, and score configs) that the store does not currently carry.

### 6.4 Korean allele-frequency comparison

Comparing repeat-allele or variant frequencies between a Korean cohort and gnomAD is **not a
pipeline**. It is `bcftools`/R work over VCFs the pipelines above produce. Nothing in nf-core does
it, and the technician's job ends at "here are the VCFs, here is the QC verdict". Do not invent a
pipeline for it and do not silently perform the comparison as if it were a pipeline step.

Note also that the `KOREF1` build in the store has FASTA only — no GTF, no BED, no BWA index, no
`.dict`. Any pipeline pointed at `KOREF1` will need indexes built first, and coordinates from
KOREF1 are not comparable with hg38-based catalogs without a liftover that the store does not
provide.

---

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
| **methylseq with `bismark` on 30× human WGBS** | Not wrong, but it will run for days on 22 cores | `--aligner bwameth` |
| **RRBS without `--rrbs`** | Deduplication is applied, and RRBS fragments are duplicates by construction. Most of the library is discarded | `--rrbs` |
| **sarek `--genome GATK.GRCh38`** | Bypasses the reference store, triggers a large iGenomes download, and hardcodes a name that is not the store's | `--genome null` plus explicit store paths |
| **Any pipeline with `--work-dir` on /mnt/d** | 5–10× slower, and Windows filesystem semantics break some staging | ext4, always |
| **WES without `--wes --intervals`** | Coverage QC is computed genome-wide over a capture library. Every metric is meaningless | Get the capture BED from the user. If they cannot supply it, say the QC will be unreliable |

---

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

---

## 9. Reference-store gaps this document exposes

Selecting a pipeline surfaces references the manifest does not yet carry. These are missing rows,
not missing files — fix `config/refs.manifest.tsv` and re-run `bootstrap/04-refs.sh` rather than
hand-placing anything under `/refs`.

| Standard path | Mode | Needed by | Note |
|---|---|---|---|
| `genomes/GRCh38/index/bowtie2/` | build | atacseq, chipseq, cutandrun | `bowtie2-build`, or `--save_reference` on the first run |
| `genomes/GRCh38/index/bwa/` | build | chipseq (`--aligner bwa`), methylseq bwameth | the existing BWA index is on `GRCh38gatk`, a different FASTA |
| `genomes/GRCh38/index/bwameth/` | build | methylseq `--aligner bwameth` | `bwameth.py index` |
| `genomes/GRCh38/bed/blacklist.bed` | fetch | atacseq, chipseq | ENCODE hg38 blacklist v2; the pipelines also ship copies under `assets/blacklists/` |
| `genomes/ECOLI_K12/fasta/genome.fa` + `index/bowtie2/` | fetch/build | cutandrun spike-in | otherwise the pipeline downloads it per run |
| `genomes/GRCh38/fasta/genome.dict` | build | any GATK-adjacent step on the UCSC build | already a `build` row; still absent |

Everything already flagged missing in `references/reference-store.md` — both `.dict` files, the
GATK bundle, STAR/salmon/bismark indexes, VEP/snpEff caches — applies here too. State the missing
pieces in the run plan **before** starting, with the time cost of producing each.

---

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
