# Run plan — 20260805-methylseq-sle-rrbs-smoke

## What / why

Smoke-test `nf-core/methylseq` (fifth of the nine stocked pipelines validated on this host, after
sarek, rnaseq, scrnaseq, atacseq). Real public bulk RRBS data, small on purpose, human, so the
existing `$BIOINFO_REFS/genomes/GRCh38` store is reused for the FASTA/GTF; the bismark index is
not built yet and this run builds it.

## Data

**Study**: PRJNA484966 — "DNA methylation profiles of B cell subsets from healthy and SLE
subjects" (RRBS-seq, MspI-digested, human). Real published bulk RRBS, not an nf-core test-profile
synthetic subsample. Selected via ENA portal API search (`library_strategy="Bisulfite-Seq" AND
library_selection="Reduced Representation" AND tax_eq(9606)`), sorted by total `fastq_bytes`
ascending, filtered to `PAIRED` layout, and to runs whose `sample_title` carries an explicit
`[RRBS-seq]` tag from a named GEO study (excluding the smaller/unlabelled scRRBS single-cell runs
that otherwise dominate the low end of that size-sorted list — scRRBS is a distinct, low-input
protocol, not the bulk assay this smoke test targets).

Two ENA runs picked as two independent samples, same cell type (switched-memory B cells, `.SM`
suffix), one healthy control and one SLE patient — **not** biological replication of one condition
(see "Bounded choices"):

| sample id | ENA run | sample_title | read pairs | fastq_bytes (R1;R2) |
|---|---|---|---|---|
| HC660_SM  | SRR7656851 | HC660.SM [RRBS-seq]  | 3,860,502 | 103,181,898;101,196,740 |
| SLE497_SM | SRR7657228 | SLE497.SM [RRBS-seq] | 4,004,560 | 105,244,696;107,054,706 |

Downloaded to `/work/rawdata/20260805-methylseq-sle-rrbs-prep/` (ext4), 396 MB total across 4
files — well under the ~10 GB no-approval download threshold. Verified this run, read-only: md5
against ENA's `fastq_md5` (exact match, all 4 files), read count by direct `zcat | wc -l` count
(matches ENA `read_count`/2 exactly for both mates, both samples), R1/R2 mate-pair identity from
shared instrument-coordinate read IDs, uniform 51 bp read length. Full detail:
`/work/rawdata/20260805-methylseq-sle-rrbs-prep/SOURCE.md`.

No lambda/pUC19 spike-in control is present in this library (standard human RRBS, not a
conversion-QC-spiked prep) — bisulfite conversion efficiency will be read from the non-CpG
methylation proxy (`%mCHH`), not a spike-in alignment. Noted as a known gap for the QC verdict,
not something to be silently substituted for.

## Pipeline

`nf-core/methylseq -r 3.0.0` (pin: `config/pipelines.tsv`, flagged `schema_checked=no` — "3.0 is a
template rewrite from 2.x, re-derive columns"). Schema re-derived this run (first methylseq run on
this host): `nextflow pull nf-core/methylseq -r 3.0.0`, `assets/schema_input.json` read directly —
required columns `sample, fastq_1` (`fastq_2`, `genome` optional). `--help --show_hidden` confirms
this revision's default `--aligner` is `bismark` (not `bwameth`), and that `--rrbs` exists as a
documented flag. `pipelines.tsv` row updated to `schema_checked=2026-08-05` as part of this plan
(committed alongside the other repo fixes below).

## Aligner choice

`--aligner bismark` — the pipeline's own default at this revision, and the documented choice for
small/RRBS data (`pipeline-selection.md` §4.5: "bismark for small/RRBS" vs "bwameth for human
WGS-scale"). At ~4M read pairs/sample this is nowhere near the 30x-WGBS scale where bismark's
four-alignment-instance cost becomes punishing; bwameth's speed advantage would not be worth
losing bismark's more conventional RRBS-analysis output shape. `--rrbs` is also set: MspI-aware
trimming, and — confirmed by reading `workflows/methylseq/main.nf:106,122`
(`params.skip_deduplication || params.rrbs`) — deduplication is automatically disabled, which is
required correctness for RRBS (fixed MspI cut sites make apparent duplicates real molecules, not
PCR artefacts).

## Reference store

- **FASTA**: explicit `--fasta /refs/genomes/GRCh38/fasta/GRCh38.fa`, NOT the compact
  `--genome GRCh38` form. Investigated this run:
  `nextflow -c local.config -c genomes.config config nf-core/methylseq -r 3.0.0 -profile docker -flat`
  shows methylseq 3.0.0's own `conf/igenomes.config` defines
  `params.genomes.GRCh38.{bismark, bismark_hisat2, bwameth, fasta_index, bed12, blacklist,
  mito_name, macs_gsize}` as AWS S3 igenomes URLs — and this repo's `genomes.config` GRCh38 block
  never declared those *exact* key names (it has `bismark_index`/`fasta_fai` instead, and no
  `bwameth` key at all). Reading `subworkflows/local/utils_nfcore_methylseq_pipeline/main.nf:176`
  confirms `getGenomeAttribute()` does a `containsKey` check and returns `null` (not an error) on
  a missing key, so this is not fatal — `--fasta` itself resolves correctly either way because
  that key name *does* match — but a future `--genome GRCh38` compact-form run would silently fail
  to discover a promoted bismark/bwameth index and rebuild it every time. This is a real, if minor,
  latent gap in `genomes.config`; fixed this run (see "Repo fixes" below) rather than routing
  around it silently. `--fasta` explicit form is used for the actual launch regardless, matching
  the proven-working pattern from the atacseq and scrnaseq runs on this host.
- **Bismark index**: `genomes/GRCh38/index/bismark/` does **not exist yet** (confirmed via
  `bootstrap/04-refs.sh --dry-run`: `NOT BUILT`). `--save_reference` builds it this run
  (`bismark_genome_preparation`, one-off, ~1.5–3 h, ~8–16 GB RAM, ~10–14 GB disk —
  `estimates.md` §109). It lands in this run's own `results/reference_genome/`; promotion into
  the shared store is done after a successful run (same convention as the atacseq bowtie2 index).
- `.dict`, STAR/salmon/bowtie2 indexes, GATK bundle, VEP/snpEff cache: all still absent, all
  irrelevant to this pipeline — noted only for completeness, not blocking.

## Parameters that matter here (all bounded choices, stated explicitly)

| param | value | why |
|---|---|---|
| `--aligner bismark` | pipeline default, and documented RRBS choice | see "Aligner choice" above |
| `--rrbs` | required for this library type | MspI-aware trimming + auto-disables dedup (correctness, not a shortcut) |
| `--save_reference` | first run | bismark index absent; save for reuse |
| 2 samples, HC vs SLE, no replicates | | this is a smoke test of the pipeline mechanics, not a study — do not read a health-status comparison out of n=1 vs n=1 |
| no spike-in conversion control | inherent to the source library | conversion efficiency assessed via %mCHH proxy, not a lambda alignment (`qc-interpretation.md` §3.3) |

## Estimate

**One-off** (nothing built yet on this host for methylseq):

| item | time | disk |
|---|---|---|
| bismark index, GRCh38 (bowtie2, two converted genomes) | 1.5 – 3 h | ~10 – 14 GB |
| container pulls (methylseq-specific: bismark, trim-galore, qualimap, preseq, multiqc — most core utility images already cached from 4 prior pipeline runs) | 0.15 – 0.4 h | 2 – 4 GB |
| stub run | 0.05 – 0.1 h | <1 GB |
| **subtotal** | **1.7 – 3.5 h** | **12 – 19 GB** |

**Per-sample** (~4M PE51 pairs each — ~13% of the `estimates.md` RRBS reference row's read count
at a shorter read length, so alignment/extraction time scales down, but FastQC/TrimGalore/
Qualimap/Preseq have largely fixed per-file overhead at this scale): 20–40 min/sample serialized.

```
T_total ~= T_oneoff + (N x T_serial_per_sample)/C_eff x 1.2
        ~= 1.7-3.5 h + (2 x 0.33-0.67 h)/1.5 x 1.2
        ~= 1.7-3.5 h + 0.5-1.1 h
        ~= 2.2-4.6 h
```

`C_eff ~= 1.5`, same reasoning as the atacseq run: with only 2 tiny samples the process_high
steps (bismark align, genome prep) still largely serialize on the 18 cpu/40 GB pool.

**Say the number out loud: roughly 2–5 hours, most likely ~3 h, dominated by the one-off bismark
index build (1.5–3 h of that alone). Well under the 24 h approval line.**

**Disk**: rough subtotal ~= 12-19 GB (index) + 2 samples x 3-6 GB work + 1-2 GB published results
~= 20-33 GB; x1.5 guardrail ~= 30-50 GB. Against 640 GB free on the ext4 root — not a binding
constraint. `bin/preflight.sh` invoked with `est_work_gb=35`.

## Repo fixes made / to be made this run

Two real gaps found so far, both to be fixed on a branch + PR, not routed around silently:

1. `config/genomes.config` GRCh38 block lacks the exact key names methylseq's
   `getGenomeAttribute()` reads (`bismark`, `bismark_hisat2`, `bwameth`, `fasta_index`) — it only
   has `bismark_index`/`fasta_fai`. Harmless for this run (explicit `--fasta`/`--save_reference`
   used throughout) but would silently defeat index reuse via the compact `--genome` form on a
   future methylseq run. Fix: add the missing key aliases pointing at the same paths.
2. `config/pipelines.tsv` methylseq row: `schema_checked` flips from `no` to today's date now
   that the schema has actually been read against the live 3.0.0 clone.

Any further issues found during the stub run or the real run are appended below, addendum-style,
matching the convention of the prior four pipeline runs on this host.

## What happens after

- `-stub-run` first; a stub failure is treated as a real failure.
- Real run launched from `$NXFDIR` (ext4), foreground, logged to
  `$NXFDIR/nextflow.stdout.log` and `$NXFDIR/.nextflow.log`, under `tmux` per
  `references/runbook.md` section 5 (no `nohup`, no backgrounding of the `nextflow` process
  itself).
- QC verdict against `qc-interpretation.md` §3.3 (conversion proxy, M-bias, mapping efficiency,
  duplication — expected near-zero since `--rrbs` disables it, mean CpG coverage).
- Bismark index promotion to the shared store, called out in the handoff as a followed-through
  step, not silently done.
