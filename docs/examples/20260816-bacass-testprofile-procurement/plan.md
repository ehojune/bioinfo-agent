# Plan — 20260816-bacass-testprofile-procurement

## Pipeline
nf-core/bacass -r 2.6.1 (latest stable, 92 GitHub stars, released 2026-05-05, repo pushed
2026-07-29 — well inside the "<12 months: normal" age band; not archived; org confirmed
`nf-core/bacass`). Simple bacterial genome assembly + annotation: short-read-only,
long-read-only (ONT), or short+long hybrid assembly (choice of Unicycler/Canu/Miniasm/Flye/
Raven/Dragonflye/MEGAHIT/Autocycler), followed by Prokka/Bakta/DFAST/Liftoff annotation and
QC via QUAST/BUSCO/MultiQC. `nextflowVersion = '!>=25.04.0'` in the pipeline manifest — this
box runs Nextflow 26.04.6, compatible.

## Why bacass, not mag or sarek — fills a real gap
- **vs `nf-core/mag`** (already stocked, `config/pipelines.tsv`): mag does METAGENOME assembly
  — recovering multiple, initially-unknown genomes from one community sample (co-assembly,
  binning, bin QC, taxonomic classification of bins). bacass does SINGLE-ORGANISM bacterial
  assembly — one isolate, one expected genome, straight to a single set of contigs and one
  annotation. Different question: "what organisms and genomes are in this community sample"
  (mag) vs "assemble and annotate this one bacterial isolate" (bacass). bacass has no binning
  step and no bin-level taxonomic classification at all; mag has no per-isolate
  annotation (Prokka/Bakta/DFAST) or reference-free single-genome QUAST/BUSCO reporting that
  bacass ships as its primary output.
- **vs `nf-core/sarek`** (already stocked): sarek is human/vertebrate germline+somatic
  variant-calling from an existing reference — it aligns reads to a supplied reference and
  calls variants against it. It performs no de novo assembly at all, of anything. A much
  smaller point than the mag contrast, but stated for completeness: nothing in sarek's scope
  overlaps bacass's (de novo contig construction with no reference required).

## Schema drift check performed this run
`assets/schema_input.json` at this pin (columns `ID`/`R1`/`R2`/`LongFastQ`/`Fast5`/
`GenomeSize`, required=[`ID`]) **is live-wired and authoritative** — confirmed by reading
`subworkflows/local/utils_nfcore_bacass_pipeline/main.nf:105`:
`.fromList(samplesheetToList(input, "${projectDir}/assets/schema_input.json"))`. No bundled
`bin/check_samplesheet*.py` exists in the clone (`bin/` holds only `csv_to_yaml.py`,
`find_common_reference.py`, `kmerfinder_summary.py`, `multiqc_to_custom_csv.py` — none of them
a samplesheet validator). Same class of finding as isoseq (schema IS authoritative), unlike
nanoseq/rnasplice (schema is vestigial there).

Empirically confirmed the schema's `"unique": false` on `ID`: the pipeline's own CI fixture
(`bacass_short_reseq.tsv`, fetched from
`https://raw.githubusercontent.com/nf-core/test-datasets/bacass/bacass_short_reseq.tsv`)
repeats `ID=ERR044595` across two different R1/R2 pairs (rows 1 and 3) and this is the
pipeline's own working test input, not a hypothetical — duplicate sample IDs pointing at
different read pairs is the pipeline's supported re-sequencing-merge shape, not an error.

## Scope — lightest combination first
Checked rather than assumed: `--assembler` accepts a comma-list and the workflow gates each
assembler branch on `params.assembly_type` (`workflows/bacass.nf` ~lines 132-345) — for
`assembly_type: short`, only short-read-fed branches (unicycler, megahit) receive real input;
long-read-only assemblers (canu/miniasm/flye/raven/dragonflye/autocycler) receive empty
channels and are no-ops regardless of what else is listed in `--assembler`. The pipeline's own
`conf/test.config` (its lightest, fastest CI profile) independently confirms the same choice:
`assembly_type = 'short'`, `assembler = 'unicycler'`, `skip_kraken2 = true`,
`skip_kmerfinder = true`, `prokka_args = ' --fast'`.

Stocked configuration, matching that CI-minimal shape:
- `--assembly_type short` — short-read-only assembly (no ONT/long-read input required, avoids
  Canu/Flye/Miniasm/Dragonflye/Autocycler entirely, and their long-read QC subworkflows
  NanoPlot/PycoQC/ToulligQC/Filtlong/polishing).
- `--assembler unicycler` (not the schema default, which lists all 8 assemblers
  comma-joined — running that default list under `assembly_type: short` would not actually
  execute the long-read-only ones, since their channels are empty, but it is clearer and
  cheaper to state the assembler explicitly than to rely on an empty-channel no-op).
- `--annotation_tool prokka` (the default). Prokka's own reference/HMM databases are bundled
  in its container — no external database fetch, unlike `--annotation_tool bakta`
  (`--baktadb_download` pulls a multi-GB external DB) or `--kmerfinderdb`/`--kraken2db`
  contamination-screening databases (`--kmerfinderdb`'s own `--help` text quotes ~30 GB for the
  full bacteria DB via FTP). Bakta, DFAST, Liftoff annotation are explicitly OUT OF SCOPE this
  procurement.
- `--skip_kraken2 true`, `--skip_kmerfinder true` — both are contamination-screening steps that
  need external databases not currently in `$BIOINFO_REFS`; skipping them is the same
  "lightest combination first" pattern as taxprofiler's kraken2-only stocking and mag's
  `--skip_gtdbtk`. Documented as out of scope, not silently dropped.
- BUSCO (`--busco_lineage bacteria_odb10`, `--busco_mode genome`) is left ON at its default —
  unlike kraken2/kmerfinder it self-fetches only its own lineage dataset (a few hundred MB via
  the `busco_sepp` Wave container's own download machinery, not a manifest-tracked reference),
  and it is one of bacass's two primary QC signals (alongside QUAST) for a de novo assembly, so
  keeping it is the more honest "lightest configuration that still answers the question".
- **No `--reference_fasta`/`--reference_gff`.** Both are optional; when omitted, `QUAST` still
  runs and reports its full suite of reference-free assembly metrics (N50, L50, contig count,
  total length, GC%, largest contig, etc — confirmed via `workflows/bacass.nf:768-773`, QUAST is
  called with empty tuples for reference and gff when the params are unset). Providing a
  reference genome purely for QUAST's optional identity/misassembly comparison is not required
  to get a real QC verdict on the assembly and is left out of scope for this first validation —
  a bounded choice, reversible by adding `--reference_fasta`/`--reference_gff` on a later run.
- `--skip_pycoqc true` inherited implicitly (no long reads supplied, so PycoQC has nothing to
  run on regardless).
- `--skip_polish` — N/A for `assembly_type: short` (polishing only applies to long-read
  assemblies per `workflows/bacass.nf:587`).

Out of scope, explicitly: long-read-only assembly, hybrid assembly, Bakta/DFAST/Liftoff
annotation, Kraken2/KmerFinder contamination screening, reference-based QUAST comparison,
Autocycler multi-assembler consensus, Rasusa downsampling.

## Containers
All containers resolve through `community.wave.seqera.io` (Wave-built, on-demand), confirmed by
grepping `modules/` for image references — standard for a pipeline this age, needs network on
first pull, same class as every other recently-stocked pipeline here (raredisease, rnasplice,
isoseq). No quay.io biocontainer-tag risk observed for the stocked tool set
(fastp/fastqc/unicycler/megahit/prokka/quast/busco/multiqc).

## Resources
`conf/base.config` uses standard nf-core labels (`process_single` through `process_high`,
`process_high_memory` unused by the stocked tool set). Clamped by this box's actual pool per
`config/host.env` — **16 cores / 18 GB** (`BIOINFO_MAX_CPUS=16`, `BIOINFO_MAX_MEMORY=18.GB`),
not the 18/40 figure in generic guidance; `config/local.config`'s `resourceLimits` reads the
env vars directly. `process_high` (12 cpu/72 GB requested) clamps down to the pool ceiling —
normal and already exercised by every other stocked pipeline's `process_high` labels here.

## Reference genomes
None required. De novo assembly needs no reference; QUAST runs reference-free (see Scope
above). No new rows needed in `config/refs.manifest.tsv` for this procurement — will note this
explicitly in that file's comment header area / as a no-op confirmation, not add empty rows.

## Disk
`/work` (ext4, `/dev/sdd` mount) currently has 173 GB free (`df -h /work`, measured this run —
notably less than the ~955 GB the skill's generic orientation figures assume; this box's actual
number governs). CI test-profile fixtures are a few MB (`ERR044595`/`ERR064912`, 1M-read
subsampled short-read pairs). Real-sample candidate (see below) is ~260 MB total fastq.gz.
Estimated peak work-dir size for either run: well under 5 GB (bacterial short-read assembly,
no long-read/hybrid intermediates, no large database downloads). 1.5× estimate is trivially
satisfied by 173 GB free — no disk risk for either the test-profile or real-sample run.

## Real-sample candidate
`SRR2589044` (ENA/SRA), *Escherichia coli* B str. REL606, Illumina HiSeq 2500, WGS,
paired-end. Sizes disclosed before download (ENA filereport, measured, not estimated):
`fastq_bytes` 129,138,426 + 134,214,678 B ≈ 263,353,104 B (~251 MiB) total gzip,
`base_count` 332,127,000 bp, `read_count` 1,107,090 read pairs. Coverage against the ~4.6 Mb
*E. coli* genome ≈ 332.1 Mbp / 4.6 Mbp ≈ **72x** — comfortably within Unicycler's useful depth
range for a bacterial isolate, well under the ~10 GB silent-download ceiling, no approval
needed. Fetched via `curl` from the ENA FTP URLs the filereport API returned.

## Estimate
No prior bacass run on this machine (`$BIOINFO_RUNLOG` has no bacass entries — checked). Per
scale-up discipline (`new-pipeline.md` §2.8): CI test profile first (minutes, small fixture),
then one real sample timed and measured, extrapolate only if warranted. Expect both the
stub-run and the full CI test-profile gate to complete in well under 30 minutes combined
(sub-Mb fixture reads, `resourceLimits: 4 cpu/15 GB/1 h` set inside `conf/test.config` itself).
Real-sample run: ~250 MB of reads at 72x coverage on a 4.6 Mb genome — Unicycler assembly of a
single bacterial isolate at this depth is typically single-digit minutes to worse case ~1h on a
modest core count; well under the 24-hour approval threshold, no escalation needed. Both runs
launched via `tmux` per `runbook.md` §5 regardless of this short expected duration, per the
standing rule.

## Bounded choices (repeated from Scope, for visibility)
- `assembly_type=short`, `assembler=unicycler`, `annotation_tool=prokka` (default) — lightest
  real short-read assembly+annotation combination, matches the pipeline's own CI-test shape.
- `skip_kraken2=true`, `skip_kmerfinder=true` — contamination screening skipped, no local DB.
- No `--reference_fasta`/`--reference_gff` — QUAST runs reference-free.
- Real sample SRR2589044 chosen for small size (~251 MiB) and adequate coverage (~72x), not for
  any biological property of the isolate.

## Next steps
1. `bash bin/preflight.sh` for both run directories once `cmd.sh`/`samplesheet.csv` are written.
2. `-preview`, then `-stub-run`, on `-profile test,docker` (test-profile procurement dir).
3. Full (non-stub) `-profile test,docker` — the mandatory gate.
4. Real-sample run (own samplesheet, SRR2589044), launched via tmux, timed and measured.
5. QC verdict from QUAST/BUSCO/Prokka/MultiQC outputs — no biological interpretation.
6. Stock the six deliverable files, PR, `@codex review` loop, merge.
