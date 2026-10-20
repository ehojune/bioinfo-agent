# sarek

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** [Exact stub conditions](stubs/sarek.md) — read before Step 4; match every predicate.
- **Evidence lookup:** [procurement record](evidence/sarek.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** DNA short-read variant calling. FASTQ → aligned CRAM → germline and/or somatic SNVs,
indels, SVs, CNVs → annotated VCF. WGS and WES. Tumour–normal and tumour-only. Multi-sample joint
germline genotyping.

**Not for:** expression of any kind. Not for RNA variant calling (no STAR 2-pass / SplitNCigarReads
path). Not for repeat expansions or STR genotyping — read [repeat-expansion scope](../repeat-expansion.md). Not
for de novo assembly. Not for long reads. Not for methylation. Not a substitute for
`nf-core/raredisease` (`references/pipelines/raredisease.md`) when the actual goal is a pedigree-ranked rare-disease candidate
list — sarek has no HPO/pedigree-aware ranking layer at all; see `references/pipelines/raredisease.md`'s comparison table.

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
| `--step` | `mapping` \| `markduplicates` \| `recalibrate` \| `variant_calling` \| `annotate` | restart point; see [sarek restarts](../workflow-chains.md#53-sarek-step-restarts) |
| `--tools` | `haplotypecaller` germline; `mutect2,strelka,manta` somatic; add `ascat`/`cnvkit` for CNV; `snpeff` or `vep` to annotate | **empty `--tools` = preprocessing only**, which is exactly what you want before an STR caller |
| `--wes` + `--intervals <capture.bed>` | for exomes | without the capture BED, WES coverage QC and calling are both wrong |
| `--joint_germline` | cohorts | GenomicsDBImport + joint genotyping; much heavier than per-sample |
| `--skip_tools baserecalibrator` | **when the GATK bundle is absent** | BQSR needs dbsnp + known_indels; see below |
| `--genome null` + explicit refs | always here | do **not** use `--genome GATK.GRCh38`; it triggers a large iGenomes download and bypasses the store |
| `--save_output_as_bam` | when a downstream tool cannot read CRAM | HipSTR in particular — [repeat-expansion scope](../repeat-expansion.md) |

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
