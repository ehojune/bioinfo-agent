# viralrecon: exact stub gate

Read only for this pipeline, after [common stub isolation](../../runbook.md#4-preview-then-stub).
This is a partial gate at the documented revision, never permission to waive another error.
Re-check the pin in `config/pipelines.tsv`; a version change requires fresh evidence.

**`nf-core/viralrecon`, `-stub-run`, and the primer/reference contig-match check — a true
waiver, upstream shared-module stub-coverage gap, same shape as ampliseq/nanoseq/rnasplice/
isoseq.** `-stub-run` on `-profile test,docker` (this pin's `3.0.0`) fails with:
```
Contigs in primer BED file do not match those in the reference genome:

MN908947.3
```
`modules/nf-core/custom/getchromsizes/main.nf`'s `stub:` block does `touch ${fasta}.fai` — an
empty placeholder, no real contig records — and `lib/WorkflowCommons.groovy`'s
`checkContigsInBED(fai_contigs, bed_contigs, log)` reads that empty `.fai` for real, builds an
empty `fai_contigs` list, intersects it against the primer BED's real `bed_contigs` (which does
contain `MN908947.3`), gets a zero-size intersection, and calls `Nextflow.error()` —
`completed=4 failed=0` (a script `error()` thrown before any task fails, not a task failure
count). Confirmed data/config-independent: this reproduces regardless of which
`--fasta`/`--primer_bed` content is supplied, because the root cause is
`CUSTOM_GETCHROMSIZES`'s stub producing an empty `.fai`, not any property of this procurement's
own reference choices. No substitute-input workaround possible (any fasta/BED pair hits the
same empty-`.fai` comparison). **Waived, 11th documented departure** — `-preview` is unaffected
(it resolves params and the DAG without executing anything) and stays the pre-launch gate; the
full non-stub `-profile test,docker` run is what proves the pipeline actually executes —
`completed=187 failed=0 cached=8`, ~23 min wall clock, confirmed clean on this box
2026-08-18. See `references/pipelines/viralrecon.md` for the full writeup, including the
`raw.githubusercontent.com` rate-limit environment finding this procurement also hit (unrelated
to the stub gap above — a transient network condition, not a pipeline defect).
