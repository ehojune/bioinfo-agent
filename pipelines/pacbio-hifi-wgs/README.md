# pacbio-hifi-wgs

PacBio HiFi human WGS germline pipeline. Self-contained Nextflow DSL2, zero plugins —
copy this directory anywhere with Nextflow ≥ 24.04 + Docker/Singularity and run.

```
subreads.bam ──pbccs──▶ HiFi uBAM ──pbmm2──▶ aligned BAM ──┬─▶ DeepVariant ─┬─▶ WhatsHap phase ─▶ haplotag BAM
                 (entry 1)   (entry 2/3: uBAM/FASTQ)       ├─▶ Clair3 ──────┘
                                        (entry 4: aligned) ├─▶ pbsv discover+call (SV)
                                                           └─▶ mosdepth / stats / MultiQC
CLR subreads.bam ─────────────▲  (entry 5: skips pbccs entirely — SUBREAD preset, + a warning)
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
| input_type | `subreads` \| `hifi_bam` \| `hifi_fastq` \| `aligned_bam` \| `clr_subreads` |
| file | `.subreads.bam` / HiFi uBAM / `.fastq(.gz)` / sorted+aligned `.bam` / CLR `.subreads.bam` |
| index | optional: `.pbi` (subreads) or `.bai` (aligned_bam); must be empty for `hifi_*` and `clr_subreads`; built if empty. A supplied `.bai` must be named `<bam>.bai` or `<bam minus .bam>.bai` — htslib derives the name from the BAM, so any other basename is not found |

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

## CLR (`clr_subreads`) — supported, with a standing warning

Continuous Long Reads are single-pass (~85-90% accuracy). **They are not HiFi and `ccs` cannot
make them HiFi** — consensus needs several full-length subreads per ZMW (`ccs --min-passes`
default 3) and a CLR library gives about one. So `clr_subreads` skips pbccs and enters at pbmm2.

The full caller set runs on CLR by explicit request, but only two stages actually adapt:

| stage | on CLR | |
|---|---|---|
| pbmm2 | `--preset SUBREAD` (`--pbmm2_clr_preset`), against its **own** SUBREAD-built `.mmi` | adapts |
| pbsv | `--hifi` omitted | adapts |
| DeepVariant | `--model_type=PACBIO` | **no CLR model exists** |
| Clair3 | `--platform hifi`, `hifi*` model | **no CLR model exists** |
| WhatsHap | phases the above VCF | inherits the problem |

Every CLR dataset therefore gets `04_QC/CLR_WARNING.txt` next to its results, and the same
warning is printed at launch. The preset is baked into the `.mmi` and pbmm2 does **not** complain
when the align preset disagrees with the index's — it silently uses the index's parameters — so a
mixed CLR+HiFi run builds one index per preset (`<ref>.CCS.mmi`, `<ref>.SUBREAD.mmi`) and routes
each row to the matching one. Read `03_VCF/SV_pbsv/` as the usable product; treat the SNV/indel
and phased outputs as exploratory and never quote them as accuracy figures without saying they
came from CLR.

A `(sample,dataset)` group may not mix `clr_subreads` with HiFi rows — they align under
different presets and would share one merged BAM. Give CLR its own `dataset` name.

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

Mechanical validation (stub-run + two real-data E2E gates) and small-variant accuracy validation
(hap.py vs GIAB HG002 truth, chr20:1-3 Mb region, DeepVariant + Clair3) are both recorded in
`docs/examples/20260820-pacbio-hifi-wgs-validation/` (`handoff.md`, `hap-py-accuracy.md`).

**pbsv is not yet accuracy-validated.** hap.py cannot score SVs; that needs Truvari against a
GIAB SV truth set (HG002 only). The work instruction — truth-set choice, the GRCh37/GRCh38
constraint, verified region coverage, and the parameter decisions — is in the same folder's
`truvari-sv-plan.md`.

## Not implemented — known gaps and future work

Nothing here is a bug; each is a deliberate boundary. Listed so the next person does not
rediscover them at hour six.

**Reference indexes are rebuilt per run.** `SAMTOOLS_FAIDX` and `PBMM2_INDEX` write `.fai`/`.mmi`
into the work directory, so `-resume` reuses them but a *new* run rebuilds them. On a whole human
genome the `.mmi` build costs ~10-15 GB RAM and real minutes, paid once per run. Running many
datasets therefore pays it many times. **Future work:** accept a prebuilt `--mmi`/`--fai` (and
promote a built copy into `$BIOINFO_REFS/genomes/<build>/index/pbmm2/` the way the bowtie2 index
was promoted after atacseq first built it). Until then, batching datasets into one run — or
`-resume` against the same work dir — is the only way to pay it once.

**A supplied `.bai`'s contents are trusted.** With an empty index column the pipeline builds the
index, and that build fails loudly on an unsorted BAM (`samtools index` refuses: "Unsorted
positions on sequence #1", verified). A *supplied* index now has its **name** checked at parse
time — it must be `<bam>.bai` or `<bam minus .bam>.bai`, the two htslib actually looks for
(verified both ways: `a.bam.bai` and `a.bai` run; `a.custom.bai` used to reach mosdepth and die
with "index not found for: a.bam", and is now rejected before launch). Its **contents** are still
taken on faith: nothing verifies the index matches the BAM, or that the BAM is coordinate-sorted.
Do not hand-pair a stale index. **Future work:** `samtools quickcheck` + a sort-order header
assertion inside `CHECK_BAM`.

**CLR small-variant calling has no proper model.** CLR is now a supported entry point
(`clr_subreads`, see above) but DeepVariant and Clair3 ship no CLR model, so their output on a
CLR dataset is exploratory only — flagged at runtime and in `04_QC/CLR_WARNING.txt` rather than
silently produced. **Future work, if CLR small variants are ever needed for real:** a
CLR-appropriate caller, not a flag on these two.

**SV accuracy is unvalidated.** See the Validation section above and `truvari-sv-plan.md`.

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
