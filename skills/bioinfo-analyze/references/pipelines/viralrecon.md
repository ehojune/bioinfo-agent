# viralrecon

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** [Exact stub conditions](stubs/viralrecon.md) — read before Step 4; match every predicate.
- **Evidence lookup:** [procurement record](evidence/viralrecon.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** viral genome analysis from amplicon or metagenomic Illumina/Nanopore reads — reference-
based mapping + variant calling (including intrahost/low-frequency variants via Freyja) or de
novo assembly, consensus genome generation, and Pangolin/Nextclade lineage & clade assignment.
Originally built for SARS-CoV-2 but genome-agnostic (any `--fasta`/`--gff`/`--primer_bed`).
This procurement stocks the illumina/amplicon/reference-based path only — no Nanopore entry
point, no de novo assembly branch (`--skip_assembly true`).

**Not for, vs `nf-core/taxprofiler` (already stocked) — the contrast a "detect virus in this
sample" request could plausibly confuse.** taxprofiler answers "what taxa are present, and
roughly how much" — shotgun/amplicon reads through up to 14 taxonomic profilers (this repo
stocks kraken2 only), producing per-sample/per-database relative-abundance tables. It performs
**no assembly, no per-sample consensus sequence, and no lineage/clade call at all** — it never
even establishes a reference coordinate system for any one organism. viralrecon answers a
structurally different question: "I already know (or strongly suspect) this sample is one
particular virus, targeted with an amplicon panel or shotgun-sequenced — give me that virus's
consensus genome, its variants (including intrahost/low-frequency ones), and a lineage/clade
call." viralrecon produces a per-sample FASTA consensus and VCF against a named reference;
taxprofiler produces neither. A request phrased "what's in this sample" or "screen this sample
for pathogens" is taxprofiler's question (or, if metagenomic assembly of unknown organisms is
wanted, `mag`); a request phrased "assemble/call variants/lineage-type this known-virus
amplicon run" is viralrecon's. Neither substitutes for the other — taxprofiler cannot produce a
consensus genome or a lineage call, and viralrecon requires a specific named reference genome
and will not survey an unknown community sample.

**Not for, vs the other stocked pipelines:** sarek is human/vertebrate variant calling; bacass
is single bacterial genome assembly; mag is metagenome assembly+binning across potentially many
organisms. None of the three touch viral-genome-specific tooling (ARTIC amplicon primer
trimming, Pangolin/Nextclade lineage calling, Freyja intrahost deconvolution) at all.

**Schema drift note — schema IS the live validator, same class as isoseq/bacass.**
`subworkflows/local/utils_nfcore_viralrecon_pipeline/main.nf:100/122` calls
`samplesheetToList(params.input, "${projectDir}/assets/schema_input.json")` directly; `bin/`
in the clone holds only `fastq_dir_to_samplesheet.py`, a samplesheet *generator*, not a
validator. `sample` is the only `required[]` field — `fastq_1`/`fastq_2`/`barcode` are all
individually optional at schema level, so a row with no read source validates cleanly (checked
in `scripts/check-samplesheet.sh --pipeline viralrecon`, not left to the schema, same pattern as
taxprofiler/mag/raredisease/bacass). Repeated `sample` is a **supported** multi-lane/multi-run
merge (`.groupTuple()` keyed on `meta.id`), not a uniqueEntries gap — `validateInputSamplesheet()`
only rejects a repeated sample whose rows disagree on single-end vs paired-end. See
`samplesheets.md` for the full column table.

**A genuine `--help` usability quirk, worth knowing before you type it:** bare
`nextflow run nf-core/viralrecon -r 3.0.0 --help` does **not** print help — it fails with
"Parameter --platform is required (illumina / nanopore). Please specify." `main.nf`'s top-level
script (`main.nf:21-24`) hard-requires `--platform`, and `workflows/viralrecon.nf`'s top-level
script (`workflows/viralrecon.nf:49`) hard-requires `--input`, and **both execute before**
`PIPELINE_INITIALISATION`'s nf-schema help handler ever runs (top-level Groovy script code in an
`include`d file runs at parse/include time, not at workflow-invocation time). `--platform
illumina --input <any-existing-path> --help` prints the full help text and exits 0 cleanly.

**Parameters that matter:** `--platform` (`illumina`/`nanopore`, no default, hard-required —
this procurement stocks `illumina` only), `--protocol` (`amplicon`/`metagenomic` — this
procurement stocks `amplicon`), `--fasta`/`--gff`/`--primer_bed` (explicit paths — see below,
NOT the `--genome` shorthand), `--skip_assembly` (this procurement sets `true`; unset, the
default assembly branch runs SPAdes+Unicycler+minia together, then BLAST/ABACAS/QUAST/Bandage/
PlasmidID on each), `--variant_caller`/`--consensus_caller` (left at pipeline default:
`ivar`/`bcftools`), `--kraken2_db` (host-read filtering; the schema's own DEFAULT — not
something this procurement added — is a small S3-hosted human-only DB), `--pango_database`/
`--nextclade_dataset`/`--nextclade_dataset_name`/`--freyja_barcodes`/`--freyja_lineages` (all
four exist specifically so the pipeline's own runtime auto-fetch/auto-update processes
(`PANGOLIN_UPDATEDATA`/`NEXTCLADE_DATASETGET`/`FREYJA_UPDATE`) can be skipped in favour of a
static, pre-fetched local path — this procurement uses all four, after real environment findings
below).

**Do NOT use `--genome MN908947.3` (or any `--genome` value) on this box without also setting
`--custom_config_base` to a local mirror.** `--genome` resolves `--fasta`/`--gff`/`--primer_bed`/
`--nextclade_dataset*` through nf-core/configs' own remote `conf/pipeline/viralrecon/
genomes.config`, which `nextflow.config` fetches via `raw.githubusercontent.com` — the exact
host this procurement found to be intermittently rate-limited (`HTTP 429`) on this box (see
"Environment findings" below). Explicit `--fasta`/`--gff`/`--primer_bed` CLI/params-file values
survive even when `--genome` is unset (confirmed via `-preview`: `main.nf`'s own
`params.fasta = getGenomeAttribute('fasta')` reassignment at parse time does NOT clobber a
CLI-supplied value — Nextflow applies CLI/params-file params with final precedence over any
in-script `params.x = ...` assignment). This repo's stocked configuration therefore never passes
`--genome` at all for a real run.

**Reference-store paths:** `genomes/SARS-CoV-2-MN908947.3/fasta/genome.fa` + `gff/genome.gff`
(NCBI `eutils`, MN908947.3 — SARS-CoV-2 isolate Wuhan-Hu-1), `.../primer/artic-v3/primer.bed`
and `.../artic-v4.1/primer.bed` (ARTIC nCoV-2019 primer schemes — pick the version matching the
sample's actual wet-lab protocol, this is a per-run choice, not a pipeline default), `db/pangolin/`
(pangolin-data v1.32, extracted from the pinned module container), `db/nextclade/sars-cov-2/`
(Nextclade SARS-CoV-2 dataset), `db/freyja/usher_barcodes.feather` + `curated_lineages.json`
(Freyja UShER barcodes), `db/kraken2_viralrecon_human/kraken2_human/` (viralrecon's own default
host-filter DB). Full fetch/build provenance for every row in `config/refs.manifest.tsv`.

**Environment findings — three separate runtime-fetch/rate-limit/TLS issues, all routed around
by pre-fetching a static local copy instead of letting the pipeline fetch at runtime:**
1. `raw.githubusercontent.com` (GitHub's CDN) repeatedly returned `HTTP 429 Too Many Requests`
   on this box during this procurement — blocking `nextflow.config`'s own remote `includeConfig`
   (fixed with a local `git clone`-sourced `--custom_config_base` mirror), the CI test profile's
   own fixture fetch (fixed the same way), and `FREYJA_UPDATE`'s barcode-DB fetch (fixed by
   pre-fetching `usher_barcodes.feather`/`curated_lineages.json` via `git clone` and setting
   `--freyja_barcodes`/`--freyja_lineages`). Confirmed transient/rate-limit, not a hard network
   block — `github.com`, `api.github.com`, `quay.io`, EBI, NCBI, and S3 were all reachable
   throughout; a `git clone --filter=blob:none --sparse` against `github.com` directly (not
   `raw.githubusercontent.com`) sidesteps it entirely for any file that lives in a git repo.
2. `PANGOLIN_UPDATEDATA`'s `pangolin --update-data` hits GitHub's
   `/repos/cov-lineages/pangolin-data/releases` **list** endpoint (not `/releases/latest`),
   which returned a genuinely empty `[]` (HTTP 200) from this box's egress on every retry —
   confirmed via host `curl` AND `python3 urllib` run *inside* the pinned pangolin container
   itself, ruling out a client-side quirk. Routed around by extracting the pangolin-data version
   already baked into that same pinned container image instead (`--pango_database`).
3. `NEXTCLADE_DATASETGET` needs `data.clades.nextstrain.org`, which this box's corp
   TLS-inspecting proxy ("ePrism SSL"/SOOSAN INT — the same proxy `bootstrap/06-tls-trust.sh`'s
   own docstring names for `get.nextflow.io`) intercepts **inside a fresh Docker container's own
   trust store**, even though the HOST already trusts that proxy's CA from an earlier
   `bootstrap/06-tls-trust.sh --accept` run. A genuinely new class of TLS-trust gap for this
   repo (container-local, not host-level, unlike every prior `06-tls-trust.sh` finding). Routed
   around for the one-off manual dataset fetch by mounting the host's `ca-certificates.crt` into
   the container with `SSL_CERT_FILE` set, then never invoking `NEXTCLADE_DATASETGET` in the
   real pipeline run at all (`--nextclade_dataset` static path skips it structurally).

**Known gaps / stub-run behaviour.** `-stub-run` on `-profile test,docker` fails at the
primer/reference contig-match check (`CUSTOM_GETCHROMSIZES`'s stub writes an empty `.fai`,
which `checkContigsInBED()` then reads for real) — **11th documented departure**, waived,
confined to stub mode, data/config-independent. `-preview` is the pre-launch gate; the full
non-stub `-profile test,docker` gate passes cleanly (`completed=187 failed=0 cached=8`,
~23m wall clock). See `runbook.md` §4 for the full writeup.

**Key outputs:** `variants/ivar/consensus/bcftools/<sample>.consensus.fa` (masked consensus
genome), `variants/ivar/<sample>.vcf.gz` (called variants), `variants/bowtie2/mosdepth/genome/
<sample>.mosdepth.summary.txt` + `.../amplicon/<sample>.mosdepth.coverage.tsv` (genome-wide and
per-amplicon depth — the per-amplicon table is what actually reveals amplicon dropout, not the
summary mean alone), `<sample>.pangolin.csv` (raw Pangolin lineage call), Nextclade
`<sample>.csv`/`.tsv` (raw clade call + QC flags), `freyja/demix/<sample>.demix.tsv` (intrahost
lineage-abundance deconvolution), `multiqc/multiqc_report.html`.

**QC verdict checklist (measured, no biological interpretation):** consensus completeness
(% non-N bases, `<sample>.consensus.fa`), mean AND per-amplicon/per-window coverage depth
(mosdepth — a high mean with low breadth is amplicon dropout, visible only in the per-amplicon
table, not the summary), iVar/bcftools variant count, fastp/Kraken2 read-passed fractions,
Pangolin `qc_status` (raw string, e.g. `pass`/`fail`, plus its `note` field), Nextclade
`qc.overallStatus`. None of these are claims about outbreak significance, transmission, or
clinical relevance of any lineage/variant — report the raw tool output string, nothing more.

**Real-sample run** (`runs/20260818-viralrecon-sample01-realsample/`): `SAMPLE_01` from
viralrecon's own `conf/test_full.config` real-world validation cohort (S3-hosted,
protocol-confirmed ARTIC V3), Illumina PE, ~132 MiB gzip total, 2,028,184 raw read pairs —
chosen specifically because the primer scheme is protocol-documented (unlike an arbitrary
SRA/ENA pick, where it frequently is not). `completed=52 failed=0`, 3m46s wall clock, 356 MB
peak work dir. Measured QC: only 23,644 primary reads (~1.2% of input) mapped to MN908947.3
after Kraken2 human-host depletion — expected for a low-viral-titer surveillance sample; mean
genome depth 74.1x but severely uneven (per-amplicon `coverage.tsv` shows most 200bp
windows/amplicons at 0x, a handful up to 9,894x — amplicon dropout, confirmed by reading the
per-amplicon mosdepth table directly, not a masking bug); consensus 29,903 bp with 29,535 N
(98.77% N, 1.23% ACGT completeness); 2 iVar variants called; Pangolin lineage "Unassigned"
(`qc_status=fail`, `note=Ambiguous_content:0.99` — reported as the tool's raw output string);
Nextclade clade `21L (BA.2)` called despite the QC-failing consensus (Nextclade aligns and calls
on whatever sequence is present; its own `coverage` field reports 0.0123). This is a genuine,
unfavourable-but-real measurement — the pipeline executed and reported correctly on a real
low-viral-load sample; it is not a run failure and no re-pick was done to get a "nicer" number.
See `estimates.md` for the full wall-clock/disk measurement and `handoff.md` for the complete
QC table.
