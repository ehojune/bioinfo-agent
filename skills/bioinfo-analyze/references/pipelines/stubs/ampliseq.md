# ampliseq: exact stub gate

Read only for this pipeline, after [common stub isolation](../../runbook.md#4-preview-then-stub).
This is a partial gate at the documented revision, never permission to waive another error.
Re-check the pin in `config/pipelines.tsv`; a version change requires fresh evidence.

**`nf-core/ampliseq`, `-stub-run`, and `CUTADAPT_BASIC` — a true waiver, upstream module bug.**
Confirmed 2026-08-10 (`20260810-ampliseq-testprofile-procurement`) against the pin this file's own
table names, `2.18.0` (commit `2723d4c298d48321594920d0324697e14d73ee94`). `-stub-run -profile
test,docker` fails immediately with `No such variable: outformat`. Read
`modules/nf-core/cutadapt/main.nf` in the pinned clone: the `output:` block references
`outformat`, a variable the `script:` block assigns (`outformat = task.ext.outformat ?: "fastq"`)
but the `stub:` block never sets — the output declaration throws before the stub body ever runs.
This is an upstream nf-core/modules defect in the CUTADAPT module's stub, not a wiring problem
introduced by this repo's config, and there is no substitute-input workaround: the crash happens
before any process logic executes, so no stub params file can route around it the way the
differentialabundance `--features` case does. **Waived as a true stub failure** — `-preview
-profile test,docker` (clean, `completed=0 failed=0`) is the only pre-launch gate this pipeline
gets; the real command (exercised by the run itself, `completed=113 failed=0 cached=12`) is what
actually proves `CUTADAPT_BASIC` and everything downstream of it.
