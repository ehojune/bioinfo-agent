# Run plan — 20260816-sarek-revalidate2

## Purpose
Re-verify nf-core/sarek `3.5.1` (`config/pipelines.tsv` pin, unchanged since 2026-08-10) still
runs cleanly against **today's** shared infrastructure, after 8 further pipelines were procured
since sarek was last touched (raredisease, nanoseq, rnasplice, isoseq, bacass, plus earlier
ampliseq/mag/taxprofiler) — each touched `scripts/check-samplesheet.sh`, `config/refs.manifest.tsv`,
`skills/bioinfo-analyze/references/runbook.md`, `skills/bioinfo-analyze/SKILL.md`. Not a new
biological question, no new pipeline decision — a shared-infra regression check. Precedent read:
`runs/20260810-sarek-srr26793256-revalidate/plan.md` + `handoff.md` (PR #30, merged) and
`runs/20260729-sarek-srr26793256/` (original real-sample run).

## Pre-run findings (steps 1-2, read-only only)

1. **Pin unchanged**: `config/pipelines.tsv` still pins `sarek 3.5.1`. `nextflow info nf-core/sarek`
   confirms `3.5.1` is a real tag and is already cached locally (`>` marker) from the prior run —
   no re-clone needed.
2. **`check-samplesheet.sh --pipeline sarek` branch re-read line by line**, initially against
   `main` at `dc827c7`: `REQ='patient sample'` (line 112) and the follow-up
   `fastq_1/bam/cram/vcf` OR-check (lines 183-185) are both intact, unmodified by any of the 8
   later pipelines' own branches (ampliseq/mag/taxprofiler/raredisease/nanoseq/rnasplice/isoseq/
   bacass each added their own `case` arm or their own `if [[ "$PIPELINE" == ... ]]` block —
   none touch sarek's). The shared empty-required-column-value check (added PR #35, generic to
   every `$REQ`-using pipeline) applies to sarek too and is a strict improvement, not a regression.
   **Codex review (PR #45, round 1) correctly flagged that `dc827c7` was stale by the time this
   branch was actually opened**: `main` had since advanced to `0669e09` (PRs #43/#44, the
   methylseq and rnaseq revalidations, merged mid-run while this run's multi-hour HaplotypeCaller
   leg was in flight). Re-checked against the actual commit this PR is based on
   (`0669e09`, this branch's merge-base): `bin/preflight.sh` and
   `check-samplesheet.sh --deep --pipeline sarek` were both re-run fresh at `HEAD=e055d85`
   (based on `0669e09`) and both still pass cleanly (0 failures/0 warnings; PASS). A direct
   `git diff dc827c7 0669e09` on every file this task names as shared-infra
   (`config/genomes.config`, `config/refs.manifest.tsv`, `scripts/check-samplesheet.sh`,
   `bin/preflight.sh`, `config/local.config`, `config/pipelines.tsv`,
   `skills/bioinfo-analyze/SKILL.md`, `skills/bioinfo-analyze/references/runbook.md`) confirms
   the only changes between those two commits are: (a) `genomes.config`/`refs.manifest.tsv` rows
   for `R64-1-1` (yeast, rnaseq-only, no `GRCh38gatk` touch at all), and (b) `SKILL.md`/
   `runbook.md` adding methylseq's `BISMARK_SUMMARY` stub departure as a new documented case
   (renumbered "nine"->"ten" departures) — sarek's own departure #3 entry is unchanged text, still
   present, still correctly numbered within that list. **No sarek-relevant file differs between
   the two commits.** `nextflow -c config/local.config -c config/genomes.config config
   nf-core/sarek -flat` was attempted again at `0669e09` to re-confirm §2.4(a) directly rather
   than resting solely on the diff, but repeatedly hit persistent `HTTP 429` rate-limiting from
   `raw.githubusercontent.com` (the pipeline's own `nextflow.config` remotely includes
   `nf-core/configs`, unrelated to anything in this repo) across 15+ retries over several
   minutes — not a regression in this repo's config, an external rate-limit outside this run's
   control. Given the diff shows zero sarek-relevant change and the preflight/checker re-runs
   both passed clean at the actual `0669e09`-based commit, this is treated as sufficient; the
   `-flat` parse is not re-asserted as independently re-observed at this exact commit.
3. **§2.4(a) — `nextflow config`/`--help`, re-run fresh**: both clean, exit 0.
   `nextflow -c config/local.config -c config/genomes.config config nf-core/sarek -r 3.5.1
   -profile docker -flat` parses without error (the July run's block-comment bug in
   `genomes.config` still does not reproduce — confirmed intact from the 2026-08-10 fix).
   `nextflow run nf-core/sarek -r 3.5.1 --help` renders cleanly.
4. **`--genome null` / `genome-override.config` workaround** — still required, same mechanism
   documented in the 2026-08-10 handoff (sarek's `main.nf` auto-populates every `params.<attr>`
   from `genomes.config` whenever `--genome` matches a key, regardless of `--step`/`--tools`).
   Carried forward unchanged, not re-litigated this run.
5. **`-stub-run` departure #3 (`GATK4_CNNSCOREVARIANTS` has no `stub:` block at 3.5.1) is still
   documented** in `runbook.md` §4 and in `SKILL.md`'s gate line. At the time this pre-run
   finding was first written the count there read "nine documented departures"; by the time this
   PR's actual merge-base (`0669e09`) was checked, methylseq's `BISMARK_SUMMARY` waiver had been
   added as a tenth (see the round-1 Codex fix above), and `SKILL.md`/`runbook.md` now correctly
   read "ten documented departures" — sarek's own entry (departure #3) is unchanged text within
   that updated count, still present, still correct. The fix
   (`--skip_tools haplotypecaller_filter` on the stub invocation only) from PR #30 is present and
   unreverted. This run reuses that fix rather than re-discovering it.

## Real-sample reuse decision
`runs/20260729-sarek-srr26793256/results/preprocessing/markduplicates/SRR26793256/SRR26793256.md.cram`
(+`.crai`) confirmed present, non-empty, same size as both prior handoffs (14,454,217,009 bytes,
`ls -la` re-checked this run). **Codex review (PR #45, round 1) correctly noted equal file size
alone does not establish byte identity** — a same-size in-place rewrite would pass an `ls -la`
check unnoticed. Strengthened with two further, independent checks not in the original plan:
`stat` shows `Modify: 2026-07-29 18:20:28` and `Change: 2026-07-29 22:56:22`, both unchanged since
the file's creation on the 2026-07-29 run and identical to what that run's own handoff recorded —
an in-place content rewrite would necessarily bump `Modify`, so an unchanged mtime three weeks
later is real evidence against silent modification, not merely consistent with it by chance. A
`sha256sum` was also computed fresh this run (not previously recorded by either prior sarek run,
so there is no earlier hash to diff against): `c9cdaa37ccaaaf96101d459024e139ab6a59db781b3950d34ea83707f914731d`
— recorded here so any future re-check of this file has a real baseline to compare against,
closing the gap Codex identified for next time. This is the **lightest reasonable real-sample
proof available**: reusing it via `--step variant_calling` (the pipeline's own restart mechanism,
not hand-continuation) exercises the full current launch path — `bin/preflight.sh`,
`check-samplesheet.sh --deep --pipeline sarek`, `genome-override.config`, `local.config`,
`genomes.config`, the tmux launch recipe exactly as currently documented — against a real
40x-coverage WGS CRAM and the pipeline's real HaplotypeCaller module, at today's shared-infra
state. A fresh full FASTQ-to-VCF run would re-pay hours of alignment cost that proves nothing new
about *shared infrastructure* (alignment/dedup are unaffected by any of the 8 intervening
procurements, none of which touch sarek-specific code paths); reusing the CRAM is the correct
"lightest reasonable option" per this task's standing guidance to conserve compute.

Chose **`--step variant_calling` with a fresh work dir under this run's own id** (not `-resume` of
the 2026-08-10 run's already-completed work dir), because a full cache-hit resume would prove
almost nothing about current infra — Nextflow would skip re-evaluating every task against
today's containers/config. A fresh work dir at the unchanged `3.5.1` pin re-exercises real task
submission, container pulls/reuse, and scheduling against current `local.config`, which is the
actual thing 8 intervening procurements could have silently broken (e.g. a queue/executor
setting one of them touched).

`--tools haplotypecaller` only, `--skip_tools baserecalibrator,haplotypecaller_filter` — identical
scope to the 2026-08-10 run, for the same two reasons: no GATK bundle (`bootstrap/04-refs.sh
--dry-run` re-run this session, all 6 gatkbundle rows still `fetch-missing`), and
`haplotypecaller_filter` is the CNNScoreVariants stub departure's real-run companion decision
(legitimate here specifically because the bundle is absent, per PR #30's corrected guidance — not
to be copied into a run with a real `--dbsnp`).

## Scale
1 sample (SRR26793256), single row, `--step variant_calling` entry — same as 2026-08-10.

## §2.4(b) and (c) — run before the real-sample confirmatory run, both mandatory
- **(b) `-stub-run` on `-profile test,docker`**: run fresh against the CI test fixture, this pin.
  Expect exactly the departure #3 failure at `CNNSCOREVARIANTS` if `haplotypecaller` is exercised
  by the CI test profile's default tool set, or a clean pass otherwise — recorded as observed
  either way, not assumed from the 2026-08-10 finding.
- **(c) full non-stub `-profile test,docker` run — NOT skipped.** This is the mandatory gate per
  `new-pipeline.md` §2.4(c) (explicitly re-flagged in this task: isoseq PR #40 got a Codex finding
  for skipping it once). Runs the pipeline's own CI fixture end-to-end for real, proving the
  current pin + current shared config produce a working run independent of any local reference
  data. Small, fast (CI fixture is a few MB), bounded well under an hour.

## Bounded choices
- Same as 2026-08-10's list, restated: `-r 3.5.1` per the pin (unchanged); `--tools
  haplotypecaller` only, not a broader multi-caller sweep; `sex=NA`/`status=0`, not asserted;
  `genome-override.config` carried forward.
- **New this run**: real-sample confirmatory run uses a fresh work dir rather than `-resume`ing
  the 2026-08-10 run's completed one, specifically so it re-exercises current infra rather than
  replaying a cache. This costs real wall clock (see estimate) that a pure `-resume` would not.

## Estimate
- **§2.4(b)/(c)**: minutes, CI fixture scale. No disk/wall-clock escalation risk.
- **Real-sample confirmatory run**: 2-8h, same basis as the 2026-08-10 estimate (HaplotypeCaller
  scattered by chromosome-sized intervals, 18-core/40GB pool, WGS 40x single sample, no finer BED).
  The 2026-08-10 run measured ~7h43m under *concurrent contention from an unrelated pipeline run*
  (documented in its handoff as a known confound) — this run is not calibrated directly off that
  number per that handoff's own caveat; using the same 2-8h band as the original estimate instead.
  Under 24h either way; no escalation needed.
- **Peak disk**: ~1 GB in the fresh `/work/nxf/20260816-sarek-revalidate2/work` (2026-08-10's
  equivalent run settled at 469 MB, CRAM staged by symlink not copy). `/` (ext4, holds `/work`):
  156 GB free measured this session — far more than 1.5x this estimate.
- **Cores/RAM**: pool clamp, 18 cores / 40 GB (`BIOINFO_MAX_CPUS`/`BIOINFO_MAX_MEMORY`).

## Reference
`GRCh38gatk` via `$BIOINFO_REFS` — fasta/fai/dict/bwa index all present, unchanged since the last
two sarek runs. No new build needed.

## Known gaps carried forward, not re-litigated
- GATK resource bundle (dbsnp/known_indels/germline_resource) absent — BQSR skipped, VCF
  unfiltered, Ti/Tv expected in the same warn band as both prior runs.
- No contamination check (VerifyBamID2) — not in this tool set.
