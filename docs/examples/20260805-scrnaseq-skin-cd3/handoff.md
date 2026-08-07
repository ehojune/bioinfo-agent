# Run 20260805-scrnaseq-skin-cd3 — nf-core/scrnaseq -r 2.7.1 — COMPLETE WITH CAVEATS

**Inputs**       1 sample, single 10x Chromium 3' v3 lane, SRR21657609 (ENA/SRA), 3,242,030 read pairs (~150 MB gz), samplesheet: `runs/20260805-scrnaseq-skin-cd3/samplesheet.csv`
**Reference**    GRCh38 (UCSC hg38 + GENCODE v50) via explicit `--fasta`/`--gtf` (build-named alias paths) — **not** the compact `--genome GRCh38` form, see Known gaps
**Command**      `runs/20260805-scrnaseq-skin-cd3/cmd.sh` (aligner STARsolo, `--protocol 10XV3`, `--save_reference`)
**Wall clock**   final successful invocation 21m3s (18:32:00–18:53:03); ~4h across the full debugging trail — dominated by an aborted first attempt (STAR_ALIGN OOM, see Known gaps) and the STAR index build itself
**Peak disk**    results 35 GB + work 85 GB = 120 GB combined (STAR index for GRCh38 is the bulk of both — `--save_reference` counts it twice until cleanup)
**Cores/RAM used** STAR_GENOMEGENERATE peaked at 37.9 GB RSS (38 GB budget); STAR_ALIGN peaked under its new 38 GB budget (was OOM-killed at the old 34 GB — see Known gaps)
**Results**      `/work/nxf/20260805-scrnaseq-skin-cd3/results/` (35 GB)
**MultiQC**      `/work/nxf/20260805-scrnaseq-skin-cd3/results/multiqc/multiqc_report.html`
**Work dir**     `/work/nxf/20260805-scrnaseq-skin-cd3/work/` (85 GB) — RETAINED, do not delete, `-resume` depends on it

## QC verdict
**PASS WITH CAVEATS** — barcode/mapping mechanics are clean; per-cell depth metrics read low
against `qc-interpretation.md` §3.6's bands because this is a deliberately shallow smoke-test
subsample (3.24M read pairs total), not a full-depth 10x run — a depth statement, not a defect.

| Metric | Value | Band (source: qc-interpretation.md §3.6) | Verdict |
|---|---|---|---|
| Reads with valid barcodes | 98.30% | — (no band; sanity check) | Clean |
| Mapped to genome (unique+multi / unique) | 94.91% / 84.40% | — | Clean |
| Mapped to gene (unique) | 45.94% | — (no explicit band) | Reported, not diagnostic here |
| Estimated cells | 872 | 0.6–1.4× expected | **N/A** — no `--expected_cells` was set (single smoke-test sample, no prior estimate); nothing to compare against |
| Median genes/cell | 514 | PBMC ≥1200 / solid tissue ≥800 / nuclei ≥500 | **WARN** vs PBMC/solid-tissue bands, borderline-pass vs nuclei band — mechanism: mean 1570 reads/cell is far below a real 10x run's typical 20–50k reads/cell target; this is a depth ceiling, not a cell-quality problem |
| Median UMI/cell | 1136 | ≥3000 (cells) / ≥1000 (nuclei) | Same depth-limited pattern — clears the nuclei band, well under the cells band |
| Fraction reads in cells | 91.95% | ≥70% pass | **PASS** — cell/empty-droplet separation is clean despite the shallow depth |
| Sequencing saturation | 23.72% | ≥50% pass / 30–50% warn / <30% fail | Numerically in the fail band, but qc-interpretation.md is explicit that low saturation is a depth statement, not a quality defect — more sequencing on this same library would recover more genes |
| Total genes detected | 16,228 | — | Reported for reference |

Thresholds applied: `skills/bioinfo-analyze/references/qc-interpretation.md` §3.6 (droplet
scRNA-seq bands, stated as working bands not a published standard). No differential/biological
interpretation included — mechanics and depth only, per this report's scope.

## Bounded choices made
- **Aligner: `--aligner star` (STARsolo)**, not the pipeline's own default (`alevin`) — matches
  the aligner family already validated on this host (rnaseq runs) and produces the fuller
  STARsolo per-cell QC this repo's bands are written against. `--aligner alevin` would have
  been lighter (no STAR index) — noted as the undo path in `plan.md`.
- **`--protocol 10XV3`** stated explicitly, confirmed from R1 length (28bp = 16bp CB + 12bp UMI)
  in the data-prep record (`/work/rawdata/20260804-scrnaseq-skin-cd3-prep/SOURCE.md`), not left
  to `--protocol auto`.
- **`--star_feature Gene`** (pipeline default) — standard gene-level counts, not
  `GeneFull`/pre-mRNA or `Velocyto`.
- **`--save_reference`** — STAR index built this run is reusable, lands in this run's own
  `results/star/genome_generate/`, not auto-promoted to `$BIOINFO_REFS` (manifest still marks
  it `[!] build`; promotion is a follow-up action, same convention as the rnaseq runs).
- **No `--expected_cells`** — single smoke-test sample, no prior estimate of true cell count.

## Known gaps
- **Repo-level finding, fixed this run**: `nf-core/scrnaseq -r 2.7.1`'s compact `--genome <key>`
  form does not resolve `--fasta`/`--gtf` — `getGenomeAttribute()` returns nothing even though
  `genomes.config`'s `params.genomes.GRCh38.fasta`/`.gtf` are set and the identical mechanism
  works for `nf-core/rnaseq -r 3.18.0` on this host. Root cause not fully isolated (leading
  suspect: scrnaseq 2.7.1 pins the older `nf-validation@1.1.4` plugin rather than the
  `nf-schema` plugin rnaseq 3.18 uses). Worked around with explicit `--fasta`/`--gtf` pointed at
  the same build-named alias paths. A `config/genomes.config` section documenting this (section
  3a, explicit-form-only guidance for scrnaseq) is proposed in PR #8 — **open, not yet merged**
  as of this handoff. Until it merges, `genomes.config` does not yet warn a future scrnaseq run
  away from the compact `--genome <key>` form; this run's `cmd.sh`/`plan.md` are the only record
  of the workaround in the meantime.
- **Real OOM found and fixed this run**: `local.config`'s `withName: '.*STAR_ALIGN.*'` selector
  matches both bulk `nf-core/rnaseq`'s STAR_ALIGN (single-pass, fine at 34 GB, proven across
  three rnaseq runs on this host) and `nf-core/scrnaseq`'s `STARSOLO:STAR_ALIGN` (two-pass +
  CB/UMI solo processing, confirmed OOM-killed at 34 GB — kernel log showed the container
  cgroup killing STAR at anon-rss 35.46 GB). Raised to 38 GB (same constant already used for
  `process_high_memory`/`STAR_GENOMEGENERATE`, consistent with this file's existing "whole
  pool, one task at a time" design for STAR). Fix verified by a clean re-run: STAR_ALIGN
  completed within the new budget, 0 failures. PR pending (see below).
- **Operational gap, not a repo bug**: the first two attempts at this run's real execution were
  killed mid-flight — once when a delegated subagent ended its own turn while a background
  monitor watched the Nextflow process (the process died with it, exit via SIGTERM), once by
  the genuine OOM above. Neither is visible from the pipeline or reference-store code; noted
  here only because it cost real wall-clock time on this run.
- STAR index for GRCh38 (`$BIOINFO_REFS/genomes/GRCh38/index/star`) is still not promoted from
  this run's `results/star/genome_generate/` into the shared reference store — a second
  scrnaseq or rnaseq run against GRCh38's STAR index would rebuild it (~40 min) unless promoted
  by hand first.

## Next step for you
Open the MultiQC report and the STARsolo `Summary.csv` (paths above) if you want the full
per-metric detail. The depth-limited cell metrics (median genes/UMI per cell, saturation) are
expected for this pilot-scale subsample and are not evidence of a library or pipeline problem —
if a real experiment is planned on this protocol, budget for standard 10x depth (20–50k
reads/cell) rather than this run's ~1.6k reads/cell. `star/mtx_conversions/` has the
`.h5ad`/Seurat objects ready for downstream analysis (not run here, out of scope).
