# bacass: exact stub gate

Read only for this pipeline, after [common stub isolation](../../runbook.md#4-preview-then-stub).
This is a partial gate at the documented revision, never permission to waive another error.
Re-check the pin in `config/pipelines.tsv`; a version change requires fresh evidence.

**`nf-core/bacass`, `-stub-run`, and `UNICYCLER` — a true waiver, upstream module authoring bug,
different shape from every prior case (a hardcoded literal, not a stub-coverage gap).** Confirmed
2026-08-16 (`20260816-bacass-testprofile-procurement`) against this pin's `2.6.1`, on the CI
`-profile test,docker` config unmodified (`assembly_type: short`, `assembler: unicycler`).
`modules/nf-core/unicycler/main.nf`'s `stub:` block reads, verbatim:
```
cat "" | gzip > ${prefix}.scaffolds.fa.gz
cat "" | gzip >  ${prefix}.assembly.gfa.gz
```
`cat ""` passes a literal empty string as a filename argument, which every prior case in this
list did not do — the ampliseq/mag/nanoseq/rnasplice/isoseq cases all involve a stub in one
module writing an empty PLACEHOLDER FILE that a downstream module with no `stub:` block then
reads for real; here the failing process's OWN stub script is malformed on its own, no
downstream module involved at all. `completed=8 failed=1`, exact error
(`Command error: cat: '': No such file or directory`), confirmed by reading the module source
directly. No substitute-input workaround possible — there is no shortreads/longreads-shaped
input that fixes a hardcoded `cat ""`. **Waived, 9th documented departure** — `-preview` (clean)
is the pre-launch gate; the full (non-stub) `-profile test,docker` command is what actually
proves this pipeline, see `references/pipelines/bacass.md` and `config/pipelines.tsv` for the full
writeup.
