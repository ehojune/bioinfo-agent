# pipelines/ — in-repo Nextflow pipelines

Pipelines written in this repo, **not** nf-core. Each subdirectory is self-contained and
zero-plugin: copy just that directory to any host with Nextflow (version per its manifest) and a
container runtime, and it runs — agent, repo tooling, and network-at-task-time not required.

There is no `-r`: the revision is the repo checkout. Each pipeline has a row in
`config/pipelines.tsv` (revision `in-repo`), and `bin/preflight.sh` gates cmd.sh launches the
same way it does for nf-core runs (absolute path required:
`"$BIOINFO_HOME"/pipelines/<name>`).

| pipeline | what it does | docs |
|---|---|---|
| `pacbio-hifi-wgs` | PacBio HiFi human WGS germline: subreads→pbccs→pbmm2→{DeepVariant, Clair3}+WhatsHap phase/haplotag+pbsv SV+QC; per-row mid-pipeline entry via samplesheet `input_type` | its `README.md`; `pipeline-selection.md` §4.20; validation record `docs/examples/20260820-pacbio-hifi-wgs-validation/` |

Adding a new one: `skills/bioinfo-analyze/references/new-pipeline.md` §7. Whether to build new
or reuse something existing is the **user's** decision — propose and ask first.
