# Run 20260806-chipseq-vsmc-h3k27me3-smoke — nf-core/chipseq -r 2.1.0 — COMPLETE WITH CAVEATS

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

**PASS WITH CAVEATS** — alignment, duplication and control design are clean; FRiP is low even
accounting for the broad-mark exemption, and this is the metric worth treating with real caution
rather than the point-source NSC/RSC numbers, which `qc-interpretation.md` §3.5 explicitly says
not to band for a broad mark like H3K27me3.

| Metric | REP1 | REP2 | Band (qc-interpretation.md §3.5) | Verdict |
|---|---|---|---|---|
| Duplication (Picard, ChIP) | 6.35% | 4.13% | no explicit band | Clean, reported |
| Duplication (Picard, Input) | 7.76% | 10.26% | no explicit band | Clean, reported |
| Peak count (broad, MACS3) | 193 | 651 | — (no band stated for broad marks) | Reported; REP1 noticeably lower than REP2 — see caveat |
| FRiP (broad histone) | 0.477% | 0.105% | TF band (≥0.05) explicitly **does not apply** to broad marks per §3.5; doc says judge by genome-coverage/input comparison instead | **Low even for a broad mark** — §3.5's own text ("≥0.05 typical, but genuinely lower for H3K27me3") still implies a rough expectation an order of magnitude above what's seen here; flagged as a real caveat, not scored pass/fail |
| NSC | 1.111 | 1.023 | TF band ≥1.10 pass — **explicitly not meaningful for broad marks** per §3.5 | Reported, not banded |
| RSC | 0.799 | 1.962 | TF band ≥1.0 pass — **explicitly not meaningful for broad marks** per §3.5 | Reported, not banded |
| Input present, matched per replicate | yes | yes | present ≥ ChIP depth for broad marks | REP1 Input 2.9M reads (~ChIP depth); REP2 Input depth not directly compared here — see Known gaps |

Thresholds applied: `skills/bioinfo-analyze/references/qc-interpretation.md` §3.5. The FRiP and
peak-count gap between REP1 (193 peaks, 0.477% FRiP) and REP2 (651 peaks, 0.105% FRiP) is itself
notable — REP2 has more peaks but *lower* FRiP, meaning REP2's called peaks capture proportionally
fewer of its reads than REP1's, despite REP2 having ~2.7× the raw read depth (8.4M vs 3.2M). This
pattern (more peaks, lower FRiP, more depth) is consistent with REP2 picking up more
background/diffuse signal rather than a cleaner enrichment — worth a closer look before trusting
REP2's peak set as strongly as REP1's, but this report does not resolve which replicate is "more
correct" biologically.

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
- Fingerprint plots generated but not inspected (see QC verdict) — worth a look before trusting
  the low-FRiP samples' enrichment quality.
- REP2's Input depth was not directly compared against its ChIP depth in this handoff — the
  §3.5 "Input ≥ ChIP depth for broad marks" check was only done qualitatively for REP1.
- No IDR / peak-overlap reproducibility check between REP1 and REP2 beyond what the pipeline's
  own consensus-peak step does at `--min_reps_consensus 1` — worth a dedicated look given the
  FRiP/peak-count divergence noted above.

## Next step for you
Given the low FRiP and the REP1/REP2 divergence, this dataset is usable to confirm the pipeline
mechanics work (it does — clean alignment, correct control pairing, no crashes) but I would not
treat either replicate's peak calls as strong evidence of real H3K27me3 enrichment without: (1)
actually looking at the fingerprint plots, and (2) checking whether the low FRiP is a depth
artifact (both samples are shallow for ChIP-seq) or reflects the biology/library prep. Your call
on which, not this report's.
