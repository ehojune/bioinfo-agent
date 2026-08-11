# Plan — nf-core/taxprofiler first real-sample validation

RUNID: 20260812-taxprofiler-drr027580-realsample

## What this is

`new-pipeline.md` §2.8 step 2: one real sample, timed and measured, following the test-profile
pass (`20260812-taxprofiler-testprofile-procurement`, 24m 34s wall clock, 4.0 GB peak work dir,
`completed=179 failed=0` — all 14 profilers exercised clean; `-stub-run` separately passed
`completed=176 failed=0`, no waiver needed).

## Pin

nf-core/taxprofiler -r 2.0.1 (as `config/pipelines.tsv`).

## Sample

Sample count: 1. Reused, not re-downloaded: `DRR027580` (ENA run accession, BioProject
`PRJDB3255`, "fossil metagenome" per ENA's `scientific_name`), the same shotgun-metagenome
sample already staged at `/work/staging/mag-realsample/` (ext4) for mag's own real-sample
validation run (`runs/20260812-mag-drr027580-realsample/`). 436,115 paired-end read pairs
(~110 Mbp), gzip-integrity-checked already. Chosen originally for small download size, not
study relevance (no biological claim made about it); reused here to avoid a second download of
the same bytes, and because it is a genuine shotgun metagenome — the correct input shape for
taxprofiler as much as for mag.

## Classifier / database

**Single tool: Kraken2 only**, against a real (not toy) database — `db/kraken2/k2_standard_08gb`
(`config/refs.manifest.tsv`), the "Standard, capped at 8 GB" Kraken2 index (archaea + bacteria +
viral + plasmid + human + UniVec_Core), downloaded 5.96 GB, extracted to 8.0 GB. This is a
bounded choice: taxprofiler supports 14 profilers total, and this procurement stocks only the
one, deliberately, per the "lightest viable combination first" instruction — enabling more
tools, or a larger/GTDB-scale database for any of them, is future work with its own manifest row
and (for anything over ~10 GB) its own approval step. `--databases` CSV:

```csv
tool,db_name,db_path,db_params,db_type
kraken2,k2standard08gb,/refs/db/kraken2/k2_standard_08gb,,short
```

## Samplesheet

```csv
sample,run_accession,instrument_platform,fastq_1,fastq_2
DRR027580,DRR027580,ILLUMINA,/work/staging/mag-realsample/DRR027580_1.fastq.gz,/work/staging/mag-realsample/DRR027580_2.fastq.gz
```

`run_accession` set equal to `sample` since this is a single-run sample (no resequencing to
distinguish). `scripts/check-samplesheet.sh --deep --pipeline taxprofiler` on this sheet: all
checks OK, two informational WARNs carried over from the mag run's own notes on this same FASTQ
pair (non-Casava headers; R1 251bp vs R2 102bp read-length asymmetry, old 2013-era JGA/DDBJ data,
not a 10x swap) — not investigated further, out of scope for this procurement.

## Reference data behaviour

- Kraken2 DB: pre-fetched this run, see above and `config/refs.manifest.tsv`.
- No host-removal reference used (`--perform_shortread_hostremoval` left off / default) — this
  sample's `scientific_name` ("fossil metagenome") does not suggest human-host contamination the
  way a clinical gut sample would, and host removal is not this procurement's concern; can be
  added by a future user with `--hostremoval_reference` + `$BIOINFO_REFS/genomes/<build>`.
- Preprocessing QC (fastp) and complexity filtering left at their defaults (off) for this
  validation run, to isolate Kraken2's own behaviour — a production run would normally turn
  `--perform_shortread_qc true` on.

## Preflight / preview / stub

`-preview -profile docker --input samplesheet.csv --databases databases.csv --run_kraken2 true`:
clean, `completed=0 failed=0` (already verified above while building the checker).

`-stub-run` was ALSO run against this run's own real command — the actual `params.yaml`
(real samplesheet, real `--databases` pointing at the real 8 GB DB, `--run_kraken2 true` only,
no other 13 tools) — not just relying on the CI-fixture stub-run from the test-profile
procurement run, per Codex review on PR #36: a different samplesheet/database/tool-roster
topology is not proven by a different run's stub result. First attempt (no `-c
config/local.config`) failed with `Process requirement exceeds available memory -- req: 72 GB;
avail: 51 GB` — `KRAKEN2_KRAKEN2` is `process_high` (72 GB in the pipeline's own
`conf/base.config`), and without `local.config`'s `process.resourceLimits` clamp (18 cores/
40 GB) the raw request exceeded the WSL VM's 51 GB ceiling; this was a test-invocation gap, not
a pipeline defect. Re-run WITH `-c /mnt/d/bioinfo-agent/config/local.config` (matching this
run's actual `cmd.sh`) passed clean: `completed=3 failed=0`. Confirms — for THIS run's actual
topology, not just the CI fixture's — that no pipeline-level stub gap exists for taxprofiler,
unlike ampliseq/mag.

`bin/preflight.sh` run below; disk estimate 5 GB (generous — the CI test profile itself peaked
at 4.0 GB with 14 tools and larger toy DBs; this run has one tool and ~92 MB of reads).

## Command

`-profile docker` (no `test` profile — this is the real invocation shape). `params.yaml`:

```yaml
input: /mnt/d/bioinfo-agent/runs/20260812-taxprofiler-drr027580-realsample/samplesheet.csv
databases: /mnt/d/bioinfo-agent/runs/20260812-taxprofiler-drr027580-realsample/databases.csv
run_kraken2: true
```

## Estimate

No prior real-sample measurement for taxprofiler on this host (this run produces the first).
Basis: test-profile peaked at 4.0 GB / 24m 34s running **all 14 profilers** against 4 tiny CI
fixtures with database-load overhead per tool. This run enables **one** tool (Kraken2) against
**one** real sample with ~110 Mbp of sequence — Kraken2 classification itself is fast (a few
minutes for this read count against an 8 GB k-mer index once loaded); the dominant one-off cost
is loading the 8 GB `hash.k2d` into memory on first use. Rough estimate: <=30 min wall clock,
<=5 GB peak work dir. Well inside the 24 h approval rule; `/work` has >300 GB free, clears 1.5x
by a wide margin. If actual wall clock or disk diverges substantially from this estimate
partway through, this plan gets revisited before continuing.

## Bounded choices

- **Sample reuse**: DRR027580, chosen originally by mag's own download-size search, reused here
  to avoid downloading the same bytes twice — not a claim of study relevance for taxprofiler
  either.
- **Single-tool procurement (Kraken2 only)**: stated above — the lightest real (non-toy)
  classification option, not the full 14-tool roster. A future run enabling more tools needs its
  own manifest rows and, for anything sizeable, its own approval.
- **`db/kraken2/k2_standard_08gb` over a larger/more comprehensive Kraken2 build**: 5.96 GB
  download, under the ~10 GB no-ask threshold and chosen specifically to stay under it, at the
  cost of coarser/older taxonomic resolution than a full `k2_core_nt`-scale build (~150 GB,
  explicitly not fetched).
- **No host removal, no read QC/complexity filtering enabled**: isolates Kraken2's own behaviour
  for this validation run; a production run of this pipeline would normally turn these on.

## Approval

Auto mode / autonomous procurement task — proceeding per the user's explicit instruction. Time
and disk estimates are both well under the escalation thresholds (24 h wall clock; disk gated
procedurally by `bin/preflight.sh`'s 1.5x check), so no separate approval checkpoint applies here
beyond what preflight enforces mechanically. The one download in this procurement (the 5.96 GB
Kraken2 DB tarball) is under the ~10 GB no-ask threshold and is recorded above and in
`config/refs.manifest.tsv`.
