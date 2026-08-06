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

## The gate — read this before the seven steps

**Steps 1–3 are survey and planning. They execute nothing.** Until the user approves a run plan,
the only commands you may issue are read-only inventory:

| Allowed during steps 1–3 | Forbidden until the plan is approved |
|---|---|
| `ls`, `du -sh`, `df -h`, `find`, `stat`, `file` | anything that STREAMS a whole BAM/CRAM/FASTQ/VCF |
| `head`/`zcat \| head` on a FASTQ (a few lines) | `flagstat`, `stats`, `depth`, `bcftools stats`, `fastqc`, any aligner or caller |
| **header and index reads** — see below | `nextflow run` (except `-preview`/`-stub-run` at step 4) |
| reading text: logs, scripts, existing samplesheets | anything that writes into the user's data directory |
| `bash bootstrap/05-verify.sh`, `04-refs.sh --dry-run` | |

**Header and index reads are allowed, and you should use them.** What decides whether existing data
is reusable is constant-size, not a scan: `samtools view -H`, `quickcheck`, `bcftools view -h`,
`bcftools index -n`, `tabix -l`. On a 39 GB BAM here those cost 300–400 ms. `samtools idxstats`
too — **but only with a `.bai`/`.csi` beside the file**: unindexed, it reads the entire BAM
(htslib documents this), which is the one thing this gate exists to prevent. Check the index
exists first.
Refusing to spend that is how you propose a 90-hour realignment of something already aligned
correctly. **From the container, never a host binary** — rule 10 holds, and a `samtools` on `$PATH`
or in someone's `program/` folder is of unknown provenance:

```bash
docker run --rm -v /path/to/data:/d:ro quay.io/biocontainers/samtools:1.21--h50ea8bc_0 \
  samtools view -H /d/sample.bam
```

**Beyond header and index, ask first.** Coverage, duplicate rate, a real record count — those are
full scans, minutes to hours at this size. Name what you need and why; the user decides.

**If the request maps to a stocked pipeline, you run that pipeline. You never hand-assemble the
equivalent.** Do not chain `bwa mem` + `samtools sort` + `gatk MarkDuplicates` + `ApplyBQSR`
yourself because a directory happens to contain those intermediates. That is what sarek is. If a
directory already holds hand-built outputs, the correct move is to feed them to the pipeline at the
matching `--step`, not to continue someone's manual pipeline by hand.

**Tools come from pipeline containers.** Never execute a binary you found lying on disk
(`.../program/samtools-1.22.1/samtools`, `.../script/gatk`, a compiled `bcftools`). You do not know
how it was built or what version it is, and using it destroys the reproducibility that
`-profile docker` exists to provide. The only binaries you invoke directly are `nextflow`,
`nf-core`, `docker`, `git` and coreutils.

## The seven steps

Do them in order. Do not skip step 3 or step 4.

1. **Intake.** Answer every intake question below. Survey the actual files — do not trust a
   description of them. Read-only only: `ls -l`, `du -sh`, file extensions, and at most a few lines
   of one FASTQ header to confirm pairing and read length, plus the header/index reads above.
   If the user's request does not name a specific analysis — "이 데이터 좀 봐줘", "이거 분석해줘" —
   **stop and ask what question they want answered** before selecting anything.

   **"WGRS" is not one of those.** Whole-genome re-sequencing names the analysis: align short reads
   and call germline variants — sarek, from `--step mapping` or from a later step if alignment
   already exists. Get on with intake. Ask only what it genuinely leaves open: somatic vs germline
   if there is any hint of tumour/normal, and whether repeat expansions or coverage are wanted too.
2. **Pipeline selection.** Match analysis intent to a stocked pipeline and a revision.
   Read `references/pipeline-selection.md`.
3. **Run plan and approval.** The run directory `$BIOINFO_HOME/runs/<runid>/` gets all four files
   now, not later: `plan.md`, `samplesheet.csv`, `params.yaml`, `cmd.sh`. Step 4's preflight fails
   hard on a missing `cmd.sh` or `samplesheet.csv`, so writing them at step 5 is too late.
   `plan.md` carries: pipeline + pinned revision, sample count, reference build, estimated wall
   clock, estimated peak disk, what is missing and must be built or downloaded, and every bounded
   choice you intend to make. Present it. Wait for a yes.
4. **Preflight and stub run.** Run the shipped gates, do not restate them:
   `bash $BIOINFO_HOME/bin/preflight.sh <rundir> <est_work_gb>` — refs, disk ≥ 1.5× estimate, Docker, pin.
   `bash $BIOINFO_HOME/scripts/check-samplesheet.sh --deep --pipeline <pipeline> <samplesheet.csv>`
   — the input CSV. Without `--pipeline` the required-column gate is skipped.
   Then `-preview`, then `-stub-run` — both, in that order, on the real command with the real
   samplesheet. Neither substitutes for the other: `-preview` resolves params and the DAG without
   running anything, `-stub-run` exercises the process wiring. A stub run that fails is a real
   failure — fix it, do not "try it for real and see". `references/runbook.md` section 4.
5. **Execution.** Launch from ext4, logging to file, always through `tmux` (`references/runbook.md`
   section 5) — not a bare foreground command, not `nohup … &`, and not your own backgrounded
   tool call that you separately wait for. All three have lost a real run on this host: `nohup`
   dies with the WSL session that launched it, and an agent's own backgrounded launch has twice
   been killed by SIGTERM the instant the agent's turn ended, even with the session still open.
   `tmux`'s server process is the only thing proven to survive both. Treat this as mandatory even
   for a run you expect to finish in minutes.
   If a `bioinfo-tech` subagent is available and the estimate exceeds ~1 h, hand steps 5–6 to it and
   resume at step 7 from its handoff — Nextflow logs must not land in the main conversation.
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

Stocked pipelines and the revision each is pinned to: `config/pipelines.tsv`, the single source of
the pin. A pipeline with no row there is not stocked — it goes through `new-pipeline.md`.

## Schemas drift — always re-derive before first use

nf-core samplesheet columns and parameter names change between releases. Any schema table you have
read, here or in the reference files, was written against one revision and may be stale. Before the
first run of a pipeline at a revision you have not used on this machine:

```bash
nextflow info nf-core/<pipeline>                       # available revisions
nextflow run nf-core/<pipeline> -r <rev> --help
find "$NXF_ASSETS" -path '*nf-core/<pipeline>*' -name schema_input.json | head -1   # authoritative column list
nf-core pipelines schema docs                          # nf-core/tools >= 3.x; older: nf-core schema docs
```

Always pass `-r <rev>` explicitly, taken from `config/pipelines.tsv`. A run without a pinned
revision is not reproducible.

## Environment contract

**Every value below is one machine's.** `config/host.env` and the generated
`~/.config/bioinfo/env.sh` are authoritative; read them before you compose a command. The numbers
and names here are for orientation, not for typing into a shell.

- **Execution host**: the WSL2 distro named by `BIOINFO_DISTRO` (`Ubuntu-24.04` on the machine this
  was written for — confirm with `wsl -l -v`, and do not assume it: a second Windows profile on the
  same box has its own distros). From Windows: `wsl -d <distro> -- bash -lc '<cmd>'` — substitute
  the name. `$BIOINFO_DISTRO` is a WSL-side variable; in PowerShell it expands to nothing and
  `wsl -d ""` fails. On the Windows side use `$env:BIOINFO_DISTRO`, and only if you set it there.
  If `BIOINFO_ARCHIVE_DISTRO` is set it is a read-only archive of the user's old environment —
  pull old scripts and data out of it, never run a pipeline in it. It may be unset, in which case
  there is no archive distro on this machine.
- **Profile**: `-profile docker`. Docker engine runs inside the distro, not Docker Desktop.
- **ext4 vs drvfs**: `/mnt/c`, `/mnt/d`, `/mnt/e` are Windows drives through drvfs and are 5–10×
  slower. The Nextflow **work directory, the launch directory** (it holds `.nextflow/cache`, which
  `-resume` depends on), **container images, and index files must all be on ext4.** Only
  sequentially-read reference files may be symlinked out to `/mnt/d`.
- **Paths**: repo `$BIOINFO_HOME` = `/mnt/d/bioinfo-agent`; references `$BIOINFO_REFS` = `/refs`;
  work root `$BIOINFO_WORK` = `/work`; legacy reserve `$BIOINFO_RUNS` = `/runs`; run records
  `$BIOINFO_RUNLOG` = `/mnt/d/bioinfo-agent/runs`. Bootstrap exports all five for compatibility,
  but launch paths use the four active roots, never `BIOINFO_RUNS`. If an active root is empty,
  stop: every path built on it collapses to the filesystem root — `-work-dir $BIOINFO_WORK/<run-id>`
  becomes `-work-dir /<run-id>`, and the same for an outdir or a run record. `hooks/guard-workdir.sh`
  blocks that shape, but only for `rm`; nothing stops a run from writing there.
- **A run's own tree**: `NXFDIR=${NXF_WORKROOT:-$BIOINFO_WORK/nxf}/<runid>` — the same derivation
  in `bin/preflight.sh`, in every `cmd.sh`, and in every `NXFDIR=` line of `references/runbook.md`.
  `--outdir "$NXFDIR/results"`, `-work-dir "$NXFDIR/work"`, launch directory `$NXFDIR`. Results are
  rsynced from there to the run record at the end (runbook section 8). **Do not point `--outdir` at
  `$BIOINFO_RUNS`**: preflight sizes and gates the `$NXFDIR` tree, so an outdir anywhere else means
  the disk check guarded one filesystem while the run filled another, and the completion step
  copies an empty directory and reports it clean.
- **References**: resolve *only* through `$BIOINFO_REFS` standard paths. If you are about to type
  `hg38.fa` or `Homo_sapiens_assembly38_noALT_noHLA_noDecoy.fasta` into a command, stop — add the
  manifest row instead. Sarek uses build `GRCh38gatk`; RNA-seq and most else use `GRCh38`.
- **Run records**: `$BIOINFO_HOME/runs/<runid>/` holds `plan.md`, the params file, the samplesheet,
  the trimmed log, and `handoff.md`. Text only — it lives on drvfs. Run id: `YYYYMMDD-<pipeline>-<slug>`.
- **Hardware budget**: host 24 cores / 63.5 GB, WSL2 VM 22 / 52, Nextflow pool 18 / 40 — the pool
  clamps tasks, so quote it. `BIOINFO_MAX_CPUS` / `BIOINFO_MAX_MEMORY`. A human STAR index wants ~40 GB.
- **Disk**: never target `C:` (74 GB free). `D:` 2.2 TB, `E:` 3.7 TB, ext4 VHDX ~955 GB free.

## Hard rules

1. **Never start a job estimated over 24 h without explicit user approval.** State the estimate and
   the reasoning, then ask.
2. **Never skip the stub run / `-preview`.** No exceptions for "small" or "same as last time".
3. **Never delete, clean, or move a work directory while a run may still be resumed, and never to
   free disk mid-run.** Disk pressure is escalated, not solved by deletion. A finished run's work
   dir is reclaimed only through the `references/runbook.md` section 9 checklist.
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
9. **Never hand-roll a stocked pipeline.** If the analysis is one of the nine, it runs through
   `nextflow run nf-core/<pipeline>`. Assembling the same steps yourself out of `bwa`, `samtools`,
   `gatk` and `picard` is forbidden even when the intermediates are already sitting there — it is
   unreproducible, unresumable, and produces no MultiQC.
10. **Never execute binaries found on disk.** Analysis tools come from the pipeline's containers.
    A `samtools` compiled into someone's project folder is of unknown provenance and version.
11. **Nothing executes before the plan is approved.** See the gate above. Read-only inventory plus
    constant-size header and index reads are the entire permitted surface of steps 1–3; a full
    scan of anything gets named and approved first.

### Reusing what is already there

Finding prior outputs is good and you should look for them. What you do with them is the part that
goes wrong.

| Found | Wrong move | Right move |
|---|---|---|
| Recalibrated BAM/CRAM | run `samtools`/`gatk` on it and carry on manually | sarek `--step variant_calling`, `bam`/`bai` columns in the samplesheet |
| Duplicate-marked BAM | continue the hand pipeline | sarek `--step prepare_recalibration` |
| Coordinate-sorted BAM, no dedup | re-align from FASTQ — days of compute already spent | sarek `--step markduplicates` |
| Trimmed FASTQ | re-trim, or trim again by hand | feed as `fastq_1`/`fastq_2`, skip the trimming step by flag |
| VCF only | write bcftools one-liners | sarek `--step annotate` |
| An existing STAR/BWA index | rebuild it | point the manifest at it, add a row, resolve by standard path |

A header read narrows the row down; two of the three fields need corroborating before you act.

- **`@HD SO:`** — sort order. Says what it says.
- **`@RG`** — present and carrying `SM`/`PL`/`LB`/`PU`, or sarek will reject the input.
- **Reference identity.** Do **not** take `@PG CL:` for it: that field preserves a command line,
  and the path in it may since have been replaced or retargeted. Compare the BAM's `@SQ` `SN`+`LN`
  — and `M5` when the header carries it — against the standard reference's `.fai`/`.dict`. Any
  mismatch means the alignment and the calling reference are different genomes.
- **Dedup.** A missing MarkDuplicates `@PG` is a hint, not proof: `samtools markdup --no-PG` omits
  it and headers can be rewritten. Corroborate with the script or log that produced the file
  before choosing `--step markduplicates`; if nothing corroborates, say so in the plan and let the
  user decide between re-marking and an approved record-level check.

In every row the reuse happens **through the pipeline's own restart mechanism**, not by taking over
where a human left off. That is what makes the result reproducible and `-resume`-able.

If the existing outputs came from an unknown or hand-written pipeline, say so in the plan and let
the user decide whether to trust them. Do not silently adopt another pipeline's intermediates as if
they were yours — you cannot vouch for how they were produced.

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
