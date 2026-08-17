# Run 20260818-viralrecon-sample01-realsample — nf-core/viralrecon -r 3.0.0 — COMPLETE

**Inputs**       1 sample, illumina amplicon PE, samplesheet: `runs/20260818-viralrecon-sample01-realsample/samplesheet.csv`
**Reference**    SARS-CoV-2 MN908947.3 via `$BIOINFO_REFS` (explicit `--fasta`/`--gff`/`--primer_bed`,
                 ARTIC V3; built this run: pangolin/nextclade/freyja DBs pre-fetched, see plan.md)
**Command**      `runs/20260818-viralrecon-sample01-realsample/cmd.sh`
**Wall clock**   3m46s        **Peak disk**  356 MB (work) + 23 MB (results)
**Cores/RAM used** pool-clamped to 18 cpu / 40 GB (task never approached the ceiling)
**Results**      `/work/nxf/20260818-viralrecon-sample01-realsample/results` (23 MB)
**MultiQC**      `/work/nxf/20260818-viralrecon-sample01-realsample/results/multiqc/multiqc_report.html`
**Work dir**     `/work/nxf/20260818-viralrecon-sample01-realsample/work` — RETAINED, do not delete

## QC verdict
FAIL — consensus completeness is 1.23% against a typical amplicon-consensus threshold of
≥90%; the pipeline ran and reported correctly, the result itself is a genuine low-viral-titer
finding, not a run failure.

| sample | reads mapped (of raw) | mean depth | consensus completeness | variants | Pangolin | Nextclade | verdict |
|---|---|---|---|---|---|---|---|
| SAMPLE_01 | 23,644 / 2,028,184 (1.2%) | 74.1x (mean; severely uneven — see below) | 1.23% (29,535/29,903 N) | 2 (iVar) | `Unassigned` (qc_status=fail, note=Ambiguous_content:0.99) | `21L (BA.2)` (qc.overallStatus=bad, coverage=0.0123) | FAIL |

Thresholds applied: consensus completeness ≥90% = PASS, <50% = FAIL (my default, no
pipeline-stated or user-stated threshold exists for this metric). Mean depth alone is
misleading here — mosdepth's per-amplicon `coverage.tsv` shows most 200bp windows at 0x
coverage and a handful up to 9,894x, i.e. severe amplicon dropout masked by the summary mean;
always check the per-amplicon table, not just the genome-wide summary, for an amplicon
protocol.

Samples flagged: SAMPLE_01 — consensus completeness = 1.23% vs 90% threshold. Not excluded;
that is your call. The underlying cause (only ~1.2% of reads mapping to the viral genome after
Kraken2 human-host depletion — this sample's actual viral titer relative to host background)
is a measured fact about this sample, reported as such; no claim is made about why.

## Bounded choices I made
- `--skip_assembly true` — de novo assembly branch out of scope this procurement. Undo: drop
  the flag (adds SPAdes+Unicycler+minia+BLAST+ABACAS+QUAST+Bandage+PlasmidID).
- `--fasta`/`--gff`/`--primer_bed` explicit `$BIOINFO_REFS` paths instead of `--genome`
  shorthand (avoids a remote nf-core/configs dependency). Undo: `--genome MN908947.3
  --primer_set artic --primer_set_version 3` with `--custom_config_base` pointed at a configs
  mirror, or accept the remote fetch if `raw.githubusercontent.com` is reachable.
- `--pango_database`/`--nextclade_dataset`/`--freyja_barcodes`/`--freyja_lineages` pinned to
  pre-fetched local copies instead of the pipeline's runtime auto-fetch/auto-update, because of
  three real environment findings (GitHub releases-API empty-list bug for pangolin, container-
  local TLS-proxy interception for nextclade, `raw.githubusercontent.com` rate-limiting for
  freyja) — see `pipeline-selection.md` §4.18. Not a scope reduction; all three tools still run.
  Undo: drop the four flags once the underlying network issues are confirmed resolved.
- ARTIC V3 primer scheme chosen because it is the protocol-confirmed scheme for this specific
  S3-hosted sample (matches `test_full.config`'s own `primer_set_version: 3` for this cohort) —
  not a default; a different sample needs its own protocol check.
- `--freyja_repeats 10 --skip_freyja_boot true` — matches the pipeline's own `test_full.config`
  cost-control choice, not a novel reduction.

## Known gaps
- Only one real sample validated (per `new-pipeline.md` §2.8 discipline) — no wider cohort run.
- Nanopore platform, metagenomic protocol, and the de novo assembly branch are all unvalidated
  by this procurement (explicitly out of scope, see `config/pipelines.tsv`).
- Kraken2 host-filtering, Pangolin, Nextclade, and Freyja were all exercised for real on this
  sample; GATK/VEP-style downstream annotation does not apply to this pipeline at all.

## Next step for you
Review the MultiQC report and the per-amplicon `mosdepth` coverage table above (raw QC numbers
only — no biological read on this sample is offered or implied). If a higher-viral-titer real
sample is wanted for a second data point, say so and I will source and run one.

No biological interpretation is included, by design.
