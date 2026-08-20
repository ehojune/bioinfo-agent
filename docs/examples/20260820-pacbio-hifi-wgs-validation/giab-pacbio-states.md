# GIAB PacBio HiFi manifest survey — per-dataset processing states

Source: `C:\Users\admin\Desktop\GIAB_benchmarking\manifests\HG00{1..9}\pacbio_hifi.tsv` (2026-08-13 snapshot).
Movie-name prefix used for platform inference: m54=Sequel, m64=Sequel II, m84=Revio.
CLR check: `pacbio_clr.tsv` files hold only CLR datasets (PacBio_MtSinai_NIST, PacBio_CLR); **no .subreads.bam for any CCS/HiFi dataset lives there**, and no hifi manifest contains subreads either.

## HG001 (NA12878)

| dataset | subreads | hifi_ubam | hifi_fastq | aligned (refs) | haplotagged | ~GiB | platform |
|---|---|---|---|---|---|---|---|
| HudsonAlpha_PacBio_CCS | no | no | yes (.fastq.gz, 6 movies) | none | — | 66 | Sequel II |
| PacBio_CCS_15kb_20kb_chemistry2 | no | yes (uBAMs/, 6 movies) | no | GRCh38, CHM13 | yes (deepvariant.haplotagged) | 210 | Sequel II |
| PacBio_SequelII_CCS_11kb | no | no | no | hs37d5, GRCh38 | yes (whatshap.haplotag) | 110 | Sequel II |

Note: HudsonAlpha fastq movie names = chemistry2 uBAM movie names (same runs, two formats).

## HG002 (son, AJ trio)

| dataset | subreads | hifi_ubam | hifi_fastq | aligned (refs) | haplotagged | ~GiB | platform |
|---|---|---|---|---|---|---|---|
| PacBio_CCS_10kb | no | no | yes (.Q20.fastq) | hs37d5, GRCh38 | yes (whatshap.haplotag) | 282 | Sequel |
| PacBio_CCS_15kb | no | no | yes (.Q20.fastq) | hs37d5, GRCh38 | yes (whatshap.haplotag) | 292 | Sequel |
| PacBio_CCS_15kb_20kb_chemistry2 | no | no | yes (.fastq.gz, 6 movies) | hs37d5, GRCh37 (duplomap), GRCh38 | yes (haplotag; no whatshap tag) | 573 | Sequel II |
| PacBio_SequelII_CCS_11kb | no | no | yes (.fastq.gz, 6 movies) | hs37d5, GRCh38 | yes (whatshap.haplotag) | 209 | Sequel II |
| PacBio_HiFi-Revio_20231031 | no | yes (2 movies) | no | GRCh37, GRCh38-GIABv3, CHM13v2.0 (48x) | no | 287 | Revio |

## HG003 (father, AJ trio)

| dataset | subreads | hifi_ubam | hifi_fastq | aligned (refs) | haplotagged | ~GiB | platform |
|---|---|---|---|---|---|---|---|
| PacBio_CCS_15kb_20kb_chemistry2 | no | yes (6 movies) | yes (reads/, HudsonAlpha names) | hs37d5, GRCh38, CHM13 | yes (haplotag + deepvariant.haplotagged) | 658 | Sequel II |
| PacBio_CCS_Google_15kb | no | no | yes (.fastq.gz) | none | — | 45 | Sequel + Sequel II |
| PacBio_CCS_HudsonAlpha_14kb_15kb_19kb | no | no | yes (.fastq.gz) | none | — | 191 | Sequel II |
| PacBio_HiFi-Revio_20231031 | no | yes (2 movies) | no | GRCh37, GRCh38-GIABv3, CHM13v2.0 (46x) | no | 276 | Revio |

## HG004 (mother, AJ trio)

| dataset | subreads | hifi_ubam | hifi_fastq | aligned (refs) | haplotagged | ~GiB | platform |
|---|---|---|---|---|---|---|---|
| PacBio_CCS_15kb_20kb_chemistry2 | no | yes (6 movies) | no | hs37d5, GRCh38, CHM13 | yes (haplotag + deepvariant.haplotagged) | 577 | Sequel II |
| PacBio_CCS_Google_15kb | no | no | yes (.fastq.gz) | none | — | 43 | Sequel II |
| PacBio_CCS_HudsonAlpha_15kb_21kb | no | no | yes (.fastq.gz) | none | — | 196 | Sequel II |
| PacBio_HiFi-Revio_20231031 | no | yes (2 movies) | no | GRCh37, GRCh38-GIABv3, CHM13v2.0 (36x) | no | 208 | Revio |

## HG005 (son, Chinese trio)

| dataset | subreads | hifi_ubam | hifi_fastq | aligned (refs) | haplotagged | ~GiB | platform |
|---|---|---|---|---|---|---|---|
| HudsonAlpha_PacBio_CCS | no | no | yes (.fastq.gz, 7 movies) | none | — | 119 | Sequel II |
| PacBio_CCS_15kb_20kb_chemistry2 | no | yes (7 movies, = HudsonAlpha runs) | no | GRCh38, CHM13 | yes (deepvariant.haplotagged) | 369 | Sequel II |
| PacBio_SequelII_CCS_11kb | no | no | no | hs37d5, GRCh38 | yes (whatshap.haplotag) | 123 | Sequel II |

## HG006 (father, Chinese trio)

| dataset | subreads | hifi_ubam | hifi_fastq | aligned (refs) | haplotagged | ~GiB | platform |
|---|---|---|---|---|---|---|---|
| PacBio_CCS_15kb_20kb_chemistry2 | no | yes (6 movies) | yes (reads/) | GRCh38, CHM13 | yes (deepvariant.haplotagged) | 386 | Sequel II |
| PacBio_HiFi_Google | no | no | yes (.fastq.gz) | none | — | 56 | Sequel II |

## HG007 (mother, Chinese trio)

| dataset | subreads | hifi_ubam | hifi_fastq | aligned (refs) | haplotagged | ~GiB | platform |
|---|---|---|---|---|---|---|---|
| PacBio_CCS_15kb_20kb_chemistry2 | no | yes (6 movies) | yes (reads/) | GRCh38, CHM13 | yes (deepvariant.haplotagged) | 380 | Sequel II |
| PacBio_HiFi_Google | no | no | yes (.fastq.gz) | none | — | 45 | Sequel II |

## HG008 (tumor/normal, data_somatic)

| dataset | subreads | hifi_ubam | hifi_fastq | aligned (refs) | haplotagged | ~GiB | platform |
|---|---|---|---|---|---|---|---|
| BCM_Revio_20240313 (HG008-T 106x + HG008-N-D 68x) | no | yes (ubams/ per tissue) | no | GRCh37, GRCh38-GIABv3, CHM13v2.0 | no | 757 | Revio |
| PacBio_Revio_20240125 (HG008-T 116x + HG008-N-P 35x) | no | yes (per-movie hifi_reads) | no | GRCh37, GRCh38-GIABv3, CHM13v2.0 | no | 637 | Revio |

## HG009 (tumor/normal + clones, data_somatic, NIST)

All datasets: demuxed uBAM(s) (`*.demux.bcXXXX.bam`) + one aligned BAM (GRCh38-GIABv3 only) + hiphase phasing outputs; most also carry an `analysis/` dir (clair3, deepsomatic+VEP, severus, cnvkit, purple, CpG methylation, MSI/TMB). No FASTQ, no subreads. All Revio.

| dataset | subreads | hifi_ubam | hifi_fastq | aligned (refs) | haplotagged | ~GiB | platform |
|---|---|---|---|---|---|---|---|
| HG009-N_bulk/20250728p25 (WT, 32X) | no | yes | no | GRCh38-GIABv3 | hiphase outputs | 92 | Revio |
| HG009-N_bulk/20250728p4 (WT, 87X) | no | yes (2) | no | GRCh38-GIABv3 | hiphase outputs (no analysis/) | 245 | Revio |
| HG009-N_bulk/20250805p23 (LVTert, 32X) | no | yes | no | GRCh38-GIABv3 | hiphase outputs | 91 | Revio |
| HG009-T_bulk/20250715p16 (140X) | no | yes (2) | no | GRCh38-GIABv3 | hiphase outputs | 239 | Revio |
| HG009-T_bulk/20250715p42 (57X) | no | yes | no | GRCh38-GIABv3 | hiphase outputs | 95 | Revio |
| HG009-T_clones/20250918p14/1C3 (61X) | no | yes | no | GRCh38-GIABv3 | hiphase outputs | 108 | Revio |
| HG009-T_clones/20250918p14/1D5 (79X) | no | yes | no | GRCh38-GIABv3 | hiphase outputs | 148 | Revio |
| HG009-T_clones/20250918p14/3C4 (71X) | no | yes | no | GRCh38-GIABv3 | hiphase outputs | 121 | Revio |
| HG009-T_clones/20250918p14/3C9 (70X) | no | yes | no | GRCh38-GIABv3 | hiphase outputs | 130 | Revio |
| HG009-T_clones/20250918p14/3F2 (81X) | no | yes | no | GRCh38-GIABv3 | hiphase outputs | 145 | Revio |
| HG009-T_clones/20250918p14/4G9 (69X) | no | yes | no | GRCh38-GIABv3 | hiphase outputs | 127 | Revio |

## Pipeline entry-point implications

- **Subreads step (CCS generation): no dataset can enter here.** Zero `.subreads.bam` in any pacbio_hifi.tsv, and the CLR manifests hold subreads only for CLR datasets. All HiFi data starts at already-basecalled HiFi reads.
- **HiFi-reads step (alignment onward)** — datasets with uBAM and/or FASTQ:
  - FASTQ only: HG001/HG005 HudsonAlpha_PacBio_CCS; HG003 CCS_Google_15kb + CCS_HudsonAlpha; HG004 CCS_Google_15kb + CCS_HudsonAlpha; HG006/HG007 PacBio_HiFi_Google; HG002 CCS_10kb / CCS_15kb (.Q20.fastq, uncompressed) and CCS_15kb_20kb_chemistry2 / SequelII_11kb (.fastq.gz).
  - uBAM (needs bam2fastq or a uBAM-aware aligner): chemistry2 dirs of HG001/HG003–HG007; all Revio dirs (HG002-4 20231031, HG008 both, HG009 all).
- **Aligned-BAM step only** (re-call variants, or revert reads via samtools fastq): HG001 and HG005 PacBio_SequelII_CCS_11kb — aligned hs37d5+GRCh38 whatshap-haplotagged BAMs with no reads-level files in the manifest.
- Duplicates to avoid double-processing: HG001/HG005 HudsonAlpha FASTQs are the same movies as their chemistry2 uBAMs; HG003 chemistry2/reads FASTQs duplicate its HudsonAlpha dir.
- HG009 already ships full somatic analysis (deepsomatic, severus, purple, etc.); reprocessing there is only needed if you want your own pipeline's calls from the uBAMs.
