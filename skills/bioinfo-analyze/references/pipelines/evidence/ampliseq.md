# ampliseq: procurement record

Lookup only. Preserved from `config/pipelines.tsv` when the routing table was split.
These dated observations describe the recorded host and runs; verify current pins, files,
resources and upstream behavior before reuse. A completed workflow is not a scientific QC pass.

16S/ITS amplicon, DADA2+QIIME2; samplesheet takes sampleID+forwardReads/reverseReads OR sample+fastq_1/fastq_2 -- mutually exclusive per-sheet (schema oneOf/not:anyOf rejects mixing), see samplesheets.md; -stub-run fails at CUTADAPT_BASIC (upstream module bug, stub: block never sets `outformat` -- waived, 4th documented departure, see runbook.md sec 4); taxonomy DBs self-fetched via PREPTAX, cache with --ref_taxonomy_storage
