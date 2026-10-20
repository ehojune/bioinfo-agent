# mag: exact stub gate

Read only for this pipeline, after [common stub isolation](../../runbook.md#4-preview-then-stub).
This is a partial gate at the documented revision, never permission to waive another error.
Re-check the pin in `config/pipelines.tsv`; a version change requires fresh evidence.

**`nf-core/mag`, `-stub-run`, and two independent findings at this pin's `5.5.0`.** Confirmed
2026-08-12 (`20260812-mag-testprofile-procurement`, `20260812-mag-drr027580-realsample`) against
commit `56abab5b023ce953c9c43fe21090d156ad0e18af`.

*Finding 1 — a true waiver, upstream-in-mag module-patch bug, same shape as the
[ampliseq case](ampliseq.md).* `-stub-run -profile test,docker --skip_gtdbtk true` fails at `CATPACK_DB_UNTAR` with
`No such variable: output_dir`. Read `modules/nf-core/untar/untar.diff` in the pinned clone: mag
carries a **local patch** to the shared `UNTAR` module that changes the `script:` block's output
variable from `${prefix}` to `${output_dir}` (and adds a `basedir`/`output_dir` computation) but
never updates the `stub:` block, which still only sets `prefix`. The `output:` declaration
(`path("${output_dir}")`) is shared by both blocks, so it throws before the stub body ever runs —
the crash happens before any process logic executes, exactly like `CUTADAPT_BASIC` in the ampliseq stub card, so there
is no substitute-input workaround. **Scope, confirmed by reading every call site
(`grep -rn UNTAR workflows/ subworkflows/`)**: `UNTAR` is only invoked when a `.tar.gz`/`.tgz`
reference database is supplied for CAT (`--cat_db`), BUSCO (`--busco_db`), CheckM (`--run_checkm`
with no local `--checkm_db`), or virus identification (`--genomad_db`, gated behind
`--run_virus_identification`, off by default). The **test profile** exercises it because it
supplies small mock tarballs for `cat_db` and `busco_db` to keep CI fixture data small; a
**default real run** — no `cat_db`, BUSCO left on its default `auto` lineage (which downloads its
own DB directly, not via `UNTAR`), CheckM/virus-ID off — never calls `UNTAR` at all. **Waived, 5th
documented departure** — `-preview` is clean; the real command is what actually proves this
pipeline, same reasoning as the ampliseq case.

*Finding 2 — broader and more consequential, and a different shape from every prior departure in
this section: not one process, a structural property of mag's own module set.*
`grep -rL --include='main.nf' 'stub:' <clone>/modules/local/` finds **20 of mag's 23 local
(non-nf-core-catalog) modules have no `stub:` block at all** — including `bowtie2_removal_align`
(the module that does phiX/host read removal), `bowtie2_assembly_build`/`bowtie2_assembly_align`
(binning-prep mapping), and both `quast_run`/`quast_bins`. Per Nextflow's documented no-stub
fallback (same mechanism already recorded for the fetchngs 1.12.0 card), each of these runs its real
`script:` under `-stub-run`. `FASTP` (an nf-core-catalog module, stubbed) writes
`echo '' | gzip > *.fastp.fastq.gz` — a technically-valid, empty gzip stream, zero FASTQ records —
and `BOWTIE2_REMOVAL_ALIGN` then runs bowtie2 for real against it and aborts (exit 134,
`Error: reads file does not look like a FASTQ file`, confirmed by reading the bowtie2 log in the
stub work dir). This fires on **any** samplesheet with the default phiX removal on (i.e. almost
every real invocation), independent of what data is supplied — a from-FASTQ real-command stub
cannot get past `SHORTREAD_PREPROCESSING` without hitting it. Passing `--keep_phix true` for the
stub only (a legitimate stub-only substitute, same category as sarek's `--skip_tools` addition
below) routes around that one process and the stub proceeds four more stages, then dies again the
same way at `BOWTIE2_ASSEMBLY_BUILD`/`QUAST` on MEGAHIT's own empty stub contigs file. **This is
not a single bug to route around** — it is a chain, and no finite sequence of stub-only
substitutions clears the whole DAG, because the next unstubbed consumer of the next stubbed
process's placeholder output is always one more hop away. Treating `-stub-run` as authoritative
for mag beyond `SHORTREAD_PREPROCESSING` means an unbounded chase for a gate that fundamentally
cannot certify the parts of the pipeline that matter most (assembly, binning, bin QC). **Not a
waiver in the same sense as the other four departures — there is no single failing assertion to
waive.** Resolution: `-preview` (clean) is the pre-launch gate this pipeline actually gets past
`SHORTREAD_PREPROCESSING`, exactly the precedent already set for fetchngs's own no-stub download
modules; the real command is what proves the rest, and the first real run
(`20260812-mag-drr027580-realsample`, `completed=19 failed=2 cached=0`, both failures tolerated —
see that run's `handoff.md`) is that proof for this pin.
