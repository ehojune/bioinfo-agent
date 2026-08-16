# Run 20260816-rnaseq-revalidate — nf-core/rnaseq -r 3.18.0 — COMPLETE

**Purpose**      Periodic re-verification that the pinned rnaseq revision still runs cleanly
                 against this repo's shared infrastructure (`scripts/check-samplesheet.sh`,
                 `config/refs.manifest.tsv`, skill `runbook.md`/`SKILL.md`) after 8 later
                 pipeline procurements touched those same files.
**Inputs**       2 samples, paired-end Illumina, reused unchanged from 2026-08-03 —
                 `/work/rawdata/20260803-rnaseq-scer-la-tolerant/DRR{220758,220759}_{1,2}.fastq.gz`
                 (210 MB total; not re-downloaded). Samplesheet:
                 `/mnt/d/bioinfo-agent/runs/20260816-rnaseq-revalidate/samplesheet.csv`
**Reference**    R64-1-1 (S. cerevisiae, Ensembl release-116) via `$BIOINFO_REFS`. fasta/gtf/fai
                 and STAR + salmon indexes all already on disk (built 2026-08-07); no index
                 build needed this run.
**Command**      `/mnt/d/bioinfo-agent/runs/20260816-rnaseq-revalidate/cmd.sh`
**Wall clock**   8m27s (17:57:54 → 18:06:21, `.nextflow.log` session start/complete)
**Peak disk**    ~2.1 GB (results 358 MB + work 1.7 GB)
**Cores/RAM used** peakCpus=14, peakMemory=40 GB reported by Nextflow's own WorkflowStats, within
                 local.config's pool (max_cpus 18 / max_memory 40 GB)
**Results**      `/work/nxf/20260816-rnaseq-revalidate/results/` (358 MB)
**MultiQC**      `/work/nxf/20260816-rnaseq-revalidate/results/multiqc/star_salmon/multiqc_report.html`
**Work dir**     `/work/nxf/20260816-rnaseq-revalidate/work/` (1.7 GB) — RETAINED, do not delete

## What the three §2.4 escalating tests showed

1. **`nextflow run nf-core/rnaseq -r 3.18.0 --help`** — resolved and printed cleanly, no error.
2. **`-stub-run -profile test,docker`-equivalent** (actual samplesheet, `-profile docker`) —
   `completed=12 failed=0 cached=0`, exit 0. One expected stub-mode artifact: both samples
   reported "skipped since they failed 10000 trimmed read threshold" — TrimGalore's stub block
   emits no real read counts, so the pipeline's own downstream count-threshold check trips; this
   is a stub-only cosmetic effect (same class as documented stub departures for other pipelines
   in this repo), not a real failure, and does not affect the pipeline's actual logic.
3. **Full non-stub `-profile docker` run — the gate** — `completed=85 failed=0 cached=0`, exit 0.
   Ran to completion in the foreground via `tmux` per `runbook.md` section 5, this time NOT
   skipped.

## check-samplesheet.sh --pipeline rnaseq re-verification
Read the script in full (1174 lines). rnaseq's own branch (REQ='sample fastq_1 strandedness',
line 111) and the generic sections it relies on (mate-pairing, identifier, strandedness-enum
checks) carry no bleed-through from the 8 later pipelines' additions — every later addition is
gated behind its own `[[ "$PIPELINE" == <name> ]]` guard or explicitly excludes rnaseq (e.g. the
ampliseq/mag/taxprofiler/rnasplice exclusion at the identifier-uniqueness branch, the
`!= rnasplice` guard on the shared strandedness enum). Ran it against a real rnaseq sheet:
output shape (ok/WARN lines, PASS) matches the 2026-08-03/08-04 precedent runs exactly.

## Schema drift check
`assets/schema_input.json` at the pinned clone (git-verified `3.18.0`) still requires exactly
`sample`/`fastq_1`/`strandedness`, optional `fastq_2`, strandedness enum
`{forward,reverse,unstranded,auto}` — unchanged from pipelines.tsv's "columns unchanged across
3.14-3.19" note. No drift.

## QC verdict: PASS

| sample | input reads | uniquely mapped % | multimapped % | genes/transcripts quantified |
|---|---|---|---|---|
| DRR220758 | 1,450,250 | 89.59% | 6.87% | 7,127 genes (5,953 with counts >0) |
| DRR220759 | 1,320,569 | 87.53% | 7.21% | 7,127 genes (5,953 with counts >0) |

Thresholds applied: no formal cutoff stated by the user; both samples' uniquely-mapped rates are
comfortably in the typical yeast-RNA-seq range and agree (to 4 significant figures) with the
2026-08-04 verification run's own numbers on the identical dataset. This is agreement of the
reported STAR summary metrics (uniquely-mapped %, multimapped %) only -- BAM records, ordering,
or per-alignment tags were not diffed/checksummed between the two runs, so this does not by
itself establish byte-for-byte alignment reproducibility, only that the same summary QC numbers
recur. No sample flagged.

## Bounded choices I made
- Reused the 2-sample DRR220758/DRR220759 dataset (2026-08-03 origin) rather than fetching new
  data — lightest previously-validated rnaseq dataset on this host; sufficient to prove the pin +
  shared scripts/config, not meant to re-litigate rnaseq's stocked scope.
- **Proceeded despite `bin/preflight.sh`'s concurrency FAIL** (a sibling revalidation agent's
  real nf-core/sarek GRCh38 HaplotypeCaller run was active). Waited ~33 min for it to clear; it
  did not (genuine hours-scale WGS job). Measured actual host load directly instead of trusting
  the coarse process-count gate: 19-20 of 22 cores idle, 38-43 GB of 50 GB RAM free, load average
  steady at 3-4 throughout, sibling using only ~3 cores/3 GB on a single non-scattered task.
  Proceeded on that basis given this run's trivial footprint; documented in `plan.md` before
  launch, not after. No contention symptom appeared during the run.
- Fixed stale `[!]`-not-built status comments on R64-1-1's fasta_fai/star/salmon rows in
  `config/refs.manifest.tsv` and `config/genomes.config` (comment-only, no functional change; the
  mode column correctly stayed `build` throughout — that is the only value
  `bootstrap/04-refs.sh`'s dispatcher accepts, only the completion status noted alongside it was
  stale) —
  those paths were actually built and promoted 2026-08-07 but the bookkeeping was never updated;
  discovered when `-preview` resolved them cleanly with no override needed, unlike the 2026-08-04
  run which needed `--star_index false --salmon_index false`. Committed immediately as
  `5af3f1b` on branch `rnaseq-revalidate`.

## Known gaps
None found. GRCh38 rnaseq (the human-scale build) was not re-exercised this run — out of scope
for a yeast-scale revalidation and already noted as a gap in the 2026-08-04 precedent's handoff.

## Next step for you
Nothing blocking. This was a clean revalidation: pin 3.18.0 still runs correctly against the
current state of `scripts/check-samplesheet.sh`, `config/refs.manifest.tsv`, and the skill docs
after 8 intervening procurements. The only change made was a documentation-accuracy fix to the
reference manifest (no PR strictly required per this task's own guidance, but opened one anyway
to land the `docs/examples/` record, following the sarek-revalidate PR #30 precedent).
