# Run plan — 20260806-chipseq-vsmc-h3k27me3-smoke

## What / why

Smoke-test `nf-core/chipseq` — sixth of the nine stocked pipelines validated on this host, after
sarek, rnaseq, scrnaseq, atacseq, methylseq. Real public human ChIP-seq data with matched Input
control (not an nf-core test-profile synthetic subsample). Human, so the existing
`$BIOINFO_REFS/genomes/GRCh38` store is reused as-is.

## Data

**Study**: PRJNA980697 — "Prelamin A drives vascular calcification by reorganization of the
epigenetic landscape to promote inflammaging" (ChIP-Seq). Real published human ChIP-seq: vascular
smooth muscle cells (VSMC), WT vs prelamin-A, 3 biological replicates, marks H3K27me3/H3K9me3,
matched IgG and Input controls per replicate. Single-end, Illumina HiSeq 2500, 51 bp.

Slice pulled: **WT condition, biological replicates 1 and 2, H3K27me3 mark** (a broad repressive
histone mark — `--narrow_peak` intentionally NOT set, default broad mode with `--broad_cutoff 0.1`
used), with matched **Input** as the control (not IgG — this study has both; Input is the more
standard MACS control for chromatin-state/copy-number background).

| sample | replicate | role | ENA run | reads | length |
|---|---|---|---|---|---|
| VSMC_WT_H3K27me3 | 1 | ChIP | SRR24843734 | 3,160,603 | 51 bp |
| VSMC_WT_H3K27me3 | 2 | ChIP | SRR24843688 | 8,437,989 | 51 bp |
| VSMC_WT_Input | 1 | control | SRR24843726 | 7,013,129 | 51 bp |
| VSMC_WT_Input | 2 | control | SRR24843707 | 9,302,336 | 51 bp |

Downloaded to `/work/rawdata/20260806-chipseq-vsmc-h3k27me3-prep/` (ext4), 1.1 GB total gzip — well
under the ~10 GB no-approval threshold, inside the requested "hundreds of MB–1-2 GB" smoke budget.

**Pitfall found and worked around during selection**: ENA hosts two run accessions for several
samples in this study — one with 6 bp reads (a truncated/barcode-only deposit) and one with the
real 51 bp reads. Not distinguishable from `library_strategy`/`library_layout` metadata alone. The
first file downloaded (SRR24843727) turned out to be the 6 bp version on direct inspection and was
discarded; the matching 51 bp accession (SRR24843734) was used instead. Full detail and both
verification methods (md5 vs ENA `fastq_md5`, and direct `zcat`+`awk` read-count/length count vs
ENA `read_count`) in `/work/rawdata/20260806-chipseq-vsmc-h3k27me3-prep/SOURCE.md`. All four final
files: md5 match + read count match + uniform 51 bp confirmed.

## Pipeline

`nf-core/chipseq -r 2.1.0` (pin: `config/pipelines.tsv`). Schema re-derived this run (first
chipseq run on this host): `nextflow pull nf-core/chipseq -r 2.1.0`, `assets/schema_input.json`
read directly — required `sample`, `fastq_1`; `fastq_2` optional; `antibody` requires `control`;
`control` requires `antibody` + `control_replicate`. Matches pipeline-selection.md §4.7's note that
control rows are samples too — this samplesheet has 4 rows for 2 biological conditions (2 ChIP +
2 control), not 2.

`--help` confirms this revision's **default `--aligner` is `bwa`** (broad-peak mode is also the
default — `--narrow_peak` is opt-in, so no flag needed for H3K27me3).

## Compact `--genome` form — tested, NOT used (new finding this run)

Per instruction, tested empirically rather than assumed. `-stub-run` with `--genome GRCh38
--igenomes_ignore --aligner bowtie2`:

- **fasta / gtf / bowtie2_index / gene_bed DID resolve correctly** via the compact form — better
  than scrnaseq's total failure.
- **But it also auto-populates `bwa_index` and `star_index`** from `config/genomes.config`'s
  GRCh38 block (which declares those paths "for completeness" even though neither index is built
  for this FASTA — see genomes.config's own header comment). nf-schema's `exists: true`
  validation checks **every populated path param regardless of which aligner is actually
  selected**, so the run fails hard before any process starts:
  ```
  * --star_index: the file or directory '/refs/genomes/GRCh38/index/star' does not exist.
  * --bwa_index: the file or directory '/refs/genomes/GRCh38/index/bwa' does not exist.
  ```
- **blacklist is not populated by the compact form at all** — `genomes.config`'s GRCh38 block has
  no `blacklist` key, so it must always be passed explicitly regardless of form (same as atacseq).

**Decision: explicit `--fasta/--gtf/--bowtie2_index/--blacklist/--gene_bed` paths**, same
proven-safe pattern as the atacseq run. Re-verified via `-preview` (see below) — clean, no
execution, DAG resolves. This is a new, chipseq-specific pitfall (distinct from methylseq's and
scrnaseq's) worth documenting in `genomes.config`; addressed as a doc PR after this run (see
"Problems found" below).

## Preflight and validation, done this run

- `bash bin/preflight.sh <rundir> <est>` — see estimate below.
- `bash scripts/check-samplesheet.sh --deep --pipeline chipseq samplesheet.csv` → **PASS** (one
  expected WARN: repeated sample ids across replicate rows — intentional, biological replicates).
- `-stub-run` with the compact `--genome` form: **failed as designed** — caught the bwa/star
  validation trap before any real compute (see above).
- `-stub-run` with explicit paths: **failed**, but on a stub-run artifact, not a real problem —
  `GENOME_BLACKLIST_REGIONS` (a local module with no `stub:` block) ran its real script against a
  fake/empty `.fa.sizes` file produced by `CUSTOM_GETCHROMSIZES`'s stub. Confirmed by reading
  `modules/local/genome_blacklist_regions.nf` — no stub block present, so `-stub-run` falls back to
  the real script per Nextflow's documented behaviour.
- `-preview` with explicit paths: **clean pass**, full DAG resolves, no execution
  (`completed=0 failed=0`). Used as the final preflight gate in place of `-stub-run` for this
  pipeline, per the skill's "`-stub-run` (or `-preview`)" allowance.

## Reference store

- `--fasta /refs/genomes/GRCh38/fasta/GRCh38.fa`, `--gtf /refs/genomes/GRCh38/gtf/GRCh38.gtf.gz` —
  build-named alias paths, present.
- `--bowtie2_index /refs/genomes/GRCh38/index/bowtie2` — present, built by the prior atacseq run
  (`20260805-atacseq-gbr-lcl-smoke`), reused here at no extra build cost. **Bounded choice**:
  `--aligner bowtie2`, not this revision's default `bwa` — no GRCh38 (non-gatk) bwa index exists in
  the store (pipeline-selection.md §9 documented gap), and building one is unnecessary cost for a
  smoke test when a working bowtie2 index is already on disk.
- `--blacklist /refs/genomes/GRCh38/bed/blacklist.bed` — ENCODE hg38 v2, present (fetched during
  the atacseq run, PR #10, merged).
- `--gene_bed /refs/genomes/GRCh38/bed/genes.bed` — present, used for HOMER peak annotation context.
- `.dict`, STAR/salmon/bismark/bwameth indexes, GATK bundle, VEP/snpEff cache: absent, irrelevant
  to this pipeline.

## Parameters that matter here (bounded choices stated explicitly)

| param | value | why |
|---|---|---|
| `--aligner bowtie2` | not the pipeline default (`bwa`) | reuses the existing store index; no GRCh38 bwa index built |
| `--macs_gsize 2700000000` | plain decimal, NOT `2.7e9` | confirmed pitfall from atacseq/chipseq (pipeline-selection.md §4.6/§4.7) — nf-schema rejects scientific notation for this `Number`-typed param |
| (no `--narrow_peak`) | default broad mode, `--broad_cutoff 0.1` | H3K27me3 is a broad repressive mark |
| `--blacklist` ENCODE hg38 v2 | | filters ENCODE artefact regions |
| `--min_reps_consensus 1` | pipeline default, stated explicitly | with only 2 replicates on shallow real data (3.2M–9.3M reads/sample, well under the 30M reference figure), requiring 2/2 replicate agreement risked an empty or near-empty consensus set purely from depth, not biology. Chose the lenient default and will report the real per-replicate peak overlap in the QC verdict rather than force a stricter cutoff that could produce a misleadingly empty result |
| Input, not IgG, as control | | study has both; Input is the conventional MACS control for chromatin/copy-number background. IgG rows exist in ENA for this study but were not pulled — noted as available if the IgG comparison matters later |
| 2 ChIP + 2 control rows (real biological replicates, not just technical) | | exercises the pipeline's actual replicate-merge and consensus-peak logic, not just a single-sample smoke path |

## Estimate

Reference (`estimates.md` §1): 30 M reads/ChIP-sample, 1–2.5 h/sample serialised, 25–55 GB work-dir
peak/sample, 4–10 GB published/sample, `C_eff ≈ 1.8–2.2` for chipseq.

Our 4 samples are far shallower than the 30 M-read reference (3.2M/8.4M ChIP, 7.0M/9.3M input —
average ~28 % of the reference depth), so per-sample time scales down substantially, though QC/
peak-calling steps have real fixed overhead that does not shrink linearly. Estimated 0.3–0.8 h
serialised per sample.

```
T_total ≈ T_oneoff + (4 × 0.3–0.8 h) / 1.8–2.2 × 1.2
        ≈ 0.2–0.4 h (containers, mostly cached from prior atacseq/rnaseq runs)
          + 0.65–2.1 h
        ≈ 0.9 – 2.5 h
```

No one-off index build needed (bowtie2 index already in the store). Say **1–3 h**, most likely
~1.5 h.

**Disk**: work-dir peak ≈ 5–8× the 1.1 GB input ≈ 5.5–9 GB, plus mostly-cached containers, plus a
few GB published results (much smaller than the 4–10 GB/sample reference given the shallow depth).
Call it **15–25 GB** total against **601 GB free** on `/work` (ext4) — no disk risk at all; far
above the 1.5× guardrail.

Under the 24 h approval line by a wide margin; proceeding per this run's explicit instruction to
execute the smoke test to completion.

## Environment

- `NXF_SYNTAX_PARSER=v1` required (same reason as every prior pipeline on this host — nf-core
  template `check_max()` and this repo's `local.config` mix `def` with config blocks, which the v2
  parser rejects).
- Launch dir and work dir both on ext4: `$BIOINFO_WORK/nxf/20260806-chipseq-vsmc-h3k27me3-smoke/`.
- `-profile docker`, Docker engine confirmed live (`docker info` succeeded, 90 images cached from
  prior runs).

## Problems found this run (repo-side)

1. **`genomes.config`'s GRCh38 block lacks a `blacklist` key** — not itself wrong (the file's
   header explicitly says the map only needs to declare `[!]` paths that pipelines can pick up
   later), but worth a documentation note next to the atacseq/chipseq sections since both
   pipelines need `--blacklist` and neither gets it from the compact form.
2. **chipseq's compact `--genome` form is unsafe whenever `bwa`/`star` indexes are declared-but-
   absent in `genomes.config`**, regardless of which `--aligner` is actually selected — worth a
   documented pitfall (same style as scrnaseq's §3a note) so the next chipseq/cutandrun run doesn't
   rediscover it. Will add this as a genomes.config section and a pipeline-selection.md §4.7 note,
   PR'd and Codex-reviewed after the run completes.
