# Run 20260806-chipseq-vsmc-h3k27me3-smoke — nf-core/chipseq -r 2.1.0 — PIPELINE MECHANICS PASS, QC SIGNAL FAIL

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

**0 of 4 samples pass; 1 warn; 3 fail.** (Required verdict-line format,
`qc-interpretation.md` §7 — the narrative version below explains the mechanism; this line is the
formal tally a reader can act on without parsing prose.)

| Sample | Role | Deciding metric | Final verdict |
|---|---|---|---|
| VSMC_WT_Input_REP1 | Input control | Fingerprint AUC 0.238 (band: pass ≈0.5, fail if strongly bowed) | **FAIL** |
| VSMC_WT_Input_REP2 | Input control | Fingerprint AUC 0.270 (same band) | **FAIL** |
| VSMC_WT_H3K27me3_REP1 | ChIP | Mechanics clean, ChIP-vs-own-Input AUC gap points the right way, but the Input side of that comparison fails its own band (row above) — the comparison this sample's enrichment claim depends on is not valid | **WARN** — cannot be confirmed, not itself showing a failure signature |
| VSMC_WT_H3K27me3_REP2 | ChIP | ChIP AUC (0.261) nearly identical to its own Input's (0.270) — no enrichment shown independent of the Input-quality problem; 0% peak overlap with REP1 | **FAIL** |

**Pipeline mechanics: PASS** — alignment, duplication and control pairing ran cleanly, no crashes,
correct broad-mark settings. **QC signal: FAIL, at the control level, which undercuts everything
downstream of it.** This verdict has been revised twice on Codex review (PR #16), each time by
actually running a check that had been asserted or hedged instead of measured:

1. First version: `PASS WITH CAVEATS` while admitting the supporting checks were never run.
2. Second version, after running fingerprint AUC and peak-overlap: framed REP1 as showing "real
   enrichment" because its ChIP AUC sat well below its own Input's.
3. **This version**: that framing was still wrong. `qc-interpretation.md` §3.5's Fingerprint band
   requires the *Input* to be near-diagonal (AUC≈0.5) for a ChIP-vs-Input gap to mean anything —
   "input strongly bowed" is its own **fail**, independent of what the ChIP track does. Both
   Inputs here are strongly bowed (AUC 0.238, 0.270 — nowhere near 0.5). REP1's ChIP-vs-Input gap
   is real as a *number*, but it is being measured against a control that already fails the band
   on its own, so it cannot be read as clean evidence of real enrichment. Retracted that claim.

| Metric | REP1 | REP2 | Band (qc-interpretation.md §3.5) | Verdict |
|---|---|---|---|---|
| Duplication (Picard, ChIP) | 6.35% | 4.13% | no explicit band | Clean, reported |
| Duplication (Picard, Input) | 7.76% | 10.26% | no explicit band | Clean, reported |
| Peak count (broad, MACS3) | 193 | 651 | — (no band stated for broad marks) | Reported |
| FRiP (broad histone) | 0.477% | 0.105% | TF band (≥0.05) explicitly does not apply to broad marks per §3.5 | Low for both, not scored pass/fail on its own |
| NSC / RSC | 1.111 / 0.799 | 1.023 / 1.962 | explicitly not meaningful for broad marks per §3.5 | Reported, not banded |
| **Fingerprint AUC, Input** | 0.238 | 0.270 | pass = Input AUC ≈0.5 (near diagonal); **"input strongly bowed" is FAIL regardless of the ChIP track** | **FAIL, both** — neither control is clean enough to validate a ChIP-vs-Input comparison against |
| Fingerprint AUC, ChIP | 0.162 | 0.261 | (only meaningful once Input passes, which neither does here) | Gap vs. own Input exists (0.076 / 0.009) but is **not interpretable** as enrichment while the Input itself fails |
| **Replicate peak overlap (REP1 ∩ REP2)** | 0 / 193 REP1 peaks overlap a REP2 peak | 0 / 651 REP2 peaks overlap a REP1 peak | §3.5: "For broad marks use overlap fraction" (no numeric band restated, but 0% is far outside any reasonable reading of it) | **0% in both directions** — computed with `bedtools intersect -u` (cached `bedtools:2.30.0` container), cross-checked with a self-intersect control (REP1 vs REP1 correctly returns all 193) |
| Input present, matched per replicate | yes, 2.9M reads (~ChIP depth) | yes | present ≥ ChIP depth for broad marks | Present, but "present" is not the same as "clean" — see Fingerprint row above |

Thresholds applied: `skills/bioinfo-analyze/references/qc-interpretation.md` §3.5, computed
directly from `deepTools/plotFingerprint/*.qcmetrics.txt` and `bedtools intersect`, not eyeballed
from plots. Reading it together: this dataset does not establish real H3K27me3 enrichment for
*either* replicate — the controls themselves are too non-uniform to validate a ChIP-vs-Input
comparison, and independent of that problem, the two ChIP replicates share zero called peaks. A
bowed input typically means chromatin/sonication bias (per §3.5's own explanation of that band),
which would explain both findings at once: noisy fragmentation could produce non-uniform Input
coverage AND make peak calling unstable/irreproducible between replicates. That is a plausible
mechanism, not a confirmed one — this report does not resolve it. **Do not treat either
replicate's peaks as validated H3K27me3 sites, and do not average or pool REP1/REP2 for a
consensus call** — that is exactly what `--min_reps_consensus 1` (this run's bounded choice) would
otherwise let happen silently.

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
for this cell line: both Input controls are too non-uniform (strongly bowed fingerprint) to
validate a ChIP-vs-Input comparison against, and independent of that, REP1 and REP2's peak calls
share zero overlap. Whether the root cause is fragmentation/sonication quality (the mechanism
§3.5 names for a bowed Input), depth (both are shallow for ChIP-seq), a REP2-specific library
problem, or something else is not something this report resolves — the measurements are
established, the cause is not. If this mark matters for real analysis, the recommendation is
either deeper sequencing with attention to sonication/fragmentation QC before re-judging, or an appropriate
positive control (a well-characterized H3K27me3 antibody validation) to check whether REP2's
weak fingerprint is a ChIP failure specifically.
