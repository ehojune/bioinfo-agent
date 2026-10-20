# mag: procurement record

Lookup only. Preserved from `config/pipelines.tsv` when the routing table was split.
These dated observations describe the recorded host and runs; verify current pins, files,
resources and upstream behavior before reuse. A completed workflow is not a scientific QC pass.

shotgun metagenome assembly+binning+QC; samplesheet is sample+group required, short_reads_1(+2, +platform) and/or long_reads(+platform), uniqueEntries=[sample,run] is a COMPOSITE key (empirically confirmed via -preview: same sample/different run passes, same sample+run or same sample with no run column both fail) -- see samplesheets.md; -stub-run fails at UNTAR (CATPACK_DB_UNTAR/BUSCO_UNTAR) because mag's own untar.diff patch sets `output_dir` in script: but never in stub: -- waived, 5th documented departure, see runbook.md sec 4; ONLY exercised when a .tar.gz db is supplied (cat_db/busco_db/checkm without local db/genomad_db), not on a default real run; --skip_gtdbtk true required unless the user approves the default GTDB-Tk DB's 60.8 GB download (measured via curl -sI)
