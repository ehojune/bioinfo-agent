# Pipeline selection

Turning "here is my data, here is what I want" into one specific `nextflow run` command.

Read this before writing any samplesheet. The cost of picking the wrong pipeline is not a wasted
command — it is twelve hours of compute and a set of numbers that look plausible and are wrong.

---

## 0. Revision pinning — read this first

**`config/pipelines.tsv` is the single source of truth for revisions.** Every `-r` in this document
is the pin in that file; nothing here restates the table. Read it before writing a command.

**nf-core samplesheet columns and parameter names drift between releases.** Treat every schema in
this document as a starting hypothesis. Re-derive before the first run of any pipeline you have not
run on this host before:

```bash
# 1. what revisions exist
nextflow info nf-core/<pipeline>

# 2. the parameter surface of the revision you intend to run
nextflow run nf-core/<pipeline> -r <rev> --help
nextflow run nf-core/<pipeline> -r <rev> --help --show_hidden

# 3. the authoritative samplesheet schema (this is the file the pipeline actually validates against)
find "$NXF_ASSETS" -path '*nf-core/<pipeline>*' -name schema_input.json | head -1

# 4. human-readable rendering of both
nf-core pipelines schema docs nf-core/<pipeline>
```

`$NXF_ASSETS` is `$BIOINFO_REFS/cache/nf-assets` on this host, so the clone is on ext4 and
`schema_input.json` is a local read. If the clone is absent, `nextflow pull nf-core/<pipeline>
-r <rev>` first.

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

If step 1 or 2 cannot be answered from what the user said, stop and ask. §8 lists the questions.

---

## 2. Primary decision table

| Data / assay | Analysis goal | Pipeline | Chain |
|---|---|---|---|
| Bulk RNA-seq FASTQ (poly-A or ribo-depleted) | gene/transcript counts, QC | `nf-core/rnaseq` | terminal, or → differentialabundance |
| Bulk RNA-seq FASTQ | differential expression between groups | `nf-core/rnaseq` **then** `nf-core/differentialabundance` | two runs, always |
| Bulk RNA-seq FASTQ | alternative splicing / isoform usage (PSI, differential splicing) — NOT gene expression | `nf-core/rnasplice` | terminal — see §4.15, contrasted against rnaseq above |
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
| PacBio HiFi human WGS (subreads / HiFi reads / aligned BAM) | SNV+indel (DeepVariant, Clair3), SV (pbsv), phased VCF + haplotagged BAM (WhatsHap) | `pipelines/pacbio-hifi-wgs` **(in-repo)** | terminal — see §4.20 |
| PacBio HiFi tandem repeats | TRGT genotypes | **no stocked pipeline**, but §4.20 produces the HiFi alignment TRGT needs | see §6 |
| 16S / ITS amplicon (mock community, environmental, gut microbiome) | ASV table, taxonomy, alpha/beta diversity | `nf-core/ampliseq` | terminal — see §4.10 |
| Shotgun metagenome FASTQ (short and/or long read) | assembly, binning, MAGs, bin QC/taxonomy | `nf-core/mag` | terminal — see §4.11 |
| Shotgun metagenome FASTQ, taxonomy/abundance ONLY (no assembly, no binning, no MAGs) | per-sample taxon table(s), standardised across profilers | `nf-core/taxprofiler` | terminal — see §4.12 |
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
- **Reserve headroom.** The Nextflow pool is deliberately smaller than the host — `config/local.config`
  section 2 sets it and is the only place it is set. Windows, the WSL VM, and Docker itself need the
  remainder, and a hard OOM inside WSL2 can take the whole distro down.
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
export BIOINFO_HOME=/mnt/d/bioinfo-agent
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
in §7. Not for RNA variant calling — it has no GATK RNA path. Not for de novo transcript
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

### 4.2 `nf-core/differentialabundance`

**For:** taking a feature × sample count matrix plus a sample metadata table plus a contrast
definition, and producing DESeq2 (or limma) results tables, normalised matrices, QC/exploratory
plots, a self-contained HTML report, and optionally a ShinyNGS app bundle.

**Not for:** producing counts. Not for anything with fewer than two replicates per group (§7).
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

### 4.3 `nf-core/fetchngs`

**For:** resolving public accessions to FASTQ files plus metadata plus a samplesheet already
shaped for the next pipeline. Handles SRA/ENA/DDBJ run and study accessions and GEO series.

**Not for:** anything with controlled access (dbGaP, EGA) — those need their own clients and
credentials. Not for downloading BAM/CRAM from ENA. Not a substitute for reading the paper's
methods: it retrieves whatever metadata the submitter uploaded, which is frequently wrong about
strandedness and sometimes wrong about pairing.

**Minimum input:** `--input ids.csv` — a file with one accession per line (`SRRxxxxxxx`,
`SRXxxxxxxx`, `SRPxxxxxx`, `PRJNAxxxxxx`, `GSExxxxxx`, `GSMxxxxxxx`). **No header row** — see
`references/samplesheets.md`; a header line makes the pipeline abort before any download.

**Confirmed working at 1.12.0** (run 20260810-fetchngs-citest, first execution of this pipeline
on this host — the GSE/GSM UNVERIFIED note this comment used to carry is now settled): both `GSE`
and `GSM` accessions resolve correctly and expand to the right per-run granularity — a `GSM`
mapping to several sequencing runs of the same biosample produced one samplesheet row per run, not
one collapsed row, matching the "occasionally non-unique" warning below.

**`-stub-run` is not free for this pipeline — budget it like a real run.** Several of the download
modules (`modules/local/sra_fastq_ftp`, `modules/nf-core/sratools/prefetch`,
`modules/nf-core/sratools/fasterqdump`) define no Nextflow `stub:` block. Under Nextflow's
documented fallback, `-stub-run` then executes their real `script:` unchanged — i.e. the
mandatory stub step in `references/runbook.md` §4 performs the actual FASTQ download for this
pipeline. Measured on 20260810-fetchngs-citest: the "stub" run downloaded the full 939 MB in
~7m18s.

**That download is only free for the real launch if you keep the stub's work directory around and
point the real run at it — which is the opposite of `references/runbook.md` §4's general "two
stubs" rule.** On 20260810-fetchngs-citest the real launch reused the stub's downloaded FASTQ via
`-resume`/cache in 26 s, but only because its `-work-dir` was left pointed at the same tree the
stub had used — not the isolated, later-deleted `$STUBROOT` §4 otherwise mandates. Follow §4's
general procedure (separate `$STUBROOT`, deleted after validation) as written and this reuse does
not happen: the real launch's `-work-dir` has nothing cached, and the full download runs a
**second** time. That general isolation rule exists to stop a *different* pipeline's empty stub
outputs from being cached into a real run — a failure mode that cannot occur here, since
fetchngs's stub outputs are real data, not empty placeholders. For fetchngs specifically, and only
because of that, it is reasonable to deliberately keep (not delete) the stub's `-work-dir` and
point the real launch's `-work-dir` at the same tree, to avoid paying for the download twice; if
you do, say so in the run plan, since it is a deviation from the documented default. If you follow
the default (isolated, deleted) stub procedure instead, budget the download time **twice**, not
once, when estimating a large accession list.

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
for de novo assembly. Not for long reads. Not for methylation. Not a substitute for
`nf-core/raredisease` (§4.13) when the actual goal is a pedigree-ranked rare-disease candidate
list — sarek has no HPO/pedigree-aware ranking layer at all; see §4.13's comparison table.

**Minimum input** — the samplesheet schema is **per-`--step`**, which is the single most common
source of sarek failures. Columns for every step: `references/samplesheets.md`.

**You rarely need to write these by hand.** Sarek writes ready-made restart samplesheets into
`<outdir>/csv/` — `mapped.csv`, `markduplicates.csv`, `markduplicates_no_table.csv`,
`recalibrated.csv`, `variantcalled.csv`. Point the next `--step` at the matching one.
<!-- UNVERIFIED: exact filenames in <outdir>/csv/ vary slightly by revision and by which steps ran.
     `ls <outdir>/csv/` rather than assuming. -->

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--step` | `mapping` \| `markduplicates` \| `recalibrate` \| `variant_calling` \| `annotate` | restart point; see §5.3 |
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
insert-size distribution, contamination if estimated, Ti/Tv of the germline call set, het/hom ratio,
and whether the declared `sex` matches chrX/chrY coverage. Bands:
`references/qc-interpretation.md` §3.2.

### 4.5 `nf-core/methylseq`

**For:** bisulfite and enzymatic-conversion sequencing → per-cytosine methylation calls. WGBS,
RRBS, EM-seq, PBAT, NOMe-seq.

**Not for:** array data (EPIC/450k — completely different pipeline, not nf-core). Not for
differential methylation testing; it produces per-cytosine calls, and DMR/DMC calling is downstream
work. Not for long-read 5mC (that comes off the basecaller, not from an aligner). Not for
hydroxymethylation deconvolution without oxBS/ACE-seq pairs, which the pipeline does not model.

**Minimum input:** `--input samplesheet.csv` — columns in `references/samplesheets.md`.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--aligner` | `bwameth` for human WGS-scale; `bismark` for small/RRBS | bismark on 30× human WGBS is punishing on a single node. bwameth + MethylDackel is materially faster |
| `--rrbs` | RRBS libraries | enables MspI-aware trimming and disables deduplication (which is invalid for RRBS) |
| `--em_seq` | NEBNext EM-seq | sets the end-clipping the protocol requires <!-- UNVERIFIED: exact clip values (believed 8 bp at both ends of both reads); confirm via --help --show_hidden --> |
| `--clip_r1/--clip_r2/--three_prime_clip_r1/--three_prime_clip_r2` | protocol-dependent | if the kit is not one of the presets, set these manually — M-bias plots will tell you what is needed |
| `--save_reference` | first run | the bismark index build is expensive and there is no index in the store yet |
| `--cytosine_report` | only if genome-wide per-cytosine output is needed | it is large |

**Reference-store paths:**

```
$BIOINFO_REFS/genomes/GRCh38/fasta/genome.fa
$BIOINFO_REFS/genomes/GRCh38/index/bismark/     build mode — absent, first run pays for it
$BIOINFO_REFS/genomes/GRCh38/index/bwameth/     build mode — absent, first --aligner bwameth run pays for it
```

bwameth needs its own index — manifest row present (`config/refs.manifest.tsv`, added 2026-08-05),
index itself not yet built by any run on this host. Not the gap it used to be; still a real cost
the first time `--aligner bwameth` is used.

**Key outputs:** per-sample `*.bismark.cov.gz` (or MethylDackel `*.bedGraph`), splitting reports,
deduplicated BAMs, M-bias plots, MultiQC.

**QC verdict checklist:** bisulfite conversion efficiency (from lambda/pUC19 spike-in if present,
otherwise from non-CpG methylation), duplication rate, M-bias plots flat across the read (if not,
clipping is wrong and the run should be redone), mean CpG coverage, and CpGs covered at depth.
Bands: `references/qc-interpretation.md` §3.3.

**`-stub-run` always fails at `BISMARK_SUMMARY`, harmlessly.** Confirmed on this host both
2026-08-05 (`20260805-methylseq-sle-rrbs-smoke`, real samplesheet — reproduced but not written
down at the time) and re-confirmed 2026-08-16 (`20260816-methylseq-revalidate`, both the real
samplesheet and the pipeline's own `-profile test` fixture): `modules/nf-core/bismark/summary/
main.nf`'s **stub** block calls `${bam.baseName()}` on `val(bam)`, which is always a list (all
samples' BAMs collected into one call) — `nextflow.util.ArrayBag` has no `baseName()` method, so
the stub errors with `No signature of method: ... ArrayBag.baseName()`. This is a bug in
nf-core/methylseq 3.0.0's own bundled module code, not this repo's config — the **real** script
block uses `${bam.join(' ')}` correctly and is unaffected; both a full non-stub `-profile
test,docker` run and a real-sample run complete `BISMARK_SUMMARY`/`MULTIQC` successfully on this
host. Treat a stub-run stopping here, with every upstream process (FASTQC through
BISMARK_REPORT) cached/succeeded, as this known issue, not a new regression — but still run the
full non-stub test-profile pass (`new-pipeline.md` §2.4c) before trusting a methylseq run on this
pin; do not extrapolate past this one process from the stub alone.

### 4.6 `nf-core/atacseq`

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
| `--blacklist` | ENCODE hg38 blacklist v2 | confirmed bundled at `assets/blacklists/v2.0/hg38-blacklist.v2.bed` (atacseq 2.1.2); byte-identical to the store's own `genomes/GRCh38/bed/blacklist.bed` (added 2026-08-05, see §9) — not having one leaves a ring of artefact peaks |
| `--mito_name` | `chrM` | must match the FASTA. UCSC hg38 uses `chrM`. Getting this wrong means mito reads are never removed and the library looks far better than it is |
| `--min_reps_consensus` | 1 or 2 | how many replicates a peak must appear in to enter the consensus set. **This is a bounded choice — state it in the handoff** |

**Reference-store paths:**

```
$BIOINFO_REFS/genomes/GRCh38/fasta/genome.fa
$BIOINFO_REFS/genomes/GRCh38/gtf/genes.gtf.gz
$BIOINFO_REFS/genomes/GRCh38/index/bowtie2/      manifest row present (build mode) — index itself absent until a --save_reference run builds it
$BIOINFO_REFS/genomes/GRCh38/bed/blacklist.bed   present — added 2026-08-05, see §9
```

**Key outputs:** `<aligner>/merged_library/macs2/narrow_peak/` per-sample peaks, the consensus peak
BED and SAF, the featureCounts consensus count matrix (**this is the matrix that feeds
differentialabundance**), bigWigs, deepTools plots, ataqv HTML, MultiQC.

**QC verdict checklist:** TSS enrichment score, fraction of reads in peaks, mitochondrial read
fraction, nucleosomal laddering in the fragment-size histogram, library complexity, and peak counts
consistent across replicates. Bands: `references/qc-interpretation.md` §3.4.

### 4.7 `nf-core/chipseq`

**For:** ChIP-seq with input/IgG controls → peaks (narrow or broad), consensus peak set and count
matrix, bigWigs, and ChIP QC (cross-correlation, FRiP, fingerprint plots).

**Not for:** CUT&RUN or CUT&Tag if you want spike-in normalisation or SEACR — use cutandrun (§4.8).
Not for ChIP without any control unless you accept substantially worse peak calls. Not for
differential binding as a finished product (same limitation as atacseq).

**Minimum input:** `--input samplesheet.csv` — columns in `references/samplesheets.md`. Control rows
are samples too and need their own rows; that is what makes a 6-ChIP + 2-input design cost eight.

**Parameters that matter here:** `--narrow_peak` vs broad (default is broad in some revisions —
check; TFs want narrow, H3K27me3/H3K36me3 want broad), `--macs_gsize 2700000000` (plain decimal —
see the atacseq §4.6 note on why `2.7e9` fails schema validation), `--blacklist`, `--read_length`,
`--aligner bwa|bowtie2`, `--min_reps_consensus`.

**Reference-store paths:** same set as atacseq (§4.6) — **including** the blacklist, which the
store now carries at `genomes/GRCh38/bed/blacklist.bed` (§9). Not the same store asset as
cutandrun's blacklist below; see the note on §4.8's row for why those two must not be conflated.

**Do not use the compact `--genome <key>` form on this store — confirmed 2026-08-06 (chipseq
2.1.0, run `20260806-chipseq-vsmc-h3k27me3-smoke`).** Unlike scrnaseq, `fasta`/`gtf`/
`bowtie2_index`/`gene_bed` DO resolve correctly via `--genome GRCh38 --igenomes_ignore`. The
failure is different: chipseq's `main.nf` calls `getGenomeAttribute()` for `bwa`, `bowtie2`,
`chromap` AND `star` unconditionally, regardless of which one `--aligner` actually selects. This
store's `genomes.config` declares `GRCh38.bwa` and `GRCh38.star` for completeness even though
neither index is built for this FASTA, and nf-schema's `exists: true` validation checks every one
of those four params that ends up non-empty — not just the one the chosen aligner needs — so the
run aborts at parameter validation (`--bwa_index`/`--star_index` "does not exist") before any
process starts, no matter which `--aligner` is passed. `--blacklist` is a separate, permanent gap
either way: `genomes.config`'s GRCh38 block has no `blacklist` key, so the compact form never
populates it. Use explicit `--fasta`/`--gtf`/`--bowtie2_index`/`--blacklist`/`--gene_bed` instead
(`config/genomes.config` §3b has the full command and rationale). **cutandrun does NOT share this
trap — confirmed 2026-08-06 (cutandrun 3.2.2, run `20260806-cutandrun-hpsc-h3k27me3-smoke`) by
reading `main.nf` and `subworkflows/local/prepare_genome.nf` at the pinned revision directly.**
cutandrun's `main.nf` calls `getGenomeAttribute()` only for `fasta`, `bowtie2`, `gtf`,
`bed12`→`gene_bed`, and `blacklist` — it never touches `bwa`/`star`/`chromap`, so the
exists-regardless-of-aligner failure this section describes for chipseq cannot occur on cutandrun.
See §4.8 for why cutandrun still uses explicit paths anyway (a different, permanent reason: its own
bundled blacklist is not the same file the ENCODE blacklist row here would resolve to).

**Key outputs:** same shape as atacseq — per-sample peaks, consensus BED + count matrix, bigWigs,
MultiQC with phantompeakqualtools metrics.

**QC verdict checklist:** NSC/RSC from cross-correlation, FRiP, fingerprint plot separation between
ChIP and input, peak count and its consistency across replicates, duplication rate. Bands:
`references/qc-interpretation.md` §3.5.

### 4.8 `nf-core/cutandrun`

**For:** CUT&RUN and CUT&Tag → peaks called with SEACR and/or MACS2, spike-in normalised coverage
tracks, consensus peaks, an IGV session, and a reporting deck of QC plots.

**Not for:** conventional ChIP-seq (use chipseq — the normalisation model differs). Not for ATAC.
Not for experiments with no IgG control if you intend to use SEACR's control mode.

**Minimum input:** `--input samplesheet.csv` — columns in `references/samplesheets.md`. This family
uses `group`/`replicate`, **not** `sample`; copying an atacseq samplesheet across is the usual error.

**Known-broken on this host's Nextflow version until patched — check before every run.**
`modules/local/for_patch/trimgalore/main.nf` at 3.2.2 declares its optional outputs with the old
trailing-modifier DSL2 syntax (`emit: html optional true`). Nextflow 26.04.6 (installed here)
rejects this at script-compile time: `ERROR ~ Cannot invoke method optional() on null object`,
reproduced in isolation with a 6-line minimal `.nf` script — this is a genuine engine/pipeline
version-skew bug in the pipeline's own bundled code, not a params or samplesheet problem, and it
blocks **every** invocation (`-preview`, `-stub-run`, and the real run alike), not just a
misconfigured one. Confirmed 2026-08-06, run `20260806-cutandrun-hpsc-h3k27me3-smoke`. Fix (already
applied to this host's `NXF_ASSETS` clone as of that run): change both `optional true` occurrences
to the modern comma form, `, optional: true` — semantically identical, verified via `-preview`
failing before and passing after. **This patch lives in the pipeline clone under `NXF_ASSETS`, not
in this repo** — it is lost if the clone is ever deleted and re-pulled. Before the next cutandrun
run: `grep -n 'optional true' $(find "$NXF_ASSETS" -path '*nf-core/cutandrun*' -name main.nf)`; if
it still matches, reapply the same two-line edit (or check whether a newer cutandrun/Nextflow
pairing has fixed it upstream first).

**`-stub-run` is not a cheap gate for this pipeline — budget it, do not skip it.**
`FASTQC_TRIMGALORE:TRIMGALORE` has no `stub:` block, so `-stub-run` silently falls back to running
the *real* `trim_galore` on the *real*, full-size input fastqs (confirmed by watching
multi-hundred-MB real trimmed outputs and trimming reports appear in the stub work dir) — the same
class of issue the chipseq run hit with `GENOME_BLACKLIST_REGIONS`, and the same shape as fetchngs
in §4.3. Both `-preview` and `-stub-run` are still mandatory (SKILL.md step 4, `runbook.md` §4);
this pipeline has no waiver. What changes is the estimate: put the real trimming cost of the
samplesheet's fastqs into the plan as part of the gate, and expect the stub to take run-scale time
rather than minutes. `runbook.md` §4 has the 30-second check for which modules lack a `stub:` block.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--bowtie2` | store bowtie2 index path | **NOT** `--bowtie2_index` — that is chipseq's param name for the equivalent index. cutandrun's own is `--bowtie2`. Confirmed via `--help` and source, 2026-08-06 (run `20260806-cutandrun-hpsc-h3k27me3-smoke`); easy to get wrong copying a chipseq cmd.sh forward |
| `--peakcaller` | `seacr` or `seacr,macs2` | order matters: the first listed is used for the consensus/reporting. Pipeline default is `seacr` alone |
| `--normalisation_mode` | `Spikein` if a spike-in was used, else `CPM` | pipeline default is `Spikein`; declaring it with no real spike-in reads produces garbage scale factors — silently wrong, not an error. **`CPM` switches the entire spike-in arm off: no spike-in alignment, no spike-in index build, and none of the `qc-interpretation.md` §3.5 spike-in QC band.** See the boxed correction below — an earlier version of this row claimed the opposite, and a completed run disproved it |
| `--spikein_genome` | E. coli K12 by default | if the experiment used a different carrier, override. Ignored once `--spikein_fasta` is passed explicitly |
| `--spikein_fasta` / `--spikein_bowtie2` | store paths | **Both are inert unless `--normalisation_mode Spikein`.** Under `Spikein`, `--spikein_bowtie2` may be omitted and the pipeline builds the index itself from `--spikein_fasta` via `BOWTIE2_BUILD_SPIKEIN` (trivial, ~4.6 Mb). Under `CPM` neither is read: passing a valid `--spikein_fasta` produces no spike-in output and no error |
| `--macs2_narrow_peak` | pipeline default `true` (narrow) | set `false` for broad marks (H3K27me3/H3K9me3/H3K36me3), same reasoning as chipseq's broad-mode choice |
| `--use_control` / `--igg_scale_factor` | with IgG | controls how the IgG track is subtracted |
| `--dedup_target_reads` | usually **off** for CUT&RUN | high-efficiency CUT&RUN produces genuine duplicate fragments; deduplicating them throws away signal. This is a real judgement call — state which way you went |
| `--consensus_peak_mode` | `group` | `all` collapses across the whole experiment |

**Reference-store paths:**

```
$BIOINFO_REFS/genomes/GRCh38/fasta/GRCh38.fa           alias, present
$BIOINFO_REFS/genomes/GRCh38/gtf/GRCh38.gtf.gz         alias, present
$BIOINFO_REFS/genomes/GRCh38/index/bowtie2/            present — built by atacseq, reused by chipseq and cutandrun
$BIOINFO_REFS/genomes/GRCh38/bed/cutandrun_blacklist.bed   present — added 2026-08-06, see below
$BIOINFO_REFS/genomes/ECOLI_K12/fasta/genome.fa        present — added 2026-08-06 (NCBI RefSeq GCF_000005845.2)
$BIOINFO_REFS/genomes/ECOLI_K12/index/bowtie2/         manifest row present (build mode) — built per-run ONLY under --normalisation_mode Spikein; a CPM run never builds it (see below)
```

**`--normalisation_mode CPM` switches the whole spike-in arm off. Measured, and it corrects a
claim this file previously made.** Until 2026-08-10 the `--normalisation_mode` row above said
spike-in alignment and its QC metrics "run unconditionally regardless of this setting", citing a
source read. Run `20260810-cutandrun-hpsc-h3k27me3` (cutandrun 3.2.2, `--normalisation_mode CPM`,
a valid `--spikein_fasta` passed, `--save_reference true`) completed 146 tasks and **not one of
them was a spike-in task** — no `BOWTIE2_BUILD_SPIKEIN`, no `BOWTIE2_SPIKEIN_ALIGN`, no
`EXTRACT_BT2_SPIKEIN_META` (`grep -ci spikein` over the trace: 0). MultiQC emitted a
`Bowtie2 (target)` general-stats column and no spike-in column at all,
`02_alignment/bowtie2/` published only `target/log/*.bowtie2.log`, and
`$BIOINFO_REFS/genomes/ECOLI_K12/index/bowtie2/` did not exist after the run.

The old claim was half a reading. The `ALIGN_BOWTIE2` **call site**
(`workflows/cutandrun.nf:260-262`) really is guarded only by `params.run_alignment` and
`params.aligner == "bowtie2"` — that much was right. But the spike-in processes inside it are
starved by a **data dependency** gated further upstream:

```
prepare_genome.nf:46    if (params.normalisation_mode == "Spikein") { ch_spikein_fasta = ... }
                        -> under CPM, ch_spikein_fasta stays Channel.empty()
prepare_genome.nf:152   if (normalisation_mode == "Spikein" && params.spikein_bowtie2) { ...untar/use... }
                        else { BOWTIE2_BUILD_SPIKEIN(ch_spikein_fasta) }   <- empty in, no task out
                        -> ch_bt2_spikein_index stays empty
align_bowtie2.nf:36     BOWTIE2_SPIKEIN_ALIGN(reads, ch_spikein_index.collect{...}, ...)
                        -> never receives a complete input tuple, so it never runs
```

Note the `else` on line 152: passing `--spikein_bowtie2` explicitly does **not** rescue this
under `CPM` — the condition requires `Spikein` too, so control still falls to the build branch
and that branch is fed the empty channel.

Two consequences to carry into any plan:

- **A `CPM` run cannot report the §3.5 spike-in fraction band.** There are no spike-in reads to
  count. Do not promise that metric in a plan that selects `CPM`, and do not record its absence
  as a failure — it is a direct consequence of the normalisation choice.
- **A `CPM` run never builds the E. coli index**, so `--save_reference` has nothing to persist and
  the `ECOLI_K12/index/bowtie2` manifest row stays unmaterialised no matter how many `CPM` runs go
  through.

The judgement itself is unchanged and still stands: `Spikein` with no real spike-in carrier
produces scale factors from stray reads, which is silently wrong. The correction is only that
choosing `CPM` to avoid that **also** costs the spike-in QC readout, rather than keeping it as a
free diagnostic. If the spike-in fraction is wanted precisely *in order to decide* whether a
spike-in was used, that has to be measured some other way — `CPM` will not measure it for you.

**Do not point `--blacklist` at `genomes/GRCh38/bed/blacklist.bed` (the atacseq/chipseq ENCODE
list) for this pipeline.** nf-core/cutandrun 3.2.2's own `conf/igenomes.config` maps GRCh38 to its
bundled `assets/blacklists/GRCh38-blacklist.bed` — a different, CUT&RUN-specific region set (1049
regions vs 636 in the ENCODE ChIP-seq list; confirmed by diff 2026-08-05). As of 2026-08-06 this
file is copied into the store at `genomes/GRCh38/bed/cutandrun_blacklist.bed` (fetch-mode manifest
row pinned to the 3.2.2 tag URL + sha256 in `refs.manifest.tsv`, so a fresh machine materialises
it without a pipeline clone) rather than left pointing at the pipeline's `NXF_ASSETS` clone
directory, which changes hash on every `nextflow pull`. Do not reuse the atacseq/chipseq row, and
do not point atacseq/chipseq at this one either.

The E. coli K12 spike-in genome (`genomes/ECOLI_K12/fasta/genome.fa`) was fetched and manifest-
tracked as of 2026-08-06 rather than left to the pipeline's own per-run download — the store is
offline-reproducible for this pipeline now. The spike-in bowtie2 index is still built per-run
(cheap — seconds, for a 4.6 Mb genome) unless a future run promotes a built copy to the store path
above, the same way the human GRCh38 bowtie2 index was promoted after atacseq first built it.

**Key outputs:** SEACR/MACS2 peak BEDs per group, consensus peaks, normalised bigWigs, the
`igv_session.xml`, the reporting HTML, MultiQC.

**QC verdict checklist:** spike-in read fraction and the resulting scale factors (wildly divergent
factors across samples means the spike-in was not added consistently), FRiP, peak counts per group,
IgG background level, duplication. Bands: `references/qc-interpretation.md` §3.5.

### 4.9 `nf-core/scrnaseq`

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
| `--star_feature` | `GeneFull` for **single-nucleus** | nuclei are intron-dominated; counting exons only discards most of the signal. This is the snRNA adjustment (§7) |
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

---

### 4.10 `nf-core/ampliseq`

**For:** 16S/18S rRNA or ITS amplicon sequencing → primer trimming (cutadapt), denoising into ASVs
(DADA2), dual taxonomic classification (DADA2 + QIIME2), alpha/beta diversity (Shannon, Faith's
PD, observed features; Bray-Curtis, Jaccard, weighted/unweighted UniFrac; PCoA + PERMANOVA via
`QIIME2_DIVERSITY_ADONIS`), phyloseq/TreeSummarizedExperiment export.

**Not for:** shotgun metagenomics (no assembly, no functional profiling, no primer trimming
of amplicon reads — that is `nf-core/mag` for assembly+binning, §4.11, or
`nf-core/taxprofiler` for read-level taxonomic profiling without assembly, §4.12). Not for
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

---

### 4.11 `nf-core/mag`

**For:** shotgun metagenome sequencing (short-read Illumina, long-read ONT/PacBio, or hybrid)
→ read QC/host removal → assembly (MEGAHIT and/or SPAdes for short reads; Flye/MetaMDBG for
long reads) → binning (MetaBAT2, MaxBin2, CONCOCT, SemiBin2, COMEBin, MetaBinner — pick a
subset, see below) → bin QC (BUSCO/CheckM/CheckM2/GUNC) → taxonomic classification of bins
(GTDB-Tk) and/or contigs (CAT/BAT via CAT_pack, geNomad for viral) → per-bin gene
prediction/annotation (Prodigal, Prokka).

**Not for:** amplicon sequencing (that is `nf-core/ampliseq`, §4.10 — no primer trimming or
ASV/OTU calling here). Not for read-level taxonomic profiling without assembly, binning, or
MAGs (that is `nf-core/taxprofiler`, §4.12 — lighter-weight, and the right choice when the
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

---

### 4.12 `nf-core/taxprofiler`

**For:** shotgun metagenome sequencing (short-read Illumina, long-read ONT/PacBio, or a mix)
→ optional read QC (fastp/AdapterRemoval2, complexity filtering, host removal, run-merging) →
taxonomic classification/profiling with any combination of up to 14 tools (Kraken2, Bracken,
KrakenUniq, Centrifuge, DIAMOND, Kaiju, MALT, MetaPhlAn, mOTUs, KMCP, ganon, sylph, Melon,
metacache) → per-tool taxon tables, standardised/merged across tools (taxpasta), optional
Krona plots. No assembly step anywhere in the DAG.

**Not for:** genome recovery (no assembly, no binning, no MAGs — that is `nf-core/mag`,
§4.11: pick mag when the question is "recover genomes from this community", taxprofiler when
it is "what taxa, and roughly how much of each"). Not for amplicon sequencing (`nf-core/
ampliseq`, §4.10). Running taxprofiler does not substitute for mag and vice versa — they
answer different questions from the same kind of raw data, and the same FASTQ can legitimately
go through both.

**Minimum input:** **two** CSVs, not one.

- `--input samplesheet.csv` — `assets/schema_input.json` (2.0.1) requires `sample` +
  `run_accession` + `instrument_platform` on every row (`instrument_platform` is a closed
  enum — `ILLUMINA`, `OXFORD_NANOPORE`, `PACBIO_SMRT`, and 8 others). **`fastq_1`, `fastq_2`,
  and `fasta` are all schema-OPTIONAL** — a row with none of them validates cleanly
  (empirically confirmed via `-preview`, `completed=0 failed=0`, no error), which means the
  schema alone will not catch a metadata-only row with nothing to actually profile;
  `scripts/check-samplesheet.sh --pipeline taxprofiler` hard-fails on that shape rather than
  passing it through. `uniqueEntries [sample, run_accession]` is a **composite** key (same
  shape as mag's `[sample, run]`, empirically confirmed 2026-08-12: same `sample` with a
  different `run_accession` passes — this is exactly how the pipeline represents "same
  biological sample, multiple sequencing runs" for `--perform_runmerging`). Separately,
  **`fastq_1`, `fastq_2`, and `fasta` are each their OWN per-field `uniqueEntries`
  constraint** — reusing one FASTQ path across two sheet rows is a hard schema failure here,
  unlike mag or rnaseq where that is unremarkable.
- `--databases databases.csv` — `assets/schema_database.json` requires `tool` (enum: the 14
  names above, plus `bracken`) + `db_name` + `db_path` per row; `db_params`/`db_type`
  optional. This is where the actual classifier database gets wired in, and it is what
  decides both cost (some DBs are GBs, some are 100s of GB) and which `--run_<tool>` flags do
  anything — a `--run_kraken2 true` with no `kraken2` row in `--databases` is a no-op, not an
  error caught early.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--run_<tool>` (one per profiler, e.g. `--run_kraken2`) | `true` only for tools that have a matching row in `--databases` | off by default for all 14; turning one on with no matching database row silently does nothing useful |
| `--databases` | one row per `(tool, db_name)` you actually want run | see above — the CSV, not the `--run_*` flags, is what actually points at a database |
| `--perform_shortread_qc` / `--perform_longread_qc` | `true` for anything but a pre-cleaned fixture | off by default; raw reads straight into a classifier inflate false-positive low-abundance calls |
| `--perform_shortread_hostremoval` / `--hostremoval_reference` | `true` + a host FASTA for a human/host-associated sample | off by default; without it, host reads are classified too and dominate a human-gut-style sample |
| `--perform_runmerging` | `true` when `run_accession` values represent re-sequencing of the same `sample`, not independent samples | off by default; without it, per-run profiles are not merged even though the composite key says they are related |
| `--run_profile_standardisation` | `true` if comparing across tools | standardises taxon tables to one schema (taxpasta) across profilers — off by default, each tool's native format otherwise |

**Reference-store paths:** `db/kraken2/k2_standard_08gb/` — the ONE profiler DB this
procurement stocks (`config/refs.manifest.tsv`), a RAM-capped Kraken2 standard index
(archaea+bacteria+viral+plasmid+human+UniVec_Core, 5.96 GB download, 8.0 GB extracted),
chosen deliberately as the single lightest real-classification option over the ~150 GB
`k2_core_nt`/`k2_nt` builds or a multi-tool combination. **No other profiler's database is
pre-provisioned.** Enabling MetaPhlAn, MALT, GTDB-scale Kraken2/KrakenUniq builds, or any
other profiler at production scale is a new `fetch`-mode manifest row and, for anything over
~10 GB, a download that needs the user's approval first — same discipline as mag's
`--skip_gtdbtk` default.

**Known gaps / stub-run behaviour:** none. `-stub-run` on `-profile test,docker` **passes
end to end** (`completed=176 failed=0 cached=0`, all 14 profilers exercised against the CI
fixture databases) — no waiver needed, unlike ampliseq's `CUTADAPT_BASIC` gap or mag's
`UNTAR`/`CATPACK_DB_UNTAR` gap. This is the first of the three microbiome pipelines stocked
here where the shipped `stub:` coverage is actually complete enough to trust as a pre-launch
gate on its own. The full `-profile test,docker` run also passes clean (`completed=179
failed=0`, ~24.5 min wall clock, 4.0 GB peak work dir — see `references/estimates.md`). A
CI-fixture stub pass does not by itself prove a different real-command topology (different
samplesheet, database, and tool selection) — confirmed separately by re-running `-stub-run`
against the actual real-sample `params.yaml`/`--databases`/single-tool shape before that run's
launch (`runs/20260812-taxprofiler-drr027580-realsample/plan.md`), which also passed clean once
`-c config/local.config` was included (the pool's `resourceLimits` clamp — omitting it makes
`KRAKEN2_KRAKEN2`'s `process_high` 72 GB request exceed the raw 51 GB WSL VM ceiling, a
test-invocation gap unrelated to taxprofiler's own stub coverage).

**Key outputs:** per-sample, per-tool raw profiler output (`<tool>/<db_name>/`), per-tool
merged/standardised taxon tables (`<tool>/<db_name>/*.{tsv,csv,biom}` via taxpasta when
`--run_profile_standardisation` is on), optional Krona HTML plots, MultiQC (FastQC/fastp/
host-removal/profiler summary stats — no per-taxon abundance interpretation in MultiQC
itself).

**QC verdict checklist:** percent reads classified vs unclassified per sample per tool (from
each profiler's own report, e.g. Kraken2's `.kreport2` unclassified line); host-removal
percentage if `--perform_shortread_hostremoval` is on; agreement/disagreement between tools
when more than one profiler is run on the same sample (`run_profile_standardisation` output
makes this comparable). **No formal QC band exists yet** — the one real-sample run so far
(`runs/20260812-taxprofiler-drr027580-realsample/`, DRR027580, the same 436K-read-pair
"fossil metagenome" sample used for mag's real-sample validation, single tool: Kraken2
against the 8 GB-capped standard DB, ~47s wall clock, 9.7 MB peak work dir, peak single-process
RAM 7.8 GB dominated by loading the DB itself) establishes only that the pipeline runs end to
end against real data with a real reference database and produces real (if 99.07% unclassified)
per-taxon output; it does not establish what a normal percent-classified range looks like for
this sample type — this sample is a known outlier (mag's own real-sample run on the identical
reads assembled to only 74 short contigs), but the CAUSE of the near-total-unclassified Kraken2
result is unresolved, not established: a shallow/low-diversity input and a database that simply
lacks coverage for this sample's actual content are both consistent with the same observation,
and only one database was tested against one sample. Not a pipeline defect either way — the
pipeline ran correctly and produced a real, if hard-to-interpret, result. A run against a sample
with known community composition, or a second real sample/database for comparison, is what
would start that band and what would actually distinguish the two explanations.

### 4.13 `nf-core/raredisease`

**For:** WGS/WES rare-disease variant *calling and scoring* — short-read alignment (or a
pre-aligned BAM entry point) → DeepVariant SNV calling → Manta/Tiddit/CNVnator SV calling →
a parallel mitochondrial-genome subworkflow (subsample, shift-align, Mutect2, liftover) →
optionally CADD/VEP annotation, gnomAD/SVDB frequency annotation, ExpansionHunter repeat
genotyping, SMNCopyNumberCaller, and GENMOD HPO/pedigree-aware ranking to produce a clinically
ordered variant list. `PED`-style `sex`/`phenotype`/`case_id` fields on every sheet row exist
because the ranking step is pedigree-aware, not because the pipeline itself does any
inheritance/genotype-pattern reasoning outside GENMOD.

**Not for — and not a substitute for `nf-core/sarek` (§4.4), nor the reverse.** Both take
short-read DNA to a germline VCF and both accept a pre-aligned/dedup BAM as an alternate entry
point via `$BIOINFO_REFS/genomes/GRCh38gatk`. Past that, they diverge:

| | sarek | raredisease |
|---|---|---|
| default SNV caller | GATK HaplotypeCaller (`--tools` selects) | DeepVariant (always on) |
| default SV callers | none (`--tools` adds Manta etc.) | Manta + Tiddit + CNVnator, always on |
| MT subworkflow | none | always runs, regardless of `--tools`-equivalent flags |
| clinical ranking/scoring | none | GENMOD (HPO/pedigree-aware), when annotation subworkflows are on |
| tumour-normal / CNV-cohort | yes (sarek's actual specialty) | no |
| repeat expansion genotyping | no | ExpansionHunter, when repeat_calling is on |
| SMN copy number | no | SMNCopyNumberCaller, always on |

Pick sarek for tumour-normal, cohort-CNV, or "just give me calls with whatever caller I
choose." Pick raredisease when the end goal is a pedigree-ranked candidate list for a
single-family rare-disease case — but see the scope caveat below: this repo's procurement
does not exercise the ranking layer yet.

**Minimum input:** `--input samplesheet.csv`, `assets/schema_input.json` (3.1.2) re-read this
procurement. `required[]` = `sample` + `sex` + `phenotype` + `case_id`; `sex` and `phenotype`
are closed integer enums (PED convention: `sex` 0/1/2/other, `phenotype` 0/1/2), not sarek's
free-text style. One of `fastq_1`(+`lane`)/`spring_1`/`bam`(+`bai`) supplies reads — none is
individually `required[]`-listed, so a sheet with none of them is a silent-scheduling gap the
JSON schema alone will not catch (same shape as taxprofiler's optional-fastq gap, §4.12); see
`references/samplesheets.md` for the exact check and the `case_id` uniqueness no-op (the
schema's `"uniqueEntries":["case_id"]` is nested inside `items`, never evaluated against the
array, and is a documented dead constraint at this pin — repeated `case_id` across a family's
rows is the intended shape, not a defect to flag).

`--genome` is a **closed enum** here (`GRCh37`/`GRCh38` only, no `null` fallback, unlike
sarek). `--intervals_wgs`/`--intervals_y` are schema-required with **no default** (sarek has
no equivalent requirement) — this repo built them via `gatk ScatterIntervalsByNs -OT ACGT`
filtered to the 25 primary contigs, stored at `genomes/GRCh38gatk/intervals/`.

**Scope of this procurement — narrower than a full run.** Stocked with
`--skip_subworkflows snv_annotation,sv_annotation,mt_annotation,repeat_calling,
repeat_annotation,me_calling,me_annotation,generate_clinical_set --skip_tools
gens,germlinecnvcaller` — the "lightest combination first" pattern used for mag/taxprofiler.
CADD resources, a VEP cache, a gnomAD allele-frequency table, a vcfanno bundle, GENMOD rank
configs, an ExpansionHunter variant catalog, and a GATK GermlineCNVCaller cohort model are all
absent from `$BIOINFO_REFS` and none are fetched by this procurement. `refs.manifest.tsv` has
`fetch`-mode placeholder rows for the four resources whose fetch source this procurement
actually identified (VEP cache, CADD resources, gnomAD allele-frequency table, ExpansionHunter
catalog) — the vcfanno bundle, GENMOD rank configs, and GermlineCNVCaller cohort model have
**no manifest row yet**, so enabling those specific pieces needs a manifest row added first,
not just a download against an existing one. This run validates
alignment-input handling, QC, DeepVariant SNV calling, Manta/Tiddit/CNVnator SV calling, the
MT subworkflow, and SMNCopyNumberCaller only — **not** the annotation/scoring/ranking layer
that makes raredisease's output "rare-disease ready" in the clinical-interpretation sense.
Enabling any skipped subworkflow is a new reference-fetch decision (CADD/VEP-scale, same order
as sarek's own VEP cache) requiring the same size-disclosure-before-fetch discipline as
mag's GTDB-Tk skip.

**Bounded choice — `--aligner bwa --mt_aligner bwa`.** `PREPARE_REFERENCES` builds a
whole-genome `bwa-mem2` index whenever `--aligner` OR `--mt_aligner` equals the default
`bwamem2`, unconditionally, even for a bam-input run where neither index is ever consumed.
Measured on this host: `bwa-mem2 index` against the 3.1 Gb GRCh38 analysis-set genome was
OOM-killed (exit 137) twice at the 40 GB pool ceiling. Switched both flags to `bwa`, matching
the already-present `GRCh38gatk/index/bwa/` store, avoiding the build entirely. A real
upstream inefficiency (the index is built off `mt_aligner`'s default with no gate on whether
alignment happens at all), not a mistake in this run's own parameters.

**Key outputs:** `call_snv/genome/*_snv.vcf.gz` (DeepVariant, GATK-selected split), `call_snv/
mitochondria/*_mitochondria.vcf.gz`, `call_sv/*_sv.vcf.gz` (Manta+Tiddit+CNVnator merged) +
`*_mitochondria_deletions.txt`, `smncopynumbercaller/out/*.tsv`, `qc_bam/` (Picard
CollectWgsMetrics, mosdepth, per-chromosome TIDDIT coverage), `pedigree/*.ped`, `peddy/`
(pedigree/sex-check QC, not clinical scoring), `multiqc/`.

**QC verdict checklist (measured, no clinical/pathogenicity interpretation):** MultiQC general
stats — mean/median coverage (Picard WGS metrics), percent bases ≥30x, mosdepth coverage
breadth at 1/5/10/30/50x, ngs-bits/peddy sex-check concordance (chrY:chrX read ratio vs.
predicted sex), peddy ancestry prediction, SMNCopyNumberCaller's `isSMA`/`isCarrier` flags and
raw copy-number estimates, raw SNV/SV record counts from the VCFs (`bcftools view -H | wc -l`).
None of these are pathogenicity or ACMG-style classifications — they are QC signal only,
consistent with this repo's "no biological/clinical interpretation" rule across every
pipeline.

**First real-sample run** (`runs/20260812-raredisease-srr26793256/`, SRR26793256, ~40x WGS,
reused as a pre-aligned BAM from `nf-core/sarek`'s own MarkDuplicates CRAM via a
`samtools view -b` format transcode — no realignment): completed successfully
(`succeededCount=50 failedCount=0`, 50 tasks run + 34 cached across resumed attempts spanning a
host reboot). Measured: median coverage 39x / mean 37.6x (Picard WGS metrics on the BAM),
83.998% bases ≥30x, ngs-bits/peddy both call `male` (chrY:chrX read ratio 0.1235, consistent
with the July sarek run's chrX≈20.8x/chrY≈15.5x observation — this run still leaves `sex=0`
unasserted in the input sheet per its own bounded-choice policy), peddy ancestry prediction
`EAS`, SMNCopyNumberCaller reports `isSMA=False isCarrier=False SMN1_CN=2 SMN2_CN=2`, genome
SNV VCF 4,852,866 records, SV VCF 17,036 records. `-stub-run` at this exact skip-flag set
passes cleanly (`completed=42 failed=0`) — no waiver needed, joining taxprofiler as a clean
stub pass; the full unskipped annotation/scoring stack's stub behaviour was not exercised and
its scope is explicitly narrower than a full nf-core CI run.

### 4.14 `nf-core/nanoseq`

**For:** Oxford Nanopore long-read demultiplexing + QC + alignment, across three protocols —
`DNA` (minimap2/graphmap2 alignment, optional medaka/DeepVariant/pepper_margin_deepvariant SNV
calling, sniffles/cuteSV SV calling), `cDNA`/`directRNA` (alignment + bambu/stringtie2
transcript quantification, DESeq2/DEXSeq differential analysis, JAFFAL fusion detection,
xpore/m6anet RNA-modification detection). Entry point is either a raw ONT run directory
(`--input_path 'fastq_pass/*'` + qcat demultiplexing) or an already-basecalled FASTQ given
directly per-sample (`--skip_demultiplexing true`, no `--input_path`).

**First long-read-*only* pipeline stocked here — no close overlap with anything else stocked.**
`mag` (§4.11) and `taxprofiler` (§4.12) both optionally *accept* ONT/PacBio long reads as one
input type among several (mag's `long_reads`/`long_reads_platform` columns,
`--input_read_length` style flags; taxprofiler's per-tool platform handling) — but both are
built short-read-first, with long-read support as an additional path through the same
short-read-shaped workflow. nanoseq is the reverse: it is ONT-only end to end (no Illumina input
path at all) and does real ONT-specific work no other stocked pipeline does — qcat barcode
demultiplexing, medaka/pepper_margin_deepvariant ONT-tuned variant calling, NanoPlot long-read
QC, RNA-modification detection (xpore/m6anet) from raw signal-derived basecall quality, and
JAFFAL fusion calling from long cDNA/directRNA reads. Nothing else stocked here does any of that.

**Schema drift note — read before trusting `assets/schema_input.json`.** At this pin (3.1.0)
that file describes a `sample`/`fastq_1`/`fastq_2` shape but is **never referenced by any `.nf`
file in the clone** (grepped `workflows/`, `subworkflows/`, `modules/` for
`schema_input|validateParameters|fromSamplesheet|nf-validation|nf-schema` — nothing). It is
vestigial nf-core-template boilerplate the pipeline's own samplesheet handling bypasses
entirely. The samplesheet actually enforced at runtime is the pipeline's own bundled
`bin/check_samplesheet.py` (invoked via the `SAMPLESHEET_CHECK` module,
`subworkflows/local/input_check.nf`), against a completely different header:
`group,replicate,barcode,input_file,fasta,gtf`. See `samplesheets.md` for the full column table
and every rule that script actually enforces.

**Minimum input:** a samplesheet with `group`+`replicate` required on every row, plus at least
one of `barcode`/`input_file`/`fasta`/`gtf` populated (the script's `MIN_COLS=3` rule).
`input_file` is a FASTQ (`.fastq.gz`/`.fq.gz`), a BAM, or an ONT run directory (fast5+fastq, for
nanopolish); all `input_file` entries across the *whole sheet* must share one extension family.
`fasta` is a per-sample reference genome path (plain `.fa`/`.fasta`, gzip optional — looser than
taxprofiler's `fasta` column, which requires `.gz`) or an iGenomes shorthand key; this repo's
convention is always the standard absolute manifest path, never the iGenomes shorthand.
Replicate ids must run `1..N` contiguously per group with no gaps or repeats.

**Reference-store paths:** no dedicated `genomes/<build>/index/minimap2/` row needed — nanoseq
builds `SAMTOOLS_FAIDX`/`GET_CHROM_SIZES`/`MINIMAP2_INDEX` in-run from a plain FASTA, seconds at
small-genome scale. Point `fasta` at any existing `$BIOINFO_REFS/genomes/<build>/fasta/genome.fa`
directly; no new manifest row is required purely to run nanoseq against a genome already stocked
for another pipeline (this procurement reused `genomes/ECOLI_K12/fasta/genome.fa`, added
originally for cutandrun's spike-in alignment).

**Known gaps / stub-run behaviour.** `-stub-run` on the CI `test` profile
(`-profile test,docker`, DNA protocol + qcat demux) and separately on this procurement's own
real command both fail identically: `completed=24 failed=4` / `completed=13 failed=2`,
respectively, always at `BAM_STATS_SAMTOOLS:SAMTOOLS_IDXSTATS`/`SAMTOOLS_FLAGSTAT`
(`"failed to read header for ... .sorted.bam"`). Root cause confirmed by reading the modules
directly: `modules/nf-core/samtools/sort/main.nf` HAS a `stub:` block (writes a header-less,
touch'd empty `.bam`), but `modules/nf-core/samtools/idxstats/main.nf` and `.../flagstat/main.nf`
have **no** `stub:` block at all — under `-stub-run` those two run for real against the fake
empty BAM and correctly refuse to read it. **Waived as the 6th documented departure** (same
class as ampliseq's `CUTADAPT_BASIC` and mag's `UNTAR`) — an upstream shared-module
stub-coverage gap, not a nanoseq or local-config defect; `SAMTOOLS_STATS`, which does have a
stub block, succeeds cleanly in the same run.

**Key outputs (DNA protocol, this procurement's scope):** `minimap2/*.sorted.bam(.bai)`,
`minimap2/samtools_stats/*.{flagstat,idxstats,stats}`, `nanoplot/NanoStats.txt` +
NanoPlot HTML/plots, `fastqc/`, `bigwig/*.bigWig`, `multiqc/`. Variant-calling outputs
(`--call_variants`), quantification (`bambu`/`stringtie2`), differential analysis, fusion
(JAFFAL), and RNA-modification (xpore/m6anet) outputs are **not produced** by this procurement's
scope — see below.

**QC verdict checklist (measured, no biological interpretation):** NanoPlot's mean/median read
length and read-quality distribution, `%Q7`/`%Q10`/`%Q12` read fractions, N50; `samtools
flagstat`'s primary-mapped percentage; `samtools idxstats`'s per-contig mapped-read counts
(single-contig for a bacterial genome, multi-contig for human); MultiQC's aggregated view of all
of the above. None of these are coverage-depth/variant-calling QC (out of scope this run, no
`--call_variants`).

**Scope of this procurement — lightest real configuration, not the full pipeline.**
`--protocol DNA`, already-basecalled FASTQ given directly as `input_file` with
`--skip_demultiplexing true` (avoids `--input_path`/`--barcode_kit`/qcat and any
GPU-basecalling assumption this host doesn't have configured), `--skip_quantification
--skip_differential_analysis --skip_fusion_analysis --skip_modification_analysis` (RNA-only
subworkflows, not applicable to DNA protocol), `--call_variants` left off entirely (medaka/
DeepVariant/pepper_margin_deepvariant not exercised). minimap2 aligner (default), default QC/
BigWig/BigBed left on. Enabling variant calling, a cDNA/directRNA run, or raw fast5 demultiplexing
are all future-work decisions with their own scope/reference/GPU-availability discussion, not
silently included here.

**First real-sample run** (`runs/20260813-nanoseq-srr25466853/`, SRR25466853, *E. coli* WGS, ONT
MinION, 4,000 reads / ~4.86 Mb, ~1.06× nominal coverage of the 4.64 Mb genome, chosen for small
ENA download size, no biological claim made): completed successfully (`completed=17 failed=0`).
Measured: 89.60% primary reads mapped (3,584/4,000 primary; 3,987/4,403 total incl.
secondary/supplementary), all 3,987 mapped reads on the single expected contig (`NC_000913.3`),
NanoPlot mean read length 1,214.2 bp / median 840.0 bp / N50 1,746 bp, mean read quality 11.0,
100% of reads above Q5/Q7, 76.0% above Q10. Wall clock ~2m31s, peak work-dir 53 MB, published
results 23 MB — see `estimates.md` for the full row.

### 4.15 `nf-core/rnasplice`

**For:** alternative splicing analysis from RNA-seq — event-level and isoform-level percent-spliced-in
(PSI) quantification and differential splicing, via SUPPA2, rMATS, DEXSeq (differential exon usage
and differential transcript usage), and edgeR (differential exon usage). **First splicing-specific
pipeline stocked here.**

**Not for gene/transcript expression quantification** — that is `nf-core/rnaseq` (§4.1), already
stocked. **The two are not redundant and do not automatically chain.** `rnaseq` produces gene/
transcript counts and TPM (STAR+Salmon or pseudo-alignment) and, chained into
`differentialabundance` (§4.2), a differential-*expression* result: which genes/transcripts go up
or down. `rnasplice` answers a different question entirely: for a given gene, does the *relative
mixture of its isoforms/exons* change between conditions — a PSI shift can happen with zero change
in a gene's total expression, and a large expression change can happen with zero PSI shift. A user
asking "which genes are differentially expressed" wants `rnaseq`→`differentialabundance`; a user
asking "which genes/exons are alternatively spliced" or "does this treatment change isoform usage"
wants `rnasplice`. **`rnasplice` runs its own alignment/quantification from FASTQ — it does not
consume `rnaseq`'s outputs.** `--source` accepts `fastq` (own STAR+Salmon or Salmon-only quant,
this procurement's scope), `genome_bam`, `transcriptome_bam`, or `salmon_results` (pre-computed
inputs from elsewhere), but there is no direct hand-off path from a completed `nf-core/rnaseq` run
— feeding `rnaseq`'s STAR BAMs in via `--source genome_bam` or its Salmon output via `--source
salmon_results` is possible in principle (matching input shape) but was **not verified this
procurement** and would need its own check before trusting it (transcript-fasta/index provenance
matters here — see the bounded-choice note in `runs/20260814-rnasplice-scer-gln3-ibutanol/plan.md`
about NOT reusing `rnaseq`'s Salmon index for exactly this reason).

**Schema-drift note #1 — `assets/schema_input.json` is unused, same class of finding as
nanoseq (§4.14).** At this pin (1.0.4) that file describes `sample`/`fastq_1`/`fastq_2`/
`strandedness`/`condition` but for the `fastq` source (the only source this procurement stocks)
is **never referenced by any `.nf` file** — grepped `workflows/`, `subworkflows/`, `modules/` for
`schema_input|validateParameters|nf-validation|nf-schema`, nothing wired to it. The samplesheet
actually enforced is the pipeline's own bundled `bin/check_samplesheet_fastq.py` (via the local
`SAMPLESHEET_CHECK` module). See `samplesheets.md` for the full column table, and note there that
one of that script's own stated rules (`check_condition_replicates()`, meant to require ≥2 rows
per `condition`) is confirmed dead code at this pin.

**Schema-drift note #2 — `--help`'s stated defaults do not match the pipeline's actual runtime
defaults.** `--help` (schema-derived) shows `aligner` defaulting to `star` and
`rmats`/`dexseq_exon`/`edger_exon`/`dexseq_dtu`/`sashimi_plot` all defaulting to `false`. The
pipeline's own `nextflow.config` — the file Nextflow actually loads, and which wins — sets
`aligner = 'star_salmon'` and **all five of those `true`**. Confirmed by reading `nextflow.config`
directly and by `-preview`'s "differs from pipeline defaults" summary. **The unscoped default run
is the full kitchen-sink toolset**, not the light one `--help` alone suggests — do not plan a run
from `--help` output alone for this pipeline.

**Minimum input (fastq source):** `sample`,`fastq_1`,`fastq_2` (header required even for
single-end; value may be empty),`strandedness` (`unstranded`/`forward`/`reverse` — **not** `auto`,
which this pipeline's own samplesheet checker rejects, unlike rnaseq),`condition` (a free-form
group label). Uniqueness key is the `(sample, fastq_1)` pair, not `sample` alone. A separate
`--contrasts` CSV (`contrast`,`treatment`,`control`) selects which condition pairs get a
differential-splicing comparison.

**Reference-store paths:** `--fasta`/`--gtf`, standard manifest paths (this procurement used
`genomes/R64-1-1/fasta/genome.fa` + `genomes/R64-1-1/gtf/genes.gtf.gz`, already stocked for
`rnaseq`). `--transcript_fasta`/`--star_index`/`--salmon_index` are all optional — the pipeline
builds them itself (`GTF_GENE_FILTER` → `RSEM_PREPAREREFERENCE` → `SALMON_INDEX`/
`STAR_GENOMEGENERATE`) if omitted. **Do not point `--salmon_index`/`--star_index` at another
pipeline's index of the same genome build** (e.g. `rnaseq`'s) without verifying the transcript-
fasta extraction and decoy handling match — rnasplice's own `RSEM_PREPAREREFERENCE`-based
extraction is a different code path than `rnaseq`'s, unverified for interchangeability; at small
genome scale (yeast, ~12 Mb) building rnasplice's own index costs well under a minute, so there is
no real reason to risk the substitution.

**Known gaps / stub-run behaviour.** `-stub-run` has one waived departure (7th documented, same
class as ampliseq/mag/nanoseq): `modules/nf-core/gunzip/main.nf`'s `stub:` block `touch`es an
empty placeholder for whichever of `--fasta`/`--gtf` is gzipped, and the downstream
`modules/local/gtf_gene_filter.nf` + `modules/nf-core/rsem/preparereference/main.nf` have **no**
`stub:` block at all, so they run for real against that empty stub input and legitimately fail
("The reference contains no transcripts!" or SUPPA's "No exons found", depending on which input
was gzipped) — confirmed by reading both modules and inspecting the stub work-dir's actual empty
files directly. The identical real (non-stub) command completes cleanly.

**Real, non-stub bug — found on the first real (non-CI-fixture) run, and load-bearing for scope.**
With `suppa_per_local_event` at its true default, `SUPPA_SALMON:GENERATE_EVENTS_IOE` **hangs
indefinitely** (measured: 53 real minutes at 99% CPU, never returning) whenever SUPPA finds zero
local splicing events of some type (SE/SS/MX/RI/AF/AL) in the genome/annotation — real on any
low-alternative-splicing organism, not a fluke. Root cause:
`modules/local/suppa_generateevents.nf`'s per-event-type `.ioe` concatenation —
`awk 'FNR==1 && NR!=1 { while (/^seqname/) getline; } 1 {print}' *.ioe` — spins forever once a
file's only line is the header being matched, because `getline` at EOF returns 0 without changing
`$0`, so the `while` condition never goes false. Reproduced standalone (outside the pipeline,
5-second `timeout`) on two synthetic header-only `.ioe` files. **Fix: `--suppa_per_local_event
false`** — structurally skips `GENERATE_EVENTS_IOE` (`subworkflows/local/suppa.nf`'s
`if (suppa_per_local_event)` gate, confirmed by reading it), leaving the per-isoform SUPPA branch
(`GENERATE_EVENTS_IOI`/`DIFFSPLICE_IOI`, transcript-level PSI/dPSI) unaffected. **This is now part
of the stocked default, not an optional flag** — see below.

**Key outputs (this procurement's scope):** `salmon/<sample>/quant.sf` (Salmon quantification),
`salmon/suppa/psi_per_isoform/suppa_isoform.psi` (per-sample transcript-level PSI),
`salmon/suppa/diffsplice/per_isoform/<contrast>_transcript_diffsplice.dpsi` (dPSI + p-value per
transcript/isoform between the two contrast conditions), `multiqc/`.

**QC verdict checklist (measured, no biological interpretation):** Salmon `percent_mapped` per
sample (this run: 92.5–95.8%, all 8 samples); TrimGalore pass rate / read counts vs
`--min_trimmed_reads` (default 10,000); FastQC per-sample flags; row count and nominal-p<0.05
fraction in the `*_diffsplice.dpsi` table (raw counts only — no multiple-testing-correction claim
unless the pipeline's own downstream `stageR` step is enabled, which this procurement's scope does
not exercise); MultiQC's aggregated view.

**Scope of this procurement — lightest combination that still exercises splicing detection, not
the kitchen-sink default.** `--skip_alignment true` (skips STAR entirely — SUPPA runs off plain
Salmon pseudo-alignment, not the STAR+Salmon combined path; structurally also gates off
`rmats`/`dexseq_exon`/`edger_exon`/`dexseq_dtu`/`sashimi_plot` since every one of those
subworkflows in `workflows/rnasplice.nf` is nested inside `if (!params.skip_alignment ...)`),
`--rmats/--dexseq_exon/--edger_exon/--dexseq_dtu/--sashimi_plot` all `false` explicitly
(redundant with the structural gate above, kept explicit so the config is self-documenting),
`--pseudo_aligner salmon` + `--suppa true` kept at default (SUPPA2 event/isoform generation,
PSI, differential splicing — the core this procurement exercises),
`--clusterevents_local_event/--clusterevents_isoform` both `false` (SUPPA's DBSCAN clustering of
significant events; disabled after a real reproducible CI-fixture failure when 0 events survive
significance — see `estimates.md`), and **`--suppa_per_local_event false`** (added mid-procurement
after the real hang above — per-isoform splicing detection only, not per-local-event). rMATS/
DEXSeq DEU/edgeR DEU/DEXSeq DTU/Miso sashimi are all out of scope: redundant or STAR-dependent
detection/visualization methods beyond SUPPA2's own core coverage, same "lightest combination
first" pattern as taxprofiler's kraken2-only and raredisease's `--skip_subworkflows` stocking.

**First real-sample run** (`runs/20260814-rnasplice-scer-gln3-ibutanol/`): 8 samples (4
conditions × 2 replicates), *S. cerevisiae* R64-1-1, real paired-end FASTQ reused from a prior
`rnaseq` procurement run (PRJEB33652, isobutanol response in WT/`gln3Δ`, no new download), 1
contrast (`WT_ibuoh` vs `WT_ctrl`). Salmon mapping rate 92.5–95.8% across all 8 samples.
Per-isoform `dPSI`/p-value table: 6,685 rows, 4,808 with nominal p<0.05 (uncorrected — no claim
about how many are real). See `estimates.md` for the full timing row, including the real
`GENERATE_EVENTS_IOE` hang found on this run.

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
nextflow run nf-core/rnaseq -r 3.18.0 ... \
  --input "$OUT/fetch/samplesheet/samplesheet.csv" \
  --outdir "$OUT/rnaseq"
```

The `--nf_core_pipeline rnaseq` flag is what makes the samplesheet drop-in compatible. Without it
you get a generic samplesheet and have to reshape it by hand.

### 5.2 rnaseq → differentialabundance

```bash
nextflow run nf-core/differentialabundance -r 1.5.0 \
  -profile docker,rnaseq \
  -c "$BIOINFO_HOME/config/local.config" \
  --input  samples_with_metadata.csv \
  --contrasts contrasts.csv \
  --matrix "$OUT/rnaseq/star_salmon/salmon.merged.gene_counts.tsv" \
  --transcript_length_matrix "$OUT/rnaseq/star_salmon/salmon.merged.gene_lengths.tsv" \
  --gtf    "$BIOINFO_REFS/genomes/GRCh38/gtf/genes.gtf.gz" \
  --outdir "$OUT/da"
```

`--transcript_length_matrix` is optional per the schema but is what the pipeline's own CI profile
pairs with the raw matrix (§4.2 above) — include it rather than passing the raw matrix alone.

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
nextflow run nf-core/sarek -r 3.5.1 ... \
  --step mapping --skip_tools baserecalibrator \
  --input samplesheet.csv --outdir "$OUT/sarek_map"

# later: call germline variants from the CRAMs already produced
nextflow run nf-core/sarek -r 3.5.1 ... \
  --step variant_calling --tools haplotypecaller \
  --input "$OUT/sarek_map/csv/markduplicates_no_table.csv" \
  --outdir "$OUT/sarek_hc"

# later still: annotate an existing VCF without recalling anything
nextflow run nf-core/sarek -r 3.5.1 ... \
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
nextflow run nf-core/sarek -r 3.5.1 \
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
# ExpansionHunter — targeted, catalog-driven, the standard short-read choice.
# The stocked disease catalog is bare-contig while the GRCh38gatk FASTA is chr-prefixed
# (see "Catalog/reference build must agree" below) — make a chr-prefixed copy once:
sed -E 's/"([0-9]+|X|Y|MT?):([0-9]+)-/"chr\1:\2-/g' \
  "$BIOINFO_REFS/catalogs/str/eh_catalog.disease.GRCh38.json" \
  > "$RUNDIR/eh_catalog.disease.chr.GRCh38.json"

ExpansionHunter \
  --reads         "$CRAM" \
  --reference     "$BIOINFO_REFS/genomes/GRCh38gatk/fasta/genome.fa" \
  --variant-catalog "$RUNDIR/eh_catalog.disease.chr.GRCh38.json" \
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

Catalog/reference build must agree — and the stocked STR catalogs do NOT agree with each other on
contig naming (verified 2026-08-22 against the store files). `eh_catalog.GRCh38.json` (full) and
`hipstr.GRCh38.bed` are `chr`-prefixed, so either stocked FASTA matches them. But
`eh_catalog.disease.GRCh38.json` uses bare GRCh38 contigs in every one of its 31 loci
(e.g. `14:92071009-92071042`) — it matches NEITHER stocked FASTA's naming, so check before launch
(`grep -o '"ReferenceRegion": "[^:"]*' <catalog> | sort -u`) and use a bare-contig FASTA or a
chr-renamed copy of the catalog with it — the `sed` in the ExpansionHunter example above builds
that copy. As always, **use the same FASTA the BAM was aligned against**, not merely a
compatible one.

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
per-read tags HiFi alignments carry. sarek's bwa path will not do — but `pipelines/pacbio-hifi-wgs`
(§4.20, added 2026-08-20) produces exactly this: a pbmm2 CCS-preset aligned (and optionally
WhatsHap-haplotagged) BAM. Chain: pacbio-hifi-wgs → TRGT on `02_alignedBAM/haplotagged/*.bam`.

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
| **methylseq with `bismark` on 30× human WGBS** | Not wrong, but it will run for days on this box | `--aligner bwameth` |
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

**This table is about rows only, and a row is not a file.** Rows removed from it over time because
the row does exist: `genomes/GRCh38/index/bowtie2/` (a `build` row from day one),
`genomes/GRCh38/index/bwameth/` (added 2026-08-05, exactly as section 4 already said),
`genomes/GRCh38/bed/blacklist.bed` (`fetch` row, PR #10), and — added 2026-08-06 during run
`20260806-cutandrun-hpsc-h3k27me3-smoke`, see §4.8 — the E. coli K12 spike-in fasta and its
bowtie2 index, plus cutandrun's own bundled GRCh38 blacklist.

**Which of those files actually exist is a separate question, and this paragraph has been wrong
about it in both directions.** It first implied a missing row meant a missing file; the correction
then overshot and asserted bowtie2/bwameth/blacklist were "still absent" with
`/refs/genomes/GRCh38/index/` an empty directory. Re-checked with `bash bootstrap/04-refs.sh
--dry-run` on 2026-08-07: **bowtie2 `OK` (6 entries), blacklist `OK`, E. coli fasta `OK`** —
bwameth is the one still `NOT BUILT`, as is the E. coli bowtie2 index. Do not repeat any of these
statuses from memory; the file-level list lives in `references/reference-store.md` and the dry-run
outranks both documents.

| Standard path | Mode | Needed by | Note |
|---|---|---|---|
| `genomes/GRCh38/index/bwa/` | build | chipseq (`--aligner bwa`), methylseq bwameth | the existing BWA index is on `GRCh38gatk`, a different FASTA |
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

### 4.16 `nf-core/isoseq`

**For:** PacBio Iso-Seq genome annotation — raw PacBio subreads in, gene/transcript models out.
Runs CCS generation (`pbccs`), primer removal (`lima`), chimera/polyA cleanup
(`isoseq3 refine` + TAMA `polyacleanup`) to produce Full-Length Non-Chimeric (FLNC) reads, maps
them to a reference genome (minimap2 or uLTRA), then cleans and merges gene models with TAMA
`collapse`/`merge` into a BED annotation. **First PacBio-specific pipeline stocked here, and the
second long-read-*only* pipeline overall** (after `nf-core/nanoseq`, ONT, §4.14).

**Not for:** general ONT long-read demultiplexing/QC/alignment (that's nanoseq, §4.14 — a
different sequencing platform with its own tool chain: qcat demux, minimap2/graphmap2 alignment,
medaka/DeepVariant SNV calling, none of which apply to PacBio Iso-Seq data) or short-read
alternative-splicing/PSI analysis (that's rnasplice, §4.15 — SUPPA2/rMATS/DEXSeq event-level
splicing statistics computed from Illumina short-read alignment/pseudo-alignment, structurally
incapable of processing raw long-read signal). Three genuinely different starting materials and
questions:
- **"I have raw PacBio Iso-Seq subreads and want gene/transcript models"** → isoseq (this
  section). Only pipeline stocked here that ingests PacBio subreads BAMs or does CCS generation
  at all.
- **"I have raw Oxford Nanopore reads (any protocol) and want demux/QC/alignment, optionally
  variant calling or RNA quantification"** → nanoseq (§4.14). Different platform, no CCS/FLNC
  concept — ONT reads are used directly.
- **"I have Illumina short-read RNA-seq and want to know whether isoform/exon usage differs
  between conditions"** → rnasplice (§4.15). No raw long-read signal involved at all; PSI/dPSI
  computed from short-read (pseudo-)alignment.
None of the three consumes another's output — there is no hand-off path between isoseq's FLNC/
BED annotation, nanoseq's aligned BAMs, and rnasplice's PSI tables in this repo.

**Schema drift note — a contrast with nanoseq/rnasplice, not the same finding.** At this pin
(2.0.0), `assets/schema_input.json` **is** the real, live validator:
`subworkflows/local/utils_nfcore_isoseq_pipeline/main.nf` calls `samplesheetToList(params.input,
..., schema_input.json)` directly, and there is no bundled `bin/check_samplesheet*.py` anywhere
in the clone (grepped `bin/` — empty). Confirmed by reading that subworkflow file directly. Read
the schema's `errorMessage` text as authoritative here, unlike the last two pipelines stocked.

**Minimum input:** `sample` (schema's only `required[]` field) plus, depending on
`--entrypoint`: `bam`+`pbi` (raw `.subreads.bam` + its **PacBio** `.bam.pbi` index — not a
samtools `.bai`) for `entrypoint: isoseq` (default), or `reads` (an already fully-processed FLNC
`.fa.gz`) for `entrypoint: map`. See `samplesheets.md` for the full column table and the `None`
placeholder convention.

**Why `entrypoint: map` is not actually the lighter path, despite looking like it.** It needs a
`.fa.gz` that is the *output* of `entrypoint: isoseq`'s own CCS→LIMA→REFINE→POLYACLEANUP chain
— nothing a public SRA/ENA PacBio Iso-Seq deposit ships directly. Manufacturing one outside the
pipeline to feed back in as `map` input would mean hand-running the pipeline's own tool chain
externally — the "hand-assemble a stocked pipeline" pattern this repo's hard rules forbid.
`entrypoint: isoseq` (this procurement's stocked default) is the only entry point obtainable
from an unmodified public deposit.

**Aligner choice — `minimap2`, not `ultra` (the CI test profile's own choice).** `--aligner`
is a required closed enum (`minimap2`/`ultra`), no default. `ultra` needs a sorted, indexed GTF
(`GNU_SORT` → `ULTRA_INDEX`) and is markedly heavier to set up for a first validation; `minimap2`
needs only the plain FASTA. `--gtf` is consumed **only** when `aligner: ultra`
(`SET_GTF_CHANNEL` is gated behind `if (params.aligner == "ultra")` in `workflows/isoseq.nf`) —
the stocked minimap2 default needs no GTF at all.

**Reference-store paths:** `--fasta`, standard manifest path. No prebuilt index required for
minimap2 (built in-run). This procurement added `genomes/GRCh38_isoseq_chr19/fasta/genome.fa` +
`.../gtf/genes.gtf` — **not** the existing chr-prefixed `genomes/GRCh38/fasta/genome.fa` — because
the real-sample reads (see below) are raw, unaligned PacBio subreads paired here with the
CI-matched, Ensembl-numbered (no `chr` prefix) reference — **not** because reusing the full
UCSC-style hg38 build would break minimap2 mapping (Codex review, PR #40, round 3: an earlier
version of this note wrongly claimed a chr-prefix naming mismatch would silently break mapping;
raw subreads carry sequence, not contig-name references, so minimap2 would map them against
either build just as well) — but for cost/provenance: the chr19-only reference is a small
fraction of the size and is exactly upstream's own CI test-config pairing. **The fasta is chr19
sequence ONLY** — despite the
directory name mentioning "isoseq" broadly and the paired GTF covering chr13+chr18+chr19 (Codex
review, PR #40, round 2: an earlier `GRCh38_chr1318_19` name incorrectly implied three-chromosome
fasta coverage) — a chr13/chr18 read in the "alz" real-sample subset has no target sequence to
align to at all under this fasta, which is a genuine mapping-rate ceiling for this reference
choice, not a contig-naming artifact. See `config/refs.manifest.tsv` for the fetch rows and
reasoning.

**Known gaps / stub-run behaviour — CI test profile vs. this procurement's stocked config
diverge.** The CI `test` profile itself (`-profile test,docker`, upstream's own `aligner=ultra`)
hits an **8th documented departure** (same class as ampliseq's `CUTADAPT_BASIC`/mag's `UNTAR`/
nanoseq's idxstats-flagstat/rnasplice's gunzip-rsem): `GNU_SORT` has a `stub:` block that
`touch`es an empty placeholder GTF, and `ULTRA_INDEX` has **no** `stub:` block at all (confirmed
by reading `modules/nf-core/ultra/index/main.nf` directly — no `stub:` section present), so it
runs for real against that empty GTF and fails (`gffutils.exceptions.EmptyInputError: No lines
parsed`) — `completed=12 failed=1`. **Waived, upstream stub-coverage gap, not a config defect —
but this failure is confined to the `ultra` branch this procurement does not stock.**
`-stub-run` on **this procurement's own stocked config** (`--aligner minimap2`, everything else
identical) — both the CI test-data variant and the real-sample command below — **passes
cleanly, no waiver needed**: `completed=11 failed=0` (CI data) and `completed=81 failed=0` (real
command), same class of clean pass as taxprofiler/raredisease.

**The mandatory full `-profile test,docker` gate** (`new-pipeline.md` §2.4(c) — this is "the
gate", not optional) was run non-stub, on the CI profile's own `aligner: ultra` default, and
**passes cleanly**: `succeededCount=19 failedCount=0 cachedCount=26`. This confirms the
`-stub-run` `ULTRA_INDEX` failure above is genuinely stub-coverage-specific and does not recur
in a real run — `ULTRA_INDEX` completed in ~62 min wall clock, the entire cost being `gffutils`
GTF-database creation over 55,652 features (measured incrementally in the task's own
`.command.err`, not a hang or an infinite loop). See `estimates.md` for the full measurement.

**Key outputs (numbered stage directories, not lowercase process names):** `09_GSTAMA_MERGE/
*.bed` (the final merged gene-model annotation) + `*_gene_report.txt`/`*_trans_report.txt`,
`07_GSTAMA_COLLAPSE/*_collapsed.bed` (pre-merge, per-chunk), `04_BAMTOOLS_CONVERT/*.fasta.gz`
(FLNC sequences, `entrypoint: isoseq` only), `01_PBCCS/*.report.txt`/`.json`,
`02_LIMA/*.lima.summary`/`.counts`, `03_ISOSEQ_REFINE/*.filter_summary.report.json`.
**`multiqc/` exists but never contains a report — see the real-run finding below.**

**Real (non-stub) bug — MultiQC never runs, in any configuration, at this pin.**
`workflows/isoseq.nf`'s own `MULTIQC(...)` call passes bare `channel.empty()` (not
`.toList()`/`.collect()`'d) for the module's `replace_names`/`sample_names` positional inputs;
`modules/nf-core/multiqc/main.nf` declares both as plain, non-list `path` inputs — an
ever-empty, non-collected channel input means the process is invoked **zero times**, regardless
of what every other (correctly `.collect()`'d) input channel carries. Confirmed two ways: by
reading both files directly (not inferred from absence alone), and empirically on the real-sample
run below — `succeededCount=38`, no `MULTIQC` task anywhere in the trace, `multiqc/` in the
published output contains only `software_versions*.yml` (published by
`CUSTOM_DUMPSOFTWAREVERSIONS`, a different process that happens to also use the multiqc
container), no `*_report.html`/`*_data` anywhere in the output tree. **A structural authoring
bug in the pipeline itself — there is no flag or config override that routes around it.** QC
verdicts for this pipeline must be read from the per-process report files listed above directly,
not from an aggregated MultiQC report.

**QC verdict checklist (measured, no biological interpretation):** PBCCS's CCS yield (ZMWs in /
ZMWs passing filters, `*.report.txt`), LIMA's primer-detection rate (ZMWs above all thresholds /
ZMWs input, `*.lima.summary`), the final FLNC read count and polyA-tail retention rate
(`*.filter_summary.report.json`), and the final collapsed/merged BED's gene/transcript-model
count (`*_gene_report.txt`/`*_trans_report.txt`). None of these are differential-expression or
splicing-significance statistics — isoseq produces an annotation, not a comparison.

**Scope of this procurement — lightest real configuration, not the full pipeline.**
`entrypoint: isoseq` (default, only honest entry point obtainable from public data — see above),
`aligner: minimap2` (default enum, lighter setup than `ultra`, no GTF needed), `capped: false`
(schema-required boolean with no stated default; no dataset metadata indicated a capped library
prep — a disclosed default, not a measurement), everything else at pipeline defaults (CCS
quality thresholds, TAMA wobble thresholds).

**First real-sample run** (`runs/20260814-isoseq-alz-chr19/`, the nf-core/isoseq project's own
CI subreads subset — genuinely real, non-synthetic data: a 1%/10,000-record subset of PacBio's
public "Alzheimer's Brain Iso-Seq" release, human chr13/18/19-restricted, chosen because every
independently-sourced SRA/ENA candidate checked either lacked the required native
subreads.bam+.pbi format (small yeast Iso-Seq runs are ENA-fastq-only, no `.pbi`) or exceeded
this repo's ~10 GB silent-download ceiling by roughly 9× (the pipeline's own "full" pig test
fixture, `ERR8606831`, 91.3 GB submitted — see `runs/20260814-isoseq-alz-chr19/plan.md` for the
full search record).

**Real (non-stub) bug hit on the first launch, load-bearing for `--chunk`.** Left at the
pipeline's own default (`--chunk 40`) against a dataset with only 531 ZMWs total (~13 per
would-be chunk — 106-107/chunk is the figure for the working `--chunk 5`), 29 of the 40 per-chunk `GSTAMA_COLLAPSE` outputs came out empty (zero reads
survived mapping/collapse in that chunk), and `GSTAMA_MERGE`'s `tama_merge.py` crashed reading
the first empty bed (`IndexError: list index out of range` at line 1 of a blank file) —
`completed=12 failed=1` before the crash. Confirmed real, not a stub artifact: reproduced by
counting zero-byte `*_collapsed.bed` files directly in the work dir. Fixed by setting `--chunk 5`
(matching what `conf/test.config` itself uses for the identical bam) and relaunching with
`-resume` — **`--chunk` must be sized to the input's actual ZMW count for a small dataset, not
left at the pipeline's default**, a bounded choice worth carrying into any future isoseq run
against a similarly small input.

Measured on the successful `--chunk 5` relaunch (`completed=38 failed=0`): 531 ZMWs input, 326
passed CCS filters (61.4%), 275 of those passed LIMA's primer-detection thresholds (84.4%) to
become FLNC reads, 100% of FLNC reads carried a polyA tail, 13 gene models / 13 transcript models
in the final chr19-restricted merged BED. See `estimates.md` for the measured wall clock and
work-dir peak, and the handoff for the full QC table.

### 4.17 `nf-core/bacass`

**For:** single-organism bacterial genome de novo assembly and annotation — short-read-only,
long-read-only (ONT), or short+long hybrid assembly (Unicycler/Canu/Miniasm/Flye/Raven/
Dragonflye/MEGAHIT/Autocycler), followed by annotation (Prokka/Bakta/DFAST/Liftoff) and QC
(QUAST/BUSCO/MultiQC). One isolate in, one genome's contigs + one annotation out.

**Not for, vs `nf-core/mag`:** mag (already stocked) does METAGENOME assembly — recovering
multiple, initially-unknown genomes from one community sample, via co-assembly, binning, bin QC,
and taxonomic classification of the resulting bins. bacass answers a structurally different
question: "assemble and annotate *this one bacterial isolate*" vs mag's "what organisms and
genomes are present in this community sample." bacass has **no binning step and no bin-level
taxonomic classification at all**; mag has **no per-isolate annotation** (Prokka/Bakta/DFAST)
and no reference-free single-genome QUAST/BUSCO reporting shaped for a known, single organism.
If the input is a mixed community sample (soil, gut, environmental swab) with an unknown number
of organisms, that's mag, not bacass. If the input is a single cultured isolate (a colony pick,
a clinical isolate, a reference-strain resequencing run), that's bacass.

**Not for, vs `nf-core/sarek`:** a much smaller point, stated for completeness — sarek is
human/vertebrate germline+somatic variant calling *against an existing reference*; it performs
no de novo assembly of anything. Nothing in sarek's scope overlaps bacass's (reference-free
contig construction), and nothing in bacass's scope overlaps sarek's (variant calling against a
known genome).

**Schema drift note — same shape as isoseq, a contrast with nanoseq/rnasplice.** At this pin
(2.6.1), `assets/schema_input.json` **is** the real, live validator:
`subworkflows/local/utils_nfcore_bacass_pipeline/main.nf:105` calls
`samplesheetToList(input, "$projectDir/assets/schema_input.json")` directly, and `bin/` in the
clone holds only `csv_to_yaml.py`/`find_common_reference.py`/`kmerfinder_summary.py`/
`multiqc_to_custom_csv.py` — none a samplesheet validator. Confirmed by reading that
subworkflow file directly.

**Minimum input, at the upstream schema level:** `ID` (schema's only `required[]` field) plus
at least one of `R1` (short-read mate 1, pairs with optional `R2`) or `LongFastQ` (ONT long
reads) — the schema itself does **not** enforce even this "at least one read source" rule (an
all-`NA` row validates cleanly, confirmed via `-preview`).

**Minimum input, for THIS REPO'S stocked scope specifically:** `R1` is required, full stop.
`scripts/check-samplesheet.sh --pipeline bacass` enforces `R1` directly, not the looser
"R1 or LongFastQ" the upstream schema would allow — because this repo's only stocked
configuration is `assembly_type: short` (see Scope below), which needs `R1` and never consumes
`LongFastQ` at all. A `LongFastQ`-only sheet is schema-valid upstream but will be **rejected by
this repo's checker**, since it has no usable read source under the only scope this repo
actually runs; a future procurement stocking `long`/`hybrid` would need to revisit that check
alongside the scope change. See `samplesheets.md` for the full column table, the comma-vs-tab
delimiter finding, and the `NA`/empty-string placeholder convention.

**Parameters that matter:** `--assembly_type` (`short`/`long`/`hybrid`, no default — selects
which read-source columns are actually consumed) and `--assembler` (comma-list; the workflow
gates each assembler's branch on `--assembly_type`, so a long-read-only assembler listed
alongside `assembly_type: short` is a structural no-op, not an error — confirmed by reading
`workflows/bacass.nf` lines ~132-345). `--annotation_tool` (`prokka` default, bundled
databases, vs `bakta`/`dfast`/`liftoff` — bakta in particular needs a separate multi-GB
`--baktadb_download`). `--skip_kraken2`/`--skip_kmerfinder` (contamination screening, each
needs an external database not currently in `$BIOINFO_REFS` — `--kmerfinderdb`'s own `--help`
text quotes ~30 GB for the full bacteria DB via FTP). `--reference_fasta`/`--reference_gff`
(both optional — QUAST runs its full reference-free metric suite without them, confirmed by
reading `workflows/bacass.nf:768-773`: empty tuples are passed to QUAST when unset).

**Reference-store paths:** none required. De novo assembly needs no reference genome, and this
procurement's stocked scope omits the optional QUAST reference comparison — see
`config/refs.manifest.tsv`'s bacass no-op note.

**Known gaps / stub-run behaviour.** `-stub-run` on the CI `test` profile's own flag set
(`assembly_type: short`, `assembler: unicycler`) fails at `UNICYCLER` — a **9th documented
departure**, but a different SHAPE from every prior case in this list: `modules/nf-core/
unicycler/main.nf`'s `stub:` block hardcodes `cat "" | gzip > ...` (a literal empty-string
filename argument), which fails unconditionally (`cat: '': No such file or directory`)
regardless of input shape. Every prior departure (ampliseq/mag/nanoseq/rnasplice/isoseq) was a
downstream module reading an upstream module's empty stub PLACEHOLDER FILE for real; here the
failing process's own stub script is malformed on its own, no downstream module involved.
`completed=8 failed=1`. No substitute-input workaround possible — there is no read-shaped input
that fixes a hardcoded `cat ""`. **Waived** — `-preview` is the pre-launch gate; see
`runbook.md` §4 for the full writeup.

**The mandatory full `-profile test,docker` gate** (`new-pipeline.md` §2.4(c)) was run non-stub
on the CI profile's own default flag set and **passes cleanly**: `completed=17 failed=0`,
~13m8s wall clock. Confirms the `-stub-run` `UNICYCLER` failure above does not recur in a real
run. The identical `-preview`/`-stub-run` sequence, re-run against the real-sample command
below, shows the same pattern (stub fails at `UNICYCLER` for the same reason, `-preview` clean).

**Key outputs:** `Unicycler/*.scaffolds.fa.gz` (assembly contigs) + `*.assembly.gfa.gz`
(assembly graph), `Prokka/<sample>/‹sample›.{txt,gff,faa,ffn,...}` (annotation, `.txt` carries
the CDS/rRNA/tRNA/tmRNA/repeat_region counts), `QUAST/report/report.{txt,tsv}` (N50/L50/contig
count/total length/GC%/largest contig), `busco/short_summary.*.txt` (BUSCO complete/fragmented/
missing lineage-completeness percentages), `multiqc/multiqc_report.html` (aggregated — unlike
isoseq, MultiQC runs normally here, confirmed on both the test-profile and real-sample runs).

**QC verdict checklist (measured, no biological interpretation):** contig count and N50/L50
from QUAST (assembly contiguity), BUSCO's Complete/Fragmented/Missing percentages against the
`bacteria_odb10` lineage (assembly completeness), Prokka's CDS/rRNA/tRNA count (annotation
yield), fastp's passed-filter read fraction (input read quality). None of these are species
identity, contamination, or pathogenicity claims — bacass with `--skip_kraken2
--skip_kmerfinder` performs no contamination/identity check at all; that is explicitly out of
this procurement's scope (see below).

**Scope of this procurement — lightest real configuration, matching the pipeline's own CI
test-profile shape exactly.** `--assembly_type short --assembler unicycler
--annotation_tool prokka --skip_kraken2 --skip_kmerfinder`, no `--reference_fasta`/
`--reference_gff`. Out of scope: long-read/hybrid assembly, Bakta/DFAST/Liftoff annotation,
Kraken2/KmerFinder contamination screening (both need external databases not in
`$BIOINFO_REFS`), Autocycler multi-assembler consensus, Rasusa downsampling, reference-based
QUAST comparison.

**Real-sample run** (`runs/20260816-bacass-srr2589044-realsample/`): `SRR2589044` (ENA/SRA),
*E. coli* B str. REL606, Illumina HiSeq 2500 PE, 1,107,090 read pairs / 332.1 Mbp (~72x coverage
of the 4.6 Mb genome), ~251 MiB total gzip — chosen for small size and adequate depth, disclosed
before download, no approval needed (well under the ~10 GB ceiling). `completed=9 failed=0`,
8m21s wall clock. Measured QC: QUAST 61 contigs (≥500bp) / N50 143,933 bp / L50 10 / total
length 4,545,618 bp / GC 50.72% / largest contig 328,315 bp; BUSCO 100.0% complete
(S:100.0%,D:0.0%,F:0.0%,M:0.0%, n=124, `bacteria_odb10`); Prokka 4,232 CDS / 5 rRNA / 77 tRNA /
1 tmRNA / 2 repeat_region across 111 contigs (Prokka's own unfiltered contig set — QUAST's
≥500bp filter drops some of these); fastp 1,890,006 / 2,214,180 reads passed filter (~85.4%).
See `estimates.md` for the full wall-clock/disk measurement and `handoff.md` for the complete
QC table.

### 4.18 `nf-core/viralrecon`

**For:** viral genome analysis from amplicon or metagenomic Illumina/Nanopore reads — reference-
based mapping + variant calling (including intrahost/low-frequency variants via Freyja) or de
novo assembly, consensus genome generation, and Pangolin/Nextclade lineage & clade assignment.
Originally built for SARS-CoV-2 but genome-agnostic (any `--fasta`/`--gff`/`--primer_bed`).
This procurement stocks the illumina/amplicon/reference-based path only — no Nanopore entry
point, no de novo assembly branch (`--skip_assembly true`).

**Not for, vs `nf-core/taxprofiler` (already stocked) — the contrast a "detect virus in this
sample" request could plausibly confuse.** taxprofiler answers "what taxa are present, and
roughly how much" — shotgun/amplicon reads through up to 14 taxonomic profilers (this repo
stocks kraken2 only), producing per-sample/per-database relative-abundance tables. It performs
**no assembly, no per-sample consensus sequence, and no lineage/clade call at all** — it never
even establishes a reference coordinate system for any one organism. viralrecon answers a
structurally different question: "I already know (or strongly suspect) this sample is one
particular virus, targeted with an amplicon panel or shotgun-sequenced — give me that virus's
consensus genome, its variants (including intrahost/low-frequency ones), and a lineage/clade
call." viralrecon produces a per-sample FASTA consensus and VCF against a named reference;
taxprofiler produces neither. A request phrased "what's in this sample" or "screen this sample
for pathogens" is taxprofiler's question (or, if metagenomic assembly of unknown organisms is
wanted, `mag`); a request phrased "assemble/call variants/lineage-type this known-virus
amplicon run" is viralrecon's. Neither substitutes for the other — taxprofiler cannot produce a
consensus genome or a lineage call, and viralrecon requires a specific named reference genome
and will not survey an unknown community sample.

**Not for, vs the other stocked pipelines:** sarek is human/vertebrate variant calling; bacass
is single bacterial genome assembly; mag is metagenome assembly+binning across potentially many
organisms. None of the three touch viral-genome-specific tooling (ARTIC amplicon primer
trimming, Pangolin/Nextclade lineage calling, Freyja intrahost deconvolution) at all.

**Schema drift note — schema IS the live validator, same class as isoseq/bacass.**
`subworkflows/local/utils_nfcore_viralrecon_pipeline/main.nf:100/122` calls
`samplesheetToList(params.input, "${projectDir}/assets/schema_input.json")` directly; `bin/`
in the clone holds only `fastq_dir_to_samplesheet.py`, a samplesheet *generator*, not a
validator. `sample` is the only `required[]` field — `fastq_1`/`fastq_2`/`barcode` are all
individually optional at schema level, so a row with no read source validates cleanly (checked
in `scripts/check-samplesheet.sh --pipeline viralrecon`, not left to the schema, same pattern as
taxprofiler/mag/raredisease/bacass). Repeated `sample` is a **supported** multi-lane/multi-run
merge (`.groupTuple()` keyed on `meta.id`), not a uniqueEntries gap — `validateInputSamplesheet()`
only rejects a repeated sample whose rows disagree on single-end vs paired-end. See
`samplesheets.md` for the full column table.

**A genuine `--help` usability quirk, worth knowing before you type it:** bare
`nextflow run nf-core/viralrecon -r 3.0.0 --help` does **not** print help — it fails with
"Parameter --platform is required (illumina / nanopore). Please specify." `main.nf`'s top-level
script (`main.nf:21-24`) hard-requires `--platform`, and `workflows/viralrecon.nf`'s top-level
script (`workflows/viralrecon.nf:49`) hard-requires `--input`, and **both execute before**
`PIPELINE_INITIALISATION`'s nf-schema help handler ever runs (top-level Groovy script code in an
`include`d file runs at parse/include time, not at workflow-invocation time). `--platform
illumina --input <any-existing-path> --help` prints the full help text and exits 0 cleanly.

**Parameters that matter:** `--platform` (`illumina`/`nanopore`, no default, hard-required —
this procurement stocks `illumina` only), `--protocol` (`amplicon`/`metagenomic` — this
procurement stocks `amplicon`), `--fasta`/`--gff`/`--primer_bed` (explicit paths — see below,
NOT the `--genome` shorthand), `--skip_assembly` (this procurement sets `true`; unset, the
default assembly branch runs SPAdes+Unicycler+minia together, then BLAST/ABACAS/QUAST/Bandage/
PlasmidID on each), `--variant_caller`/`--consensus_caller` (left at pipeline default:
`ivar`/`bcftools`), `--kraken2_db` (host-read filtering; the schema's own DEFAULT — not
something this procurement added — is a small S3-hosted human-only DB), `--pango_database`/
`--nextclade_dataset`/`--nextclade_dataset_name`/`--freyja_barcodes`/`--freyja_lineages` (all
four exist specifically so the pipeline's own runtime auto-fetch/auto-update processes
(`PANGOLIN_UPDATEDATA`/`NEXTCLADE_DATASETGET`/`FREYJA_UPDATE`) can be skipped in favour of a
static, pre-fetched local path — this procurement uses all four, after real environment findings
below).

**Do NOT use `--genome MN908947.3` (or any `--genome` value) on this box without also setting
`--custom_config_base` to a local mirror.** `--genome` resolves `--fasta`/`--gff`/`--primer_bed`/
`--nextclade_dataset*` through nf-core/configs' own remote `conf/pipeline/viralrecon/
genomes.config`, which `nextflow.config` fetches via `raw.githubusercontent.com` — the exact
host this procurement found to be intermittently rate-limited (`HTTP 429`) on this box (see
"Environment findings" below). Explicit `--fasta`/`--gff`/`--primer_bed` CLI/params-file values
survive even when `--genome` is unset (confirmed via `-preview`: `main.nf`'s own
`params.fasta = getGenomeAttribute('fasta')` reassignment at parse time does NOT clobber a
CLI-supplied value — Nextflow applies CLI/params-file params with final precedence over any
in-script `params.x = ...` assignment). This repo's stocked configuration therefore never passes
`--genome` at all for a real run.

**Reference-store paths:** `genomes/SARS-CoV-2-MN908947.3/fasta/genome.fa` + `gff/genome.gff`
(NCBI `eutils`, MN908947.3 — SARS-CoV-2 isolate Wuhan-Hu-1), `.../primer/artic-v3/primer.bed`
and `.../artic-v4.1/primer.bed` (ARTIC nCoV-2019 primer schemes — pick the version matching the
sample's actual wet-lab protocol, this is a per-run choice, not a pipeline default), `db/pangolin/`
(pangolin-data v1.32, extracted from the pinned module container), `db/nextclade/sars-cov-2/`
(Nextclade SARS-CoV-2 dataset), `db/freyja/usher_barcodes.feather` + `curated_lineages.json`
(Freyja UShER barcodes), `db/kraken2_viralrecon_human/kraken2_human/` (viralrecon's own default
host-filter DB). Full fetch/build provenance for every row in `config/refs.manifest.tsv`.

**Environment findings — three separate runtime-fetch/rate-limit/TLS issues, all routed around
by pre-fetching a static local copy instead of letting the pipeline fetch at runtime:**
1. `raw.githubusercontent.com` (GitHub's CDN) repeatedly returned `HTTP 429 Too Many Requests`
   on this box during this procurement — blocking `nextflow.config`'s own remote `includeConfig`
   (fixed with a local `git clone`-sourced `--custom_config_base` mirror), the CI test profile's
   own fixture fetch (fixed the same way), and `FREYJA_UPDATE`'s barcode-DB fetch (fixed by
   pre-fetching `usher_barcodes.feather`/`curated_lineages.json` via `git clone` and setting
   `--freyja_barcodes`/`--freyja_lineages`). Confirmed transient/rate-limit, not a hard network
   block — `github.com`, `api.github.com`, `quay.io`, EBI, NCBI, and S3 were all reachable
   throughout; a `git clone --filter=blob:none --sparse` against `github.com` directly (not
   `raw.githubusercontent.com`) sidesteps it entirely for any file that lives in a git repo.
2. `PANGOLIN_UPDATEDATA`'s `pangolin --update-data` hits GitHub's
   `/repos/cov-lineages/pangolin-data/releases` **list** endpoint (not `/releases/latest`),
   which returned a genuinely empty `[]` (HTTP 200) from this box's egress on every retry —
   confirmed via host `curl` AND `python3 urllib` run *inside* the pinned pangolin container
   itself, ruling out a client-side quirk. Routed around by extracting the pangolin-data version
   already baked into that same pinned container image instead (`--pango_database`).
3. `NEXTCLADE_DATASETGET` needs `data.clades.nextstrain.org`, which this box's corp
   TLS-inspecting proxy ("ePrism SSL"/SOOSAN INT — the same proxy `bootstrap/06-tls-trust.sh`'s
   own docstring names for `get.nextflow.io`) intercepts **inside a fresh Docker container's own
   trust store**, even though the HOST already trusts that proxy's CA from an earlier
   `bootstrap/06-tls-trust.sh --accept` run. A genuinely new class of TLS-trust gap for this
   repo (container-local, not host-level, unlike every prior `06-tls-trust.sh` finding). Routed
   around for the one-off manual dataset fetch by mounting the host's `ca-certificates.crt` into
   the container with `SSL_CERT_FILE` set, then never invoking `NEXTCLADE_DATASETGET` in the
   real pipeline run at all (`--nextclade_dataset` static path skips it structurally).

**Known gaps / stub-run behaviour.** `-stub-run` on `-profile test,docker` fails at the
primer/reference contig-match check (`CUSTOM_GETCHROMSIZES`'s stub writes an empty `.fai`,
which `checkContigsInBED()` then reads for real) — **11th documented departure**, waived,
confined to stub mode, data/config-independent. `-preview` is the pre-launch gate; the full
non-stub `-profile test,docker` gate passes cleanly (`completed=187 failed=0 cached=8`,
~23m wall clock). See `runbook.md` §4 for the full writeup.

**Key outputs:** `variants/ivar/consensus/bcftools/<sample>.consensus.fa` (masked consensus
genome), `variants/ivar/<sample>.vcf.gz` (called variants), `variants/bowtie2/mosdepth/genome/
<sample>.mosdepth.summary.txt` + `.../amplicon/<sample>.mosdepth.coverage.tsv` (genome-wide and
per-amplicon depth — the per-amplicon table is what actually reveals amplicon dropout, not the
summary mean alone), `<sample>.pangolin.csv` (raw Pangolin lineage call), Nextclade
`<sample>.csv`/`.tsv` (raw clade call + QC flags), `freyja/demix/<sample>.demix.tsv` (intrahost
lineage-abundance deconvolution), `multiqc/multiqc_report.html`.

**QC verdict checklist (measured, no biological interpretation):** consensus completeness
(% non-N bases, `<sample>.consensus.fa`), mean AND per-amplicon/per-window coverage depth
(mosdepth — a high mean with low breadth is amplicon dropout, visible only in the per-amplicon
table, not the summary), iVar/bcftools variant count, fastp/Kraken2 read-passed fractions,
Pangolin `qc_status` (raw string, e.g. `pass`/`fail`, plus its `note` field), Nextclade
`qc.overallStatus`. None of these are claims about outbreak significance, transmission, or
clinical relevance of any lineage/variant — report the raw tool output string, nothing more.

**Real-sample run** (`runs/20260818-viralrecon-sample01-realsample/`): `SAMPLE_01` from
viralrecon's own `conf/test_full.config` real-world validation cohort (S3-hosted,
protocol-confirmed ARTIC V3), Illumina PE, ~132 MiB gzip total, 2,028,184 raw read pairs —
chosen specifically because the primer scheme is protocol-documented (unlike an arbitrary
SRA/ENA pick, where it frequently is not). `completed=52 failed=0`, 3m46s wall clock, 356 MB
peak work dir. Measured QC: only 23,644 primary reads (~1.2% of input) mapped to MN908947.3
after Kraken2 human-host depletion — expected for a low-viral-titer surveillance sample; mean
genome depth 74.1x but severely uneven (per-amplicon `coverage.tsv` shows most 200bp
windows/amplicons at 0x, a handful up to 9,894x — amplicon dropout, confirmed by reading the
per-amplicon mosdepth table directly, not a masking bug); consensus 29,903 bp with 29,535 N
(98.77% N, 1.23% ACGT completeness); 2 iVar variants called; Pangolin lineage "Unassigned"
(`qc_status=fail`, `note=Ambiguous_content:0.99` — reported as the tool's raw output string);
Nextclade clade `21L (BA.2)` called despite the QC-failing consensus (Nextclade aligns and calls
on whatever sequence is present; its own `coverage` field reports 0.0123). This is a genuine,
unfavourable-but-real measurement — the pipeline executed and reported correctly on a real
low-viral-load sample; it is not a run failure and no re-pick was done to get a "nicer" number.
See `estimates.md` for the full wall-clock/disk measurement and `handoff.md` for the complete
QC table.
### 4.19 `nf-core/spatialaxe`

**For:** spatial transcriptomics QC and processing for 10x Genomics **Xenium** in-situ imaging
data — cell/nucleus segmentation (image-based via Cellpose/StarDist/XeniumRanger, or
coordinate/transcript-based via Proseg/Segger/Baysor), segmentation-free neighbourhood analysis
(Ficture/Baysor), transcript-to-cell assignment, and QC reporting (MultiQC's xenium-extra
plugin + off-target-probe-tracking). **FIRST spatial transcriptomics / imaging-based pipeline
stocked here** — a genuinely new domain. Input is an already-generated **Xenium Onboard
Analysis (XOA) output bundle** (a directory of parquet/zarr/h5/csv.gz/OME-TIFF files the
instrument's own onboard software produced), not raw sequencing reads in any FASTQ sense —
confirmed by reading `workflows/spatialaxe.nf` directly, not assumed from the pipeline's name.
`nf-core/spatialvi` (a different, Visium-based spatial pipeline) was considered and rejected:
only a `dev`-branch tag (0.1.0), no formal GitHub Release — fails this repo's trust gate
(`new-pipeline.md` §2.4).

**Not for, vs `nf-core/scrnaseq`:** scrnaseq (already stocked) quantifies per-cell gene
expression from droplet/well-based **dissociated** single cells — the tissue is disaggregated
before sequencing, so no spatial location survives; a cell's only "position" is which
droplet/well it landed in. spatialaxe quantifies per-cell gene expression **with real spatial
coordinates preserved on the original tissue**, derived from in-situ imaging (Xenium probes
hybridize and are imaged directly in an intact tissue section — every transcript and every
segmented cell carries an (x, y) micron position). scrnaseq has zero spatial/imaging component
at all; spatialaxe's entire pipeline (cell segmentation from a morphology image,
transcript-to-cell assignment on a coordinate plane, micron-region tiling/patching) has no
scrnaseq analogue whatsoever. Different question: "what genes does this dissociated cell
express" (scrnaseq) vs "what genes does this cell express **and where does it sit in the
tissue**" (spatialaxe). If the input is a 10x-format `.h5`/`.mtx` cell-by-gene matrix from a
droplet run (Chromium), that's scrnaseq. If the input is a Xenium bundle with cell/transcript
spatial coordinates, that's spatialaxe.

**Schema drift note — a genuinely new shape at this repo, not matching either prior pattern.**
`assets/schema_input.json` **is** wired in and **is** the live column-shape validator
(`subworkflows/local/utils_nfcore_spatialaxe_pipeline/main.nf:137` calls `samplesheetToList()`
directly against it) — same class as isoseq/bacass/viralrecon, unlike nanoseq/rnasplice where
the shipped schema is vestigial. **But the schema alone is not sufficient**, unlike every one of
those four prior cases: `workflows/spatialaxe.nf` (~lines 177-220) layers its own POST-STAGING
bundle-CONTENT check on top, via plain Groovy `error()` calls that enforce a fixed 16-entry
required-file list inside the `bundle` directory — something no JSON Schema keyword can express.
Confirmed by reading that block directly, not inferred from its existence.

**Minimum input:** `sample` + `bundle` (schema's only two `required[]` fields), `image` optional
(falls back to `morphology.ome.tif` inside `bundle` when omitted). **But `bundle` passing the
schema's `^\S+$` pattern check is nowhere near "usable input"** — it must resolve to a local,
already-extracted directory (a tarball URL only auto-stages under `-profile test`, gated by
`workflow.profile.contains('test')`) containing all 16 of `workflows/spatialaxe.nf`'s own
`bundle_required_files` (see `samplesheets.md` for the full itemized list) — a missing one
aborts before any process runs, with a message the schema layer never produces. See
`samplesheets.md` for the full column table and the exact required-file list.

**Parameters that matter:** `--mode` (`image`/`coordinate`/`segfree`/`preview`/`qc`, no
default — selects the whole processing path: `image` runs
`CELLPOSE→BAYSOR→XR-IMPORT_SEGMENTATION→SPATIALDATA→QC`, `coordinate` runs
`PROSEG→PROSEG2BAYSOR→XR-IMPORT_SEGMENTATION→SPATIALDATA→QC`, `segfree` runs
`BAYSOR_SEGFREE`, `preview` runs `BAYSOR_PREVIEW`, `qc` runs QC alone). `--method` further picks
a specific tool within a mode (`cellpose`/`xeniumranger`/`baysor`/`stardist` for image;
`proseg`/`baysor`/`segger` for coordinate; `baysor`/`ficture` for segfree). `--run_qc` (default
`true`) couples the QC layer onto any other mode. `--gene_panel` (defaults to the bundle's own
`gene_panel.json` when unset). No genome/reference parameters exist anywhere in
`nextflow_schema.json` — this pipeline does no alignment.

**Resource note that drove this procurement's scope, straight from the pipeline's own README
runtime table (measured by the pipeline authors, not by this procurement):** Cellpose on CPU
peaks at up to **1115 GB RSS** on a real full-size Xenium slide (554 GB even on GPU); Baysor
whole-image up to 650 GB; XeniumRanger resegment up to 60 GB; Segger needs a GPU for all three
of its steps. This box's Nextflow pool is 16 cores / 18 GB (`config/host.env`) — orders of
magnitude under what real, full-size image-mode segmentation needs. **Proseg (coordinate mode)
is by far the lightest tool in that table** (279 MB / 3.8 GB / 136 GB min/med/max RSS) and is
the only realistic choice for anything beyond a genuinely tiny bundle on this hardware.

**Reference-store paths:** none. spatialaxe consumes only the Xenium bundle's own pre-computed
transcript/cell/probe-panel data; there is no alignment step and no genome FASTA/GTF parameter.
No rows needed in `config/refs.manifest.tsv`.

**Known gaps / stub-run behaviour.** `-stub-run` on the CI `test` profile (`--mode coordinate`,
the profile's own default) **PASSES CLEANLY** at this pin:
`succeededCount=10 failedCount=0` (Nextflow's own `WorkflowStats`) — **no waiver needed, no 12th
documented departure**, same class as taxprofiler/raredisease/isoseq's minimap2 branch/bacass's
full-gate. First run took ~11.5 minutes wall clock, almost entirely first-pull time for two
container images (`quay.io/nf-core/xeniumranger:4.0`, 3.78 GB; a Wave-built MultiQC
xenium-extra-plugin variant, ~3 GB) — the 10 stub tasks themselves completed in 21.2 seconds
combined once the images were cached.

**The mandatory full `-profile test,docker` gate** (`new-pipeline.md` §2.4(c)) — see
`estimates.md` and the procurement `plan.md`/`handoff.md` for the complete measured writeup.

**Key outputs (coordinate mode, this procurement's stocked scope):**
`coordinate/proseg/preset/cell-polygons.geojson.gz` (2D cell polygons), `expected-counts.csv.gz`
(cell-by-gene count matrix), `cell-metadata.csv.gz` (centroids/volume), `coordinate/
proseg2baysor/xr-cell-polygons.geojson` + `xr-transcript-metadata.csv` (stitched, XeniumRanger-
importable format), `multiqc/multiqc_report.html` (aggregated, xenium-extra-plugin sections),
`opt/stat/*.tsv` (off-target-probe-tracking summary stats).

**QC verdict checklist (measured, no biological interpretation):** cell/nucleus count from the
bundle's own `metrics_summary.csv`/`experiment.xenium` (`num_cells`), transcripts-per-cell and
genes-per-cell from the same, fraction of transcripts assigned to a cell
(`fraction_transcripts_assigned`), Proseg's own per-cell transcript-assignment probability
summary, and MultiQC's xenium-extra QC sections (segmentation/assignment metrics aggregated
across whatever tool ran). None of these are tissue-architecture or cell-type-identity claims.

**Scope of this procurement — lightest real configuration.** Test-profile run left entirely at
`conf/test.config`'s own defaults (`--mode coordinate`, no other overrides) — no hand-picked
tool combination. Real-sample run used the same coordinate-mode default. Image-mode segmentation
(Cellpose/StarDist/XeniumRanger resegment) and Segger (GPU-only) are explicitly **out of scope**
this procurement, per the resource note above.

**Real-sample run:** see `estimates.md`/`handoff.md` for the complete measured numbers
(`Xenium_Prime_Mouse_Ileum_tiny_outs`, a real 10x-published "tiny_outs" Xenium bundle, 23 MB
extracted, 23 cells — found on `nf-core/test-datasets@spatialaxe`, well under the ~10 GB silent-
download ceiling).

### 4.20 `pipelines/pacbio-hifi-wgs` (in-repo)

**For:** PacBio HiFi human WGS germline variant calling — raw subreads and/or HiFi reads and/or
already-aligned BAMs in, per-dataset deliverables out: HiFi uBAM (`pbccs`), aligned BAM (`pbmm2`),
SNV/indel VCFs (DeepVariant **and** Clair3, plus SNV/INDEL convenience splits), phased VCF +
haplotagged BAM (WhatsHap), SV VCF (`pbsv`), mosdepth/samtools/bcftools QC + MultiQC. The first
**in-repo** pipeline: it lives at `pipelines/pacbio-hifi-wgs/` in this repository, is not an
nf-core pipeline, has no `-r` (revision = repo checkout), and uses zero Nextflow plugins so the
directory can be copied to an offline SGE+Singularity cluster and run as-is. Order follows
PacBio's HiFi-human-WGS-WDL v1.x: DeepVariant (≥1.4, internal read phasing) and pbsv both consume
the plain aligned BAM; WhatsHap phases afterwards.

**Not for:** somatic tumour–normal calling (no paired mode — DeepSomatic/ClairS are different
tools). Not for ONT (nanoseq, §4.14). Not for Iso-Seq (isoseq, §4.16). Not for short reads
(sarek, §4.4). Not for assembly. Repeat genotyping is downstream: its haplotagged pbmm2 BAM is
exactly what TRGT consumes (§6.2, which this pipeline un-blocks).

**Minimum input:** `--input samplesheet.csv --fasta ref.fa`. Samplesheet columns
`sample,dataset,input_type,file[,index]` — the `input_type` column (`subreads` | `hifi_bam` |
`hifi_fastq` | `aligned_bam` | `clr_subreads`) is the per-row mid-pipeline entry mechanism; rows sharing
(sample,dataset) merge after alignment. Full spec: `references/samplesheets.md` and the
pipeline's own `README.md`.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--clair3_model` | `hifi_revio` (default) \| `hifi_sequel2` \| `hifi` | **must match platform** — movie prefix m84=Revio, m64=Sequel II (→`hifi_sequel2`), m54=Sequel. Wrong model runs silently with degraded accuracy |
| `--phase_vcf` | `deepvariant` (default) \| `clair3` | which small-variant VCF WhatsHap phases/haplotags from |
| `--pbsv_tandem_repeats` | TRF bed | officially recommended for pbsv discover; absent = still runs |
| `--ccs_chunks` | 8 | size to the movie's ZMW count — the isoseq §4.16 lesson (empty chunks crash downstream) applies to any chunked CCS |
| `--clair3_args` | `--include_all_ctgs` | only to call decoy/unplaced/ALT contigs — Clair3's default set covers 1–22/X/Y with AND without `chr` prefix, so plain hs37d5 needs nothing |
| `--container_*` | image URIs | every tool image is a param; defaults verified 2026-08-20 |

**Version pins that are choices, not defaults:** clair3 `v1.2.0` deliberately (hkubal/clair3
v2.x images drop **all** bundled HiFi models — verified empirically on v2.0.2); pbmm2 26.2.0
(calendar versioning since 2026); DeepVariant 1.10.0; WhatsHap 2.8 (phases indels by default,
unlike the 0.17 used for the historical GIAB haplotagged BAMs — `--whatshap_args --only-snvs`
restores old behaviour).

**Reference-store paths:** any FASTA works via `--fasta`; on this host
`$BIOINFO_REFS/genomes/GRCh38gatk/fasta/genome.fa` (chr-prefixed, no-ALT) is the natural choice.
`.fai` and `.mmi` are built in-run; no pre-built index rows needed.

**Validation record (2026-08-20, `docs/examples/20260820-pacbio-hifi-wgs-validation/`):**
`-stub-run` passes end to end on a mixed 5-row samplesheet covering all four entry types
(60+ tasks, all callers + phasing + QC). Real E2E: (a) `-profile test,docker` runs real subreads
(nf-core isoseq CI subset) through pbindex→ccs→pbmerge→pbmm2; (b) HG002 GIAB Sequel II HiFi
chr20:1–3 Mb (11,004 reads, S3 range-fetch) through the full caller chain against a chr20-only
GRCh38 ref. Wall-clock/disk: `references/estimates.md`. **Accuracy** (2026-08-20/21,
`hap-py-accuracy.md` in the same folder): hap.py vs GIAB HG002 NISTv4.2.1 truth, same
chr20:1–3 Mb region, confident-BED-restricted (2.77 Mb, 4,793 evaluated truth records) — DeepVariant SNP
F1 0.9999 / INDEL F1 0.9960, Clair3 (`hifi_sequel2`) SNP F1 1.0000 / INDEL F1 0.9984. **Scope
note:** this is a chr20:1–3 Mb slice, not a whole-genome accuracy claim — no segdup/HLA/centromere
coverage; and the input FASTQ was range-fetched from GIAB's own already-aligned BAM, so this
measures caller accuracy on reads a prior alignment already placed in the region, not
alignment-stage recall on unselected reads (detail: `hap-py-accuracy.md`).
**SV accuracy is still open:** hap.py scores only small variants (symbolic `<DEL>`/`<INS>`/`BND`
are outside its model, and v4.2.1 holds nothing >=50 bp), so pbsv has no accuracy number yet.
Closing it needs Truvari against a GIAB SV truth set, which is **HG002-only** and forces a
reference-build choice — Tier1 SV v0.6 is stable but GRCh37-only, the T2T-Q100 `stvar` set covers
GRCh38 but is labelled draft by its own authors. Work instruction, with the verified region
coverage and parameter decisions: `truvari-sv-plan.md` in the same folder.

**CLR is a supported entry point, with a caveat that must travel with the numbers.**
`clr_subreads` (Sequel CLR `.subreads.bam`) **skips ccs** — CLR is single-pass and ccs needs ~3
full-length subreads per ZMW, so it cannot be turned into HiFi. The full caller set runs on CLR
by explicit request (2026-08-21), but only pbmm2 (`--preset SUBREAD`) and pbsv (`--hifi`
dropped) actually adapt; DeepVariant's PACBIO model and Clair3's `hifi*` models have no CLR
equivalent, and WhatsHap phases their output. Every CLR dataset therefore gets
`04_QC/CLR_WARNING.txt` plus a launch-time warning: read `SV_pbsv/` as the product and treat the
SNV/indel and phased outputs as exploratory. A group may not mix CLR with HiFi rows.

**Deliberate non-goals, so they are not rediscovered mid-run:** reference `.fai`/`.mmi` are built
per run (a fresh run rebuilds the whole-genome `.mmi`, ~10-15 GB RAM — batch datasets or `-resume`
to pay it once); a *supplied* `.bai` is trusted as-is (an omitted one is built, and that build
refuses an unsorted BAM); and `input_type` is declared, never sniffed — CLR
reads mislabelled as `hifi_fastq` still run with the CCS preset and no warning, so label them
`clr_subreads`. Full list: the pipeline README's "Not implemented" section.

**GIAB fit (the phase-2 use case):** the GIAB pacbio_hifi manifests contain **zero raw
subreads** — every dataset enters at `hifi_fastq`/`hifi_bam` or `aligned_bam`; the survey table
per sample×dataset (what exists where, which movies are duplicated across dirs) is in the
validation record's `giab-pacbio-states.md`.
