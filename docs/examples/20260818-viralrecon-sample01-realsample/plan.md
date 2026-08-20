# Plan — 20260818-viralrecon-sample01-realsample

Pipeline: nf-core/viralrecon -r 3.0.0 (same pin as `config/pipelines.tsv`). One sample.

Companion to `runs/20260818-viralrecon-testprofile-procurement/plan.md` (pipeline choice,
schema-drift check, scope rationale, and the `raw.githubusercontent.com` environment finding are
all there, not repeated in full here). This plan covers the ONE real sample required by
`new-pipeline.md` §2.8 scale-up discipline before wider stocking.

## Sample
`SAMPLE_01` from nf-core/viralrecon's own `conf/test_full.config` cohort (the pipeline's own
48-sample real-world validation set, S3-hosted at `s3://ngi-igenomes/test-data/viralrecon/
210212_K00102_0557_AHKN3LBBXY/fastq/`). Chosen over an ad hoc SRA/ENA pick specifically because
`test_full.config` pins `primer_set_version = 3` for this exact cohort — the ARTIC primer scheme
used in library prep is therefore KNOWN and protocol-confirmed, unlike an arbitrary SRA/ENA
amplicon deposit where the wet-lab primer version is frequently undocumented in the run
metadata (checked: ENA candidate `ERR11728471`/`PRJEB45305`, a Slovak national SARS-CoV-2
surveillance run, had no primer-scheme field in either its study or sample XML).

`GOL2051A67473_S133_L002_{R1,R2}_001.fastq.gz`, Illumina HiSeq/NovaSeq-style paired-end,
65,133,308 + 72,631,211 bytes gzip (~132 MiB total) — disclosed before download, no approval
needed (well under the ~10 GB ceiling). One sample only, per §2.8 ("one real sample, timed and
measured" before any wider cohort commitment).

## Command
`--platform illumina --protocol amplicon --skip_assembly true`, `--fasta`/`--gff` at
`$BIOINFO_REFS` standard paths, `--primer_bed
/refs/genomes/SARS-CoV-2-MN908947.3/primer/artic-v3/primer.bed` (V3, matching the
protocol-confirmed scheme above — NOT this repo's V4.1 row, which is stocked for a future
V4.1-protocol sample), `--pango_database /refs/db/pangolin`, `--nextclade_dataset
/refs/db/nextclade/sars-cov-2 --nextclade_dataset_name sars-cov-2`, `--freyja_barcodes
/refs/db/freyja/usher_barcodes.feather --freyja_lineages /refs/db/freyja/curated_lineages.json
--freyja_repeats 10 --skip_freyja_boot true`, `--kraken2_db
/refs/db/kraken2_viralrecon_human/kraken2_human`. `--custom_config_base` is NOT needed here
(unlike the test-profile run) — this run does not use `--genome`, so `main.nf`'s
`getGenomeAttribute()` calls all resolve against an empty `params.genomes` map and return `''`,
which the explicit CLI/params-file values for `--fasta`/`--gff`/`--primer_bed`/
`--nextclade_dataset`/`--pango_database` above override regardless (confirmed empirically via
`-preview` during the test-profile procurement — CLI-set params win over the script's own
internal reassignment).

## Estimate and disk
Test-profile CI fixture (3 tiny samples, ~13 MB total FASTQ) took ~23 min wall clock end-to-end
(`completed=187 failed=0 cached=8`, resumed once after the Freyja-barcode fix) with a 333 MB
peak work-dir and 82 MB results — see `runs/20260818-viralrecon-testprofile-procurement/`. This
real sample is ~10x the FASTQ volume of one CI sample and skips the assembly branch (this CI run
did NOT skip it, so this run has strictly fewer processes per sample), so a low double-digit
minutes wall clock and a peak work dir in the low single-digit GB is expected — both comfortably
under the 24 h approval threshold; no approval needed. `D:` ext4 VHDX ~1.3 TB free, `/` ext4 root
145 GB free at last check — more than 1.5x either figure by a wide margin.

## Bounded choices
Same five as the companion plan.md, plus: ARTIC V3 (not V4.1) selected specifically because it
is the protocol-confirmed scheme for this sample (see "Sample" above) — not a default, a
per-run match to the actual wet-lab protocol.

## Test plan
`-preview` only (no repeat `-stub-run`): the pipeline's process graph and stub-mode behaviour
were already exercised end-to-end by the companion test-profile run above on the identical
pipeline pin; this run changes parameter VALUES (skip_assembly, primer scheme, database paths)
but not the code path in any way `-stub-run` would newly exercise. `-preview` catches any
parameter-resolution mistake specific to this run's own flag set before real compute starts.
