# hap.py accuracy validation — pacbio-hifi-wgs, chr20:1-3,000,000 (HG002)

Closes the gap `handoff.md` named explicitly: E2E-B validated mechanics only. This run compares
that same pipeline's DeepVariant and Clair3 calls against the official GIAB HG002 truth set,
restricted to the same chr20:1-3,000,000 slice. **Region-scoped only** — this is not a
whole-genome accuracy claim.

## Reuse status

The prior E2E-B outputs (`/work/scratch/pbwgs-e2eb/`) and the chr20-only reference
(`/work/staging/pbwgs-e2e/`) were gone from disk (host is at 90% ext4 usage; scratch dirs get
reclaimed). The pipeline was **re-run from scratch** — not resumed — reproducing `cmd.sh`
exactly (same samplesheet row, same htslib S3 range-fetch of the same source BAM, same
`--clair3_model hifi_sequel2`, same chr20-only GRCh38 reference). New run directory:
`/work/scratch/pbwgs-happy-rerun/` (ext4, not committed — `cmd.sh`/`ss.csv`/`e2e.config` there
mirror this folder's `cmd.sh`).

Reproduction check against the original E2E-B numbers in `handoff.md`:

| metric | E2E-B (2026-08-20) | this re-run | |
|---|---|---|---|
| primary mapped reads | 10,985/11,004 | 11,004 reads extracted, same source range | source-identical |
| DeepVariant records | 8,158 | 8,158 | exact match |
| Clair3 records | 6,731 | 6,730 | 1 record different, within caller/tool-version noise |

`completed=23 failed=0` (`-resume` had nothing to resume against; fresh cache, all tasks ran).
Wall clock for the whole rerun (align + both callers + pbsv + phasing + QC): under 10 minutes.

## Truth set

GIAB HG002 (NA24385, AJ son) small-variant benchmark, **NISTv4.2.1**, GRCh38, chr-prefixed
(matches this pipeline's `hg38.fa` reference, which is UCSC-style chr-prefixed):

```
https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/AshkenazimTrio/HG002_NA24385_son/NISTv4.2.1/GRCh38/
  HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz            (156,252,944 bytes)
  HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz.tbi        (1,657,747 bytes)
  HG002_GRCh38_1_22_v4.2.1_benchmark_noinconsistent.bed (11,494,021 bytes)
```

Total download 169 MB. `NISTv5.0q` also exists on the GIAB FTP (newer, assembly/T2T-Q100-based,
dated 2025-01-17 / updated 2026-07-17) but its own README labels it a **draft** benchmark set;
v4.2.1 is the mapping-based release still treated as the field's stable reference standard and is
what the published DeepVariant/Clair3 HiFi accuracy figures were benchmarked against, so it was
used here. **Bounded choice**, stated: re-run against v5.0q is possible later if the draft is
promoted to a stable release.

Truth VCF and confident-regions BED were both restricted to `chr20:1-3,000,000`
(`bcftools view -r chr20:1-3000000`, `awk` region-clip on the BED). The confident BED contains
**2,766,533 bp** (461 intervals) inside the 3 Mb slice — the actual comparison denominator; the
rest of the slice has no truth-confidence claim either way. Truth VCF in that window: 5,023
records.

## Method

`jmcdani20/hap.py:v0.3.12` (Docker), default `vcfeval` comparison engine, against the pipeline's
full (unsplit) caller VCFs — `.../03_VCF/deepvariant/*.vcf.gz` and `.../03_VCF/clair3/*.vcf.gz` —
each compared separately to the same truth VCF + confident BED:

```
hap.py truth_chr20_1_3M.vcf.gz  <caller>.vcf.gz  \
  -f confident_chr20_1_3M.bed  -r chr20.fa  -o <caller>/happy  --engine=vcfeval
```

`-r` is the same chr20-only FASTA the pipeline aligned and called against, so coordinates match
between query and reference identically to the run itself.

## Measured results

### DeepVariant 1.10.0

| Type | Truth total | TP | FN | Query total | FP | Recall | Precision | F1 |
|---|---|---|---|---|---|---|---|---|
| SNP | 4,187 | 4,186 | 1 | 5,401 | 0 | 0.999761 | 1.000000 | 0.999881 |
| INDEL | 606 | 605 | 1 | 1,112 | 4 | 0.998350 | 0.993671 | 0.996005 |

### Clair3 v1.2.0 (`hifi_sequel2` model)

| Type | Truth total | TP | FN | Query total | FP | Recall | Precision | F1 |
|---|---|---|---|---|---|---|---|---|
| SNP | 4,187 | 4,187 | 0 | 5,645 | 0 | 1.000000 | 1.000000 | 1.000000 |
| INDEL | 606 | 606 | 0 | 1,153 | 2 | 1.000000 | 0.996835 | 0.998415 |

(`ALL` and `PASS` filter rows are identical or near-identical for both callers on this input —
neither VCF carries a meaningfully filtering FILTER column here. `QUERY.UNK` — query records with
no truth-region overlap, i.e. outside the confident BED — ranges **480–521 for INDELs and
1,209–1,452 for SNPs** (DeepVariant SNP 1,209; Clair3 SNP 1,452; DeepVariant INDEL 480; Clair3
INDEL 521). All `QUERY.UNK` records are excluded from the recall/precision denominators by
hap.py, as intended — the reported SNP precision of 1.0 for both callers is over the ~4,200
in-confident-region calls only, not the full 5,400–5,650 query total.)

Full hap.py output (`happy.summary.csv`, `happy.extended.csv`, ROC csvs, per-variant `happy.vcf.gz`)
retained at `/work/scratch/pbwgs-happy-rerun/happy/{deepvariant,clair3}/` (ext4 scratch, not
committed) and copied here for `deepvariant`/`clair3` summary + extended CSVs:
`docs/examples/20260820-pacbio-hifi-wgs-validation/happy-outputs/`.

## Reading these numbers — measured only

Both callers land at or above 99.9% F1 for SNPs and above 99.6% F1 for indels in this region.
Published DeepVariant/Clair3 HiFi benchmarks typically report SNP F1 above 99% and indel F1 in
the high 90s on HiFi WGS data — these numbers are in that plausible range, not outliers in either
direction. Clair3's slightly higher recall/precision here than DeepVariant's is a single small
region's measurement (5,023 truth records total across both variant types), not a general
performance claim between the two callers — do not extrapolate it past this slice.

**No FN or FP was individually reviewed for cause.** DeepVariant has 1 SNP `TRUTH.FN` and 1 indel
`TRUTH.FN`; Clair3 has 0 SNP `TRUTH.FN` and 0 indel `TRUTH.FN` (see per-caller tables above —
these are not the same for both callers). `QUERY.FP` counts (DeepVariant 0 SNP/4 indel, Clair3
0 SNP/2 indel) are all single digits on a 5,023-record truth set. Nothing here crossed a
threshold worth flagging.

This is a **chr20:1-3 Mb slice** — a few thousand truth variants, not a genome-scale cohort. It
validates that the pipeline's calling chain produces accurate calls on the region it was already
mechanically validated on; it says nothing about coverage-dependent or region-specific behavior
elsewhere in the genome (segdups, HLA, centromeres, etc. were not touched by this slice or by
E2E-B).

## Files

- Truth set + region-restricted derivatives: `/work/staging/pbwgs-happy/` (ext4 scratch)
- Rerun pipeline outputs: `/work/scratch/pbwgs-happy-rerun/results/`
- hap.py outputs: `/work/scratch/pbwgs-happy-rerun/happy/{deepvariant,clair3}/`
- Summary/extended CSVs copied into this repo: `happy-outputs/{deepvariant,clair3}/`
