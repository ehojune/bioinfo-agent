# Plan — nf-core/mag procurement + first validation run

RUNID: 20260812-mag-testprofile-procurement

## What this is

Procurement of nf-core/mag per `skills/bioinfo-analyze/references/new-pipeline.md`.
Not yet stocked in `config/pipelines.tsv`. This run is section 2.4(c) of that procedure
(full `-profile test` on the bundled dataset) — the first, minutes-scale gate before a
real single sample, per section 2.8's scale-up discipline. Same precedent as ampliseq's
`20260810-ampliseq-testprofile-procurement`.

## Pin

nf-core/mag -r 5.5.0 (latest stable, released 2026-08-01, not archived, star count high —
"별점 최고" per the task brief). Verified via `https://api.github.com/repos/nf-core/mag/releases/latest`
and `nextflow info nf-core/mag`. Requires `nextflowVersion = '!>=26.04.0'`; installed
Nextflow is `26.04.6.12646` — satisfies it.

## Evaluation so far

- `nextflow config` / `--help`: resolve cleanly.
- `-preview -profile test,docker --skip_gtdbtk true`: clean, `completed=0 failed=0`, DAG
  resolves, no schema errors.
- `-stub-run -profile test,docker --skip_gtdbtk true`: FAILS at `CATPACK_DB_UNTAR` (and would
  also fail at `BUSCO_UNTAR` if reached), both instances of the shared `UNTAR` module, with
  `No such variable: output_dir`. Read `modules/nf-core/untar/main.nf` in the pinned clone:
  mag carries a **local patch** (`modules/nf-core/untar/untar.diff`) that changes the
  `script:` block's output variable from `${prefix}` to `${output_dir}` (and adds a
  `basedir`/`output_dir` computation) but never touches the `stub:` block, which still only
  sets `prefix`. The `output:` declaration (`path("${output_dir}")`) is shared by both
  blocks, so under `-stub-run` it throws before the stub body ever executes — a self-inflicted
  bug in mag's own module patch, not something this repo's config caused and not something
  this repo can fix (editing `$NXF_ASSETS` is forbidden, and this is a pinned upstream clone).
  **Waived, documented departure (5th on this host** — the 4 in `runbook.md` section 4 plus
  this one; `SKILL.md`'s "only these four" line updated to five in this change**)** — same
  shape as ampliseq's `CUTADAPT_BASIC` case: `-preview` is clean, and no stub-input
  substitution can route around it because the crash is in the output declaration itself,
  before any process logic runs.
  - **Scope of the bug, confirmed by reading the call sites**: `UNTAR` is only invoked when a
    `.tar.gz`/`.tgz` reference database is supplied for CAT (`--cat_db`), BUSCO
    (`--busco_db`), CheckM (`--run_checkm` with no local `--checkm_db`), or virus
    identification (`--genomad_db`, gated behind `--run_virus_identification`, off by
    default). The **test profile** exercises it because it supplies small mock tarballs for
    `cat_db` and `busco_db` to keep the fixture data small. A **default real run** — no
    `cat_db`, BUSCO left on its default `auto` lineage (which downloads its own DB directly,
    not via `UNTAR`), CheckM/virus-ID off — never calls `UNTAR` at all, so this bug does not
    block ordinary real-sample validation.

## Reference data behaviour

The test profile ships its own small mock databases (bacteria BUSCO lineage, GTDB-Tk mockup
r232, CAT minigut) fetched from `nf-core/test-datasets` at run time — all well under the
~10 GB approval threshold. No local reference-store rows needed for the test profile itself.

**`--skip_gtdbtk true` is added on top of the test profile's own params, not part of it.**
The test profile's own `gtdb_db` points at a small mockup tarball, so leaving GTDB-Tk on
would be cheap in the test profile specifically — but the flag is added here anyway so the
exact same `cmd.sh` shape can be reused unmodified for the real-sample run, where GTDB-Tk's
*default* database (`gtdb_db`'s pipeline default) is a measured 60.8 GB download
(`content-length` on `https://data.gtdb.aau.ecogenomic.org/.../gtdbtk_r232_data.tar.gz`,
checked via `curl -sI`) — far over the ~10 GB no-ask threshold, so GTDB-Tk stays off by
default at this pin until the user asks for taxonomic classification and approves that
download explicitly.

## Command

`-profile test,docker` plus `--skip_gtdbtk true` (see above). Uses the pipeline's own bundled
`test_minigut` samplesheet from `nf-core/test-datasets` — no local samplesheet needed.

## Estimate

No prior measurement on this host for mag (first run). `conf/test.config` caps resources at
4 CPUs / 15 GB / 1 h per process and is designed to finish in well under an hour on CI
runners. This host gives it up to the pool ceiling (18 cores / 40 GB). Estimate: <=1 h wall
clock, <=15 GB peak work dir. Well inside the 24 h approval rule; `/work` has hundreds of GB
free, easily clears 1.5x.

## Bounded choices

- Using the pipeline's OWN `-profile test` parameters verbatim (assembler/binner selection,
  BUSCO/CAT/GTDB-Tk mock DBs, `prokka_fast_mode`) rather than picking my own — this is a
  procurement validation run, not a scientific analysis.
- Adding `--skip_gtdbtk true` on top of the test profile, for the reason stated above (keeps
  `cmd.sh`'s shape reusable for the real-sample run, where the default GTDB-Tk DB is a 60.8 GB
  download that needs separate approval).
- Waiving the `CATPACK_DB_UNTAR`/`UNTAR` stub failure per the evidence above rather than
  blocking on a self-inflicted upstream module-patch bug outside this repo's control.

## Preflight note

`bin/preflight.sh` reports one FAIL on this run: `input MISSING` against a path-shaped token
inside `samplesheet.csv`'s explanatory comment (`mag/samplesheets/samplesheet.multirun.v4.csv`).
This is a known false positive for a `-profile test` procurement run: there is no real
`--input` (the test profile supplies its own remote samplesheet), so `samplesheet.csv` is a
documentation stub, not a real sheet — same shape and same FAIL as
`20260810-ampliseq-testprofile-procurement`. Every other preflight section is clean (docker,
ext4 work dir, 1.5x disk, revision pin, stocked-set match, no concurrent run). Proceeding past
this one FAIL for this test-profile-only launch; the real-sample run below gets a genuine
local samplesheet and must pass preflight with zero FAILs.

## Approval

Auto mode / autonomous procurement task — proceeding per user's explicit instruction to run
this pipeline through to first validation without per-step confirmation.
