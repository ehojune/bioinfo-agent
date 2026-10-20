# nanoseq

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** [Exact stub conditions](stubs/nanoseq.md) — read before Step 4; match every predicate.
- **Evidence lookup:** [procurement record](evidence/nanoseq.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** Oxford Nanopore long-read demultiplexing + QC + alignment, across three protocols —
`DNA` (minimap2/graphmap2 alignment, optional medaka/DeepVariant/pepper_margin_deepvariant SNV
calling, sniffles/cuteSV SV calling), `cDNA`/`directRNA` (alignment + bambu/stringtie2
transcript quantification, DESeq2/DEXSeq differential analysis, JAFFAL fusion detection,
xpore/m6anet RNA-modification detection). Entry point is either a raw ONT run directory
(`--input_path 'fastq_pass/*'` + qcat demultiplexing) or an already-basecalled FASTQ given
directly per-sample (`--skip_demultiplexing true`, no `--input_path`).

**First long-read-*only* pipeline stocked here — no close overlap with anything else stocked.**
`mag` (`references/pipelines/mag.md`) and `taxprofiler` (`references/pipelines/taxprofiler.md`) both optionally *accept* ONT/PacBio long reads as one
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
