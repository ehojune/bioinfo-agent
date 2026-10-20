# isoseq

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** [Exact stub conditions](stubs/isoseq.md) — read before Step 4; match every predicate.
- **Evidence lookup:** [procurement record](evidence/isoseq.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** PacBio Iso-Seq genome annotation — raw PacBio subreads in, gene/transcript models out.
Runs CCS generation (`pbccs`), primer removal (`lima`), chimera/polyA cleanup
(`isoseq3 refine` + TAMA `polyacleanup`) to produce Full-Length Non-Chimeric (FLNC) reads, maps
them to a reference genome (minimap2 or uLTRA), then cleans and merges gene models with TAMA
`collapse`/`merge` into a BED annotation. **First PacBio-specific pipeline stocked here, and the
second long-read-*only* pipeline overall** (after `nf-core/nanoseq`, ONT, `references/pipelines/nanoseq.md`).

**Not for:** general ONT long-read demultiplexing/QC/alignment (that's nanoseq, `references/pipelines/nanoseq.md` — a
different sequencing platform with its own tool chain: qcat demux, minimap2/graphmap2 alignment,
medaka/DeepVariant SNV calling, none of which apply to PacBio Iso-Seq data) or short-read
alternative-splicing/PSI analysis (that's rnasplice, `references/pipelines/rnasplice.md` — SUPPA2/rMATS/DEXSeq event-level
splicing statistics computed from Illumina short-read alignment/pseudo-alignment, structurally
incapable of processing raw long-read signal). Three genuinely different starting materials and
questions:
- **"I have raw PacBio Iso-Seq subreads and want gene/transcript models"** → isoseq (this
  section). Only pipeline stocked here that ingests PacBio subreads BAMs or does CCS generation
  at all.
- **"I have raw Oxford Nanopore reads (any protocol) and want demux/QC/alignment, optionally
  variant calling or RNA quantification"** → nanoseq (`references/pipelines/nanoseq.md`). Different platform, no CCS/FLNC
  concept — ONT reads are used directly.
- **"I have Illumina short-read RNA-seq and want to know whether isoform/exon usage differs
  between conditions"** → rnasplice (`references/pipelines/rnasplice.md`). No raw long-read signal involved at all; PSI/dPSI
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
