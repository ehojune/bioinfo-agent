# taxprofiler

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** No registered stub waiver. Preview and the full-command stub must pass; missing upstream stubs can execute real work.
- **Evidence lookup:** [procurement record](evidence/taxprofiler.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** shotgun metagenome sequencing (short-read Illumina, long-read ONT/PacBio, or a mix)
→ optional read QC (fastp/AdapterRemoval2, complexity filtering, host removal, run-merging) →
taxonomic classification/profiling with any combination of up to 14 tools (Kraken2, Bracken,
KrakenUniq, Centrifuge, DIAMOND, Kaiju, MALT, MetaPhlAn, mOTUs, KMCP, ganon, sylph, Melon,
metacache) → per-tool taxon tables, standardised/merged across tools (taxpasta), optional
Krona plots. No assembly step anywhere in the DAG.

**Not for:** genome recovery (no assembly, no binning, no MAGs — that is `nf-core/mag`,
`references/pipelines/mag.md`: pick mag when the question is "recover genomes from this community", taxprofiler when
it is "what taxa, and roughly how much of each"). Not for amplicon sequencing (`nf-core/
ampliseq`, `references/pipelines/ampliseq.md`). Running taxprofiler does not substitute for mag and vice versa — they
answer different questions from the same kind of raw data, and the same FASTQ can legitimately
go through both.

**Minimum input:** **two** CSVs, not one.

- `--input samplesheet.csv` — `assets/schema_input.json` (2.0.1) requires `sample` +
  `run_accession` + `instrument_platform` on every row (`instrument_platform` is a closed
  enum — `ILLUMINA`, `OXFORD_NANOPORE`, `PACBIO_SMRT`, and 8 others). **`fastq_1`, `fastq_2`,
  and `fasta` are all schema-OPTIONAL** — a row with none of them validates cleanly
  (empirically confirmed via `-preview`, `completed=0 failed=0`, no error), which means the
  schema alone will not catch a metadata-only row with nothing to actually profile;
  `scripts/check-samplesheet.sh --pipeline taxprofiler` hard-fails on that shape rather than
  passing it through. `uniqueEntries [sample, run_accession]` is a **composite** key (same
  shape as mag's `[sample, run]`, empirically confirmed 2026-08-12: same `sample` with a
  different `run_accession` passes — this is exactly how the pipeline represents "same
  biological sample, multiple sequencing runs" for `--perform_runmerging`). Separately,
  **`fastq_1`, `fastq_2`, and `fasta` are each their OWN per-field `uniqueEntries`
  constraint** — reusing one FASTQ path across two sheet rows is a hard schema failure here,
  unlike mag or rnaseq where that is unremarkable.
- `--databases databases.csv` — `assets/schema_database.json` requires `tool` (enum: the 14
  names above, plus `bracken`) + `db_name` + `db_path` per row; `db_params`/`db_type`
  optional. This is where the actual classifier database gets wired in, and it is what
  decides both cost (some DBs are GBs, some are 100s of GB) and which `--run_<tool>` flags do
  anything — a `--run_kraken2 true` with no `kraken2` row in `--databases` is a no-op, not an
  error caught early.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--run_<tool>` (one per profiler, e.g. `--run_kraken2`) | `true` only for tools that have a matching row in `--databases` | off by default for all 14; turning one on with no matching database row silently does nothing useful |
| `--databases` | one row per `(tool, db_name)` you actually want run | see above — the CSV, not the `--run_*` flags, is what actually points at a database |
| `--perform_shortread_qc` / `--perform_longread_qc` | `true` for anything but a pre-cleaned fixture | off by default; raw reads straight into a classifier inflate false-positive low-abundance calls |
| `--perform_shortread_hostremoval` / `--hostremoval_reference` | `true` + a host FASTA for a human/host-associated sample | off by default; without it, host reads are classified too and dominate a human-gut-style sample |
| `--perform_runmerging` | `true` when `run_accession` values represent re-sequencing of the same `sample`, not independent samples | off by default; without it, per-run profiles are not merged even though the composite key says they are related |
| `--run_profile_standardisation` | `true` if comparing across tools | standardises taxon tables to one schema (taxpasta) across profilers — off by default, each tool's native format otherwise |

**Reference-store paths:** `db/kraken2/k2_standard_08gb/` — the ONE profiler DB this
procurement stocks (`config/refs.manifest.tsv`), a RAM-capped Kraken2 standard index
(archaea+bacteria+viral+plasmid+human+UniVec_Core, 5.96 GB download, 8.0 GB extracted),
chosen deliberately as the single lightest real-classification option over the ~150 GB
`k2_core_nt`/`k2_nt` builds or a multi-tool combination. **No other profiler's database is
pre-provisioned.** Enabling MetaPhlAn, MALT, GTDB-scale Kraken2/KrakenUniq builds, or any
other profiler at production scale is a new `fetch`-mode manifest row and, for anything over
~10 GB, a download that needs the user's approval first — same discipline as mag's
`--skip_gtdbtk` default.

**Known gaps / stub-run behaviour:** none. `-stub-run` on `-profile test,docker` **passes
end to end** (`completed=176 failed=0 cached=0`, all 14 profilers exercised against the CI
fixture databases) — no waiver needed, unlike ampliseq's `CUTADAPT_BASIC` gap or mag's
`UNTAR`/`CATPACK_DB_UNTAR` gap. This is the first of the three microbiome pipelines stocked
here where the shipped `stub:` coverage is actually complete enough to trust as a pre-launch
gate on its own. The full `-profile test,docker` run also passes clean (`completed=179
failed=0`, ~24.5 min wall clock, 4.0 GB peak work dir — see `references/estimates.md`). A
CI-fixture stub pass does not by itself prove a different real-command topology (different
samplesheet, database, and tool selection) — confirmed separately by re-running `-stub-run`
against the actual real-sample `params.yaml`/`--databases`/single-tool shape before that run's
launch (`runs/20260812-taxprofiler-drr027580-realsample/plan.md`), which also passed clean once
`-c config/local.config` was included (the pool's `resourceLimits` clamp — omitting it makes
`KRAKEN2_KRAKEN2`'s `process_high` 72 GB request exceed the raw 51 GB WSL VM ceiling, a
test-invocation gap unrelated to taxprofiler's own stub coverage).

**Key outputs:** per-sample, per-tool raw profiler output (`<tool>/<db_name>/`), per-tool
merged/standardised taxon tables (`<tool>/<db_name>/*.{tsv,csv,biom}` via taxpasta when
`--run_profile_standardisation` is on), optional Krona HTML plots, MultiQC (FastQC/fastp/
host-removal/profiler summary stats — no per-taxon abundance interpretation in MultiQC
itself).

**QC verdict checklist:** percent reads classified vs unclassified per sample per tool (from
each profiler's own report, e.g. Kraken2's `.kreport2` unclassified line); host-removal
percentage if `--perform_shortread_hostremoval` is on; agreement/disagreement between tools
when more than one profiler is run on the same sample (`run_profile_standardisation` output
makes this comparable). **No formal QC band exists yet** — the one real-sample run so far
(`runs/20260812-taxprofiler-drr027580-realsample/`, DRR027580, the same 436K-read-pair
"fossil metagenome" sample used for mag's real-sample validation, single tool: Kraken2
against the 8 GB-capped standard DB, ~47s wall clock, 9.7 MB peak work dir, peak single-process
RAM 7.8 GB dominated by loading the DB itself) establishes only that the pipeline runs end to
end against real data with a real reference database and produces real (if 99.07% unclassified)
per-taxon output; it does not establish what a normal percent-classified range looks like for
this sample type — this sample is a known outlier (mag's own real-sample run on the identical
reads assembled to only 74 short contigs), but the CAUSE of the near-total-unclassified Kraken2
result is unresolved, not established: a shallow/low-diversity input and a database that simply
lacks coverage for this sample's actual content are both consistent with the same observation,
and only one database was tested against one sample. Not a pipeline defect either way — the
pipeline ran correctly and produced a real, if hard-to-interpret, result. A run against a sample
with known community composition, or a second real sample/database for comparison, is what
would start that band and what would actually distinguish the two explanations.
