# Run 20260812-mag-testprofile-procurement — nf-core/mag -r 5.5.0 — COMPLETE

**Purpose**    `new-pipeline.md` §2.4(c)/§2.8 step 1: first full `-profile test` execution as
part of procuring nf-core/mag into this repo's stocked set.
**Inputs**     Pipeline's own bundled `test_minigut`/`test_minigut_sample2` fixture
(`nf-core/test-datasets`, `mag/samplesheets/samplesheet.multirun.v4.csv`), not staged locally.
**Reference**  No `$BIOINFO_REFS` genome involvement. Small mock DBs (BUSCO bacteria_odb10,
GTDB-Tk mockup r232, CAT minigut) fetched by the test profile itself, not pre-staged.
**Command**    `/mnt/d/bioinfo-agent/runs/20260812-mag-testprofile-procurement/cmd.sh`
**Wall clock**   27m 46s (session `nasty_albattani`, `nextflow log`)
**Peak disk**  work dir 2.2 GB, published results 195 MB      **Cores/RAM used** pool ceiling
(18 cores / 40 GB), not sustained — see per-process notes in `estimates.md`
**Results**      `/work/nxf/20260812-mag-testprofile-procurement/results/` (not copied into the
run's own `runs/` folder — CI-fixture output, superseded by the real-sample run below)
**MultiQC**  `.../results/multiqc/multiqc_report.html`
**Work dir**     `/work/nxf/20260812-mag-testprofile-procurement/work` — RETAINED, do not
delete, `-resume` depends on it

## QC verdict

PASS WITH CAVEATS — `completed=179 failed=1 cached=0`, but the 1 failure is `MAXBIN2` exit 255
on `MEGAHIT-test_minigut_sample2`, which mag's own `conf/base.config` marks
`errorStrategy 'ignore'` for exactly that exit code (MaxBin2's own documented "cannot be
binned" exit path on marker-gene-sparse input) — the pipeline's own completion banner
("Pipeline completed successfully, but with errored process(es)") is nf-core's standard
wording for exactly this tolerated-failure shape, not a real defect. All 4 assemblers/binner
combinations that were enabled reached MultiQC. No formal QC thresholds applied — this is a
CI-fixture-scale procurement smoke, not a scientific run; see the real-sample run's handoff
for the first measured, threshold-relevant result.

## Bounded choices

- Used the pipeline's own `-profile test` parameters verbatim (assembler/binner selection,
  mock DBs, `prokka_fast_mode`) — a procurement validation run, not a scientific analysis.
- Added `--skip_gtdbtk true` on top of the test profile so the same `cmd.sh` shape could be
  reused unmodified for the real-sample run (whose default GTDB-Tk DB is 60.8 GB and needs
  separate approval).

## Stub-run finding (procurement-relevant, not just this run)

`-stub-run -profile test,docker` fails at `CATPACK_DB_UNTAR` with `No such variable:
output_dir`. Root cause read directly from `modules/nf-core/untar/untar.diff` in the pinned
clone: mag carries a local patch to the shared `UNTAR` module that changes the `script:`
block's output variable to `${output_dir}` but never updates the `stub:` block, which still
only sets `prefix`. Confirmed the bug fires only when a `.tar.gz`/`.tgz` reference DB is
supplied (CAT/BUSCO/CheckM/geNomad) — the test profile does this deliberately to keep its
fixture data small; a default real run does not. **Waived, 5th documented departure** — see
`skills/bioinfo-analyze/references/runbook.md` section 4 and `SKILL.md`'s departures list,
both updated by this procurement.

## Next step for this record

Superseded by `runs/20260812-mag-drr027580-realsample/` for anything requiring real-data
numbers. Kept as the procurement-gate record.
