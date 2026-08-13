# Run 20260812-raredisease-srr26793256 — nf-core/raredisease -r 3.1.2 — COMPLETE

**Inputs**       1 sample, ~40x WGS, SRR26793256 — pre-aligned BAM reused from `nf-core/sarek`'s
own MarkDuplicates CRAM (`runs/20260729-sarek-srr26793256/results/preprocessing/markduplicates/
SRR26793256/SRR26793256.md.cram`), format-transcoded to BAM via `samtools view -b` (no
realignment). Samplesheet: `/mnt/d/bioinfo-agent/runs/20260812-raredisease-srr26793256/samplesheet.csv`
**Reference**    `$BIOINFO_REFS/genomes/GRCh38gatk` (fasta/fai/dict/bwa index — all reused from
the sarek procurement, no rebuild); `GRCh38gatk/intervals/intervals_wgs.interval_list` and
`intervals_y.interval_list` built this run via `gatk ScatterIntervalsByNs -OT ACGT`, filtered to
chr1-22/X/Y/M
**Command**      `/mnt/d/bioinfo-agent/runs/20260812-raredisease-srr26793256/cmd.sh`
(`--aligner bwa --mt_aligner bwa`, `--skip_subworkflows snv_annotation,sv_annotation,
mt_annotation,repeat_calling,repeat_annotation,me_calling,me_annotation,generate_clinical_set
--skip_tools gens,germlinecnvcaller` — see `plan.md` for the full flag rationale)
**Wall clock**   elapsed across 5 resumed attempts spanning a host reboot: ~9h35m
first-launch-to-completion (12:49→22:25 same day) — NOT a clean single-shot number; dominant
per-process realtime measured from trace files: `PICARD_COLLECTMULTIPLEMETRICS` 55m30s,
`TIDDIT_SV` 29m23s, `CNVNATOR_PARTITION` 28m48s, `DEEPVARIANT` 26m13s (concurrent on this
host's 18-core pool, not serial) — see `references/estimates.md` for the full note
**Peak disk**    work dir 56 GB across all resumed attempts (not re-measured for a clean
single run); published results 6.1 GB
**Cores/RAM used**  pool ceiling (18 cores / 40 GB); peak single-process RAM 772.8 MB
(`CALL_SV_MANTA:MANTA`) — comfortably under the pool ceiling throughout
**Results**      `/mnt/d/bioinfo-agent/runs/20260812-raredisease-srr26793256/results/`
(rsynced from `/work/nxf/20260812-raredisease-srr26793256/results/`)
**MultiQC**      `.../results/multiqc/multiqc_report.html`
**Work dir**     `/work/nxf/20260812-raredisease-srr26793256/work` — RETAINED, do not delete,
`-resume` depends on it

## QC verdict (measured only — no biological/clinical interpretation, no pathogenicity or
ACMG-style classification)

PASS (mechanical pipeline validation) — `succeededCount=50 failedCount=0` (34 more tasks
cached across the resumed attempts). All processes exit 0.

| sample | metric | value | verdict |
|---|---|---|---|
| SRR26793256 | median / mean coverage (Picard WGS metrics) | 39x / 37.6x | consistent with the ~40x input |
| SRR26793256 | % bases ≥30x | 83.998% | measured |
| SRR26793256 | mosdepth 1x / 5x / 10x / 30x / 50x breadth | 94.0% / 94.0% / 94.0% / 83.0% / 12.0% | measured |
| SRR26793256 | ngs-bits sex-check | male (chrY:chrX ratio 0.1235, reads chrY 2,605,882 / chrX 21,102,456) | consistent with the July sarek run's chrX≈20.8x/chrY≈15.5x observation; input sheet still leaves `sex=0` unasserted per this run's own bounded-choice policy (see `plan.md`) |
| SRR26793256 | peddy sex-check | male, error_sex_check=False | agrees with ngs-bits |
| SRR26793256 | peddy ancestry prediction | EAS | measured, not independently verified |
| SRR26793256 | SMNCopyNumberCaller | `isSMA=False isCarrier=False SMN1_CN=2 SMN2_CN=2 SMN2delta7-8_CN=0` | measured raw output, no clinical reading offered |
| SRR26793256 | genome SNV VCF record count | 4,852,866 | `bcftools view -H | wc -l` |
| SRR26793256 | SV VCF record count | 17,036 | `bcftools view -H | wc -l` (Manta+Tiddit+CNVnator merged) |

Thresholds applied: none formal — first real-sample run for this pipeline on this host (source:
my default, stated in `pipeline-selection.md` §4.13). No sample flagged/excluded.

## Bounded choices I made

- **BAM-input reuse from sarek, not a fresh alignment**: avoids re-aligning the same reads
  twice across two pipelines. Not a claim that raredisease's own alignment step (BWA-MEM2 by
  default) was validated by this run — it wasn't exercised. Undo: supply `fastq_1`/`fastq_2`
  instead of `bam`/`bai` in the samplesheet to exercise raredisease's own alignment.
- **`--aligner bwa --mt_aligner bwa`** instead of the pipeline default `bwamem2`: the
  whole-genome `bwamem2` index build is triggered unconditionally by either flag defaulting to
  `bwamem2`, even though this bam-input run never uses either index; it was OOM-killed twice
  at this host's 40 GB pool ceiling. Switched to the already-present `bwa` index instead. Undo:
  build/fetch a `bwa-mem2` index (needs >40 GB RAM or a swap-backed build) and revert the flags.
- **Narrow procurement scope**: annotation/scoring subworkflows skipped (`snv_annotation`,
  `sv_annotation`, `mt_annotation`, `repeat_calling`, `repeat_annotation`, `me_calling`,
  `me_annotation`, `generate_clinical_set`, plus `gens`/`germlinecnvcaller` tools) because CADD
  resources, a VEP cache, a gnomAD table, a vcfanno bundle, GENMOD configs, an ExpansionHunter
  catalog, and a GATK-CNV cohort model are all absent from `$BIOINFO_REFS` and none were
  fetched. Undo/extend: fetch each resource (VEP/CADD are the largest, ~25 GB+ each, same order
  as sarek's own VEP cache) and re-run without the skip flags — each is a new
  `refs.manifest.tsv fetch` row needing size disclosure/approval first.
- **`sex=0`/`phenotype=0` (unasserted) in the input sheet**: carried forward from the July
  sarek handoff's own non-assertion of sex from coverage alone. Undo: set `sex=1` given the
  ngs-bits/peddy concordant `male` call above, if a future run wants pedigree-aware ranking
  (GENMOD, currently skipped) to have a real sex value to work from.

## Known gaps

- Annotation/scoring/ranking layer (CADD/VEP/gnomAD/vcfanno/GENMOD/ExpansionHunter/
  GermlineCNVCaller) not exercised at all — this run validates alignment-input handling, QC,
  DeepVariant SNV calling, Manta/Tiddit/CNVnator SV calling, the MT subworkflow, and
  SMNCopyNumberCaller only. No pedigree-ranked candidate list was produced.
- No formal QC band for this pipeline on this host yet — first real-sample run.
- Wall-clock figure is contaminated by a mid-run host reboot and 3 forced `-resume` relaunches;
  not a clean single-shot measurement. A future run without interruption would give a tighter
  number (see `references/estimates.md`'s note).
- Only one sample (singleton "case", not a real family/trio) — the `case_id`/pedigree-grouping
  shape (multiple rows sharing one `case_id`) is documented but not exercised end-to-end with
  the ranking step that would actually consume it.

## Next step for you

Review `results/multiqc/multiqc_report.html` and the raw VCFs under `results/call_snv/` /
`results/call_sv/` if you want to see the unannotated output directly. If a production run is
wanted, decide which annotation resources to fetch first (VEP cache is the natural starting
point, same order of magnitude as sarek's) — each needs your approval given size.

No biological interpretation is included, by design.
