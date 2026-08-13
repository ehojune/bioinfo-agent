# Plan — 20260813-nanoseq-srr25466853

## Pipeline
nf-core/nanoseq -r 3.1.0 (latest stable, 228 stars, pushed 2026-07-27 — actively maintained).
**First procurement of this pipeline in this repo, and the first long-read-specific pipeline
stocked here.** Every other stocked pipeline (rnaseq, sarek, ampliseq, mag, taxprofiler,
raredisease, etc.) is short-read-Illumina-first; mag/taxprofiler optionally *accept* long reads
as one input type among several, but nanoseq is long-read-*only* (ONT DNA/cDNA/directRNA) — see
`pipeline-selection.md` §4.14 for the full comparison.

## Schema drift check performed this run
`assets/schema_input.json` at this pin describes `sample`/`fastq_1`/`fastq_2` — but it is
**never referenced by any `.nf` file in the pinned clone** (`grep -rn
"schema_input|validateParameters|fromSamplesheet|nf-validation|nf-schema"` across
`workflows/`, `subworkflows/`, `modules/` returns nothing). It is vestigial nf-core-template
boilerplate. The samplesheet actually enforced at runtime is the pipeline's own bundled
`bin/check_samplesheet.py` (invoked through the `SAMPLESHEET_CHECK` module), against a
completely different header: `group,replicate,barcode,input_file,fasta,gtf`. Confirmed by
reading `subworkflows/local/input_check.nf` (calls `SAMPLESHEET_CHECK`, then
`.splitCsv(header:true)` on ITS `sample,barcode,input_file,fasta,gtf,is_transcripts,
nanopolish_fast5` output — the check script's reformatted CSV, not the user's). This is
documented in `config/pipelines.tsv`, `samplesheets.md`, and `scripts/check-samplesheet.sh`'s
new `nanoseq)` branch, all keyed off the Python script's actual logic rather than the unused
JSON schema.

## Scope — lightest real configuration first
Per the task's "lightest combination first" instruction, checked before choosing:
- **Entry point**: `--input_path` (raw fast5/basecall-requiring directory) needs `qcat`
  demultiplexing and implies GPU-friendly basecalling context this host doesn't have configured.
  The pipeline supports a lighter path: an **already-basecalled FASTQ given directly as
  `input_file`** with `--skip_demultiplexing true` and no `--input_path`/`--barcode_kit` at all
  — confirmed via `workflows/nanoseq.nf` (the qcat/barcode-kit validation block only runs when
  `!params.skip_demultiplexing`). Chosen. This is the entry point nanoseq's own
  `test_full`/`test_nodx_*` CI profiles use for non-demux scenarios.
- **Protocol**: `DNA` (not `cDNA`/`directRNA`) — skips the RNA-specific quantification
  (bambu/stringtie2), differential-analysis (DESeq2/DEXSeq), fusion (JAFFAL), and modification
  (xpore/m6anet) subworkflows entirely via their own `--skip_*` flags, all set explicitly below
  rather than relying on protocol-implied defaults.
- **Variant calling**: left off (`--call_variants` is false by default; not set). medaka/
  DeepVariant/pepper_margin_deepvariant are comparatively heavy for a first validation and are
  not needed to exercise alignment + QC, which is the part this run validates.
- **Aligner**: default `minimap2` (the standard ONT aligner; no reason to override).
- **QC/bigwig/bigbed**: left at pipeline defaults (on) — cheap at this genome size (4.6 Mb),
  and exercises more of the pipeline's own QC surface (NanoPlot, FastQC, samtools stats,
  BigWig/BigBed) for a more meaningful real-sample QC report.

Flags actually set: `protocol: DNA`, `skip_demultiplexing: true`, `skip_quantification: true`,
`skip_differential_analysis: true`, `skip_fusion_analysis: true`, `skip_modification_analysis:
true`. (The last four are RNA-only subworkflows; harmless but explicit for a DNA-protocol run —
matches the CI `test` profile's own practice of setting them explicitly rather than relying on
protocol-gating alone.)

## Reference
**Reused, not fetched.** `$BIOINFO_REFS/genomes/ECOLI_K12/fasta/genome.fa` (RefSeq ASM584v2,
`NC_000913.3`, 4.5 MB) — already in `config/refs.manifest.tsv`, originally fetched for
cutandrun's spike-in alignment. nanoseq's alignment step is minimap2-based and needs only a
plain FASTA (no prebuilt index; `PREPARE_GENOME:SAMTOOLS_FAIDX`/`GET_CHROM_SIZES` and
`ALIGN_MINIMAP2:MINIMAP2_INDEX` are built inside the run, seconds at this genome size — no new
manifest row needed for those, matching how nanoseq's own `--fasta` per-sample column works: a
plain FASTA path, index built in-run).

**Bounded choice — E. coli, not human.** The task allowed either a full human genome or a
smaller/CI-scale genome matching the real sample's actual organism, at technician judgment. The
smallest ENA ONT WGS dataset with a meaningful (non-degenerate) read count is bacterial (see
below), so a bacterial reference is the correct match, not GRCh38gatk/GRCh38 — using a human
reference against a 4000-read *E. coli* run would be a scale mismatch, not a lighter choice.

## Real sample
Sample count: 1. ENA run **SRR25466853** — *Escherichia coli*, WGS, Oxford Nanopore MinION
(`PRJNA1000618`/`SAMN36772644`, study "CAST VK on-target transposition study"). Chosen for small
download size via the ENA portal API (`instrument_platform=OXFORD_NANOPORE AND
library_strategy=WGS AND scientific_name="Escherichia coli"`, sorted by `fastq_bytes` ascending,
filtered to `read_count>1000` to exclude near-empty barcode-bin runs under ~1 KB that are not a
meaningful pipeline exercise), same "smallest real dataset" discipline as mag/taxprofiler's
DRR027580 pick — **not chosen for study relevance, and no biological claim is made about it.**
4,000 reads, 4,856,605 bases (~1.06× nominal coverage of the 4.64 Mb genome), single FASTQ,
5,040,312 bytes. Downloaded to `/work/staging/nanoseq-realsample/SRR25466853.fastq.gz` (ext4);
MD5 verified against ENA's own `f671be60a4e2c7cf570ba38a40b106d7` — match.

## Samplesheet
```csv
group,replicate,barcode,input_file,fasta,gtf
SRR25466853,1,,/work/staging/nanoseq-realsample/SRR25466853.fastq.gz,/refs/genomes/ECOLI_K12/fasta/genome.fa,
```
`scripts/check-samplesheet.sh --deep --pipeline nanoseq` on this sheet: PASS, all checks OK
(including a purpose-built negative-case smoke test against a synthetic bad sheet exercising
every new check — MIN_COLS, non-integer replicate/barcode, group-with-space, mixed input_file
extensions, duplicate group/replicate pair, non-contiguous replicate run — all fired correctly).

## Estimate

**Test profile.** `nextflow run nf-core/nanoseq -r 3.1.0 -profile test,docker -stub-run` (the
`test` profile → `conf/test.config`, DNA protocol, qcat demultiplexing against a tiny bundled
fastq, `skip_quantification`/`skip_bigwig`/`skip_bigbed`/`skip_fusion_analysis`/
`skip_modification_analysis` all true): `completed=24 failed=4`, wall clock a few minutes. The 4
failures are `BAM_STATS_SAMTOOLS:SAMTOOLS_IDXSTATS`/`SAMTOOLS_FLAGSTAT` for both `sample_R1`/
`sample_R2`, all `"failed to read header for ... .sorted.bam"`. Root-caused, not just observed:
`modules/nf-core/samtools/sort/main.nf` HAS a `stub:` block (writes a touch'd, header-less empty
`.bam`), but `modules/nf-core/samtools/idxstats/main.nf` and `.../flagstat/main.nf` have **no**
`stub:` block at all — so under `-stub-run` those two run for real against the fake empty BAM
`SAMTOOLS_SORT`'s stub produced, and real `samtools idxstats`/`flagstat` correctly refuse to
read a file with no header. This is the same class of upstream shared-module stub-coverage gap
already documented for ampliseq's `CUTADAPT_BASIC` (4th departure) and mag's `UNTAR` (5th
departure) — **waived as the 6th documented departure**, not a defect in this run's parameters:
`SAMTOOLS_STATS` (which DOES have a stub block) succeeded cleanly in the same run, and the
failure is confined to two modules with no stub coverage, not to nanoseq's own code.

**Real sample.** 4,000 ONT reads / ~4.86 Mb against a 4.64 Mb bacterial genome, minimap2
alignment, default QC (NanoPlot/FastQC/samtools stats/BigWig/BigBed), no variant calling, no
RNA-specific subworkflows. This is far below any pipeline row in `estimates.md` (smallest
existing row, taxprofiler's real-sample DRR027580, is 110 Mbp of Illumina short reads and ran in
under a minute) — expect low single-digit minutes wall clock, work dir in the tens of MB. Well
under the 24h approval line by a wide margin; no approval gate triggered.

## Disk check
`/work` (ext4): 188 GB free at plan time (per `preflight.sh`). 1.5× a conservatively-padded 5 GB
estimate = 7.5 GB — covered by a wide margin. Container image pulls (nanoseq's own toolset:
minimap2, samtools, NanoPlot, FastQC, ucsc-bedgraphtobigwig, MultiQC, etc.) are the only
meaningful disk cost this run and are a one-off, reused by every future nanoseq run.

## Approval
Pre-approved by task instructions (autonomous procurement, explicitly authorized, no mid-task
confirmation required for ordinary procurement decisions). Estimate is far under the 24h /
10 GB-download gates that would otherwise require a stop.
