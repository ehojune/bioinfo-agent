# taxprofiler: procurement record

Lookup only. Preserved from `config/pipelines.tsv` when the routing table was split.
These dated observations describe the recorded host and runs; verify current pins, files,
resources and upstream behavior before reuse. A completed workflow is not a scientific QC pass.

shotgun metagenome taxonomic profiling (no assembly, lighter than mag); samplesheet is sample+run_accession+instrument_platform required (schema does NOT require fastq_1/fastq_2/fasta -- a row with none of them validates cleanly, see samplesheets.md), uniqueEntries=[sample,run_accession] is a COMPOSITE key (same shape as mag's [sample,run], empirically confirmed via -preview), but fastq_1/fastq_2/fasta are EACH ALSO their own separate per-field uniqueEntries -- reusing one FASTQ path across two sheet rows is a hard schema failure here (unlike mag); separate --databases CSV (tool+db_name+db_path required) selects which of 14 profilers run, none stocked by default -- this procurement stocks ONLY kraken2 against a small 8 GB-capped standard DB (see refs.manifest.tsv db/kraken2/), not the full tool roster, per "lightest combination first"; -stub-run PASSES cleanly end to end (completed=176 failed=0) with all 14 profilers on the CI test fixtures -- no waiver needed, unlike ampliseq/mag
