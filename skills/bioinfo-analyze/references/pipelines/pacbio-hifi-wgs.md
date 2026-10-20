# pacbio-hifi-wgs

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** No registered stub waiver. Preview and the full-command stub must pass; missing upstream stubs can execute real work.
- **Evidence lookup:** [procurement record](evidence/pacbio-hifi-wgs.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** PacBio HiFi human WGS germline variant calling — raw subreads and/or HiFi reads and/or
already-aligned BAMs in, per-dataset deliverables out: HiFi uBAM (`pbccs`), aligned BAM (`pbmm2`),
SNV/indel VCFs (DeepVariant **and** Clair3, plus SNV/INDEL convenience splits), phased VCF +
haplotagged BAM (WhatsHap), SV VCF (`pbsv`), mosdepth/samtools/bcftools QC + MultiQC. The first
**in-repo** pipeline: it lives at `pipelines/pacbio-hifi-wgs/` in this repository, is not an
nf-core pipeline, has no `-r` (revision = repo checkout), and uses zero Nextflow plugins so the
directory can be copied to an offline SGE+Singularity cluster and run as-is. Order follows
PacBio's HiFi-human-WGS-WDL v1.x: DeepVariant (≥1.4, internal read phasing) and pbsv both consume
the plain aligned BAM; WhatsHap phases afterwards.

**Not for:** tumour-only somatic calling (only tumour–normal is wired — `*_TUMOR_ONLY` models are
rejected at launch), somatic SV/CNV, or ClairS. Not for ONT (nanoseq, `references/pipelines/nanoseq.md`). Not for Iso-Seq (isoseq, `references/pipelines/isoseq.md`). Not for short reads
(sarek, `references/pipelines/sarek.md`). Not for assembly. Repeat genotyping is downstream: its haplotagged pbmm2 BAM is
exactly what TRGT consumes (§6.2, which this pipeline un-blocks).

**Minimum input:** `--input samplesheet.csv --fasta ref.fa`. Samplesheet columns
`sample,dataset,input_type,file[,index]` — the `input_type` column (`subreads` | `hifi_bam` |
`hifi_fastq` | `aligned_bam` | `clr_subreads`) is the per-row mid-pipeline entry mechanism; rows sharing
(sample,dataset) merge after alignment. Full spec: `references/samplesheets.md` and the
pipeline's own `README.md`.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--clair3_model` | `hifi_revio` (default) \| `hifi_sequel2` \| `hifi` | **must match platform** — movie prefix m84=Revio, m64=Sequel II (→`hifi_sequel2`), m54=Sequel. Wrong model runs silently with degraded accuracy |
| `--phase_vcf` | `deepvariant` (default) \| `clair3` | which small-variant VCF WhatsHap phases/haplotags from |
| `--pbsv_tandem_repeats` | TRF bed | officially recommended for pbsv discover; absent = still runs |
| `--ccs_chunks` | 8 | size to the movie's ZMW count — the isoseq `references/pipelines/isoseq.md` lesson (empty chunks crash downstream) applies to any chunked CCS |
| `--clair3_args` | `--include_all_ctgs` | only to call decoy/unplaced/ALT contigs — Clair3's default set covers 1–22/X/Y with AND without `chr` prefix, so plain hs37d5 needs nothing |
| `--container_*` | image URIs | every tool image is a param; defaults verified 2026-08-20 |

**Version pins that are choices, not defaults:** clair3 `v1.2.0` deliberately (hkubal/clair3
v2.x images drop **all** bundled HiFi models — verified empirically on v2.0.2); pbmm2 26.2.0
(calendar versioning since 2026); DeepVariant 1.10.0; WhatsHap 2.8 (phases indels by default,
unlike the 0.17 used for the historical GIAB haplotagged BAMs — `--whatshap_args --only-snvs`
restores old behaviour).

**Reference-store paths:** any FASTA works via `--fasta`; on this host
`$BIOINFO_REFS/genomes/GRCh38gatk/fasta/genome.fa` (chr-prefixed, no-ALT) is the natural choice.
`.fai` and `.mmi` are built in-run; no pre-built index rows needed.

**Validation record (2026-08-20, `docs/examples/20260820-pacbio-hifi-wgs-validation/`):**
`-stub-run` passes end to end on a mixed 5-row samplesheet covering all four entry types
(60+ tasks, all callers + phasing + QC). Real E2E: (a) `-profile test,docker` runs real subreads
(nf-core isoseq CI subset) through pbindex→ccs→pbmerge→pbmm2; (b) HG002 GIAB Sequel II HiFi
chr20:1–3 Mb (11,004 reads, S3 range-fetch) through the full caller chain against a chr20-only
GRCh38 ref. Wall-clock/disk: `references/estimates.md`. **Accuracy** (2026-08-20/21,
`hap-py-accuracy.md` in the same folder): hap.py vs GIAB HG002 NISTv4.2.1 truth, same
chr20:1–3 Mb region, confident-BED-restricted (2.77 Mb, 4,793 evaluated truth records) — DeepVariant SNP
F1 0.9999 / INDEL F1 0.9960, Clair3 (`hifi_sequel2`) SNP F1 1.0000 / INDEL F1 0.9984. **Scope
note:** this is a chr20:1–3 Mb slice, not a whole-genome accuracy claim — no segdup/HLA/centromere
coverage; and the input FASTQ was range-fetched from GIAB's own already-aligned BAM, so this
measures caller accuracy on reads a prior alignment already placed in the region, not
alignment-stage recall on unselected reads (detail: `hap-py-accuracy.md`).
**Whole-genome accuracy** (GIAB public HiFi, `docs/examples/20260926-pacbio-hifi-wgs-giab-wholegenome/`): 19 runs
vs v4.2.1 — SNP F1 0.9984–0.9994; DeepVariant INDEL F1 0.975–0.997 on Sequel II/Revio and
0.928/0.965 on Sequel I, the gap sitting in homopolymers of 12 bp or more. Both callers run by
default; read DeepVariant as the primary call set (Clair3 v1.2.0 loses INDEL on Revio). pbsv on HG002 (5 runs, Truvari 5.4.0 vs v5.0q
`stvar`, the only GRCh38 germline SV truth): precision 0.897–0.904, recall 0.757–0.788 — recall is
the weak side.

**CLR is a supported entry point, with a caveat that must travel with the numbers.**
`clr_subreads` (Sequel CLR `.subreads.bam`) **skips ccs** — CLR is single-pass and ccs needs ~3
full-length subreads per ZMW, so it cannot be turned into HiFi. The full caller set runs on CLR
by explicit request (2026-08-21), but only pbmm2 (`--preset SUBREAD`) and pbsv (`--hifi`
dropped) actually adapt; DeepVariant's PACBIO model and Clair3's `hifi*` models have no CLR
equivalent, and WhatsHap phases their output. Every CLR dataset therefore gets
`04_QC/CLR_WARNING.txt` plus a launch-time warning: read `SV_pbsv/` as the product and treat the
SNV/indel and phased outputs as exploratory. A group may not mix CLR with HiFi rows.

**Somatic tumour–normal (0.2.0, `--somatic_input`).** A second, independent sheet
`pair_id,tumor_sample,tumor_bam,tumor_index,normal_sample,normal_bam,normal_index` of BAMs
**already aligned to `--fasta`** runs DeepSomatic 1.10.0 (`--model_type=PACBIO`, the model bundled in
the CPU image `google/deepsomatic:1.10.0`, so an offline node needs nothing else). It runs with
or without `--input`; nothing is realigned. One normal may back several pairs and is checked once
(`CHECK_BAM`: `@SQ` name+length vs `--fasta`, mapped reads > 0). Output
`<outdir>/<tumor_sample>/PacBio/<pair_id>/03_VCF/deepsomatic/`, FILTER one of `PASS`/`GERMLINE`/
`RefCall`/`LowQual`/`NoCall`, FORMAT carries tumour `VAF` and normal `NAF`. The pipeline rewrites
DeepSomatic 1.10.0's `FORMAT/NAF` header from `Number=R` to `Number=A` — the tool writes one value
per ALT and `bcftools norm` aborts on the original. `DEEPSOMATIC` inherits `process_high`
(16 CPU); `--num_shards` follows `task.cpus`, so raise that label's CPUs in a site config to use
a bigger node. Validation: stub regression against the germline-only base + 10 negative cases and
one real CPU slice (2026-09-25, `docs/examples/20260925-pacbio-somatic-cpu-validation/`), then 13
whole-genome GIAB HG008 pairs (2026-09-25, `docs/examples/20260926-pacbio-hifi-wgs-giab-wholegenome/`): the
matched pair with a 68x normal scores SNV recall 0.950 / precision 0.953, INDEL recall 0.249.
Pairs with a borrowed normal are read for recall only — the truth holds truncal variants, so a
clone's own variants count as FP. 60 CPU: 2.4–3.4 h per pair.

**Deliberate non-goals, so they are not rediscovered mid-run:** reference `.fai`/`.mmi` are built
per run (a fresh run rebuilds the whole-genome `.mmi`, ~10-15 GB RAM — batch datasets or `-resume`
to pay it once); a *supplied* `.bai` is trusted as-is (an omitted one is built, and that build
refuses an unsorted BAM); and `input_type` is declared, never sniffed — CLR
reads mislabelled as `hifi_fastq` still run with the CCS preset and no warning, so label them
`clr_subreads`. Full list: the pipeline README's "Not implemented" section.

**GIAB fit (the phase-2 use case):** the GIAB pacbio_hifi manifests contain **zero raw
subreads** — every dataset enters at `hifi_fastq`/`hifi_bam` or `aligned_bam`; the survey table
per sample×dataset (what exists where, which movies are duplicated across dirs) is in the
validation record's `giab-pacbio-states.md`.
