# Plan — nf-core/mag first real-sample validation

RUNID: 20260812-mag-drr027580-realsample

## What this is

Section 2.8 step 2 of `new-pipeline.md`'s scale-up discipline: one real sample, timed and
measured, following the test-profile pass (`20260812-mag-testprofile-procurement`,
27m 46s wall clock, 2.2 GB peak work dir, `completed=179 failed=1` — the 1 failure is
MaxBin2 exit 255, which mag's own `conf/base.config` marks `errorStrategy 'ignore'` for
exactly that exit code; the pipeline's own completion banner
("Pipeline completed successfully, but with errored process(es)") confirms this is
tolerated, not a real failure).

## Pin

nf-core/mag -r 5.5.0 (as `config/pipelines.tsv`).

## Sample

Sample count: 1. Single-end library layout is not used — paired-end Illumina shotgun
metagenome, no long reads. `ENA` run accession `DRR027580` (BioProject `PRJDB3255`,
"fossil metagenome" per ENA's `scientific_name`), chosen by searching ENA's portal API for
the smallest `library_strategy=WGS AND library_source=METAGENOMIC AND
instrument_platform=ILLUMINA AND library_layout=PAIRED` runs with a non-trivial read count
(`https://www.ebi.ac.uk/ena/portal/api/search`, sorted by `fastq_bytes` ascending):
436,115 read pairs, ~110 Mbp total, ~92 MB gzipped combined (47 MB + 45 MB). Downloaded from
`ftp://ftp.sra.ebi.ac.uk/vol1/fastq/DRR027/DRR027580/` to
`/work/staging/mag-realsample/` (ext4, not `/mnt/d`) and gzip-integrity-checked
(`gzip -t`, both files OK). This is a genuine ENA-hosted biological sample, not a CI
fixture — chosen for size, not for study relevance; no biological claim is made about it.

**Read-length asymmetry, noted not investigated**: `scripts/check-samplesheet.sh --deep`
flags R1=251 bp vs R2=102 bp as a WARN (its 10x-swap heuristic). This is old (2013-era JGA/
DDBJ) sequencing data, not 10x Chromium data, so the heuristic does not apply; not
investigated further since it is outside this procurement's scope (mechanical pipeline
validation, not sequencing-QC archaeology of a fixture sample).

## Reference data behaviour

- PhiX removal (default on): bundled reference in the pipeline's own `assets/`, no
  download.
- BUSCO (`run_busco` default `true`, `busco_db_lineage: auto`): downloads its own lineage
  dataset directly (not through the buggy `UNTAR` path — see below), typically tens to a
  few hundred MB; not pre-staged, allowed under the ~10 GB no-ask threshold.
- GTDB-Tk, CheckM/CheckM2, CAT, geNomad: all off (defaults or explicit skip below). GTDB-Tk's
  *default* database is a measured 60.8 GB download (`curl -sI` on the pipeline's default
  `gtdb_db` URL, confirmed during procurement) — well over the no-ask threshold, so
  `--skip_gtdbtk true` stays in this run. No manifest rows added this run; nothing here
  needed one.

## Preflight / preview / stub

`bin/preflight.sh runs/20260812-mag-drr027580-realsample 20`: **0 failures**, 2 warnings (both
informational — plan.md's sample-count phrasing, and "no `/refs` path referenced" since this
run needs no reference-store row). `-preview -profile docker`: clean, `completed=0 failed=0`.

**`-stub-run` is not a usable gate beyond the first few stages of this pipeline, for a
structural reason distinct from the UNTAR/CATPACK bug already recorded against this pin in
`runbook.md` section 4.** `grep -rL --include='main.nf' 'stub:' <clone>/modules/local/` finds
**20 of mag's 23 local (non-nf-core-catalog) modules carry no `stub:` block at all** —
including `bowtie2_removal_align` (phiX/host read removal), `bowtie2_assembly_build`/
`bowtie2_assembly_align` (binning-prep mapping), and both `quast_run`/`quast_bins`. Per
Nextflow's documented fallback (same shape already recorded for fetchngs 1.12.0 in
`runbook.md` section 4), a process with no `stub:` block runs its real `script:` under
`-stub-run`. `FASTP` (an nf-core-catalog module) *does* have a stub, and that stub writes
`echo '' | gzip > *.fastp.fastq.gz` — a technically-valid but empty gzip stream, zero FASTQ
records. `BOWTIE2_REMOVAL_ALIGN` then runs for real against that placeholder and Bowtie2
aborts (exit 134, `Error: reads file does not look like a FASTQ file`, confirmed by reading
`.command.err`/the bowtie2 log in the stub work dir). Passing `--keep_phix true` for the
stub only (a legitimate stub-only substitute, same category as sarek's `--skip_tools`
addition in `runbook.md` section 4 — not carried into the real command below) routes around
that one process and the stub proceeds four more stages, then dies again the same way at
`BOWTIE2_ASSEMBLY_BUILD`/`QUAST` on MEGAHIT's own empty stub contigs file. This is not one
isolated bug to route around (the ampliseq/UNTAR shape); it is mag's *local* module set
being broadly unstubbed, so every hop between an unstubbed process and its next unstubbed
consumer is a new potential crash site with a new work-dir to diagnose, and no finite set of
stub-only substitutions clears the whole DAG. **Treating `-stub-run` as authoritative for
this pipeline beyond `SHORTREAD_PREPROCESSING` would mean an unbounded chase of stub-only
workarounds for a gate that fundamentally cannot certify the parts of the pipeline that
matter most (assembly, binning, bin QC).**

**Resolution, following the fetchngs precedent exactly**: `-preview` (clean) is the pre-launch
gate this pipeline actually gets, same as fetchngs and ampliseq before it. The real command
below is what proves `SHORTREAD_PREPROCESSING` end to end (host/phiX removal), assembly,
binning-prep, binning, and bin QC — none of which any stub attempt reached cleanly. Not
re-attempting further stub-only substitutions past the two above; the incremental diagnostic
value of a third stub-only patch is near zero (it would prove wiring one more hop, at the
cost of another crash-diagnosis cycle) against the cost of just running the real, already
preflighted, already time/disk-bounded command.

## Command

`-profile docker` (no `test` profile this time — this is the real invocation shape a future
user would run). `params.yaml`:

```yaml
input: /mnt/d/bioinfo-agent/runs/20260812-mag-drr027580-realsample/samplesheet.csv
skip_gtdbtk: true
skip_spades: true
skip_concoct: true
skip_comebin: true
skip_metabinner: true
skip_ale: true
```

## Estimate

No prior real-sample measurement for mag on this host (this run produces the first). Basis:
test-profile peaked at 2.2 GB / 27m 46s on ~4 tiny CI-fixture samples with resources capped
at 4 CPU/15 GB/process by `conf/test.config`; this run gets the full pool (18 cores/40 GB)
and one sample with ~110 Mbp of real short-read data (roughly two orders of magnitude more
sequence than the fixture). Rough estimate: <=3 h wall clock, <=20 GB peak work dir — MEGAHIT
assembly of ~110 Mbp is normally a matter of minutes, and with SPAdes/CONCOCT/COMEBin/
MetaBinner/ALE all skipped (see bounded choices) the remaining heavy steps are MEGAHIT,
Bowtie2 mapping, MetaBAT2/MaxBin2/SemiBin2 binning, BUSCO, and Prokka — all of which
completed quickly on the much-smaller test data. Well inside the 24 h approval rule; `/work`
has 343 GB free, clears 1.5x by a wide margin. **If actual wall clock or work-dir size
diverges substantially from this estimate partway through, this plan gets revisited before
continuing** rather than assumed correct to the end.

## Bounded choices

- **Sample selection**: picked for small download size via an ENA API size sort, not for
  any experimental relevance — stated explicitly, per the "say every bounded choice" rule.
- **`skip_spades: true`**: single assembler (MEGAHIT only) to bound runtime for this
  validation run. A production run of mag would typically run both and compare; skipping
  SPAdes here is a time-bound choice, not a claim MEGAHIT is sufficient in general.
- **`skip_concoct/comebin/metabinner: true`**: keeps MetaBAT2 + MaxBin2 + SemiBin2 as the
  binners exercised (same three that ran clean, modulo the tolerated MaxBin2 exit-255
  ignore, in the test-profile run) — mirrors the pipeline's own `conf/test.config` choice to
  bound CI runtime, applied here for the same reason.
- **`skip_ale: true`**: ALE needs properly paired-end reads in a shape the pipeline's own
  test.config comment says its fixture reads do not have; not verified whether DRR027580
  would hit the same issue, so skipped defensively rather than risking a late failure deep
  into a multi-hour run.
- **`skip_gtdbtk: true`**: stated above — avoids an unapproved 60.8 GB download.
- **BUSCO left at its default `auto` lineage** rather than pinned to a specific one — this
  is a validation run, not a run whose BUSCO lineage choice needs to be reproducible science.

## Approval

Auto mode / autonomous procurement task — proceeding per user's explicit instruction. Time
and disk estimates are both well under the escalation thresholds (24 h wall clock, and disk
is gated procedurally by `bin/preflight.sh`'s 1.5x check), so no separate approval checkpoint
applies here beyond what preflight enforces mechanically.
