# pacbio-hifi-wgs

PacBio HiFi human WGS germline pipeline. Self-contained Nextflow DSL2, zero plugins —
copy this directory anywhere with Nextflow ≥ 24.04 + Docker/Singularity and run.

```
subreads.bam ──pbccs──▶ HiFi uBAM ──pbmm2──▶ aligned BAM ──┬─▶ DeepVariant ─┬─▶ WhatsHap phase ─▶ haplotag BAM
                 (entry 1)   (entry 2/3: uBAM/FASTQ)       ├─▶ Clair3 ──────┘
                                        (entry 4: aligned) ├─▶ pbsv discover+call (SV)
                                                           └─▶ mosdepth / stats / MultiQC
```

Order follows PacBio's HiFi-human-WGS-WDL v1.x best practice: DeepVariant (≥1.4 phases reads
internally) and pbsv both run on the plain aligned BAM; WhatsHap phases the chosen small-variant
VCF afterwards and haplotags the BAM.

## Quick start

From the repo root:

```bash
nextflow run pipelines/pacbio-hifi-wgs -profile docker \
  --input samplesheet.csv --fasta GRCh38.fa --outdir results
```

In a `cmd.sh` (or anywhere the working directory isn't the repo root) write the target as an
absolute path — `"$BIOINFO_HOME"/pipelines/pacbio-hifi-wgs`. `bin/preflight.sh` refuses a
relative target because it cannot know which directory the script will be launched from.

Smoke test (downloads a 48 MB real subreads subset + a chr19 reference; CCS→align→BAM QC,
variant callers skipped):

```bash
nextflow run pipelines/pacbio-hifi-wgs -profile test,docker --outdir smoke-results
```

## Samplesheet

CSV with header `sample,dataset,input_type,file[,index]`. `#` comments allowed; no quoted commas.

| column | value |
|---|---|
| sample | e.g. `HG002` (`A-Za-z0-9._-`) |
| dataset | e.g. `PacBio_CCS_15kb` — output namespace |
| input_type | `subreads` \| `hifi_bam` \| `hifi_fastq` \| `aligned_bam` |
| file | `.subreads.bam` / HiFi uBAM / `.fastq(.gz)` / sorted+aligned `.bam` |
| index | optional: `.pbi` (subreads) or `.bai` (aligned_bam); built if empty |

Rows sharing (sample, dataset) are merged after alignment — one row per movie is the normal
multi-movie shape. All rows of a group must be against the same reference. This is how you enter
the pipeline mid-way per dataset: give whatever the most-processed form you have is, the earlier
steps are skipped for that row. A single pre-`aligned_bam` row is used in place (not re-published).

## Key parameters

| param | default | note |
|---|---|---|
| `--fasta` | — | reference FASTA (uncompressed); `.fai`/`.mmi` built in-run |
| `--ref_name` | fasta basename | appears in output filenames |
| `--ccs_chunks` | 8 | CCS scatter per movie — sized for real WGS movies; lower it for small subsets (test profile uses 2) |
| `--clair3_model` | `hifi_revio` | **set per platform**: Revio (`m84*` movies) → `hifi_revio`, Sequel II (`m64*`) → `hifi_sequel2`, Sequel (`m54*`) → `hifi`. A wrong model runs silently with degraded calls. One model per run — don't mix platforms in one samplesheet; run per dataset |
| `--phase_vcf` | `deepvariant` | which VCF WhatsHap phases (`deepvariant`\|`clair3`) |
| `--pbsv_tandem_repeats` | — | TRF bed, officially recommended for pbsv |
| `--gvcf` | false | also emit DeepVariant gVCF |
| `--skip_deepvariant/clair3/pbsv/phasing/qc` | false | step toggles |
| `--clair3_args` | '' | e.g. `--include_all_ctgs` to call decoy/unplaced/ALT contigs (Clair3's default set already covers 1–22/X/Y both with and without `chr` prefix, so plain hs37d5 works without it) |
| `--container_*` | see nextflow.config | every tool image is a param — pin any version |

Container/version pins (verified 2026-08-20): pbccs 6.4.0 (final release; Revio does CCS
on-instrument), pbmm2 26.2.0, pbsv 2.11.0, WhatsHap 2.8, DeepVariant 1.10.0, Clair3 v1.2.0.
Clair3 is deliberately not v2.x: the v2 images dropped all bundled HiFi models. WhatsHap 2.x
phases indels by default (0.17 did not; `--only-snvs` restores old behaviour via `--whatshap_args`).

## Outputs

```
<outdir>/<sample>/PacBio/<dataset>/
  01_HIFI/                 <movie>.hifi_reads.bam + ccs_reports/        (subreads entry only)
  02_alignedBAM/           <sample>.<dataset>.<ref>.bam(.bai)
    haplotagged/           <sample>.<dataset>.<ref>.haplotagged.bam(.bai)
  03_VCF/
    deepvariant/           full VCF (+gVCF, visual report html); clair3/ full VCF
    SNV_deepvariant/ INDEL_deepvariant/ SNV_clair3/ INDEL_clair3/       (bcftools norm -m -any splits)
    SV_pbsv/               <...>.pbsv.vcf.gz(.tbi)
    phased_whatshap/       phased VCF + whatshap stats
  04_QC/                   mosdepth/ samtools/ bcftools_stats/
<outdir>/multiqc/          one report across all samples
<outdir>/pipeline_info/    timeline/report/trace/dag
```

## Validation

Mechanical validation (stub-run + two real-data E2E gates) and accuracy validation (hap.py vs
GIAB HG002 truth, chr20:1-3 Mb region, DeepVariant + Clair3) are both recorded in
`docs/examples/20260820-pacbio-hifi-wgs-validation/` (`handoff.md`, `hap-py-accuracy.md`).

## SGE server, offline compute nodes (Singularity)

One-time, on a node with egress (login node):

```bash
export NXF_SINGULARITY_CACHEDIR=/shared/containers        # shared FS, visible to compute nodes
cd "$NXF_SINGULARITY_CACHEDIR"
# image list comes straight from nextflow.config (container_* params);
# cache filename convention Nextflow looks up: strip docker://, s#[/:]#-#g, append .img
for uri in $(grep -oE "container_[a-z0-9_]+ *= *'[^']+'" /path/to/pacbio-hifi-wgs/nextflow.config \
             | cut -d"'" -f2 | sort -u); do
  singularity pull --name "$(echo "$uri" | sed 's#[/:]#-#g').img" "docker://$uri"
done
```

Then (every launch shell, not just the first):

```bash
export NXF_SINGULARITY_CACHEDIR=/shared/containers
export NXF_OFFLINE=true      # zero-plugin local pipeline: no network needed at head-job time
nextflow run /path/to/pacbio-hifi-wgs -profile sge,singularity \
  --input samplesheet.csv --fasta /path/GRCh38.fa --outdir results \
  --sge_queue all.q --sge_pe smp
```

- `--sge_pe`: parallel environment name — site-specific; list with `qconf -spl`. Required for multi-CPU jobs.
- Nextflow translates `process.memory` to `-l h_rss=...,mem_free=...`. If your site enforces
  `h_vmem` (usually per slot), add it via `--sge_options '-l h_vmem=4G'`.
- DeepVariant/Clair3 write intermediates to the task workdir (not container /tmp) — no extra binds needed.

## Notes

- pbmm2 runs with `--sample <sample>` (uniform SM), `--unmapped` (uBAM is lossless), and
  sorts with 4 threads × 1 GB; FASTQ rows additionally get `--rg` with the movie id.
  DeepVariant is pinned to the same sample name (`--sample_name`), so both callers' VCFs agree.
- mosdepth uses 500 bp windows, no fast mode (fast mode overcounts depth across intra-read
  deletions in long reads).
- Every per-dataset BAM is guarded before calling (CHECK_BAM): each `@SQ` name **and length**
  must match `--fasta`'s `.fai`, and the BAM must have >0 mapped reads. Names alone are not
  enough — a GRCh37 `chr20` BAM against a GRCh38 `chr20` FASTA shares the name but not the
  length, and would otherwise produce coordinate-shifted calls with no error.
- `pbmm2 index`/`align` only run when the samplesheet has at least one non-`aligned_bam` row,
  so an aligned-BAM-only run never pays the ~10–15 GB whole-genome `.mmi` build.
- WhatsHap runs with `--ignore-read-groups` (single-sample VCFs; tolerates GIAB BAMs whose SM
  differs from the samplesheet sample name).
- pbsv runs on the plain aligned BAM (haplotags are not used by pbsv).
- `-resume` works across invocations; a samplesheet row upgraded from `hifi_bam` to `aligned_bam`
  re-enters later without redoing alignment.
