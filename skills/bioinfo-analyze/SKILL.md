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

**Header and index reads are allowed:** `samtools view -H`, `quickcheck`, `bcftools view -h`,
`bcftools index -n`, `tabix -l`. `samtools idxstats`
too — **but only with a `.bai`/`.csi` beside the file**: unindexed, it reads the entire BAM
so check that index exists first. Use the pinned container, never a host binary:

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
   Read `references/pipeline-selection.md`, then only the selected `references/pipelines/<name>.md`
   card. Follow its stub link before Step 4 and evidence links only when needed.
3. **Run plan and approval.** The run directory `$BIOINFO_RUNLOG/<runid>/` gets all four files
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
   samplesheet. Use `scripts/stub-gate.sh` for detached full-sheet execution (runbook section 4);
   this protects session lifetime, not an O(N) speedup. Neither substitutes for the other: `-preview` resolves params and the DAG without
   running anything, `-stub-run` exercises the process wiring. A stub run that fails is a real
   failure — fix it, do not "try it for real and see". `references/runbook.md` section 4.
   Read the selected `references/pipelines/<name>.md` card and its linked exact stub gate
   before composing this command. The eleven registered departures live under
   `references/pipelines/stubs/`; they retain their revision, branch, error and follow-up
   predicates. A waived failure, substitute input and stub-only flag are different cases.
   **Match every predicate and record the uncovered branch in `plan.md` and `handoff.md`.**
   No matching documented case means stop, diagnose and re-stub; similar-looking errors do
   not authorize a new waiver. A new case needs evidence and a reviewed card first.
5. **Execution.** Launch from ext4, logging to file, always through `tmux` (`references/runbook.md`
   section 5), including short runs. Session/turn teardown has killed `nohup` and agent-side
   background launches; the runbook retains the evidence and exact PID-recording recipe.
   If a run stops, start with `bash $BIOINFO_HOME/scripts/triage-run.sh "$NXFDIR"`; it reads the
   logs, trace, and failed task files without changing the run or its resume cache.
   If a `bioinfo-tech` subagent is available and the estimate exceeds ~1 h, hand steps 5–6 to it and
   resume at step 7 from its handoff — Nextflow logs must not land in the main conversation.
6. **QC verdict.** Read MultiQC and the pipeline's own metrics. Report PASS / PASS WITH CAVEATS /
   FAIL per sample against stated thresholds. Read `references/qc-interpretation.md`.
7. **Handoff.** Output locations, sizes, what was decided, what the user does next. No biology.
   For structured run evidence, use `scripts/run-meta.py` to initialize and validate
   `run-meta.json` with artifact hashes; keep unknown metrics unknown. A metadata snapshot
   does not prove human approval, live-process state, scientific QC or cleanup authorization.

## Reference files — read on demand, not up front

| File | Read it when |
|---|---|
| `references/pipeline-selection.md` | Step 2. Choosing a pipeline, or the request spans several. |
| `references/pipelines/<name>.md` | After Step 2 selection; exact scope and linked stub predicates. |
| `references/host-runtime.md` | Before any command; configured roots, budgets and runtime precedence. |
| `references/samplesheets.md` | Step 1/4. Building, validating, or debugging the input CSV. |
| `references/runbook.md` | Steps 4–5. Launching, monitoring, resuming, diagnosing a crash. |
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

For nf-core, pass `-r <rev>` from `config/pipelines.tsv`; for an in-repo pipeline, record
its repository commit and absolute pipeline target. Inspect cached schemas during intake;
help/pull/schema commands that execute or download wait for Step 3 approval.

## Environment contract

Read [references/host-runtime.md](references/host-runtime.md) before composing paths or budgets.
Parse `config/host.env` with `bootstrap/lib/host-env.sh`; **never source `host.env`**.
The generated `~/.config/bioinfo/env.sh` is authoritative for runtime paths and `NXF_*`.
Stop if an active root is empty. Inspect current CPU, RAM, disk and installed versions.

- Docker profile; analysis tools run inside pinned pipeline containers.
- Launch, work, resume cache, container cache and indexes stay on ext4.
- `NXFDIR=${NXF_WORKROOT:-$BIOINFO_WORK/nxf}/<runid>` owns live results, work and reports.
- `$BIOINFO_RUNLOG/<runid>` holds the plan, parameters, samplesheet, command and handoff.
- Resolve references through `$BIOINFO_REFS` and the manifest. An absent reference is a planning
  decision, never permission to download or hand-place it.
- Quote the effective `BIOINFO_MAX_CPUS` / `BIOINFO_MAX_MEMORY` pool, not historical host specs.
  Recheck the target filesystem's free space against the 1.5× estimate gate.

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
9. **Never hand-roll a stocked pipeline.** If the analysis matches a row in
   `config/pipelines.tsv`, use its documented `nextflow run` target (nf-core or in-repo). Assembling the
   same steps yourself out of `bwa`, `samtools`,
   `gatk` and `picard` is forbidden even when the intermediates are already sitting there — it is
   unreproducible, unresumable, and produces no MultiQC.
10. **Never execute binaries found on disk.** Analysis tools come from the pipeline's containers.
    A `samtools` compiled into someone's project folder is of unknown provenance and version.
11. **Nothing executes before the plan is approved.** See the gate above. Read-only inventory plus
    constant-size header and index reads are the entire permitted surface of steps 1–3; a full
    scan of anything gets named and approved first.

## Existing runs and intermediates

Search matching sample/accession handoffs under `$BIOINFO_RUNLOG` during intake.
Read [references/intake-reuse.md](references/intake-reuse.md) before proposing reuse.
Do not infer reference identity from `@PG CL:`: compare `@SQ` names, lengths and available
M5 checksums against the standard reference. A missing dedup `@PG` is not proof of no dedup;
corroborate from the producing script/log or ask for an approved record-level check.
Reuse through the stocked pipeline's entry point, with provenance and user approval.

Transfer past estimates only when pipeline/revision, entry step/tools, reference/index state,
and input scale all match. Otherwise calibrate and explain the changed assumptions.
Keep history lookup brief; do not audit unrelated past work.

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
8. **What already exists?** Two places.
   - **On disk**: prior BAMs, trimmed FASTQs, an existing index, a previous partial run with an
     intact work dir. Reusing beats recomputing.
   - **In `$BIOINFO_RUNLOG`** (local, never committed): `ls` it, and read the `handoff.md` of
     anything whose sample or accession matches. Read `references/intake-reuse.md` when a match exists.
9. **Where should outputs land**, and who reads them next.

If the user cannot answer 2, 3, or 4, inspect the files and answer it yourself, then confirm.
