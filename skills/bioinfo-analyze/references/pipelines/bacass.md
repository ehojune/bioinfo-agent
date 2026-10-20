# bacass

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** [Exact stub conditions](stubs/bacass.md) — read before Step 4; match every predicate.
- **Evidence lookup:** [procurement record](evidence/bacass.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** single-organism bacterial genome de novo assembly and annotation — short-read-only,
long-read-only (ONT), or short+long hybrid assembly (Unicycler/Canu/Miniasm/Flye/Raven/
Dragonflye/MEGAHIT/Autocycler), followed by annotation (Prokka/Bakta/DFAST/Liftoff) and QC
(QUAST/BUSCO/MultiQC). One isolate in, one genome's contigs + one annotation out.

**Not for, vs `nf-core/mag`:** mag (already stocked) does METAGENOME assembly — recovering
multiple, initially-unknown genomes from one community sample, via co-assembly, binning, bin QC,
and taxonomic classification of the resulting bins. bacass answers a structurally different
question: "assemble and annotate *this one bacterial isolate*" vs mag's "what organisms and
genomes are present in this community sample." bacass has **no binning step and no bin-level
taxonomic classification at all**; mag has **no per-isolate annotation** (Prokka/Bakta/DFAST)
and no reference-free single-genome QUAST/BUSCO reporting shaped for a known, single organism.
If the input is a mixed community sample (soil, gut, environmental swab) with an unknown number
of organisms, that's mag, not bacass. If the input is a single cultured isolate (a colony pick,
a clinical isolate, a reference-strain resequencing run), that's bacass.

**Not for, vs `nf-core/sarek`:** a much smaller point, stated for completeness — sarek is
human/vertebrate germline+somatic variant calling *against an existing reference*; it performs
no de novo assembly of anything. Nothing in sarek's scope overlaps bacass's (reference-free
contig construction), and nothing in bacass's scope overlaps sarek's (variant calling against a
known genome).

**Schema drift note — same shape as isoseq, a contrast with nanoseq/rnasplice.** At this pin
(2.6.1), `assets/schema_input.json` **is** the real, live validator:
`subworkflows/local/utils_nfcore_bacass_pipeline/main.nf:105` calls
`samplesheetToList(input, "$projectDir/assets/schema_input.json")` directly, and `bin/` in the
clone holds only `csv_to_yaml.py`/`find_common_reference.py`/`kmerfinder_summary.py`/
`multiqc_to_custom_csv.py` — none a samplesheet validator. Confirmed by reading that
subworkflow file directly.

**Minimum input, at the upstream schema level:** `ID` (schema's only `required[]` field) plus
at least one of `R1` (short-read mate 1, pairs with optional `R2`) or `LongFastQ` (ONT long
reads) — the schema itself does **not** enforce even this "at least one read source" rule (an
all-`NA` row validates cleanly, confirmed via `-preview`).

**Minimum input, for THIS REPO'S stocked scope specifically:** `R1` is required, full stop.
`scripts/check-samplesheet.sh --pipeline bacass` enforces `R1` directly, not the looser
"R1 or LongFastQ" the upstream schema would allow — because this repo's only stocked
configuration is `assembly_type: short` (see Scope below), which needs `R1` and never consumes
`LongFastQ` at all. A `LongFastQ`-only sheet is schema-valid upstream but will be **rejected by
this repo's checker**, since it has no usable read source under the only scope this repo
actually runs; a future procurement stocking `long`/`hybrid` would need to revisit that check
alongside the scope change. See `samplesheets.md` for the full column table, the comma-vs-tab
delimiter finding, and the `NA`/empty-string placeholder convention.

**Parameters that matter:** `--assembly_type` (`short`/`long`/`hybrid`, no default — selects
which read-source columns are actually consumed) and `--assembler` (comma-list; the workflow
gates each assembler's branch on `--assembly_type`, so a long-read-only assembler listed
alongside `assembly_type: short` is a structural no-op, not an error — confirmed by reading
`workflows/bacass.nf` lines ~132-345). `--annotation_tool` (`prokka` default, bundled
databases, vs `bakta`/`dfast`/`liftoff` — bakta in particular needs a separate multi-GB
`--baktadb_download`). `--skip_kraken2`/`--skip_kmerfinder` (contamination screening, each
needs an external database not currently in `$BIOINFO_REFS` — `--kmerfinderdb`'s own `--help`
text quotes ~30 GB for the full bacteria DB via FTP). `--reference_fasta`/`--reference_gff`
(both optional — QUAST runs its full reference-free metric suite without them, confirmed by
reading `workflows/bacass.nf:768-773`: empty tuples are passed to QUAST when unset).

**Reference-store paths:** none required. De novo assembly needs no reference genome, and this
procurement's stocked scope omits the optional QUAST reference comparison — see
`config/refs.manifest.tsv`'s bacass no-op note.

**Known gaps / stub-run behaviour.** `-stub-run` on the CI `test` profile's own flag set
(`assembly_type: short`, `assembler: unicycler`) fails at `UNICYCLER` — a **9th documented
departure**, but a different SHAPE from every prior case in this list: `modules/nf-core/
unicycler/main.nf`'s `stub:` block hardcodes `cat "" | gzip > ...` (a literal empty-string
filename argument), which fails unconditionally (`cat: '': No such file or directory`)
regardless of input shape. Every prior departure (ampliseq/mag/nanoseq/rnasplice/isoseq) was a
downstream module reading an upstream module's empty stub PLACEHOLDER FILE for real; here the
failing process's own stub script is malformed on its own, no downstream module involved.
`completed=8 failed=1`. No substitute-input workaround possible — there is no read-shaped input
that fixes a hardcoded `cat ""`. **Waived** — `-preview` is the pre-launch gate; see
`runbook.md` §4 for the full writeup.

**The mandatory full `-profile test,docker` gate** (`new-pipeline.md` §2.4(c)) was run non-stub
on the CI profile's own default flag set and **passes cleanly**: `completed=17 failed=0`,
~13m8s wall clock. Confirms the `-stub-run` `UNICYCLER` failure above does not recur in a real
run. The identical `-preview`/`-stub-run` sequence, re-run against the real-sample command
below, shows the same pattern (stub fails at `UNICYCLER` for the same reason, `-preview` clean).

**Key outputs:** `Unicycler/*.scaffolds.fa.gz` (assembly contigs) + `*.assembly.gfa.gz`
(assembly graph), `Prokka/<sample>/‹sample›.{txt,gff,faa,ffn,...}` (annotation, `.txt` carries
the CDS/rRNA/tRNA/tmRNA/repeat_region counts), `QUAST/report/report.{txt,tsv}` (N50/L50/contig
count/total length/GC%/largest contig), `busco/short_summary.*.txt` (BUSCO complete/fragmented/
missing lineage-completeness percentages), `multiqc/multiqc_report.html` (aggregated — unlike
isoseq, MultiQC runs normally here, confirmed on both the test-profile and real-sample runs).

**QC verdict checklist (measured, no biological interpretation):** contig count and N50/L50
from QUAST (assembly contiguity), BUSCO's Complete/Fragmented/Missing percentages against the
`bacteria_odb10` lineage (assembly completeness), Prokka's CDS/rRNA/tRNA count (annotation
yield), fastp's passed-filter read fraction (input read quality). None of these are species
identity, contamination, or pathogenicity claims — bacass with `--skip_kraken2
--skip_kmerfinder` performs no contamination/identity check at all; that is explicitly out of
this procurement's scope (see below).

**Scope of this procurement — lightest real configuration, matching the pipeline's own CI
test-profile shape exactly.** `--assembly_type short --assembler unicycler
--annotation_tool prokka --skip_kraken2 --skip_kmerfinder`, no `--reference_fasta`/
`--reference_gff`. Out of scope: long-read/hybrid assembly, Bakta/DFAST/Liftoff annotation,
Kraken2/KmerFinder contamination screening (both need external databases not in
`$BIOINFO_REFS`), Autocycler multi-assembler consensus, Rasusa downsampling, reference-based
QUAST comparison.

**Real-sample run** (`runs/20260816-bacass-srr2589044-realsample/`): `SRR2589044` (ENA/SRA),
*E. coli* B str. REL606, Illumina HiSeq 2500 PE, 1,107,090 read pairs / 332.1 Mbp (~72x coverage
of the 4.6 Mb genome), ~251 MiB total gzip — chosen for small size and adequate depth, disclosed
before download, no approval needed (well under the ~10 GB ceiling). `completed=9 failed=0`,
8m21s wall clock. Measured QC: QUAST 61 contigs (≥500bp) / N50 143,933 bp / L50 10 / total
length 4,545,618 bp / GC 50.72% / largest contig 328,315 bp; BUSCO 100.0% complete
(S:100.0%,D:0.0%,F:0.0%,M:0.0%, n=124, `bacteria_odb10`); Prokka 4,232 CDS / 5 rRNA / 77 tRNA /
1 tmRNA / 2 repeat_region across 111 contigs (Prokka's own unfiltered contig set — QUAST's
≥500bp filter drops some of these); fastp 1,890,006 / 2,214,180 reads passed filter (~85.4%).
See `estimates.md` for the full wall-clock/disk measurement and `handoff.md` for the complete
QC table.
