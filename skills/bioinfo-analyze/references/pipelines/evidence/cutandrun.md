# cutandrun: procurement record

Lookup only. Preserved from `config/pipelines.tsv` when the routing table was split.
These dated observations describe the recorded host and runs; verify current pins, files,
resources and upstream behavior before reuse. A completed workflow is not a scientific QC pass.

schema_input.json re-read this run: group+replicate+fastq_1+fastq_2+control all required (not sample); confirmed via main.nf/prepare_genome.nf that compact --genome form never touches bwa/star/chromap (unlike chipseq) and that the target-genome index param is --bowtie2, not --bowtie2_index

## Historical compatibility finding

The following records the original manual workaround. Current runs use the checked patch helper in the card.

**Known-broken on this host's Nextflow version until patched — check before every run.**
`modules/local/for_patch/trimgalore/main.nf` at 3.2.2 declares its optional outputs with the old
trailing-modifier DSL2 syntax (`emit: html optional true`). Nextflow 26.04.6 (installed here)
rejects this at script-compile time: `ERROR ~ Cannot invoke method optional() on null object`,
reproduced in isolation with a 6-line minimal `.nf` script — this is a genuine engine/pipeline
version-skew bug in the pipeline's own bundled code, not a params or samplesheet problem, and it
blocks **every** invocation (`-preview`, `-stub-run`, and the real run alike), not just a
misconfigured one. Confirmed 2026-08-06, run `20260806-cutandrun-hpsc-h3k27me3-smoke`. Fix (already
applied to this host's `NXF_ASSETS` clone as of that run): change both `optional true` occurrences
to the modern comma form, `, optional: true` — semantically identical, verified via `-preview`
failing before and passing after. **This patch lives in the pipeline clone under `NXF_ASSETS`, not
in this repo** — it is lost if the clone is ever deleted and re-pulled. Before the next cutandrun
run: `grep -n 'optional true' $(find "$NXF_ASSETS" -path '*nf-core/cutandrun*' -name main.nf)`; if
it still matches, reapply the same two-line edit (or check whether a newer cutandrun/Nextflow
pairing has fixed it upstream first).
