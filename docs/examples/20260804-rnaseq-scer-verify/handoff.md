# Run 20260804-rnaseq-scer-verify — nf-core/rnaseq -r 3.18.0 — COMPLETE

**Purpose**      Verification-only run: confirm PR #4 (`fix/rnaseq-igenomes-alias`, merged as
                 `f1ef117`) actually fixes the AWS-iGenomes filename heuristic collision, using
                 the repo-standard mechanism only (no ad-hoc alias workaround), and specifically
                 via the `--genome R64-1-1` **compact form** — the form Codex review flagged as
                 still vulnerable before the final commits (`9214484`, `6b64910`).
**Inputs**       2 samples, paired-end Illumina (75 bp), reused from the 2026-08-03 run —
                 `/work/rawdata/20260803-rnaseq-scer-la-tolerant/DRR{220758,220759}_{1,2}.fastq.gz`
                 (not re-downloaded). Samplesheet: `/mnt/d/bioinfo-agent/runs/20260804-rnaseq-scer-verify/samplesheet.csv`
**Reference**    R64-1-1 (S. cerevisiae, Ensembl release-116) via `$BIOINFO_REFS`. fasta/gtf
                 already OK (fetched 2026-08-03); STAR + salmon indexes built fresh this run.
**Command**      `/mnt/d/bioinfo-agent/runs/20260804-rnaseq-scer-verify/cmd.sh`
**Wall clock**   9m9s (17:32:08.970 → 17:41:18.109, from `.nextflow.log`)
**Peak disk**    ~2.5 GB (results 620 MB + work 1.9 GB)
**Cores/RAM used** within local.config's resourceLimits pool (max_cpus 18 / max_memory 40 GB);
                 actual per-task usage far below, genome is 12 Mb
**Results**      `/work/nxf/20260804-rnaseq-scer-verify/results/` (620 MB)
**MultiQC**      `/work/nxf/20260804-rnaseq-scer-verify/results/multiqc/star_salmon/multiqc_report.html`
**Work dir**     `/work/nxf/20260804-rnaseq-scer-verify/work/` (1.9 GB) — RETAINED, do not delete

## Verification verdict: PASS

The alias fix works correctly through the repo-standard mechanism, via the compact form,
with no manual workaround. Evidence:

1. **Alias resolution, confirmed at config level before any run** (`nextflow -c ... config
   nf-core/rnaseq -flat`, and again in the `-stub-run` params summary):
   `params.genomes.'R64-1-1'.fasta = '/refs/genomes/R64-1-1/fasta/R64-1-1.fa'` and
   `.gtf = '/refs/genomes/R64-1-1/gtf/R64-1-1.gtf.gz'` — the build-named ALIAS, not the
   canonical `genome.fa`/`genes.gtf.gz` basenames that trigger `is_aws_igenome`.
2. **No `_IGENOMES`-suffixed process anywhere in the real run's log** (`grep -c IGENOMES` on
   the full stdout log = 0). The DAG ran `NFCORE_RNASEQ:PREPARE_GENOME:STAR_GENOMEGENERATE` and
   `NFCORE_RNASEQ:RNASEQ:ALIGN_STAR:STAR_ALIGN` — the modern path, not
   `STAR_GENOMEGENERATE_IGENOMES` / `STAR_ALIGN_IGENOMES`.
3. **STAR version actually used: 2.7.11b** (`STAR-avx2` binary), confirmed in both the genome-
   build task's `.command.log` and both align tasks' `versions.yml` — not the 2.6.1d legacy
   build that segfaults on this CPU. No segfault, no exit-139, anywhere in the run.
4. **Task-level success**: 87/87 processes exit code 0 (`find work -name .exitcode` all `0`),
   pipeline's own summary line `[SUCCESS] completed=87 failed=0 cached=0`,
   `nf-core/rnaseq Pipeline completed successfully`. Zero `ERROR` lines in the log; 2 `WARN`
   lines, both benign and expected (first run so `-resume` was a no-op; the standard
   "unrecognised parameter" notice for `--max_cpus`/`--max_memory`/`--max_time`/`--refs`,
   documented as expected in `genomes.config` section 5).
5. **Newly built indexes match the alias naming with no friction**: `results/genome/index/star/`
   and `results/genome/index/salmon/` built cleanly against `R64-1-1.fa` /
   `R64-1-1.filtered.gtf` as the working basenames throughout (task symlinks named
   `R64-1-1.fa -> /refs/genomes/R64-1-1/fasta/genome.fa`, etc.) — the index build itself never
   touched or needed the canonical `genome.fa`/`genes.gtf.gz` names directly.
6. **Numerical cross-check against the 2026-08-03 workaround run** (same FASTQ, same reference
   content, different mechanism to reach it): STAR uniquely-mapped % identical to five
   significant figures — DRR220758 89.59%, DRR220759 87.53%; multimapped % identical —
   6.87% / 7.21%. Same alignment result via the fixed repo mechanism as via the old ad-hoc
   workaround; the fix changes only how the safe filename is reached, not what gets aligned.

No QC re-interpretation performed here — this run's purpose was mechanism verification, not a
fresh biological QC pass; metrics above are cited only to show byte-for-byte alignment
equivalence with the prior successful run.

## Bounded choices I made
- **Strandedness `auto`** in the samplesheet (unchanged from 2026-08-03; already confirmed
  `reverse` by both RSeQC and Salmon in that prior run, kept as `auto` here rather than
  hardcoding, since re-confirming the auto-inference path was itself part of the exact-repeat
  intent).
- **`--star_index false --salmon_index false` added to the compact-form command** — see "New
  finding" below. Undo: not applicable once the index is promoted into `$BIOINFO_REFS` (see
  Known gaps), at which point these paths would resolve and exist, and the override becomes
  unnecessary (though harmless to leave).

## New finding (separate from PR #4, discovered during this verification)
`--genome <key>` auto-populates `star_index`/`salmon_index` params from `genomes.config`'s map
even when those paths are declared but not yet built ([!] rows in the manifest). nf-schema then
fails pipeline-parameter validation before the run starts, because those paths don't exist yet
on disk:
```
* --star_index (/refs/genomes/R64-1-1/index/star): the file or directory ... does not exist
* --salmon_index (/refs/genomes/R64-1-1/index/salmon): the file or directory ... does not exist
```
Confirmed via `-stub-run` first, before touching the real run. Passing `--star_index ''`
(empty string) does not work — the nextflow CLI parses a bare empty-string argument as
boolean `true`, which fails schema type validation the other way (`Value is [boolean] but
should be [string]`). `--star_index false --salmon_index false` is what nf-schema accepts as
"unset, build it" and is what unblocked both the stub run and the real run here.
`genomes.config` section 2's "first run on this host" note ("Omit --star_index and
--salmon_index") is accurate for the **explicit `--fasta`/`--gtf` form** but does not carry
over to the **`--genome` compact form**, where omission is not possible — the map sets them
regardless. Worth a doc addition to `genomes.config` section 2(a) and/or a
`bootstrap/04-refs.sh`-adjacent note; not fixed in this task since it is out of this task's
verification scope (it is a first-index-build usability gap, not a correctness bug — once an
index is built and the manifest shows `(ok)`, the compact form needs no override).

## Known gaps
- STAR/salmon indexes built this run (`results/genome/index/{star,salmon}/`) are **not**
  promoted into `$BIOINFO_REFS/genomes/R64-1-1/index/` — same convention as the 2026-08-03 run.
  The manifest rows remain `[!] build`. A future rnaseq run against R64-1-1 will rebuild them
  (minutes, not expensive for this genome) unless promoted by hand.
- Routine STAR tuning warning in the genome-build log: `--genomeSAindexNbases 11 is too large
  for the genome size=12157105 ... recommended --genomeSAindexNbases 10`. Cosmetic for this
  tiny genome, unrelated to the alias fix; not acted on.
- This run did not re-verify GRCh38 (the build actually named in PR #4's motivating
  description, and the far more expensive one — ~1h/38GB index build). The mechanism confirmed
  here (fasta/gtf alias resolution, no `_IGENOMES` routing, STAR 2.7.11b) is generic across
  every build per `04-refs.sh`'s alias step, but GRCh38 itself has not been exercised
  end-to-end since the fix landed.

## Next step for you
Nothing blocking. If useful: (1) promote this run's STAR/salmon indexes into `$BIOINFO_REFS` so
the next R64-1-1 rnaseq run skips the rebuild; (2) add the `--star_index false --salmon_index
false` compact-form note to `genomes.config` section 2(a) before the first GRCh38 rnaseq run,
so that ~1h/38GB build isn't repeated needlessly on the same schema-validation snag found here.
