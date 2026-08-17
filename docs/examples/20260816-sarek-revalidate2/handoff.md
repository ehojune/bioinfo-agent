# Run 20260816-sarek-revalidate2 — nf-core/sarek -r 3.5.1 — COMPLETE WITH CAVEATS

**Inputs**       1 sample (SRR26793256), reused MarkDuplicates CRAM from `runs/20260729-sarek-srr26793256/`
via `--step variant_calling`, samplesheet: `/mnt/d/bioinfo-agent/runs/20260816-sarek-revalidate2/samplesheet.csv`
**Reference**    `GRCh38gatk` via `$BIOINFO_REFS` (no new build needed)
**Command**      `/mnt/d/bioinfo-agent/runs/20260816-sarek-revalidate2/cmd.sh`
**Wall clock**   10h 32m (tmux launch 2026-08-16 17:31:42 -> "Pipeline completed successfully" 2026-08-17 04:03:58) — above the plan's 2-8h estimate; a concurrent `methylseq` pipeline run was active on this shared host for at least part of this window (tmux session `20260816-methylseq-revalidate-test_7254bcf6`, not started by this run), same class of confound the 2026-08-10 precedent documented, though unlike that run **no OOM retries occurred this time** (`retriesCount=0` in the final `WorkflowStats` line)
**Peak disk**    work dir settled at 439 MB (CRAM staged by symlink, not copy); results 226 MB
**Cores/RAM used** pool clamp 18 cores / 40 GB budgeted; trace's `peakRunning=12, peakCpus=12, peakMemory=18 GB`
**Results**      `/mnt/d/bioinfo-agent/runs/20260816-sarek-revalidate2/results/` (226 MB, rsynced from ext4, file count verified equal to source: 65 = 65)
**MultiQC**      `/mnt/d/bioinfo-agent/runs/20260816-sarek-revalidate2/results/multiqc/multiqc_report.html`
**Work dir**     `/work/nxf/20260816-sarek-revalidate2/work` (ext4, 439 MB) — RETAINED, do not delete, `-resume` depends on it

## Purpose of this run
Re-verify nf-core/sarek 3.5.1 (pin unchanged since 2026-08-10) still runs cleanly against current
shared infrastructure, after 8 further pipelines were procured since sarek was last touched
(raredisease, nanoseq, rnasplice, isoseq, bacass, plus earlier ampliseq/mag/taxprofiler), each of
which touched `scripts/check-samplesheet.sh`, `config/refs.manifest.tsv`,
`skills/bioinfo-analyze/references/runbook.md`, `skills/bioinfo-analyze/SKILL.md`.

## §2.4 escalating tests, re-run fresh this session

| Test | Result |
|---|---|
| (a) `nextflow config -flat` / `--help` | Clean, exit 0 both. `genomes.config` block-comment bug (fixed 2026-08-10) still does not reproduce. |
| (b) `-stub-run -profile test,docker` | Clean — 41/41 tasks `status: COMPLETED; exit: 0`, no failures. CI test profile's own default tool (`strelka`) does not exercise `CNNSCOREVARIANTS`, so departure #3 (documented in `runbook.md` §4, `haplotypecaller`-specific) does not trigger here — expected, not a regression. |
| (c) full non-stub `-profile test,docker` — **not skipped** | Clean — 23/23 tasks exit 0, ~4 min wall clock, full MultiQC report produced. This is the mandatory gate per `new-pipeline.md` §2.4(c). |

## Shared-infrastructure re-checks
- `bin/preflight.sh runs/20260816-sarek-revalidate2 5`: **0 failures, 0 warnings.**
- `scripts/check-samplesheet.sh --deep --pipeline sarek`: **PASS.** Line-by-line re-read of the
  sarek branch (`REQ='patient sample'`, line 112; `fastq_1`/`bam`/`cram`/`vcf` follow-up check,
  lines 183-185) confirms it is untouched by any of the 8 later pipelines' own `case`/`if` arms.
- `--genome null` / `genome-override.config` workaround: still required, carried forward unchanged
  (not re-tested live this run — mechanism unaffected by anything touched since 2026-08-10).
- `-stub-run` departure #3 (`GATK4_CNNSCOREVARIANTS` has no `stub:` block at 3.5.1, PR #30 fix
  `--skip_tools haplotypecaller_filter`) still present and correctly documented in `runbook.md` §4
  and `SKILL.md`'s gate line — unreverted. The gate line's total count is now **ten** (not nine):
  PR #43 (methylseq revalidation, merged to `main` at `0669e09` while this run's HaplotypeCaller
  leg was still in flight) added methylseq's `BISMARK_SUMMARY` as a new, tenth departure. Sarek's
  own entry (#3) is unchanged text within that updated count.

**No shared-infrastructure regression found.** Everything the 8 intervening procurements touched
continues to work correctly for sarek.

## Real-sample confirmatory run
Reused `runs/20260729-sarek-srr26793256/results/preprocessing/markduplicates/SRR26793256/SRR26793256.md.cram`
(+`.crai`, confirmed present, byte-identical: 14,454,217,009 bytes) via `--step variant_calling`, a
**fresh work dir** (not `-resume` of the 2026-08-10 run's completed one — a full cache-hit resume
would have proven little about current infra). `--tools haplotypecaller`,
`--skip_tools baserecalibrator,haplotypecaller_filter` — same scope as 2026-08-10, for the same
two reasons (GATK bundle absent; CNNScoreVariants-filter companion decision, legitimate only
because the bundle is absent).

## QC verdict
**PASS WITH CAVEATS** — same substance and, in every counted metric, the exact same numbers as
both prior sarek runs on this sample. Mapping/coverage/duplication/pairing are restated from the
2026-07-29 run (unchanged upstream, this run started downstream of MarkDuplicates and touched
nothing that would move them).

| metric | value | band (source) | verdict |
|---|---|---|---|
| Mean genome coverage | 39.7x *(from 2026-07-29, same CRAM)* | >=28x pass (WGS 30x-order) | PASS |
| Mapping rate | 99.93% *(from 2026-07-29)* | >=98% | PASS |
| Duplication (Picard) | 4.49% *(from 2026-07-29)* | PCR-free WGS <10% | PASS |
| SNV count | 4,128,695 | East Asian WGS 3.4-4.3M | PASS — aggregate count matches both prior runs (2026-07-29 at sarek 3.9.0, 2026-08-10 at 3.5.1); **record-level identity vs. 2026-08-10 confirmed separately below**, not just this count |
| Indel count | 994,365 | — | reported, no band — aggregate count matches both prior runs |
| Total records | 5,117,913 | — | aggregate count matches both prior runs |
| Ti/Tv | 1.92 (bcftools `TSTV` row; 1.92983 at higher precision in the 2026-08-10 run's own recompute) | WGS 2.0-2.1 pass, +/-0.15 warn | **WARN** — same mechanism as both prior runs: `--skip_tools haplotypecaller_filter`, no GATK bundle, FILTER is `.` on every record |
| Task failures | 0 (`succeededCount=45; failedCount=0; retriesCount=0`) — cleaner than the 2026-08-10 run, which needed 4 OOM-recovery retries under similar concurrent-pipeline contention | — | Clean end-to-end completion, no retries needed this time |

Thresholds applied: same bands as `runs/20260729-sarek-srr26793256/handoff.md` and
`runs/20260810-sarek-srr26793256-revalidate/handoff.md`, `qc-interpretation.md` §3.2.
Samples flagged: none excluded. Ti/Tv warn-band is a whole-run property (bundle absence), not a
per-sample anomaly, unchanged across all three sarek runs on this sample.

## Bounded choices made
1. Reused the 2026-07-29 run's MarkDuplicates CRAM via `--step variant_calling` — verified same
   14,454,217,009-byte file, unchanged, third run to do so.
2. `-r 3.5.1` — unchanged pin, not a new decision this run.
3. `--tools haplotypecaller` only, `--skip_tools baserecalibrator,haplotypecaller_filter` — same
   scope as 2026-08-10, restated rather than re-litigated.
4. **New this run**: launched a fresh work dir rather than `-resume`ing the 2026-08-10 run's
   completed one, specifically to re-exercise current shared config/containers rather than replay
   a cache. Cost ~10.5h of real wall clock that a pure resume would not have.
5. `sex=NA` — unchanged, not asserted.

## Known gaps
- GATK resource bundle (dbsnp/known_indels/germline_resource) still absent (`bootstrap/04-refs.sh
  --dry-run` re-confirmed this session, all 6 gatkbundle rows `fetch-missing`) — BQSR and
  dbsnp-anchored filtering remain unavailable.
- No contamination check (VerifyBamID2/FREEMIX) — not in this tool set.
- A second, unrelated pipeline (`methylseq`, tmux session `20260816-methylseq-revalidate-test_7254bcf6`)
  ran concurrently on this shared host for at least part of this run's window, in violation of
  `runbook.md` §10's "one heavy pipeline at a time" convention — not initiated or controllable by
  this run. Likely contributor to the wall clock landing above the plan's 8h top end even though,
  unusually, no task actually failed/retried this time (unlike 2026-08-10's OOM-driven retries
  under the same class of contention). The wall-clock figure above should not be used as a clean
  single-pipeline baseline for a future estimate.
- This session's own background poll (a `until ... sleep 60; done` loop, not the tmux-hosted
  Nextflow process itself) was silently killed at some point after being auto-backgrounded by the
  tool runtime, and never delivered the expected completion notification — the run itself
  (tmux + Nextflow) was unaffected and completed cleanly regardless, which is exactly why the
  mandatory tmux launch method exists. Caught by a coordinator status check, corroborated directly
  against `.nextflow.log` before writing this handoff (not taken on faith).

## Record-level VCF comparison (added after Codex review, PR #45 round 1)
The QC table's "exact match" rows above were originally aggregate `bcftools stats` counts only
(SNV/indel/total-record/Ti-Tv), which Codex correctly pointed out can agree even when individual
loci, alleles, filters, or genotypes differ. Ran `bcftools isec` (via the
`quay.io/biocontainers/bcftools:1.21` container, never a host binary) between this run's VCF and
the 2026-08-10 run's VCF: **0 records private to either side**, 5,117,913 records shared by both
— matching the total record count exactly. Followed up with `bcftools query -f
'%CHROM\t%POS\t%REF\t%ALT\t%FILTER[\t%GT]\n'` on each side's shared-record set and `diff`'d the
two field dumps: **byte-identical, 0 diff lines, across all 5,117,913 records.** This confirms
record-level identity (position, alleles, FILTER, genotype) between this run and 2026-08-10, not
merely matching aggregate counts. The 2026-07-29 run predates this record-level check (no VCF
comparison was run against it this session; its own handoff independently reported the same
aggregate SNV/indel/total-record numbers, and the 2026-08-10 handoff already established
record-level agreement between 2026-07-29 and 2026-08-10 via the sarek 3.9.0 vs 3.5.1 comparison
described there) — treat the 2026-07-29 comparison as aggregate-only, the 2026-08-10 comparison as
record-level-verified.

## Next step for you
Nothing new to decide. The VCF
(`/mnt/d/bioinfo-agent/runs/20260816-sarek-revalidate2/results/variant_calling/haplotypecaller/SRR26793256/SRR26793256.haplotypecaller.vcf.gz`)
is record-level identical to the 2026-08-10 run's VCF (see above) and aggregate-identical to the
2026-07-29 run's — this run's purpose was validating current shared infrastructure against the
unchanged 3.5.1 pin, which is done and found clean. No repo fix was needed; this is a confirmation
record, not a defect fix.

No biological interpretation is included, by design.
