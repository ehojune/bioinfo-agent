# Plan — 20260820-pacbio-hifi-wgs-validation

## What this is
First validation of the **in-repo** pipeline `pipelines/pacbio-hifi-wgs` (v0.1.0) — not an
nf-core procurement. Built because nf-core has no PacBio HiFi human WGS germline pipeline and
the GIAB benchmarking work (phase 2, separate conversation) needs per-dataset mid-pipeline
entry: GIAB PacBio data ships in wildly different processing states.

## Pipeline shape
subreads →(pbccs, chunked)→ HiFi uBAM →(pbmm2)→ aligned BAM →
{DeepVariant 1.10.0, Clair3 v1.2.0} SNV/indel + WhatsHap 2.8 phase/haplotag + pbsv 2.11.0 SV +
mosdepth/samtools/bcftools stats/MultiQC. Per-row entry via samplesheet `input_type`
(subreads | hifi_bam | hifi_fastq | aligned_bam); rows sharing (sample,dataset) merge after
alignment. Zero Nextflow plugins — portable to the offline SGE+Singularity cluster.

## Bounded choices (named per repo practice)
- **Latest-stable tool pins**, user-confirmed this session over GIAB-legacy versions
  (WhatsHap 0.17 / pbsv 2.2.1); containers are params, so legacy pins remain one flag away.
- **Clair3 v1.2.0, not v2.x**: v2.0.2's image has NO HiFi models in /opt/models (verified by
  running the image); v1.2.0 bundles hifi + hifi_revio + hifi_sequel2. Offline clusters need
  bundled models.
- **clair3_model default `hifi_revio`** (current platform); Sequel II data must pass
  `--clair3_model hifi_sequel2` — wrong model runs silently, documented in three places.
- pbmm2 `--unmapped` (lossless uBAM→BAM), `-J 4 --sort-memory 1G`; mosdepth `--no-per-base
  --by 500` (no `-x`: fast mode overcounts depth across intra-read deletions); SNV/indel splits
  after `bcftools norm -f ref -m -any` (multiallelic mixed records land in exactly one split);
  WhatsHap `--ignore-read-groups` (GIAB BAM SM tags vary); phasing source default DeepVariant.
- DeepVariant and pbsv consume the **plain** aligned BAM (DV ≥1.4 phases reads internally) —
  PacBio HiFi-human-WGS-WDL v1.x order, confirmed against the WDL.

## Validation gates run (all on this host, WSL2 Ubuntu-22.04 / Nextflow 24.10.5 / Docker 29.7.1)
1. `nextflow config` — parses.
2. `-stub-run`, mixed 5-row samplesheet (all 4 input_types, multi-movie merge groups, an
   aligned passthrough row): **passes end to end**, published tree matches the intended layout.
3. **E2E-A** `-profile test,docker`: real PacBio subreads (nf-core isoseq CI subset
   alz.1perc.subreads.10000.bam, 48 MB, streamed over https) → pbindex → ccs ×2 chunks →
   pbmerge → pbmm2 vs chr19 fasta → FINALIZE → mosdepth/samtools → MultiQC. Callers skipped
   (RNA subreads; mechanics smoke by design).
4. **E2E-B** full chain on real WGS data: HG002 GIAB Sequel II HiFi, chr20:1–3,000,000 slice
   (11,004 reads, 124 MB fastq.gz) extracted by htslib S3 range-fetch from
   `.../PacBio_CCS_15kb_20kb_chemistry2/GRCh38/HG002...pbmm2.GRCh38.haplotag.10x.bam` →
   `hifi_fastq` entry → pbmm2 → DeepVariant + Clair3 (hifi_sequel2) + pbsv + WhatsHap
   phase/haplotag + full QC vs a chr20-only GRCh38 ref. Results: handoff.md.

## GIAB phase-2 fit
`giab-pacbio-states.md` (this folder) maps all 33 GIAB PacBio HiFi dataset dirs: **zero raw
subreads anywhere** — every dataset enters at hifi_fastq/hifi_bam or aligned_bam. The subreads
entry point exists for completeness (and E2E-A exercises it), not for GIAB. Duplicate movies
across dirs (HudsonAlpha FASTQ = chemistry2 uBAM) are flagged there to avoid double-processing.

## Repo integration
- `config/pipelines.tsv` row `pacbio-hifi-wgs` (revision `in-repo`).
- `bin/preflight.sh` now recognises `pipelines/<name>` cmd.sh invocations (no -r needed;
  requires the tsv row). It resolves the actual run target: a tree outside this checkout FAILs,
  and a relative target is refused outright (Nextflow resolves it against the launch shell's
  cwd, which preflight cannot know — use an absolute path or `"$BIOINFO_HOME"/pipelines/<name>`).
  `BIOINFO_HOME` assigned *inside* cmd.sh wins over preflight's own environment, matching bash:
  a literal value and the `${BIOINFO_HOME:-/default}` template form are both evaluated exactly;
  anything else (command substitution, other variables) FAILs rather than being guessed at.
- `pipeline-selection.md` §4.20 + decision-table row; §6.2 TRGT unblock note.
- `samplesheets.md` in-repo section.
