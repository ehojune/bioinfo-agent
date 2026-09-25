# Handoff — 20260926-pacbio-hifi-wgs-giab-wholegenome

Whole-genome accuracy of `pipelines/pacbio-hifi-wgs` on GIAB public HiFi data, measured by a
downstream benchmarking project that vendored this pipeline and ran it on an SGE cluster
(offline compute nodes, Singularity). It closes the three gaps the earlier records left open:
small variants were scored on a 2 Mb slice only, pbsv had no accuracy number, and the somatic path
had no whole-genome run.

Scoring was done outside the pipeline (hap.py / Truvari / aardvark on the published VCFs). The code
ran as committed except the germline copy's 3-line `run_label` patch (table below); the somatic run
raised `DEEPSOMATIC` CPUs through a site config only. Numbers are PASS rows unless stated.

## Pipeline versions

| path | commit | local changes |
|---|---|---|
| germline (DeepVariant, Clair3, pbsv) | `48ec463` (2026-08-20) | 3 lines: a `run_label` param, `pipeline_info/<run_label>-*`, `multiqc/<run_label>/` — later upstreamed as `--run_label` |
| somatic (DeepSomatic) | `f2de95e` (0.2.0 branch of PR #57) | none |

**How this maps to the current code (0.2.0).** 0.2.0 also adds the CLR entry point, the supplied-`.bai`
name check for `aligned_bam`, and the somatic path; none of those touch `hifi_fastq`/`hifi_bam`
germline runs. On that path the one change is the pbmm2 index file name, now per preset
(`<ref>.mmi` → `<ref>.CCS.mmi`; HiFi still uses the CCS preset). Caller images, command lines, defaults and sample channels for
`hifi_fastq`/`hifi_bam` are unchanged (independent Codex diff review, 2026-09-26). No run repeated
these datasets on 0.2.0, so the numbers below are results **of `48ec463`**, not a proof that 0.2.0
writes identical files — the new index path can at least appear in the BAM's `@PG` line.

## Inputs and run shape

- 45 GIAB HiFi datasets (HG001–HG009), 16 `hifi_fastq` + 29 `hifi_bam`, 43–166 GiB each, GRCh38
  `GCA_000001405.15_GRCh38_no_alt_analysis_set`. Four more runs repeat the same movies under a
  second directory (49 runs in all).
- One SGE job per dataset, 30 slots, Nextflow `local` executor capped at 30 CPU / 70 GB.
- Only HG001–HG007 have germline truth, so accuracy below covers 19 runs (small variants) and the 5
  HG002 runs (SV). HG008/HG009 germline runs completed but have no germline benchmark.

## Small variants — whole genome, 19 runs

hap.py 0.3.12 (`jmcdani20/hap.py:v0.3.12`) vs GIAB NIST v4.2.1 benchmark VCF + BED
(`_noinconsistent.bed` for HG002–HG004), raw pipeline VCF in (hap.py applies FILTER itself).
DeepVariant 1.10.0 (one PACBIO model for all runs), Clair3 v1.2.0 (`hifi` / `hifi_sequel2` /
`hifi_revio` by instrument). Instrument is read from the movie ID (m54 Sequel I, m64 Sequel II,
m84 Revio), not from the dataset name.

| dataset | instrument | INDEL F1 DV | INDEL F1 Clair3 | SNP F1 DV | SNP F1 Clair3 |
|---|---|---:|---:|---:|---:|
| HG002.PacBio_HiFi-Revio_20231031 | Revio | 0.9913 | 0.9747 | 0.9992 | 0.9990 |
| HG003.PacBio_HiFi-Revio_20231031 | Revio | 0.9916 | 0.9785 | 0.9991 | 0.9990 |
| HG004.PacBio_HiFi-Revio_20231031 | Revio | 0.9920 | 0.9862 | 0.9991 | 0.9987 |
| HG001.HudsonAlpha_PacBio_CCS | Sequel II | 0.9762 | 0.9752 | 0.9991 | 0.9991 |
| HG001.PacBio_SequelII_CCS_11kb | Sequel II | 0.9930 | 0.9939 | 0.9994 | 0.9992 |
| HG002.PacBio_CCS_15kb_20kb_chemistry2 | Sequel II | 0.9973 | 0.9980 | 0.9993 | 0.9993 |
| HG002.PacBio_SequelII_CCS_11kb | Sequel II | 0.9932 | 0.9951 | 0.9992 | 0.9990 |
| HG003.PacBio_CCS_Google_15kb | Sequel I + II (1 + 2 movies) | 0.9855 | 0.9843 | 0.9987 | 0.9986 |
| HG003.PacBio_CCS_HudsonAlpha_14kb_15kb_19kb | Sequel II | 0.9950 | 0.9959 | 0.9992 | 0.9991 |
| HG004.PacBio_CCS_Google_15kb | Sequel II | 0.9860 | 0.9866 | 0.9986 | 0.9986 |
| HG004.PacBio_CCS_HudsonAlpha_15kb_21kb | Sequel II | 0.9933 | 0.9949 | 0.9992 | 0.9991 |
| HG005.HudsonAlpha_PacBio_CCS | Sequel II | 0.9963 | 0.9955 | 0.9993 | 0.9992 |
| HG005.PacBio_SequelII_CCS_11kb | Sequel II | 0.9968 | 0.9969 | 0.9992 | 0.9991 |
| HG006.PacBio_HiFi_Google | Sequel II | 0.9921 | 0.9930 | 0.9992 | 0.9989 |
| HG007.PacBio_HiFi_Google | Sequel II | 0.9747 | 0.9749 | 0.9985 | 0.9984 |
| HG002.PacBio_CCS_10kb | Sequel I | 0.9646 | 0.9640 | 0.9989 | 0.9988 |
| HG002.PacBio_CCS_15kb | Sequel I | 0.9282 | 0.9130 | 0.9988 | 0.9988 |
| HG006.PacBio_CCS_15kb_20kb_chemistry2 | (no movie ID) | 0.9967 | 0.9974 | 0.9993 | 0.9991 |
| HG007.PacBio_CCS_15kb_20kb_chemistry2 | (no movie ID) | 0.9935 | 0.9936 | 0.9992 | 0.9992 |

- `HG003.PacBio_CCS_Google_15kb` mixes one Sequel I movie (`m54262U`) with two Sequel II movies
  (`m64017`); it is not used for generation statements (the ranges below do not change without it).
- **SNP is saturated**: F1 0.9984–0.9994 over all 38 run × caller pairs.
- **INDEL splits by instrument generation, not caller model.** DeepVariant runs one model on every
  instrument and shows the same Sequel I gap as Clair3.
- **Stratified** (GIAB stratifications v3.6, 25 strata, DeepVariant INDEL F1): the gap sits in
  homopolymers ≥ 12 bp. Outside homopolymers Sequel I is 0.9945–0.9951, like the rest; inside
  HP ≥ 12 it is 0.737–0.871, and 83–87% of its INDEL errors fall there. Sequel II runs at 27x or
  less are lower outside homopolymers too (0.986–0.995) — depth, not instrument.
- **Revio: Clair3 v1.2.0 `hifi_revio` loses to DeepVariant on INDEL** (−0.006 to −0.017); 80–91% of
  Clair3's errors there are in HP ≥ 12. On Sequel II the two callers tie (−0.002 to +0.001).
- **Outside v4.2.1** (HG002, v5.0q smvar, the 83 Mb v4.2.1 leaves out, scored as strata of one
  v5.0q run): DeepVariant still leads — SNP on all 5 runs, INDEL on Sequel II and Revio.

| HG002, outside v4.2.1 | SNP F1 DV / Clair3 | INDEL F1 DV / Clair3 |
|---|---|---|
| Revio | 0.954 / 0.922 | 0.870 / 0.733 |
| Sequel II (2 runs) | 0.948–0.954 / 0.919–0.924 | 0.907–0.937 / 0.867–0.891 |
| Sequel I (2 runs) | 0.938–0.941 / 0.908–0.913 | 0.604–0.728 / 0.603–0.747 |

**Default small-variant caller for HiFi: DeepVariant.** Keep Clair3 as a cross-check.

## Structural variants — pbsv, HG002, 5 runs

Truvari 5.4.0 vs GIAB HG002 **v5.0q stvar** (the only GRCh38 germline SV truth for these samples),
using the v5.0q README's own command: `truvari bench --includebed <bed> --pick ac --passonly
-r 2000 -C 5000`, then `truvari refine`. `ALT=*` records were removed from the truth first, as that
README asks. Everything else is Truvari's default (sizemin 50, sizemax 50,000, pctseq/pctsize 0.70).

This is **not** the parameter set `../20260820-pacbio-hifi-wgs-validation/truvari-sv-plan.md`
proposed: `--passonly` was kept because the README uses it, and no DEL/INS-only restriction was
applied.

| HG002 dataset | instrument | precision | recall | F1 | F1 gain from refine |
|---|---|---:|---:|---:|---:|
| PacBio_HiFi-Revio_20231031 | Revio | 0.9041 | 0.7875 | 0.8418 | +0.0543 |
| PacBio_CCS_15kb_20kb_chemistry2 | Sequel II | 0.9010 | 0.7801 | 0.8362 | +0.0526 |
| PacBio_CCS_15kb | Sequel I | 0.9021 | 0.7743 | 0.8333 | +0.0519 |
| PacBio_SequelII_CCS_11kb | Sequel II | 0.8989 | 0.7666 | 0.8275 | +0.0499 |
| PacBio_CCS_10kb | Sequel I | 0.8967 | 0.7567 | 0.8208 | +0.0489 |

- **Recall is the weak side.** Of 28,123 truth SVs, pbsv finds 21,282–22,147 and misses
  5,976–6,841. Precision is flat at 0.897–0.904.
- **No generation order for SV**, and the SV ranking does not follow the INDEL ranking —
  `CCS_15kb` is last on INDEL and third on SV. Do not rank runs on one "quality" axis.
- Why recall is low (v5.0q's hard regions or pbsv itself) was not investigated. Do not compare
  with Tier1 v0.6-era F1 values.

## Somatic — DeepSomatic 1.10.0, HG008, 13 pairs

Already-aligned BAMs from the germline runs above (no realignment), `google/deepsomatic:1.10.0`
CPU, `--model_type=PACBIO`, tumor-normal, 60 CPU per pair (`DEEPSOMATIC` raised to the job's
slots in a site config, as the README's CPU note describes). Scored with aardvark v1.0.0 vs NIST
HG008-T smvar **V0.3** `tumorvariants`, PASS and tumour VAF ≥ 0.05, BED `all` (in brackets:
`nogermlineinterference`).

| pair | normal | SNV recall | SNV precision | INDEL recall | INDEL precision |
|---|---|---:|---:|---:|---:|
| HG008-T BCM Revio (72x) | matched, HG008-N-D 68x | 0.950 (0.984) | 0.953 | 0.249 (0.430) | 0.986 |
| HG008-T PacBio Revio (79x) | matched, HG008-N-P 35x | 0.951 (0.984) | 0.864 | 0.255 (0.437) | 0.917 |
| 11 other tumour runs (bulk p21/p41/p100, 8 clones; 29–47x) | borrowed HG008-N-D | 0.892–0.934 | not read | 0.199–0.246 | not read |
| (reference) public UCSC DeepSomatic 1.6.0 callset | | 0.948 (0.981) | 0.937 | 0.205 (0.353) | 0.921 |

- **Precision is read for the two matched pairs only.** The V0.3 truth holds truncal variants of
  one batch; clones and other passages carry real private variants that score as FP. The long
  passage (p100) has the most of them (2,885 PASS SNVs outside truth).
- The matched pair with the 35x normal has lower SNV precision (0.864 vs 0.953). That matches the
  normal-depth difference in direction; the cause was not checked.
- INDEL recall is low for the public 1.6.0 callset as well (0.205 vs 0.249) — not specific to this
  pipeline.
- The UCSC callset's input pair was not confirmed to be the same as ours, so the gap to it is not a
  version effect by itself.
- All 13 pairs exit 0; FILTER counts per pair: PASS 12,100–14,947, LowQual 0.

## Resources (per job, one node each)

| step | slots / threads | wall | maxvmem |
|---|---|---|---|
| germline pipeline, 49 runs | 30 | 4.7 – 11.7 h | 38 – 80 GB |
| somatic pipeline, 13 pairs (`--num_shards=60`) | 60 | 2.4 – 3.4 h | 200 – 258 GB |
| hap.py, 19 runs | 16 | 56 – 83 min | 48.4 – 48.8 GB |
| Truvari bench + refine, 5 runs | `-t 8` | ~4 min | 91.6 – 136.2 GB |

- maxvmem is SGE's **virtual** memory for the whole job; resident memory was not measured, and the
  somatic value was measured at one shard count only — do not scale it by shards.
- Truvari refine at `-t 22` failed with ENOMEM (a single 64 GiB allocation) when two jobs shared a
  251 GB node; at `-t 8` memory fell only 29–46% for a 64% thread cut. Control concurrency, not
  threads.

## Not validated by this record

- `clr_subreads` and `subreads` entry points, and the `aligned_bam` entry for germline calling.
- SV accuracy beyond HG002, and anything on GRCh37.
- Somatic SV/CNV (the pipeline does not call them), tumour-only mode (the pipeline refuses it).
