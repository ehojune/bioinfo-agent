# Handoff — 20260925-pacbio-somatic-cpu-validation

`pipelines/pacbio-hifi-wgs`: `--run_label` became a general feature, and DeepSomatic tumor-normal
(`--somatic_input`, CPU) was added. Validated mechanically and on one small real slice.
**Not validated at whole-genome scale, and not an accuracy benchmark.** (Whole-genome accuracy since
then: `../20260926-pacbio-hifi-wgs-giab-wholegenome/handoff.md`.)

## Gate 1 — stub regression (`stub-regression.sh`)

| check | result |
|---|---|
| germline sheet (6 rows, all 5 input_types) through base `dd9262b` vs new | published tree identical outside `pipeline_info/`; `pipeline_info/` names unchanged (`dag/report/timeline/trace-<ts>`) |
| `--run_label ds1` | `multiqc/ds1/`, `pipeline_info/ds1-*` |
| germline + 3 somatic pairs (shared normal; tumor/normal with the same basename) | 10 CHECK_BAM (5 germline + 5 distinct somatic BAMs; the shared normal checked once), 3 DEEPSOMATIC |
| somatic only (no `--input`) | 5 CHECK_BAM, 3 DEEPSOMATIC, 0 PBMM2, MultiQC from bcftools stats |
| `--deepsomatic_customized_model` (added after PR #57 review) | checkpoint prefix → staged as its directory, flag `--customized_model=ckpt/model.ckpt`, `.index`/`.data-*` present in the task; SavedModel directory → `--customized_model=ckpt`; no model → no flag (the stub records the exact flag via the same `dsModelArg()` the script uses) |
| somatic only with `--skip_deepvariant` (added in PR #57 review round 2) | runs — germline-only checks (`--phase_vcf` vs `--skip_deepvariant/--skip_clair3`) apply only when `--input` is given |
| germline only with `--deepsomatic_model PACBIO_TUMOR_ONLY` (round 3) | runs — the tumor-only model check applies only when `--somatic_input` is given |
| `scripts/check-samplesheet.sh --pipeline pacbio-hifi-wgs` on a pair sheet (round 3) | detects the `pair_id` header and validates somatic columns; accepts a valid 2-pair sheet, rejects duplicate pair_id, tumor = normal sample, tumor/normal the same file via symlink, bad index path |
| 10 negative cases | all exit non-zero **and** print the expected message: bad index basename, duplicate pair_id, missing index, `*_TUMOR_ONLY` model, neither sheet given, bad run_label, tumor = normal sample, a model path that is neither a directory nor a checkpoint prefix, germline `--input` with `--phase_vcf deepvariant --skip_deepvariant`, tumor/normal BAM the same file under two names (symlink) |

`stub-regression.sh` now exits 1 if any check fails (a failed positive run, a tree diff, a task-count
mismatch, a negative case that did not fail with its message) — before PR #57's review it printed
`STUB_DONE` and exited 0 regardless. Re-run after the review fixes (2026-09-25, WSL2 + Docker, base
`dd9262b`): **all checks pass, exit 0** (re-run again after review rounds 2 and 3). `real-slice.sh` likewise stops with the Nextflow exit code on a
failed run and propagates trace/output-check failures, and `fetch-inputs.sh` stops on a failed slice
and checks each slice (quickcheck, mapped reads); it was not re-run (the fix touches only its exit
handling, and the slice numbers below are from the original run).

BCFTOOLS_SPLIT and every other germline process script are byte-identical to the base, so
existing `-resume` caches stay valid. Only MULTIQC's publishDir (a directive) changed.

## Gate 2 — real CPU slice (`fetch-inputs.sh`, `real-slice.sh`)

GIAB `PacBio_Revio_20240125`, HG008-T 116x vs HG008-N-P 35x, GRCh38-GIABv3 BAMs sliced to
chr13:82–86 Mb (79 truth variants, the densest 4 Mb of smvar V0.3 `tumorvariants`), GIABv3 FASTA,
`--deepsomatic_regions` = that window. `google/deepsomatic:1.10.0`
(`sha256:6cd98c41781cdc1a2916d8029bedef70a57b87d41f933bd4cf259c80f291e27b`), 16 CPU clamp.

| metric | value |
|---|---|
| DEEPSOMATIC wall / %CPU / peak RSS | 1 m 46 s / 498 % / **17.8 GB** |
| stage CPU (user+sys) | make_examples ≈ 266 s, call_variants ≈ 204 s, postprocess + report ≈ 10 s |
| whole run wall | 159 s (FASTA index 24 s included) |
| FILTER | PASS 54, GERMLINE 1,813, RefCall 1,408, NoCall 392 |
| PASS matching truth (pos+allele, no BED/VAF filter) | 47 / 54; truth in window 79 |
| tumor VAF of matched calls | 0.20–0.59, median 0.49 |

These counts show the output is sane (VAF present, FILTER meaningful). They are not precision or
recall: no benchmark BED, no VAF cutoff, no aardvark/vcfeval.

## Fix caught by gate 2

DeepSomatic 1.10.0 declares `FORMAT/NAF` as `Number=R` but writes one value per ALT, so
`bcftools norm` aborts on the first multiallelic record ("wrong number of fields in FMT/NAF …
expected 3, found 2"). DEEPSOMATIC now rewrites only that header line to `Number=A`. Records are
untouched. Anything that runs `bcftools norm` on raw DeepSomatic 1.10.0 output hits the same error.

## Whole-genome estimate (linear extrapolation, ±2×)

~480 CPU-s per 4 Mb at 151x combined depth → **~100 CPU-h per whole-genome pair at that depth**,
scaled linearly with length (×775) and combined tumor+normal depth. That is about 2 h wall on a
64-core node at 80 % efficiency.

| pairs | combined depth | est. CPU-h each |
|---|---|---|
| HG008-T BCM ↔ N-D BCM | 72 + 68x | ~96 |
| HG008-T PacBio ↔ N-P PacBio | 79 + 35x | ~78 |
| 11 NIST bulk/clones ↔ N-D | 29–47 + 68x | ~66–79 |
| **13 pairs** | | **~1,000 CPU-h ≈ 20 h wall on one 64-core node** — far below the 2-week limit |

Unmeasured: one 4 Mb window may not represent the genome; memory with more than 16 shards
(peak 17.8 GB at 16 fits `process_high`'s 32 GB, but was not measured at 64).

## Environment

WSL2 Ubuntu-22.04 (the only distro on this Windows profile; the other profile's Ubuntu-24.04 is
not visible from here), Nextflow 24.10.5, Docker 29.7.1, VM 24 cores / 31 GB.
`process.resourceLimits = [cpus: 16, memory: 24.GB]`: without it, `process_high` (32 GB) exceeds
the 31 GB VM and Nextflow refuses the task before running it. This is a host limit, not a code
defect. Run long jobs in `tmux`: a one-shot `wsl.exe` session was torn down mid-run
("Failed to start the systemd user session").
