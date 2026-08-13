# Plan — 20260812-raredisease-srr26793256

## Pipeline
nf-core/raredisease -r 3.1.2 (latest stable, released 2026-07-06, 122 stars, not archived,
pushed 2026-08-11 — actively maintained). First procurement of this pipeline in this repo.

## Input
1 sample, SRR26793256 — reused nf-core/sarek's own MarkDuplicates CRAM
(`runs/20260729-sarek-srr26793256/results/preprocessing/markduplicates/SRR26793256/SRR26793256.md.cram`,
~40x WGS, East Asian sample per prior sarek handoff) via raredisease's own documented `bam`/`bai`
samplesheet columns (its supported external-BAM entry point — not a bypass of raredisease's own
pipeline; alignment did not happen inside raredisease for this run).

**Bounded choice — CRAM→BAM conversion.** raredisease's schema_input.json requires `bam`/`bai`
extensions literally (`^\S+\.bam$` / `^\S+\.bai$`); CRAM is not accepted. Converted via
`samtools view -b` in the `quay.io/biocontainers/samtools:1.21` container (not a host binary),
writing to `/work/build/raredisease-input/SRR26793256.md.bam` (+`.bai`) on ext4. This is a pure
format transcode of already-deduplicated alignment data — no realignment, no re-derivation.

**Bounded choice — sex/phenotype left unasserted.** `sex=0` (unknown, PED convention),
`phenotype=0` (missing/unknown). The July sarek run observed chrX≈20.8x / chrY≈15.5x coverage
(present, non-zero Y) but did not assert sex from it; same non-assertion carried forward here.
`case_id=SRR26793256_case` (arbitrary label, one singleton "case").

## Reference build performed this run
- `intervals_wgs.interval_list` / `intervals_y.interval_list` — schema-**required** params with no
  default in this pipeline (unlike sarek, which has no such requirement). Built via
  `gatk ScatterIntervalsByNs -OT ACGT` against `GRCh38gatk/fasta/genome.fa` (41s), then filtered to
  the 25 primary contigs (chr1-22,X,Y,M) — **bounded choice**: unplaced/unlocalized/decoy scaffolds
  excluded from the WGS QC/calling interval set, matching how sarek's own capture-BED-free WGS runs
  on this host are scoped. Stored at `$BIOINFO_REFS/genomes/GRCh38gatk/intervals/`.
- Everything else (`fasta`, `fai`, `dict`, `bwa` index) already present from sarek's `GRCh38gatk`
  build — reused directly, no rebuild.

## Scope of this run — what is skipped and why
`--skip_subworkflows snv_annotation,sv_annotation,mt_annotation,repeat_calling,repeat_annotation,`
`me_calling,me_annotation,generate_clinical_set --skip_tools gens,germlinecnvcaller`

This is the "lightest combination first" procurement pattern (same principle as taxprofiler's
kraken2-only stocking). raredisease's annotation/scoring/ranking stack needs CADD resources
(indel scores), a VEP cache (~25 GB, same order as sarek's), a gnomAD allele-frequency table,
vcfanno resource bundle, GENMOD rank-model configs, an ExpansionHunter variant catalog, and a
GATK GermlineCNVCaller cohort model — **none of which exist in `$BIOINFO_REFS` and none of which
this run fetches.** This run validates alignment-input handling, QC, SNV calling (DeepVariant),
and SV calling (Manta/Tiddit/CNVnator) only — the part of the pipeline that needs only the
reference genome and the two interval lists built above. Annotation/scoring remains a known gap,
named below, not silently dropped.

## sarek vs raredisease — what overlaps, what's new
Overlap: both take short-read DNA to a germline VCF; both can consume a pre-aligned/dedup BAM as
an alternate entry point; both use `$BIOINFO_REFS/genomes/GRCh38gatk`.
Different: raredisease's default SNV caller is DeepVariant (not GATK HaplotypeCaller), default SV
callers are Manta+Tiddit+CNVnator (sarek needs `--tools` to add these), it always runs a parallel
MT-genome subworkflow (subsample, shift-align, Mutect2, liftover) regardless of `--tools`, and its
full scope (not exercised this run) adds HPO/pedigree-aware ranking (GENMOD), CADD/VEP annotation,
SVDB frequency annotation, ExpansionHunter repeat genotyping, and SMNCopyNumberCaller — none of
which sarek has at all. sarek has no equivalent to raredisease's clinical scoring/ranking layer;
raredisease has no tumour-normal/CNV-cohort machinery sarek has. They are not substitutes for each
other past the shared alignment/preprocessing/basic-calling core.

## Estimate
Test profile (tiny GRCh37 CI fixture): `-stub-run` completed cleanly in ~35 min wall clock across
3 resumed attempts on this host (mostly Docker image pulls + reference stub builds; real compute
per stub task is seconds). No `-profile test,docker` full test-data run was executed (would add a
GRCh37 tiny genome download + a second CADD/VEP-included reference set not needed for scope
validation); the `-stub-run` DAG pass at this exact flag set is the gate per policy — same standing
as taxprofiler's clean pass.

Real sample (SRR26793256, ~40x WGS, bam/bai input, no realignment): DeepVariant on 25 primary
contigs + Manta/Tiddit/CNVnator SV calling + parallel MT subworkflow, single sample, 18-core/40GB
pool. Estimate 2-6h wall clock (DeepVariant is the dominant process at this coverage on this CPU
budget), well under the 24h approval line. Peak work-dir estimated ~80-120GB (BAM is ext4-to-ext4,
symlinked not copied by Nextflow staging; VCF/BED/wig outputs are all small relative to the BAM).

## Bounded choice added mid-run — `--aligner bwa --mt_aligner bwa`
raredisease's `PREPARE_REFERENCES` subworkflow builds `BWAMEM2_INDEX_GENOME` against the FULL
genome fasta whenever `--aligner` OR `--mt_aligner` equals `bwamem2` — both default to `bwamem2`,
so it is built unconditionally even for this bam-input, no-realignment run where neither index is
ever consumed. Measured on this host: `bwa-mem2 index` on the 3.1 Gb GRCh38 analysis-set genome
was OOM-killed (exit 137) at this host's 40 GB pool ceiling, retried automatically, OOM-killed
again. Switched `--aligner`/`--mt_aligner` to `bwa` (matching the already-present, already-copied
`GRCh38gatk/index/bwa/` store index) to avoid the build entirely — MT alignment then uses its own
small MT-reference bwa index instead, built in seconds. This is a real upstream inefficiency (the
whole-genome index is built off `mt_aligner`'s default with no gate on whether the sample needs
alignment at all), not a mistake in this run's parameters; documented in pipelines.tsv's note.

## Disk check
`/work` (ext4 root): 251 GB free at plan time. 1.5x of a 120 GB estimate = 180 GB — covered.

## Approval
Pre-approved by task instructions (autonomous procurement + first real-sample validation,
explicitly authorized, no mid-task confirmation required).
