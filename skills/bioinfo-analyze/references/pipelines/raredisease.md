# raredisease

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** No registered stub waiver. Preview and the full-command stub must pass; missing upstream stubs can execute real work.
- **Evidence lookup:** [procurement record](evidence/raredisease.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** WGS/WES rare-disease variant *calling and scoring* — short-read alignment (or a
pre-aligned BAM entry point) → DeepVariant SNV calling → Manta/Tiddit/CNVnator SV calling →
a parallel mitochondrial-genome subworkflow (subsample, shift-align, Mutect2, liftover) →
optionally CADD/VEP annotation, gnomAD/SVDB frequency annotation, ExpansionHunter repeat
genotyping, SMNCopyNumberCaller, and GENMOD HPO/pedigree-aware ranking to produce a clinically
ordered variant list. `PED`-style `sex`/`phenotype`/`case_id` fields on every sheet row exist
because the ranking step is pedigree-aware, not because the pipeline itself does any
inheritance/genotype-pattern reasoning outside GENMOD.

**Not for — and not a substitute for `nf-core/sarek` (`references/pipelines/sarek.md`), nor the reverse.** Both take
short-read DNA to a germline VCF and both accept a pre-aligned/dedup BAM as an alternate entry
point via `$BIOINFO_REFS/genomes/GRCh38gatk`. Past that, they diverge:

| | sarek | raredisease |
|---|---|---|
| default SNV caller | GATK HaplotypeCaller (`--tools` selects) | DeepVariant (always on) |
| default SV callers | none (`--tools` adds Manta etc.) | Manta + Tiddit + CNVnator, always on |
| MT subworkflow | none | always runs, regardless of `--tools`-equivalent flags |
| clinical ranking/scoring | none | GENMOD (HPO/pedigree-aware), when annotation subworkflows are on |
| tumour-normal / CNV-cohort | yes (sarek's actual specialty) | no |
| repeat expansion genotyping | no | ExpansionHunter, when repeat_calling is on |
| SMN copy number | no | SMNCopyNumberCaller, always on |

Pick sarek for tumour-normal, cohort-CNV, or "just give me calls with whatever caller I
choose." Pick raredisease when the end goal is a pedigree-ranked candidate list for a
single-family rare-disease case — but see the scope caveat below: this repo's procurement
does not exercise the ranking layer yet.

**Minimum input:** `--input samplesheet.csv`, `assets/schema_input.json` (3.1.2) re-read this
procurement. `required[]` = `sample` + `sex` + `phenotype` + `case_id`; `sex` and `phenotype`
are closed integer enums (PED convention: `sex` 0/1/2/other, `phenotype` 0/1/2), not sarek's
free-text style. One of `fastq_1`(+`lane`)/`spring_1`/`bam`(+`bai`) supplies reads — none is
individually `required[]`-listed, so a sheet with none of them is a silent-scheduling gap the
JSON schema alone will not catch (same shape as taxprofiler's optional-fastq gap, `references/pipelines/taxprofiler.md`); see
`references/samplesheets.md` for the exact check and the `case_id` uniqueness no-op (the
schema's `"uniqueEntries":["case_id"]` is nested inside `items`, never evaluated against the
array, and is a documented dead constraint at this pin — repeated `case_id` across a family's
rows is the intended shape, not a defect to flag).

`--genome` is a **closed enum** here (`GRCh37`/`GRCh38` only, no `null` fallback, unlike
sarek). `--intervals_wgs`/`--intervals_y` are schema-required with **no default** (sarek has
no equivalent requirement) — this repo built them via `gatk ScatterIntervalsByNs -OT ACGT`
filtered to the 25 primary contigs, stored at `genomes/GRCh38gatk/intervals/`.

**Scope of this procurement — narrower than a full run.** Stocked with
`--skip_subworkflows snv_annotation,sv_annotation,mt_annotation,repeat_calling,
repeat_annotation,me_calling,me_annotation,generate_clinical_set --skip_tools
gens,germlinecnvcaller` — the "lightest combination first" pattern used for mag/taxprofiler.
CADD resources, a VEP cache, a gnomAD allele-frequency table, a vcfanno bundle, GENMOD rank
configs, an ExpansionHunter variant catalog, and a GATK GermlineCNVCaller cohort model are all
absent from `$BIOINFO_REFS` and none are fetched by this procurement. `refs.manifest.tsv` has
`fetch`-mode placeholder rows for the four resources whose fetch source this procurement
actually identified (VEP cache, CADD resources, gnomAD allele-frequency table, ExpansionHunter
catalog) — the vcfanno bundle, GENMOD rank configs, and GermlineCNVCaller cohort model have
**no manifest row yet**, so enabling those specific pieces needs a manifest row added first,
not just a download against an existing one. This run validates
alignment-input handling, QC, DeepVariant SNV calling, Manta/Tiddit/CNVnator SV calling, the
MT subworkflow, and SMNCopyNumberCaller only — **not** the annotation/scoring/ranking layer
that makes raredisease's output "rare-disease ready" in the clinical-interpretation sense.
Enabling any skipped subworkflow is a new reference-fetch decision (CADD/VEP-scale, same order
as sarek's own VEP cache) requiring the same size-disclosure-before-fetch discipline as
mag's GTDB-Tk skip.

**Bounded choice — `--aligner bwa --mt_aligner bwa`.** `PREPARE_REFERENCES` builds a
whole-genome `bwa-mem2` index whenever `--aligner` OR `--mt_aligner` equals the default
`bwamem2`, unconditionally, even for a bam-input run where neither index is ever consumed.
Measured on this host: `bwa-mem2 index` against the 3.1 Gb GRCh38 analysis-set genome was
OOM-killed (exit 137) twice at the 40 GB pool ceiling. Switched both flags to `bwa`, matching
the already-present `GRCh38gatk/index/bwa/` store, avoiding the build entirely. A real
upstream inefficiency (the index is built off `mt_aligner`'s default with no gate on whether
alignment happens at all), not a mistake in this run's own parameters.

**Key outputs:** `call_snv/genome/*_snv.vcf.gz` (DeepVariant, GATK-selected split), `call_snv/
mitochondria/*_mitochondria.vcf.gz`, `call_sv/*_sv.vcf.gz` (Manta+Tiddit+CNVnator merged) +
`*_mitochondria_deletions.txt`, `smncopynumbercaller/out/*.tsv`, `qc_bam/` (Picard
CollectWgsMetrics, mosdepth, per-chromosome TIDDIT coverage), `pedigree/*.ped`, `peddy/`
(pedigree/sex-check QC, not clinical scoring), `multiqc/`.

**QC verdict checklist (measured, no clinical/pathogenicity interpretation):** MultiQC general
stats — mean/median coverage (Picard WGS metrics), percent bases ≥30x, mosdepth coverage
breadth at 1/5/10/30/50x, ngs-bits/peddy sex-check concordance (chrY:chrX read ratio vs.
predicted sex), peddy ancestry prediction, SMNCopyNumberCaller's `isSMA`/`isCarrier` flags and
raw copy-number estimates, raw SNV/SV record counts from the VCFs (`bcftools view -H | wc -l`).
None of these are pathogenicity or ACMG-style classifications — they are QC signal only,
consistent with this repo's "no biological/clinical interpretation" rule across every
pipeline.

**First real-sample run** (`runs/20260812-raredisease-srr26793256/`, SRR26793256, ~40x WGS,
reused as a pre-aligned BAM from `nf-core/sarek`'s own MarkDuplicates CRAM via a
`samtools view -b` format transcode — no realignment): completed successfully
(`succeededCount=50 failedCount=0`, 50 tasks run + 34 cached across resumed attempts spanning a
host reboot). Measured: median coverage 39x / mean 37.6x (Picard WGS metrics on the BAM),
83.998% bases ≥30x, ngs-bits/peddy both call `male` (chrY:chrX read ratio 0.1235, consistent
with the July sarek run's chrX≈20.8x/chrY≈15.5x observation — this run still leaves `sex=0`
unasserted in the input sheet per its own bounded-choice policy), peddy ancestry prediction
`EAS`, SMNCopyNumberCaller reports `isSMA=False isCarrier=False SMN1_CN=2 SMN2_CN=2`, genome
SNV VCF 4,852,866 records, SV VCF 17,036 records. `-stub-run` at this exact skip-flag set
passes cleanly (`completed=42 failed=0`) — no waiver needed, joining taxprofiler as a clean
stub pass; the full unskipped annotation/scoring stack's stub behaviour was not exercised and
its scope is explicitly narrower than a full nf-core CI run.
