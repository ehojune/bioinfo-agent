# Handoff — 20260820-pacbio-hifi-wgs-validation

`pipelines/pacbio-hifi-wgs` v0.1.0 validated on this host. Three gates, all passed.

## Gate 1 — `-stub-run`, mixed samplesheet
5 rows / 4 input_types / 3 (sample,dataset) groups incl. two multi-unit merges and one
aligned-BAM passthrough. All 60+ tasks stubbed OK; published tree matches the intended
`<sample>/PacBio/<dataset>/{01_HIFI,02_alignedBAM,03_VCF,04_QC}` layout.

## Gate 2 — E2E-A, subreads entry (`-profile test,docker`)
Real PacBio subreads (nf-core isoseq CI subset, 48 MB, 10,000 records, streamed over https)
→ pbindex → ccs ×2 chunks (23 s each) → pbmerge (6 s) → pbmm2 vs chr19 (1 s) → merge/QC/MultiQC.
`completed=10 failed=0` (after one MULTIQC output-name fix, see below). RNA subreads — callers
skipped by the test profile; this gate is CCS/align mechanics only.

## Gate 3 — E2E-B, full caller chain on real WGS data
HG002 GIAB Sequel II HiFi (PacBio_CCS_15kb_20kb_chemistry2), chr20:1–3,000,000 slice pulled by
htslib S3 range-fetch (11,004 reads, 124 MB fastq.gz) → `hifi_fastq` entry → full chain vs
chr20-only GRCh38 ref, `--clair3_model hifi_sequel2`. `completed=21 failed=0`.

| metric | value |
|---|---|
| primary mapped | 99.83 % (10,985/11,004) |
| region depth (chr20:1–3 Mb) | ~51× (mosdepth total bases / 3 Mb) |
| DeepVariant | 8,158 records (6,399 SNP / 1,772 indel) |
| Clair3 (hifi_sequel2) | 6,731 records (5,645 SNP / 1,096 indel) |
| pbsv | 68 SVs |
| WhatsHap | 4,197/5,036 het phased (83.3 %), 11 blocks, 2.67 Mb in blocks |

Caller wall-clock on the slice (16 cpus): DeepVariant 37 s / **peak 16.1 GB** (model load
dominates — the RSS floor holds for any input size), Clair3 48 s / 2.7 GB, pbmm2 8 s,
WhatsHap phase 7 s + haplotag 6 s, pbsv 3 s. MultiQC picked up mosdepth + samtools + bcftools
+ whatshap modules in one report.

These numbers validate mechanics, not accuracy — no hap.py/truth-set comparison was run
(that is the GIAB phase-2 work this pipeline exists for).

## Fixes made during validation (already in the committed code)
Caught by the gates:
1. `PBSV_CALL.out.vcf` → `vcf_raw` + missing `BCFTOOLS_SORT_PBSV` call (stub-run).
2. MULTIQC declared `multiqc_data`/`multiqc_report.html` but `--title` renames both outputs —
   pinned with `-n multiqc_report.html` (E2E-A, reproduced by E2E-B).
3. pbsv raw `.vcf` double-published next to the sorted `.vcf.gz` — publish removed (stub tree).

Caught by the 5-lens adversarial review (all re-validated by re-running every gate after fixing):
4. `FINALIZE_BAM` branched on `bams.size()` — Nextflow unwraps a 1-element path collection to
   a bare Path whose `.size()` is the FILE SIZE IN BYTES, so single-unit groups always took the
   merge branch; normalized via `instanceof List`.
5. Both `groupTuple` sites collected in completion order, changing task hashes run-to-run and
   silently defeating `-resume` — now `sort: true` (CCS chunks) / explicit name-sort (merge groups).
6. DeepVariant r1.10 defaults `--vcf_stats_report=false`, so the declared visual-report output
   was never produced; and without `--sample_name` the VCF sample column came from the BAM's SM
   (mislabeled for GIAB passthrough BAMs, inconsistent with Clair3) — both flags added.
7. README's offline pre-pull loop used `nextflow inspect` with no params, which errors before
   printing anything (silent no-op pulling zero images) — replaced with a config-grep loop; the
   launch block now also exports `NXF_SINGULARITY_CACHEDIR` (was only in the one-time block).
8. New `CHECK_BAM` guard: BAM contigs must be ⊆ `--fasta`'s `.fai` and mapped reads > 0 —
   otherwise wrong-reference/mixed-reference groups and unmapped inputs sail through to green
   runs with empty or chimeric call sets.
9. Parse-time duplicate detection: same file twice, or two rows in one (sample,dataset) whose
   filenames collapse to one unit name (late, cryptic staging collision otherwise).
10. `pbsv discover` is single-threaded — was reserving 8 CPUs; `pbsv call` first attempt raised
    to 64 GB (PacBio's own WDL provisions 64 GB; 32 GB guaranteed an OOM+retry cycle on WGS).
11. SGE h_vmem/h_rss kills can leave no exit code (Nextflow reports Integer.MAX_VALUE) — added
    to the retry list so memory escalation actually fires on the cluster.
12. `--help` said clair3_model default `[hifi]` (actual: `hifi_revio`); example samplesheet had
    a Revio movie as `subreads` (Revio never emits subreads); hs37d5 docs wrongly demanded
    `--include_all_ctgs` (Clair3's default covers 1–22/X/Y with and without `chr`);
    `nextflowVersion` now `!>=24.04.0` (hard-fail instead of warn).

## Environment
WSL2 Ubuntu-22.04 (admin profile), Nextflow 24.10.5, Docker 29.7.1, 24 cores / 31 GB VM,
`process.resourceLimits = [cpus:16, memory:24.GB]` clamp. All 11 container images pre-pulled;
tags in `pipelines/pacbio-hifi-wgs/nextflow.config` (registry-verified 2026-08-20).

## For the phase-2 GIAB runs (next conversation)
- `giab-pacbio-states.md` (this folder): per-sample × dataset entry-point map. No GIAB HiFi
  dataset has raw subreads; everything enters at `hifi_fastq`/`hifi_bam` or `aligned_bam`.
- Set `--clair3_model` per dataset platform (m84→hifi_revio, m64→hifi_sequel2, m54→hifi).
- hs37d5 works with Clair3 defaults (its contig list covers 1–22/X/Y with and without `chr`);
  `--clair3_args '--include_all_ctgs'` is only for decoy/unplaced/ALT contigs.
- One `--clair3_model` per run — don't mix platforms in one samplesheet; run per dataset.
- Server deploy: README §SGE — pre-pull SIFs on the login node (compute nodes have no egress),
  `-profile sge,singularity`, `--sge_pe` from `qconf -spl`.
