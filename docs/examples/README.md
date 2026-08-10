# Worked examples

Seven real runs, kept as documentation of what a run record looks like. Each is the five-file set
the agent writes into `runs/<runid>/`: `plan.md`, `samplesheet.csv`, `params.yaml`, `cmd.sh`,
`handoff.md`.

| Example | Shows |
|---|---|
| `20260804-rnaseq-scer-verify` | nf-core/rnaseq end to end on a small genome — the shortest complete record |
| `20260805-methylseq-sle-rrbs-smoke` | RRBS, and how a smoke run gets scoped before the full cohort |
| `20260805-scrnaseq-skin-cd3` | scRNA-seq, aligner-native QC rather than MultiQC |
| `20260806-chipseq-vsmc-h3k27me3-smoke` | ChIP-seq with input controls in the samplesheet |
| `20260807-rnaseq-testprofile-e` | a **failed** run, kept deliberately — STAR cannot create FIFOs on drvfs |
| `20260807-rnaseq-salmononly-e` | the same data completing via the pseudo-aligner path |
| `20260810-fetchngs-citest` | first run of nf-core/fetchngs on this host — headerless accession list, GSE/GEO resolution, and the discovery that `-stub-run` downloads real data for this pipeline |

The last two are the evidence behind the ext4 rule in
`skills/bioinfo-analyze/references/runbook.md` section 1.

**Your own runs do not go here.** They land in `runs/`, which is gitignored — see the comment in
`.gitignore`. The agent reads that directory locally when planning, to notice a sample it has seen
before; nothing about it is pushed anywhere.
