# Repeat-expansion scope

Read only for STR/TR requests; availability is not validation or a clinical interpretation.

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
([pipeline card](pipelines/pacbio-hifi-wgs.md)) produces exactly this: a pbmm2 CCS-preset aligned (and optionally
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
