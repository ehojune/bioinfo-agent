# Plan — 20260816-rnaseq-revalidate

Purpose: periodic re-verification that nf-core/rnaseq -r 3.18.0 (pinned, `config/pipelines.tsv`,
"columns unchanged across 3.14-3.19") still runs cleanly against this repo's shared
infrastructure, after 8 later pipeline procurements (raredisease, nanoseq, rnasplice, isoseq,
bacass, ampliseq, mag, taxprofiler) each touched `scripts/check-samplesheet.sh`,
`config/refs.manifest.tsv`, and the skill's `runbook.md`/`SKILL.md`. Not a redesign of rnaseq's
stocked scope — that was settled in the 2026-08-03/08-04/08-07 runs.

**Pipeline**: nf-core/rnaseq -r 3.18.0 (pinned). `nextflow info nf-core/rnaseq` confirms the
revision is still resolvable in the local git cache (`> 3.18.0 [t]`).
**Schema drift check**: `assets/schema_input.json` at the pinned clone
(`/refs/cache/nf-assets/.repos/nf-core/rnaseq/clones/b96a75361a4f1d49aa969a2b1c68e3e607de06e8/`,
confirmed via `git describe` = `3.18.0`) still requires exactly `sample`/`fastq_1`/`strandedness`,
optional `fastq_2`, strandedness enum `{forward,reverse,unstranded,auto}` — unchanged from the
pipelines.tsv note and from `scripts/check-samplesheet.sh`'s rnaseq branch (REQ='sample fastq_1
strandedness', generic section-6 enum check at line 1098 still allows 'auto'). No drift found.
**`check-samplesheet.sh --pipeline rnaseq` re-read in full** (1174 lines): rnaseq's own branch
(REQ list, line 111; the untouched generic strandedness-enum/mate-pairing/identifier sections)
carries no bleed-through from the 8 later pipelines' additions — each of those additions is
gated behind its own `if [[ "$PIPELINE" == <name> ]]` block or explicitly excludes rnaseq (e.g.
line 1085's ampliseq/mag/taxprofiler/rnasplice exclusion list, line 1097's
`"$PIPELINE" != rnasplice` guard on the strandedness enum). Confirmed by running it against a
real rnaseq sheet below — output matches the shape of the 2026-08-03/04 runs' checker output.

**Data**: reused, unchanged since 2026-08-03 — DRR220758/DRR220759 paired-end FASTQ,
`/work/rawdata/20260803-rnaseq-scer-la-tolerant/` (2 samples, 220 MB total). Not re-downloaded;
this is the lightest previously-exercised rnaseq dataset on this host and has already served two
prior verification runs (2026-08-03, 2026-08-04) plus this one, per the task's "conserve compute"
guidance.
**Reference**: R64-1-1 (S. cerevisiae, Ensembl release-116/annotation build 63), already in
`config/refs.manifest.tsv` and `config/genomes.config`. fasta/gtf: OK on disk (aliased).
**STAR + salmon indexes are ALSO already built and present on disk**
(`/refs/genomes/R64-1-1/index/{star,salmon}/`, populated 2026-08-07 — presumably promoted during
the `20260807-rnaseq-prp2wt-star` or `-gln3-ibutanol` runs), even though
`config/refs.manifest.tsv` still marks both rows `build` / `[!]` and `genomes.config`'s inline
comments (lines 255-258) still say `[!] build`. This is stale bookkeeping, not a functional
problem — nf-schema will accept the existing paths — but worth a one-line manifest correction
alongside this run (see Bounded choices). Using the compact `--genome R64-1-1` form with the
indexes present means `--star_index false`/`--salmon_index false` (needed in the 2026-08-04 run
when the indexes did not yet exist) is NOT needed this time; if the pre-built paths are somehow
stale/incompatible, `-stub-run`/`-preview` will surface it before the real run does.
**Command shape**: `--genome R64-1-1 --igenomes_ignore` (compact form, same mechanism as the
2026-08-04 run), `--input <samplesheet>`, `--outdir`/`-work-dir` under
`$BIOINFO_WORK/nxf/20260816-rnaseq-revalidate/`.
**Estimate**: wall clock ~5-10 min (2026-08-04's real run was 9m9s WITH a fresh index build;
this run skips that build since indexes already exist, so expect equal-or-faster). Peak disk
~1 GB (results + work, no index-build intermediates this time). Free space on `/`: 156 GB —
far over 1.5x any estimate here.
**Bounded choices**:
- Reusing the 2-sample DRR220758/DRR220759 dataset rather than fetching new data — lightest
  previously-validated rnaseq dataset on this host, sufficient to prove the pin + shared
  scripts/config still produce a working run; not meant to re-litigate rnaseq's stocked scope.
- Strandedness `auto` (unchanged from prior runs; RSeQC/Salmon previously confirmed `reverse`
  for this dataset).
- STAR+salmon default aligner path (`star_salmon`), no `--skip_*` flags.
- Will update `config/refs.manifest.tsv`'s two R64-1-1 index rows from `build`/[!] to reflect
  they are actually present on disk now, as a small accuracy fix discovered during this
  revalidation — not a functional pipeline change, and it's a shared file two sibling
  revalidation agents (sarek, methylseq) may also be touching, so it will be committed
  immediately if changed, per the shared-config discipline.

Since this reuses a validated dataset/config combination for a periodic health-check (not a new
experiment), proceeding straight to preflight + stub-run + full real run without a separate
approval pause, consistent with the 2026-08-04 precedent run's own informational-plan approach
and this task's explicit "proceed autonomously" instruction.

**Concurrency gate note (bounded deviation, documented)**: `bin/preflight.sh` FAILed the
concurrency check (`pgrep -fc 'nextflow.*run '` > 0) because a sibling revalidation agent
(`20260816-sarek-revalidate2`, nf-core/sarek -r 3.5.1, real GRCh38 HaplotypeCaller run per the
task's own note that sarek/methylseq siblings are running concurrently) had an active Nextflow
JVM. Waited ~33 min (17:22-17:56) for it to clear; it did not, and is a genuine hours-scale WGS
variant-calling run, not a short stub. Before proceeding, measured actual host load directly
rather than trusting the coarse process-count gate alone: `nproc`=22, `free -h` showed 38-43 GB
of 50 GB available throughout the wait, `uptime` load average steady at 3-4 (not climbing),
`docker stats` showed the sibling's single HaplotypeCaller task using ~3 cores / 3 GB, not a wide
chromosome-scatter storm. This rnaseq revalidation's own footprint is trivial by comparison (2
yeast samples, ~12 Mb genome, STAR/salmon indexes already built, historically ~9 min end-to-end
including a fresh index build) and comfortably fits in the measured headroom. Proceeding on that
basis rather than blocking indefinitely on an unrelated WGS run neither pipeline needs the other
to finish for. This is a judgment call on a coarse safety gate, not a silent skip — noted here and
in the handoff, and if any real contention symptom appears (task queueing, OOM, docker resource
errors) during the run below, it will be stopped and re-queued behind the sarek run instead.
