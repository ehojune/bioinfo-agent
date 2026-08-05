# Run 20260805-methylseq-sle-rrbs-smoke — nf-core/methylseq -r 3.0.0 — COMPLETE WITH CAVEATS

**Inputs**       2 samples, bulk RRBS (MspI-digested), human, PRJNA484966 ("DNA methylation
profiles of B cell subsets from healthy and SLE subjects") — real public data, not an nf-core
test-profile subsample. HC660_SM (SRR7656851, healthy control) and SLE497_SM (SRR7657228, SLE
patient), same cell type (switched-memory B cells), ~3.9–4.0M read pairs each, 396 MB total.
Samplesheet: `runs/20260805-methylseq-sle-rrbs-smoke/samplesheet.csv`
**Reference**    GRCh38 (UCSC hg38), explicit `--fasta` (build-named alias path, not `--genome
GRCh38` — same reason as scrnaseq/atacseq on this host). Bismark index **built this run**
(`--save_reference`), not yet promoted to `$BIOINFO_REFS`
**Command**      `runs/20260805-methylseq-sle-rrbs-smoke/cmd.sh` (`--aligner bismark --rrbs`)
**Wall clock**   1h44m30s (23:38:37–01:23:07), dominated by the Bismark genome-preparation step
for GRCh38 (~1h9m of the total)
**Peak disk**    results 20 GB + work 17 GB = 37 GB combined (bismark index is the bulk of both)
**Results**      `/work/nxf/20260805-methylseq-sle-rrbs-smoke/results/` (20 GB)
**MultiQC**      `/work/nxf/20260805-methylseq-sle-rrbs-smoke/results/multiqc/bismark/multiqc_report.html`
**Work dir**     `/work/nxf/20260805-methylseq-sle-rrbs-smoke/work/` (17 GB) — RETAINED, do not
delete, `-resume` depends on it

## QC verdict

**PASS WITH CAVEATS** — mapping and correct RRBS handling (no deduplication ran, as required) are
clean; conversion-efficiency and global-methylation numbers read low against `qc-interpretation.md`
§3.3's bands, but those bands are written for WGBS and this is RRBS, whose CpG-island-enrichment
bias plausibly explains part of the gap on its own — with no lambda spike-in in this library, the
weaker %mCHH proxy can't fully separate "real conversion issue" from "RRBS locus-selection bias."

| Metric | HC660_SM | SLE497_SM | Band (qc-interpretation.md §3.3) | Verdict |
|---|---|---|---|---|
| Mapping efficiency | 71.93% | 70.85% | WGBS bismark 55–80% (no RRBS-specific band stated) | Falls inside the WGBS band, but this is RRBS — reported, not scored against a matching band |
| Conversion proxy (%mCHH, no spike-in) | 2.334% | 2.735% | ≤1.0% pass / 1.0–2.0% warn / >2.0% fail | **FAIL** both — but this is the weaker, no-spike-in proxy on a library with no lambda control; see caveat below |
| Global mCpG | 59.02% | 63.2% | 70–82% pass / 65–70% or 82–88% warn / further fail | **FAIL** both by the stated (WGBS) band — RRBS's CpG-island enrichment selects for typically-hypomethylated regions, which pulls this number down independent of conversion quality; the two effects are not separable from this data alone |
| Duplication (dedup) | not run | not run | RRBS must NOT be deduplicated | **Correct** — `--rrbs` correctly skipped `deduplicate_bismark`, confirmed by the empty "Duplicate Reads (removed)" column in `bismark_summary_report.txt` for both samples |
| Read length | 51 bp uniform | 51 bp uniform | — | Reported, matches SOURCE.md's intake verification |
| M-bias, CHH context, R1 pos 1 | 5.70% | 8.21% | flat pass / edge ≤10bp warn / >20bp fail | **WARN, both** — inspected `bismark/methylation_calls/mbias/*.M-bias.txt` directly (not deferred). Elevated apparent methylation at R1 position 1 only (~2–3× the ~2.7% baseline both samples settle to by position 4), R2 flat from position 1 in both samples. Matches the classic RRBS end-repair fill-in artifact (Bismark's own docs recommend 5' clipping on R1 for exactly this), confined to ≤2bp — inside the warn band, not the fail band |
| CpGs at ≥10× (per sample) | 4,414 | 2,025 | — (no pass/warn/fail band; report the absolute number) | Computed directly from `methylation_coverage/*.bismark.cov.gz` (coverage = methylated + unmethylated count per CpG) |
| **CpGs at ≥10× in ALL samples** | **1,242** | | site-level DMC analysis needs this to be most of the CpG universe of interest | Computed as the intersection of both samples' ≥10× CpG sets (cross-checked with two independent methods, `comm` and `join`, same result). This is the actual analysable denominator for any cross-sample comparison on this data — **too few for genome-wide DMC/tiled work**; ~4.7M CpG positions have ≥1× coverage per sample (RRBS's characteristic sharp coverage drop-off away from MspI fragment ends), so 1,242 at ≥10× is a depth statement about this smoke-scale run, not a library-quality defect |

**This M-bias finding directly bears on the FAIL rows above**: the aggregate %mCHH conversion proxy sums across all 51 positions, so ~1–2bp of artificially elevated signal at the very start of R1 inflates the whole-read average by a small, bounded amount — it does not by itself explain a swing from ≤1% (pass) to >2.7% (fail), but it is a real, non-conversion contributor to that number, on top of the RRBS-band-mismatch caveat already noted. Re-running with `--clip_r1 2` (or similar) and recomputing %mCHH on the clipped data would separate the two effects; not done in this run.

Thresholds applied: `skills/bioinfo-analyze/references/qc-interpretation.md` §3.3. Note explicit in
that file: "real non-CpG methylation exists in neurons and ES cells" as a caveat on the %mCHH
proxy — B cells are not one of those tissues, so that specific exception does not apply here, but
the RRBS-vs-WGBS band mismatch stands on its own as a reason not to read the two FAIL rows as
proven conversion failure.

**HC660_SM** and **SLE497_SM**: both show %mCHH (2.33%, 2.74%) and global mCpG (59.0%, 63.2%)
outside the WGBS-calibrated bands, in the same direction for both samples and both metrics —
consistent with either (a) a genuine, mild bisulfite conversion shortfall common to both libraries,
or (b) RRBS's inherent CpG-island enrichment lowering the CpG-methylation average relative to a
genome-wide WGBS number, which the %mCHH proxy cannot rule out without a spike-in. Distinguishing
these needs a lambda-spike-in run or RRBS-specific reference bands neither of which this repo has
yet — reported as an open question, not resolved here.

## Bounded choices made
- **Aligner: `--aligner bismark`**, not `bwameth` — appropriate per `pipeline-selection.md` §4.5
  ("bwameth for human WGS-scale; bismark for small/RRBS"), and this is RRBS.
- **`--rrbs`** — enables MspI-aware trimming and disables deduplication (required for RRBS;
  verified correct in the QC table above).
- **Dataset**: two independent samples (different subjects, one healthy/one SLE) — **not**
  biological replicates of one condition; no differential methylation comparison is implied.
- **`--save_reference`** — bismark index built this run, lands in `results/bismark/reference_genome/`,
  not auto-promoted to `$BIOINFO_REFS` (manifest still `[!] build`; promotion is a follow-up action,
  same convention as every prior run this session).
- **No lambda/pUC19 spike-in** — this library doesn't have one; conversion efficiency is read from
  the weaker %mCHH proxy, stated as a known gap rather than silently substituted.

## Known gaps
- **Repo-level findings from this run, fixed and merged**: `genomes.config` was missing methylseq's
  own key names (`bismark`/`bwameth`/`fasta_index` — methylseq's `main.nf` reads these exact names,
  not the `bismark_index`/`fasta_fai` spellings the file had) — PR #13, merged. While fixing that,
  found `fasta_index` pointed at the canonical `genome.fa.fai` while `params.fasta` for GRCh38 is
  the `GRCh38.fa` alias (PR #4) — methylseq's bwameth/MethylDackel path needs the FAI discoverable
  under the *same* basename as the FASTA it's given, so `04-refs.sh`'s alias mechanism was extended
  to cover `.fai` files too, same PR. **Caveat documented inline in genomes.config**: empirically,
  under `--igenomes_ignore`, these three new keys (bismark/bwameth/fasta_index) do not appear to
  actually reach `getGenomeAttribute()` — a compact `--genome GRCh38 --igenomes_ignore` stub-run
  still ran `BISMARK_GENOMEPREPARATION` rather than treating the (still-absent) index as prebuilt.
  Root cause not isolated; use the explicit `--fasta` form (as this run did — `--bismark_index`
  specifically was NOT exercised, since no promoted index existed yet; `cmd.sh` passes `--fasta`
  and lets `--save_reference` build the index fresh) until that's resolved.
- Bismark index for GRCh38 not promoted from `results/bismark/reference_genome/` into
  `$BIOINFO_REFS` — a second methylseq run would rebuild it (~1h9m) unless promoted by hand first.
- No RRBS-specific QC bands exist in `qc-interpretation.md` §3.3 (only WGBS mapping/global-mCpG
  bands are stated) — the mismatch noted throughout this verdict is a documentation gap worth
  closing if RRBS becomes a recurring workload on this host.

## Next step for you
M-bias is inspected above (WARN, R1 position 1 only, both samples) — it's a real but small,
bounded contributor to the elevated %mCHH number, not the whole explanation. If bisulfite
conversion quality matters for downstream work on this protocol: (1) a `--clip_r1 2`-and-recompute
pass would isolate how much of the %mCHH gap the edge artifact alone accounts for, and (2) a
spike-in-controlled run is the only way to get a real conversion-efficiency number rather than the
weaker CHH proxy. Neither was run here — this run's scope was the mechanics smoke test.
