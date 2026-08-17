# Worked examples

Eleven real runs, kept as documentation of what a run record looks like. A full record in
`runs/<runid>/` is five files — `plan.md`, `samplesheet.csv`, `params.yaml`, `cmd.sh`, `handoff.md`
— but not every example carries all five: `20260804-rnaseq-scer-verify` passes its references on the
command line and so has no `params.yaml`, the two `-e` runs kept only `cmd.sh` and `handoff.md`, and
the three `-testprofile-procurement` runs (scratch procurement smokes, not run-record launches) kept
only `plan.md`/`handoff.md`. `20260812-taxprofiler-drr027580-realsample` additionally carries a
`databases.csv` — taxprofiler is the one stocked pipeline whose input is two CSVs, not one.

| Example | Shows |
|---|---|
| `20260804-rnaseq-scer-verify` | nf-core/rnaseq end to end on a small genome — the shortest complete record |
| `20260805-methylseq-sle-rrbs-smoke` | RRBS, and how a smoke run gets scoped before the full cohort |
| `20260805-scrnaseq-skin-cd3` | scRNA-seq, aligner-native QC rather than MultiQC |
| `20260806-chipseq-vsmc-h3k27me3-smoke` | ChIP-seq with input controls in the samplesheet |
| `20260807-rnaseq-testprofile-e` | a **failed** run, kept deliberately — STAR cannot create FIFOs on drvfs |
| `20260807-rnaseq-salmononly-e` | the same data completing via the pseudo-aligner path |
| `20260810-fetchngs-citest` | first run of nf-core/fetchngs on this host — headerless accession list, GSE/GEO resolution, and the discovery that `-stub-run` downloads real data for this pipeline |
| `20260812-mag-testprofile-procurement` | nf-core/mag CI-fixture run — `-stub-run` waived (`UNTAR`/`CATPACK_DB_UNTAR`), full test profile clean |
| `20260812-mag-drr027580-realsample` | nf-core/mag against a real shotgun metagenome — a shallow sample that assembles to no bins, a legitimate zero-bin outcome, not a defect |
| `20260812-taxprofiler-testprofile-procurement` | nf-core/taxprofiler CI-fixture run — `-stub-run` and full test profile both clean, no waiver needed (unlike ampliseq/mag) |
| `20260812-taxprofiler-drr027580-realsample` | nf-core/taxprofiler against the same real shotgun metagenome as the mag example — a `--databases` CSV (separate from `--input`), single-tool (Kraken2) procurement, and a 99%-unclassified real result on a shallow sample |
| `20260816-bacass-testprofile-procurement` | nf-core/bacass CI-fixture run — `-stub-run` waived (`UNICYCLER`, a hardcoded `cat ""` in the module's own stub script — a different shape of departure from every prior waiver), full test profile clean |
| `20260816-bacass-srr2589044-realsample` | nf-core/bacass against a real bacterial isolate WGS sample — comma-delimited `.csv` samplesheet despite the pipeline's own tab-delimited docs/CI fixture, and a measured QUAST/BUSCO/Prokka QC table for a single-organism de novo assembly |
| `20260816-sarek-revalidate2` | second re-verification of the (unchanged) nf-core/sarek 3.5.1 pin, this time against 8 further pipelines' worth of shared-infrastructure drift since the 2026-08-10 revalidation — all three §2.4 escalating tests clean, `check-samplesheet.sh`'s sarek branch untouched by any of the 8, and a real-sample `--step variant_calling` confirmatory run from the reused MarkDuplicates CRAM producing variant counts identical to both prior sarek runs on this sample |

`20260807-rnaseq-testprofile-e` and `20260807-rnaseq-salmononly-e` are the evidence behind the ext4
rule in `skills/bioinfo-analyze/references/runbook.md` section 1.

**Your own runs do not go here.** They land in `runs/`, which is gitignored — see the comment in
`.gitignore`. The agent reads that directory locally when planning, to notice a sample it has seen
before; nothing about it is pushed anywhere.
