---
name: bioinfo-analyze
description: >-
  Plans and executes bioinformatics analyses on sequencing data using nf-core Nextflow pipelines
  in a local WSL2 + Docker environment. Use this skill when the user has sequencing data and wants
  an analysis run, or mentions nf-core, Nextflow, nextflow run, a samplesheet, or a pipeline
  profile; when they name FASTQ, fastq.gz, BAM, CRAM, VCF, gVCF, or a MultiQC report; when they ask
  for RNA-seq, bulk or single-cell expression, differential expression or differentialabundance,
  variant calling, WGS, WES, germline or somatic calling, sarek, GATK, BWA alignment, methylation,
  bisulfite, methylseq, EM-seq, ATAC-seq, ChIP-seq, CUT&RUN, scRNA-seq, or cellranger-style
  quantification; when they reference GEO, SRA, ENA or accessions like GSE, GSM, SRR, SRP, PRJNA
  and want them fetched; when they ask how long a run will take, how much disk it needs, whether a
  run passed QC, why a pipeline failed, or how to resume it; and when they ask to run any pipeline
  locally rather than on a cluster or cloud. Also covers building and validating samplesheets and
  resolving reference genome paths.
---

# bioinfo-analyze

You are running real pipelines on the user's own hardware. Every mistake costs hours of wall clock
and tens of gigabytes. Plan before you run; validate before you commit.

## The seven steps

Do them in order. Do not skip step 3 or step 4.

1. **Intake.** Answer every intake question below. Inspect the actual files — do not trust a
   description of them. `ls -l`, count reads, check the FASTQ header, confirm pairing.
2. **Pipeline selection.** Match analysis intent to a stocked pipeline and a revision.
   Read `references/pipeline-selection.md`.
3. **Run plan and approval.** Write the plan to `$BIOINFO_HOME/runs/<runid>/plan.md`: pipeline +
   pinned revision, sample count, reference build, estimated wall clock, estimated peak disk,
   what is missing and must be built or downloaded, and every bounded choice you intend to make.
   Present it. Wait for a yes.
4. **Preflight and stub run.** Verify references resolve, disk is ≥ 1.5× the estimate, Docker is
   up. Then `-stub-run` (or `-preview`) the real command with the real samplesheet. A stub run
   that fails is a real failure — fix it, do not "try it for real and see".
5. **Execution.** Launch from ext4, detached, logging to file. Read `references/runbook.md`.
6. **QC verdict.** Read MultiQC and the pipeline's own metrics. Report PASS / PASS WITH CAVEATS /
   FAIL per sample against stated thresholds. Read `references/qc-interpretation.md`.
7. **Handoff.** Output locations, sizes, what was decided, what the user does next. No biology.

## Reference files — read on demand, not up front

| File | Read it when |
|---|---|
| `references/pipeline-selection.md` | Step 2. Choosing a pipeline, or the request spans several. |
| `references/samplesheets.md` | Step 1/4. Building, validating, or debugging the input CSV. |
| `references/runbook.md` | Step 5. Launching, monitoring, resuming, diagnosing a crash. |
| `references/qc-interpretation.md` | Step 6. Reading MultiQC, setting thresholds, flagging samples. |
| `references/estimates.md` | Step 3. Any time/disk number you are about to state out loud. |
| `references/reference-store.md` | Any time a genome, GTF, index, or catalog path is needed. |
| `references/new-pipeline.md` | The analysis is outside the stocked set and a pipeline must be procured. |

Stocked pipelines: `rnaseq`, `differentialabundance`, `fetchngs`, `sarek`, `methylseq`, `atacseq`,
`chipseq`, `cutandrun`, `scrnaseq`. Anything else goes through `new-pipeline.md`.

## Schemas drift — always re-derive before first use

nf-core samplesheet columns and parameter names change between releases. Any schema table you have
read, here or in the reference files, was written against one revision and may be stale. Before the
first run of a pipeline at a revision you have not used on this machine:

```bash
nextflow info nf-core/<pipeline>                       # available revisions
nextflow run nf-core/<pipeline> -r <rev> --help
cat "$NXF_ASSETS/nf-core/<pipeline>/assets/schema_input.json"   # authoritative column list
nf-core pipelines schema docs                          # nf-core/tools >= 3.x; older: nf-core schema docs
```

Always pass `-r <rev>` explicitly. A run without a pinned revision is not reproducible.

## Environment contract

- **Execution host**: WSL2 distro `Ubuntu-24.04`. From Windows:
  `wsl -d Ubuntu-24.04 -- bash -lc '<cmd>'`. Never run pipelines in `Ubuntu-legacy` — that distro is
  a read-only archive of the user's old environment, useful only for pulling old scripts and data.
- **Profile**: `-profile docker`. Docker engine runs inside the distro, not Docker Desktop.
- **ext4 vs drvfs**: `/mnt/c`, `/mnt/d`, `/mnt/e` are Windows drives through drvfs and are 5–10×
  slower. The Nextflow **work directory, the launch directory** (it holds `.nextflow/cache`, which
  `-resume` depends on), **container images, and index files must all be on ext4.** Only
  sequentially-read reference files may be symlinked out to `/mnt/d`.
- **Paths**: repo `$BIOINFO_HOME` = `/mnt/d/bioinfo-agent`; references `$BIOINFO_REFS` = `/refs`;
  scratch/work/results on ext4 under `$BIOINFO_WORK` = `/work`. All four are exported by
  `~/.bioinfo.env`, which `bootstrap/03-nextflow.sh` generates. If `$BIOINFO_WORK` is ever empty,
  stop: `-work-dir $BIOINFO_WORK/<run-id>` becomes `-work-dir /<run-id>` and the run tries to write
  at the filesystem root.
- **References**: resolve *only* through `$BIOINFO_REFS` standard paths. If you are about to type
  `hg38.fa` or `Homo_sapiens_assembly38_noALT_noHLA_noDecoy.fasta` into a command, stop — add the
  manifest row instead. Sarek uses build `GRCh38gatk`; RNA-seq and most else use `GRCh38`.
- **Run records**: `$BIOINFO_HOME/runs/<runid>/` holds `plan.md`, the params file, the samplesheet,
  the trimmed log, and `handoff.md`. Text only — it lives on drvfs. Run id: `YYYYMMDD-<pipeline>-<slug>`.
- **Hardware budget**: 24 logical cores, 63.5 GB RAM. Leave headroom — cap at ~20 cores and ~48 GB
  unless the user says the machine is theirs alone. A human STAR index build alone wants ~40 GB.
- **Disk**: never target `C:` (74 GB free). `D:` 2.2 TB, `E:` 3.7 TB, ext4 VHDX ~955 GB free.

## Hard rules

1. **Never start a job estimated over 24 h without explicit user approval.** State the estimate and
   the reasoning, then ask.
2. **Never skip the stub run / `-preview`.** No exceptions for "small" or "same as last time".
3. **Never delete, clean, or move a work directory.** `nextflow clean`, `rm -rf work/`, and tidying
   between runs are all forbidden — they destroy `-resume`. Disk pressure is escalated, not solved
   by deletion.
4. **Refuse to start when free disk on the target filesystem is below 1.5× the estimate.** Report
   the shortfall.
5. **Always `-resume` on restart.** Never silently re-run from scratch; if `-resume` is impossible,
   say why before relaunching.
6. **QC verdicts only.** Report metrics against thresholds. Do not interpret biology — no "this gene
   is upregulated, therefore…", no calling variants pathogenic, no explaining what a cluster means.
7. **Say every bounded choice out loud.** Sub-sampling reads, taking top-N, dropping a failing
   sample, picking a default threshold, choosing an aligner — all of it goes in the plan and the
   handoff, in plain words.
8. **No silent large downloads.** Anything over ~10 GB (GATK bundle, VEP cache, iGenomes, SRA
   fetches) gets named, sized, and approved first.

## Intake questions — all answered before any plan is written

1. **Where is the data, exactly?** Absolute paths. Windows or WSL. How many files, total bytes.
2. **What format and layout?** FASTQ/BAM/CRAM/VCF; gzipped; paired or single end; one pair per
   sample or several lanes per sample; read length; instrument/platform (Illumina short read vs ONT
   vs PacBio HiFi — long reads rule out most stocked pipelines).
3. **Organism and genome build.** Human → `GRCh38`, `GRCh38gatk`, or `KOREF1`? Anything non-human
   means a new reference and a manifest edit.
4. **Assay specifics.** RNA: polyA vs ribo-depleted, strandedness (or `auto`). DNA: WGS vs WES vs
   targeted panel, and the capture BED if targeted. Methylation: WGBS vs EM-seq vs RRBS. ChIP/CUT&RUN:
   which mark, and are there input/IgG controls.
5. **What is the actual question?** Determines whether the run ends at quantification or continues
   into `differentialabundance`, and whether tumour/normal pairing is needed.
6. **Design.** Groups, replicates per group, batch structure, covariates, pairing. If there are
   fewer than 3 replicates per group, say so now — it changes what step 6 can honestly report.
7. **Wall-clock tolerance.** Is an overnight run fine? Is >24 h acceptable? Is the machine needed
   for other work?
8. **What already exists?** Prior BAMs, trimmed FASTQs, an existing index, a previous partial run
   with an intact work dir. Reusing beats recomputing.
9. **Where should outputs land**, and who reads them next.

If the user cannot answer 2, 3, or 4, inspect the files and answer it yourself, then confirm.
