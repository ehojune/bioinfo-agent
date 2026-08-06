# Run 20260806-chipseq-vsmc-h3k27me3-smoke — nf-core/chipseq -r 2.1.0 — PIPELINE MECHANICS PASS, REPLICATE CONCORDANCE FAIL

**Inputs**       4 samples (2 ChIP + 2 matched Input), single-end 51bp, human. PRJNA980697
("Prelamin A drives vascular calcification..."), vascular smooth muscle cells (VSMC), WT
condition, H3K27me3 mark (broad repressive histone mark), biological replicates 1 and 2, real
public data. Samplesheet: `runs/20260806-chipseq-vsmc-h3k27me3-smoke/samplesheet.csv`
**Reference**    GRCh38, explicit `--fasta`/`--gtf`/`--bowtie2_index`/`--blacklist`/`--gene_bed`
(build-named alias paths — compact `--genome GRCh38` tested via `-stub-run` and found to
auto-populate `bwa_index`/`star_index` from `genomes.config`, which nf-schema then fails
`exists:true` validation on since neither is built, regardless of the aligner actually
selected — same class of issue as scrnaseq/methylseq)
**Command**      `runs/20260806-chipseq-vsmc-h3k27me3-smoke/cmd.sh` (`--aligner bowtie2`, reusing
the bowtie2 index the atacseq run built and promoted; `--macs_gsize 2700000000` plain decimal,
not `2.7e9`; broad-peak mode, default `--broad_cutoff 0.1`)
**Wall clock**   ~57 min total (08:54–09:51), across an interrupted first attempt (background
process died when the executing subagent's turn ended — not a pipeline or config bug, see the
process-reliability issue tracked separately) and a clean `-resume` that finished the remaining
work in a few minutes from cache
**Peak disk**    results 5.3 GB + work 13 GB = 18.3 GB combined
**Results**      `/work/nxf/20260806-chipseq-vsmc-h3k27me3-smoke/results/` (5.3 GB)
**MultiQC**      `/work/nxf/20260806-chipseq-vsmc-h3k27me3-smoke/results/multiqc/broad_peak/multiqc_report.html`
**Work dir**     `/work/nxf/20260806-chipseq-vsmc-h3k27me3-smoke/work/` (13 GB) — RETAINED, do not
delete, `-resume` depends on it

## QC verdict

**Pipeline mechanics: PASS.** Alignment, duplication and control pairing are clean, and REP1 shows
real enrichment signal (fingerprint AUC below its own Input's, in the expected direction).
**Replicate concordance: FAIL, not "worth a closer look" — actually checked, and it is bad.** An
earlier version of this verdict called the whole run "PASS WITH CAVEATS" while explicitly listing
the checks that would support that as not done (Codex review on PR #16 caught this — a verdict is
not supported by caveats it admits it never checked). Ran them. They do not support a pass.

| Metric | REP1 | REP2 | Band (qc-interpretation.md §3.5) | Verdict |
|---|---|---|---|---|
| Duplication (Picard, ChIP) | 6.35% | 4.13% | no explicit band | Clean, reported |
| Duplication (Picard, Input) | 7.76% | 10.26% | no explicit band | Clean, reported |
| Peak count (broad, MACS3) | 193 | 651 | — (no band stated for broad marks) | Reported |
| FRiP (broad histone) | 0.477% | 0.105% | TF band (≥0.05) explicitly does not apply to broad marks per §3.5 | Low for both, REP2 markedly lower — consistent with the fingerprint/overlap findings below, not scored pass/fail on its own |
| NSC / RSC | 1.111 / 0.799 | 1.023 / 1.962 | explicitly not meaningful for broad marks per §3.5 | Reported, not banded |
| **Fingerprint AUC, ChIP vs. own Input** | ChIP 0.162 vs Input 0.238 (gap 0.076) | ChIP 0.261 vs Input 0.270 (gap 0.009) | §3.5: "input near diagonal (AUC≈0.5), ChIP strongly bowed (AUC well below 0.5)" — a bigger ChIP-vs-Input AUC gap is the enrichment signal | **REP1 shows the expected pattern. REP2's ChIP is barely distinguishable from its own Input** — computed directly from `deepTools/plotFingerprint/*.qcmetrics.txt`, not eyeballed from the plot |
| **Replicate peak overlap (REP1 ∩ REP2)** | 0 / 193 REP1 peaks overlap a REP2 peak | 0 / 651 REP2 peaks overlap a REP1 peak | §3.5: "For broad marks use overlap fraction" (no numeric band restated, but 0% is far outside any reasonable reading of it) | **0% in both directions** — computed with `bedtools intersect -u` (via the cached `bedtools:2.30.0` container), cross-checked with a self-intersect control (REP1 vs REP1 correctly returns all 193) to confirm the tool and coordinate system are working, not silently broken |
| Input present, matched per replicate | yes, 2.9M reads (~ChIP depth) | yes | present ≥ ChIP depth for broad marks | REP1 comparison done; REP2 Input depth not separately checked against REP2 ChIP depth |

Thresholds applied: `skills/bioinfo-analyze/references/qc-interpretation.md` §3.5. Reading the
three findings together: REP1 has real, if modest, enrichment (fingerprint gap, lower FRiP-context
peak count) and REP2's peaks are called from a ChIP sample whose read-distribution is nearly
identical to its own Input's — weak or absent real enrichment — which is exactly the scenario
where a peak caller still produces peaks (651 of them, MACS3 does not know to refuse) that are
mostly background, not signal. Zero peak overlap between two supposed biological replicates of the
same mark and condition is the direct, measurable consequence: they are not measuring the same
thing. **Do not treat REP2's 651 peaks as validated H3K27me3 sites, and do not average or pool
REP1/REP2 for a consensus call without addressing this first** — that is exactly what
`--min_reps_consensus 1` (this run's bounded choice) would otherwise let happen silently.

**Fingerprint plots** (`deeptools plotFingerprint`, per-sample SVG/PNG under
`results/bowtie2/merged_library/deeptools/plotfingerprint/`) were generated but not visually
inspected in this handoff — flagging that gap explicitly rather than asserting a shape I did not
look at.

## Bounded choices made
- **Aligner: `--aligner bowtie2`**, not the pipeline default (`bwa`) — reuses the bowtie2 index
  the prior atacseq run built and promoted to `$BIOINFO_REFS`, avoiding a second ~20min index
  build for this smoke test.
- **No `--narrow_peak`** — H3K27me3 is a broad mark; pipeline default (broad mode, cutoff 0.1) is
  correct as-is per `pipeline-selection.md` §4.7.
- **`--min_reps_consensus 1`** (pipeline default, not tightened) — 2 real biological replicates
  exist but depth is shallow for a smoke test; kept lenient rather than risk an empty consensus
  purely from depth, not from genuine disagreement between replicates.
- **Input, not IgG, as control** — this study has both; Input is the more standard MACS
  background model for chromatin-state marks like H3K27me3.
- **`--macs_gsize 2700000000`** plain decimal — `2.7e9` fails nf-schema's Number-type validation
  (confirmed pitfall, same as atacseq).

## Known gaps
- **Process-reliability issue, not a pipeline/config bug**: the first real attempt at this run
  died via SIGTERM when the delegated subagent's own turn ended while Nextflow was still running
  as its background child — a recurring failure mode in this session (also hit on scrnaseq).
  Tracked and being fixed separately (repo-level fix to `agents/bioinfo-tech.md`, not part of
  this run's own scope). This run's data is intact — resumed cleanly from cache, 0 failures.
- REP2's Input depth was not directly compared against its ChIP depth in this handoff — the
  §3.5 "Input ≥ ChIP depth for broad marks" check was only done for REP1.
- No IDR analysis (not appropriate for a broad mark per §3.5's own guidance) — the overlap-fraction
  check above is the one this doc says to use instead, and it was done.

## Next step for you
This run is solid evidence the pipeline mechanics work on this host (clean alignment, correct
control pairing, no crashes) — use it for that. It is not evidence of a reliable H3K27me3 profile
for this cell line: REP1's peaks carry a real, if modest, enrichment signal; REP2's do not look
distinguishable from background by fingerprint, and the two replicates share zero peaks. Whether
that is depth (both are shallow for ChIP-seq, REP1 especially), a REP2-specific library problem,
or a genuine difference between the two biological samples is not something this report resolves —
the mechanism (weak enrichment → mostly-background peak calls → no overlap with a real-signal
replicate) is established, the cause is not. If this mark matters for real analysis, the
recommendation is either deeper sequencing on both replicates before re-judging, or an appropriate
positive control (a well-characterized H3K27me3 antibody validation) to check whether REP2's
weak fingerprint is a ChIP failure specifically.
