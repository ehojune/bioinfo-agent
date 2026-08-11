# Run 20260812-mag-drr027580-realsample — nf-core/mag -r 5.5.0 — COMPLETE WITH CAVEATS

**Purpose**    `new-pipeline.md` §2.8 step 2: one real sample, timed and measured, following
the test-profile pass.
**Inputs**     1 sample, `DRR027580` (ENA, study `PRJDB3255`, ENA `scientific_name`
"fossil metagenome"), Illumina paired-end, 436,115 read pairs (~110 Mbp), downloaded from
`ftp.sra.ebi.ac.uk` to `/work/staging/mag-realsample/` (ext4), gzip-integrity-checked.
Chosen by ENA portal-API size search for the smallest real
`WGS`+`METAGENOMIC`+`ILLUMINA`+`PAIRED` run — a size choice, not a study-relevance choice; no
biological claim is made about this sample. Samplesheet:
`/mnt/d/bioinfo-agent/runs/20260812-mag-drr027580-realsample/samplesheet.csv`
**Reference**  No `$BIOINFO_REFS` genome involvement. PhiX removal used mag's own bundled
reference (no download). GTDB-Tk off (`--skip_gtdbtk true`, avoids the pipeline's 60.8 GB
default DB download). CheckM/CheckM2/CAT/geNomad all off (defaults).
**Command**    `/mnt/d/bioinfo-agent/runs/20260812-mag-drr027580-realsample/cmd.sh`
**Wall clock**   ~3m 16s total across two launches (2m 17s to the first hard failure at
`SEMIBIN_SINGLEEASYBIN`, + 59.5s `-resume` after the host-level tolerance fix below)
**Peak disk**  work dir 122 MB, published results 19 MB      **Cores/RAM used** pool ceiling
(18 cores / 40 GB) available, actual per-process peaks all under 1.6 GB (see table below) —
nothing near the ceiling on this input size
**Results**      `/mnt/d/bioinfo-agent/runs/20260812-mag-drr027580-realsample/results/` (19 MB,
rsynced from `/work/nxf/20260812-mag-drr027580-realsample/results/`, diff-verified clean)
**MultiQC**  `.../results/multiqc/multiqc_report.html`
**Work dir**     `/work/nxf/20260812-mag-drr027580-realsample/work` — RETAINED, do not delete,
`-resume` depends on it

## QC verdict

PASS WITH CAVEATS (mechanical pipeline validation) — `completed=19 failed=2 cached=0` on the
final `-resume` invocation (16 completed earlier + cached, 3 completed + 2 tolerated-fail on
resume). Pipeline reached `MULTIQC` and exited with the standard "completed successfully, but
with errored process(es)" banner. Every stage from `FASTQC_RAW` through `METABAT2_METABAT2`
completed clean (exit 0); `SEMIBIN_SINGLEEASYBIN` and `MAXBIN2` both failed, tolerated (see
Bounded choices).

| metric | value |
|---|---|
| reads in (pairs) | 436,115 |
| MEGAHIT contigs | 74, all < 1500 bp (max observed ~400 bp) |
| MetaBAT2 bins produced | 0 — all contigs discarded as `tooShort`/`lowDepth` |
| MaxBin2 | failed, exit 255, tolerated (mag's own `base.config`: "marker gene number <= 1") |
| SemiBin2 | failed, exit 1, tolerated by this run's host-level config addition (below) |

**No genome bins were produced from this sample.** This is a property of the input — a
436K-read-pair sample assembles to 74 short contigs with no long-enough sequence for any of
the three enabled binners to work with — not a pipeline defect. The mechanical proof this run
provides is that `SHORTREAD_PREPROCESSING` (FastQC, fastp, phiX removal), `MEGAHIT` assembly,
`BINNING_PREPARATION` (Bowtie2 index + align), `METABAT2_METABAT2`, and `MULTIQC` all ran real
tools against real data end to end and produced real (if empty-of-bins) output. Bin QC
(BUSCO/Prokka) never triggered because no bin passed through to it — that branch is untested
by this specific sample; the test-profile run (`20260812-mag-testprofile-procurement`)
exercised BUSCO/Prokka against its own fixture bins, so that wiring is separately proven.

## Bounded choices

- **Sample selection**: DRR027580 chosen by download size, not scientific relevance — stated
  per the "say every bounded choice" rule.
- **`--skip_spades`, `--skip_concoct`, `--skip_comebin`, `--skip_metabinner`, `--skip_ale`**:
  bound this validation run's scope to MEGAHIT + MetaBAT2/MaxBin2/SemiBin2, mirroring the
  pipeline's own test-profile discipline. Stated in `plan.md`.
- **`--skip_gtdbtk true`**: avoids an unapproved 60.8 GB default-database download.
- **Host-level `config/local.config` addition, made mid-run**: `SEMIBIN_SINGLEEASYBIN` exits 1
  when an assembly has no contigs ≥ 1500 bp (SemiBin2's own message). mag's own
  `conf/base.config` already tolerates the equivalent case for `MAXBIN2` (ignore on exit
  1/255) but not for `SEMIBIN_SINGLEEASYBIN`, so the first launch aborted the whole pipeline
  over one binner with nothing to bin, even though `METABAT2_METABAT2` had already completed
  cleanly on the same assembly. Added `withName: '.*SEMIBIN_SINGLEEASYBIN.*' { errorStrategy
  = { exitStatus == 1 ? 'ignore' : 'finish' } }` to `config/local.config` §3 (host-level
  operational tolerance, not a pipeline-scope change) and `-resume`d. This is now a
  permanent, documented host config, not a one-off hand edit — the next mag run on this host
  inherits it automatically and does not need to rediscover this failure mode.

## Stub-run finding (procurement-relevant, broader than the test-profile one)

`-stub-run` from a from-FASTQ real-command shape is **not a usable pre-launch gate beyond
`SHORTREAD_PREPROCESSING`** for this pipeline, for a reason distinct from the
`CATPACK_DB_UNTAR` bug already recorded against this pin: `grep -rL --include='main.nf'
'stub:' <clone>/modules/local/` finds **20 of mag's 23 local modules have no `stub:` block**,
including `bowtie2_removal_align`, `bowtie2_assembly_build`/`bowtie2_assembly_align`, and
`quast_run`/`quast_bins`. Under Nextflow's documented no-stub fallback (real `script:` runs
instead — same shape already recorded for fetchngs 1.12.0), a real, unstubbed process
consumes `FASTP`'s stub output (a technically-valid-but-empty gzip stream) and crashes for
real: confirmed `BOWTIE2_REMOVAL_ALIGN` aborts with `Error: reads file does not look like a
FASTQ file` (bowtie2 exit 134). Routing around it with a stub-only `--keep_phix true` reaches
four more stages, then crashes again the same way at `BOWTIE2_ASSEMBLY_BUILD`/`QUAST` on
MEGAHIT's own empty stub contigs file. This is a chain, not an isolated bug — no finite
sequence of stub-only substitutions clears the whole DAG. `-preview` (clean) is therefore the
pre-launch gate this pipeline actually gets past the first stage, exactly as already true for
fetchngs; the real command is what proves the rest. See `plan.md` for the full evidence and
`skills/bioinfo-analyze/references/runbook.md` section 4 for the write-up shared across runs.

## Real-sample measurement (writes into `estimates.md`)

| Metric | Test profile (4 tiny CI fixtures) | This real sample (1 x 436K read pairs) |
|---|---|---|
| Wall clock | 27m 46s | **~3m 16s** (aborted+resumed once; net compute time lower still) |
| Work-dir peak | 2.2 GB | **122 MB** |
| Published results | 195 MB | **19 MB** |
| Peak single-process RAM | not separately measured | **`FASTQC_RAW` 1.5 GB**, `FASTP` 1.1 GB,
`MULTIQC` 791 MB, `FASTQC_TRIMMED` 585 MB — nothing else over 100 MB |

The real sample finished faster and smaller than the multi-sample/multi-run CI fixture
because the fixture pays a per-run-per-sample multiplier (2 samples x up to 2 runs x 2
assemblers x up to 5 binners) that this single-sample, single-assembler, 3-binner run does
not. **This measurement should not be read as "mag is cheap"** — it reflects a shallow input
that produced almost no assembled sequence; a real microbiome sample with actual community
diversity would drive MEGAHIT/SPAdes, Bowtie2 mapping, and binning far harder. Flagged in
`estimates.md` as a lower-bound / floor measurement, not a typical-case one.
