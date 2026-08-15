# Plan — 20260814-isoseq-alz-chr19

## Pipeline
nf-core/isoseq -r 2.0.0 (latest stable, only release since 1.1.5/2023-09, 54 GitHub stars,
pushed 2026-08-14 — actively maintained but the 2.0.0 tag itself is ~23.4 months old at plan
time, i.e. just inside the "12-24 months: probably fine" band, not the ">24 months: assume work
needed" band). **First PacBio-specific pipeline in this repo, and the second long-read-only
pipeline overall** (after nf-core/nanoseq, ONT, PR #38). Unlike nanoseq (which accepts an
already-basecalled FASTQ and skips demultiplexing as its lightest path), isoseq's own module
graph starts from raw PacBio subreads and runs CCS generation itself — see "Scope" below for
why there is no equivalently light skip here.

## Schema drift check performed this run
`assets/schema_input.json` at this pin (`sample`/`bam`/`pbi`/`reads`, required=[sample]) **is
actually referenced this time** — unlike nanoseq/rnasplice, isoseq has no local
`bin/check_samplesheet.py`; `main.nf`'s `PIPELINE_INITIALISATION` subworkflow builds channels
straight off `samplesheetToList(params.input, ...)` against this same schema (confirmed by
reading `subworkflows/local/utils_nfcore_isoseq_pipeline/main.nf` lines ~60-100 and 271-310, no
separate validation script anywhere in `bin/`). So for isoseq the JSON schema *is* authoritative
— a genuine contrast with the last three pipelines stocked here.

Two entrypoints, selected by `--entrypoint` (`isoseq` default, or `map`), gating which
columns matter and which module chain runs (`workflows/isoseq.nf` lines 102-130):
- `entrypoint: isoseq` (default) — needs `bam` (raw `.subreads.bam`) + `pbi` (its PacBio index,
  `.bam.pbi`, **not** a samtools `.bai`) per row; `reads` is unused/must be `None`. Runs
  PBCCS → LIMA → ISOSEQ_REFINE → BAMTOOLS_CONVERT → GSTAMA_POLYACLEANUP to produce FLNC
  fasta in-run, before ever reaching alignment.
- `entrypoint: map` — needs `reads` (`.fa.gz`, **already** primer-trimmed, chimera-filtered,
  polyA-cleaned FLNC fasta — i.e. the *output* of the block above, not raw CCS/HiFi reads);
  `bam`/`pbi` must be `None`. Confirmed via `workflows/isoseq.nf:124-130` and the schema's own
  `errorMessage` text ("must have extension '.bam.pbi' or being 'None' if the entrypoint is
  'map'" / "must have extension '.fa.gz' ... if the entrypoint is 'isoseq'").

## Scope — lightest real configuration first, and why "map" is not actually lighter here
The task brief raised the possibility of a lighter entry point analogous to nanoseq's
`--skip_demultiplexing`. Checked and rejected: unlike nanoseq's skip (which only bypasses
`qcat` demultiplexing of an otherwise-standard basecalled FASTQ), isoseq's `map` entrypoint
requires a **fully-processed FLNC fasta** — the product of CCS + primer removal + chimera
detection + polyA cleanup, none of which any public SRA/ENA deposit ships directly. Producing
one myself would mean hand-running `pbccs`/`lima`/`isoseq refine`/`tama polyacleanup` outside
the pipeline to manufacture its own lightest-path input — exactly the "hand-assemble a stocked
pipeline" pattern this repo forbids (new-pipeline.md / SKILL.md hard rule 9). So this
procurement stocks **`entrypoint: isoseq`** (the default, full raw-subreads path) as the only
honest entry point, and documents `map` in samplesheets.md/pipeline-selection.md as available
for a user who already has FLNC fasta from elsewhere.

**Aligner**: `minimap2` (not `ultra`). uLTRA needs a sorted+indexed GTF and is markedly heavier
to set up for a first validation; minimap2 needs only the plain FASTA (`SET_FASTA_CHANNEL`) and
is the pipeline's other first-class option (`workflows/isoseq.nf:141-149`). The CI `test`
profile itself uses `ultra`, so `-stub-run`/`-profile test,docker` below is run with the CI
profile's own `aligner=ultra` unmodified (that is the only path that has been exercised
upstream), but the real-sample run and the stocked default use `minimap2` — a bounded choice,
recorded here and in `config/pipelines.tsv`.

**TAMA options**: left at pipeline defaults except `capped` (schema-required boolean, no
default) — set `false` (not stated by any dataset metadata found; disclosed as a bounded
default, matching this repo's practice of naming every default it picks, e.g. raredisease's
`--skip_subworkflows` stocking).

**No `--gtf`** for the minimap2/real-sample run: `--gtf` is only consumed when
`aligner: ultra` (`SET_GTF_CHANNEL` is gated behind `if (params.aligner == "ultra")`,
`workflows/isoseq.nf:97-99`). GSTAMA_COLLAPSE's own gene-model cleanup runs off the alignment
alone. This keeps the real-sample run to fasta + primers only, no annotation file needed.

## Reference
**New manifest rows, not the existing `genomes/GRCh38` build.** isoseq's own CI test data (see
"Real sample" below) is a real, PacBio-published 1% subread subsample restricted to human
chr19/13/18 reads, paired with an **Ensembl-numbered** (`19`, not `chr19`), release-104
FASTA+GTF pair — the FASTA is chr19 sequence ONLY, the GTF covers chr13+chr18+chr19 (upstream's
own CI pairing; a chr13/chr18 read has no target sequence to align to at all under this fasta,
capping the achievable mapping rate, not a naming issue) — a different accession stream and
chromosome-naming convention from the UCSC-style, chr-prefixed `genomes/GRCh38/fasta/genome.fa`
already in `config/refs.manifest.tsv`. Reusing the full hg38 build would (a) silently break
minimap2 mapping against reads that carry no `chr` prefix, and (b) cost far more mapping time
against sequence outside chr19 that none of the source reads that CAN map originate from.
Stocked instead as new rows `genomes/GRCh38_isoseq_chr19/{fasta,gtf}/...`, `fetch`
mode, sourced directly from the nf-core/test-datasets `isoseq` branch (same URLs `conf/test.config`
uses) — see `config/refs.manifest.tsv` diff. Sizes: fasta 59,594,634 B (~57 MB), gtf
76,298,435 B (~73 MB), both already gzip-free plain text per the CI config. Well under the
~10 GB silent-download line.

## Real sample
Sample count: 1. **`alz.1perc.subreads.10000.bam`** — the nf-core/isoseq project's own CI test
subreads BAM, but genuinely real, non-synthetic data: a 1%/10,000-record subset of PacBio's
public "Alzheimer's Brain Iso-Seq" release
(https://www.pacb.com/general/data-release-alzheimer-brain-isoform-sequencing-iso-seq-dataset/),
confirmed via `nf-core/test-datasets@isoseq`'s own `README.md`. 48,004,640 B bam +
91,836 B `.pbi` index.

**Why this and not an independently-sourced SRA/ENA accession** (the default expectation for a
"real sample" step per new-pipeline.md 2.8, and what every other pipeline procured in this repo
has done): searched ENA broadly before falling back to this.
- Small PacBio **Iso-Seq** (`library_source=TRANSCRIPTOMIC`, `instrument_platform=PACBIO_SMRT`)
  runs on the smallest stocked-organism candidate, *S. cerevisiae* (GEO GSE189063, e.g.
  SRR16970253-SRR16970265, ~26-56 MB each, real Iso-Seq per the GEO record's
  `Sample_data_processing: Library strategy: Iso-Seq`) exist only as **ENA-converted
  `_subreads.fastq.gz`**, with no `.pbi` and no confirmed native PacBio BAM tags (`np`, `rq`,
  etc.) that `pbccs` expects — the submitted format for those runs is empty/fastq-only, not BAM
  (checked via ENA portal API's `submitted_format` field). Manufacturing a synthetic `.pbi` and
  an unaligned BAM via `samtools import` would risk feeding `pbccs` malformed per-ZMW metadata
  and silently degrading or breaking CCS generation — not something to do quietly.
- Every other small (`submitted_format=BAM`) PacBio transcriptomic ENA entry found (Suid
  alphaherpesvirus, *Picea abies*, lamprey, vaccinia virus, toad) is an **aligned** BAM+`.bai`
  pair, not the unaligned subreads+`.pbi` pair the schema pattern requires.
- The only full-size native subreads.bam+.pbi Iso-Seq set the pipeline itself names
  (`ERR8606831`, pig muscle, `nf-core/test-datasets` "full" fixture) is 91.3 GB submitted —
  ~9x this repo's ~10 GB silent-download ceiling, and would need explicit approval it is not
  worth seeking for a first validation.

Given that landscape, the smallest dataset actually satisfying isoseq's native input format
is the pipeline's own CI subset — which is itself sourced from real public PacBio data, not a
synthetic fixture. Documented here as a bounded choice: this run doubles as both the "test
profile" check (step 1) and the "one real sample" check (step 2) of new-pipeline.md §2.8,
because no smaller or independently-sourced dataset in the correct native format exists. The
CI run below uses `-profile test,docker` verbatim (aligner=ultra, per upstream); the real-sample
run below uses the identical `alz` bam/pbi/primers/fasta/gtf inputs but with `aligner=minimap2`
(this procurement's stocked default) and without `--gtf`, so the two runs are not literally
identical despite sharing input data.

## Samplesheet
Sample count: 1.
```csv
sample,bam,pbi
alz,/work/staging/isoseq-realsample/alz.1perc.subreads.10000.bam,/work/staging/isoseq-realsample/alz.1perc.subreads.10000.bam.pbi
```
`scripts/check-samplesheet.sh --deep --pipeline isoseq` run against this sheet before launch.

## Estimate
**Test profile** (`-profile test,docker`, CI's own ultra aligner + gtf): small (48 MB bam, 57 MB
fasta, 73 MB gtf), `chunk=5` — expect low single-digit minutes plus first-run container pulls
(pbccs, lima, isoseq, bamtools, tama x2, ultra x2, gunzip, gnu-sort, multiqc — none seen
elsewhere in this repo's containers). No existing estimates.md row for a PacBio pipeline to
calibrate against; the closest prior first-procurement (nanoseq, ONT, 4.6 Mb bacterial genome)
ran in low single-digit minutes with a comparable container-pull overhead.

**Real sample** (identical input, minimap2, no gtf): same read/genome scale as the test profile,
expect a similar or shorter wall clock (minimap2 index+align is typically faster than
uLTRA index+align at this genome size). Both runs are far under the 24h approval line; no
approval gate triggered. Both timed and measured below rather than guessed, per §2.8.

## Disk check
`/` (ext4, `$BIOINFO_WORK`): 177 GB free at plan time. 1.5x a conservatively padded 5 GB
work-dir estimate = 7.5 GB — covered by a wide margin. Container image pulls (isoseq's own
tool set, ~9 distinct images) are the only meaningful one-off disk cost and are reused by every
future isoseq run.

## Post-launch addendum — `--chunk` finding
The first launch used the pipeline's own `--chunk 40` default. Against this input's 531 ZMWs
(~106-107 per would-be chunk), 29 of 40 per-chunk `GSTAMA_COLLAPSE` outputs came out empty and
`GSTAMA_MERGE` crashed reading the first one. Fixed with `--chunk 5` (matching
`conf/test.config`'s own value for the identical bam) and a `-resume` relaunch, which completed
cleanly. `params.yaml`/`cmd.sh` in this directory reflect the corrected `--chunk 5` value. See
`handoff.md` and `estimates.md` for the full writeup.

## Bounded choices (summary, detail above)
- `entrypoint: isoseq` (default, full raw-subreads path) stocked, not `map` — `map` needs
  pre-built FLNC fasta with no honest way to obtain one without hand-running the pipeline's own
  tools outside the pipeline.
- `aligner: minimap2` for the stocked/real-sample run (CI's own `-profile test` keeps `ultra`
  unmodified, run separately, unmodified, as the upstream-exercised path).
- `capped: false` (schema-required, no stated default) — no dataset metadata indicates capped
  library prep; disclosed default, not a measurement.
- Real-sample dataset is the pipeline's own CI subreads subset (real, non-synthetic PacBio data)
  rather than an independently-sourced SRA/ENA accession, because no independently-sourced
  candidate exists in the pipeline's required native subreads.bam+.pbi format under the ~10 GB
  download ceiling — full detail above.
- New reference rows added for the Ensembl chr19/13/18-only slice rather than reusing the
  existing chr-prefixed full-genome GRCh38 build (chromosome-naming and scope mismatch).
