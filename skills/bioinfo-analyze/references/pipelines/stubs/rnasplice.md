# rnasplice: exact stub gate

Read only for this pipeline, after [common stub isolation](../../runbook.md#4-preview-then-stub).
This is a partial gate at the documented revision, never permission to waive another error.
Re-check the pin in `config/pipelines.tsv`; a version change requires fresh evidence.

**`nf-core/rnasplice`, `-stub-run`, and `GTF_GENE_FILTER`/`RSEM_PREPAREREFERENCE` — a true waiver,
upstream shared-module stub-coverage gap, same shape as the ampliseq/nanoseq cases in their respective stub cards.**
Confirmed 2026-08-14 (`20260814-rnasplice-scer-gln3-ibutanol`) against this pin's `1.0.4`.
`modules/nf-core/gunzip/main.nf`'s `stub:` block does `touch $gunzip` — an empty placeholder file
— for whichever of `--fasta`/`--gtf` is gzipped, and the downstream
`modules/local/gtf_gene_filter.nf` + `modules/nf-core/rsem/preparereference/main.nf` have **no**
`stub:` block at all, so they run for real against that empty stub input. Reproduced both ways:
on the nf-core CI fixture (gzipped fasta, plain gtf), `filter_gtf_for_genes_in_genome.py`
extracts 0 chromosome names from the empty stub fasta and writes an empty GTF, then
`rsem-prepare-reference` fails with "The reference contains no transcripts!"; on this
procurement's own real-sample sheet (plain fasta, gzipped gtf) the fasta is real but the GTF
comes from `GUNZIP_GTF`'s empty stub, so `filter_gtf_for_genes_in_genome.py` instead extracts
0/0 lines and SUPPA's `GENERATE_EVENTS` fails with "No exons found" — same root cause, different
file triggers it depending on which input the samplesheet happens to gzip. No substitute-input
workaround possible, same reasoning as the ampliseq/nanoseq cases. **Waived, 7th documented
departure** — `-preview` (clean) is the pre-launch gate; the real (non-stub) `-profile
test,docker` command with the identical flag set completes cleanly (`completed=34 failed=0`).
**Separately** (not a stub artifact, found on the real 8-sample run, not covered by this waiver):
`SUPPA_SALMON:GENERATE_EVENTS_IOE` has a genuine infinite-loop bug in its own real script when
zero local splicing events exist for some event type — see `references/pipelines/rnasplice.md` and
`config/pipelines.tsv` for the full writeup; routed around with `--suppa_per_local_event false`,
which is now part of this pipeline's stocked default rather than an optional flag.
