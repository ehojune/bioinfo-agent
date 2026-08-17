# Samplesheets

Most failed runs die here, and they die late: Nextflow validates the sheet, stages 300 GB, runs
for two hours, then a lane collides or a mate file was never there. Everything in this document
exists to move that failure to minute zero.

---

## THE VERIFICATION RULE

**Read the pipeline's own schema before you write a single row. Do not trust the tables below.**

nf-core changes samplesheet columns between releases — columns get added, renamed, made
required, or given tighter regex patterns. The tables here are transcriptions, made at a stated
revision, by someone with no network access. They are a starting point for building a sheet and a
checklist for reviewing one. They are not the contract. The contract is
`assets/schema_input.json` inside the exact revision you are about to run.

```bash
# 1. Pull the revision you intend to run into the shared asset cache.
export NXF_ASSETS="${BIOINFO_REFS:-/refs}/cache/nf-assets"
nextflow pull nf-core/rnaseq -r 3.18.0

# 2. Confirm the tag actually exists (also lists every other available revision).
nextflow info nf-core/rnaseq

# 3. Read the input schema. This is ground truth.
cat "$(find "$NXF_ASSETS" -path '*nf-core/rnaseq*' -name schema_input.json | head -1)"
```

A one-liner that turns the schema into a column table, for the common
`{"type":"array","items":{...}}` shape:

```bash
schema_cols() {  # usage: schema_cols rnaseq
  local f; f=$(find "${NXF_ASSETS:?}" -path "*nf-core/$1*" -name schema_input.json | head -1)
  jq -r '[.. | objects | select(has("properties"))] | .[0]
         | (.required // []) as $r
         | .properties | to_entries[]
         | [ .key,
             (if ($r | index(.key)) then "REQUIRED" else "optional" end),
             (.value.type // "-"),
             (.value.pattern // .value.enum // "-" | tostring) ] | @tsv' "$f" \
  | column -t -s $'\t'
}
```

<!-- UNVERIFIED: the `[.. | objects | select(has("properties"))] | .[0]` selector picks the first
     object carrying `properties`, which is `.items` in every schema seen so far. Some newer
     nf-schema files nest under `$defs`. If the output looks wrong, just `cat` the file. -->

Also useful:

```bash
nextflow run nf-core/rnaseq -r 3.18.0 --help            # parameter list for that exact revision
nf-core pipelines schema docs                            # renders nextflow_schema.json (tools 3.x)
nf-core schema docs                                      # same, tools 2.x
```

**Revision provenance for everything below.** Each table was written against that pipeline's pin in
`config/pipelines.tsv` — the only revision table in this repo. Confirm the tag resolves with
`nextflow info nf-core/<pipeline>` before pinning it in a run plan.

---

## House rules for every sheet on this host

1. **Absolute paths, always.** Relative paths resolve against the *launch directory* — where you
   typed `nextflow run` — not against the samplesheet's own directory. This surprises everyone
   exactly once. Use `/mnt/d/...` or an ext4 path; never `D:\data\...`, never `~/...` (Nextflow
   does not expand tilde inside a CSV field).
2. **LF line endings, no BOM, ASCII only.** The repo lives on NTFS and the sheets get edited in
   Windows editors. See the breakage table.
3. **No quoted fields, no embedded commas.** nf-core CSV parsing is naive and so is the checker.
4. **Sample IDs become filenames and, downstream, R column names.** Constrain them to
   `^[A-Za-z][A-Za-z0-9_]{0,30}$`. Leading digits, hyphens, dots and spaces survive Nextflow and
   then get silently mangled by `make.names()` in differentialabundance, at which point your
   contrasts stop matching anything.
5. **FASTQs sitting on `/mnt/d` are readable but go through drvfs at roughly a fifth of ext4
   speed.** For a total input under ~50 GB, point at `/mnt/d` and eat the penalty — say so in the
   estimate. Above that, copy into ext4 first and point the sheet at the copy. The work directory
   is never on `/mnt/d` regardless.

---

## nf-core/rnaseq — 3.18.0

| column | required | constraint | notes |
|---|---|---|---|
| `sample` | yes | `^\S+$` | rows sharing a value are treated as technical replicates of one sample and are concatenated before alignment |
| `fastq_1` | yes | `^\S+\.f(ast)?q\.gz$` | gzip only; plain `.fastq` is rejected by the pattern |
| `fastq_2` | no | same pattern | leave empty for single-end |
| `strandedness` | yes | `auto` \| `forward` \| `reverse` \| `unstranded` | see below |

```csv
sample,fastq_1,fastq_2,strandedness
KOR_CTRL_01,/data/rna/KOR_CTRL_01_L001_R1.fastq.gz,/data/rna/KOR_CTRL_01_L001_R2.fastq.gz,reverse
KOR_CTRL_01,/data/rna/KOR_CTRL_01_L002_R1.fastq.gz,/data/rna/KOR_CTRL_01_L002_R2.fastq.gz,reverse
KOR_CASE_07,/data/rna/KOR_CASE_07_L001_R1.fastq.gz,/data/rna/KOR_CASE_07_L001_R2.fastq.gz,reverse
```

Two rows for `KOR_CTRL_01` is correct and intentional: two lanes of the same library, merged by
the pipeline. Their `strandedness` values must agree or validation fails.

### Strandedness

`auto` is not free and it is not magic. It subsamples each library, runs `salmon quant` with
`--libType=A`, and maps the reported library type onto the four nf-core values (`ISR`/`SR` →
`reverse`, `ISF`/`SF` → `forward`, `IU`/`U` → `unstranded`). Two consequences on this host:

- It needs a salmon index. `/refs/genomes/GRCh38/index/salmon/` is a `build` row in the manifest —
  it does not exist yet. The first `auto` run pays the index build. Put that in the estimate.
- The inference is per-library, so a mislabelled subset of samples shows up as disagreement
  between rows rather than as an error.

When you already know the prep, declare it and let `auto` off the hook:

| library prep | value |
|---|---|
| Illumina TruSeq Stranded mRNA / Total RNA (dUTP) | `reverse` |
| NEBNext Ultra II Directional (dUTP) | `reverse` |
| KAPA / Roche Stranded (dUTP) | `reverse` |
| Lexogen QuantSeq 3' FWD | `forward` |
| Lexogen QuantSeq 3' REV | `reverse` |
| SMART-Seq2 / SMART-Seq v4 (non-directional, full length) | `unstranded` |
| legacy non-stranded TruSeq | `unstranded` |

<!-- UNVERIFIED: Takara SMARTer Stranded Total RNA-Seq (Pico) v2/v3 orientation — determine
     empirically with a single-sample `auto` run rather than guessing. -->

**When declared and inferred disagree.** rnaseq reports this; recent revisions surface it as a
strand-check table in MultiQC and as `*.strand_check.txt` / `salmon_lib_format_counts.json` under
the salmon output directory. Rules of thumb:

- Inference is unambiguous (one direction dominant) and *consistent across every sample*, but
  contradicts the kit datasheet → **trust the data**. Datasheets describe the kit; sheets describe
  what the core facility actually did. Re-run with the inferred value.
- Inference is ambiguous (roughly balanced) on a library that should be stranded → suspect
  degraded RNA, gDNA carry-over, or a non-directional prep mislabelled. Report it; do not silently
  pick a side.
- Inference splits *between* samples in the same batch → you have two library preps in one
  experiment, or a swapped file. Stop and hand it back to the user with the per-sample table.

Getting this wrong does not crash anything. It roughly halves usable counts and inflates the
antisense fraction, and the run reports success. This is the single most expensive silent error in
RNA-seq.

<!-- UNVERIFIED: recent rnaseq revisions expose `--stranded_threshold` (~0.8) and
     `--unstranded_threshold` (~0.1) controlling how the salmon call is bucketed. Confirm with
     `nextflow run nf-core/rnaseq -r <rev> --help | grep -i strand`. -->

---

## nf-core/sarek — 3.5.1

Sarek's sheet carries more semantics than any other stocked pipeline, because it drives read
groups, pairing, and ploidy.

### Columns at `--step mapping` (FASTQ input)

| column | required | values | what it controls |
|---|---|---|---|
| `patient` | yes | `^\S+$` | the individual. Groups rows for tumour–normal pairing and for joint germline calling |
| `sample` | yes | `^\S+$` | the biosample / library. Unique within a patient. Becomes `SM:` in the read group and the output filename stem |
| `lane` | yes (with FASTQ) | free string | the sequencing unit. Becomes `PU:` and, combined with sample, the read-group `ID:` |
| `sex` | no | `XX` \| `XY` \| `NA` | ploidy for CNV/allele-specific callers (ASCAT, CNVkit, ControlFREEC) and sex-chromosome handling. Default `NA` |
| `status` | no | `0` (normal) \| `1` (tumour) | default `0`. Drives somatic pairing |
| `fastq_1`, `fastq_2` | yes | `^\S+\.f(ast)?q\.gz$` | |

```csv
patient,sex,status,sample,lane,fastq_1,fastq_2
KG0142,XY,0,KG0142_blood,HKJL7DSX5.1,/data/wgs/KG0142_blood_HKJL7DSX5_L001_R1.fastq.gz,/data/wgs/KG0142_blood_HKJL7DSX5_L001_R2.fastq.gz
KG0142,XY,0,KG0142_blood,HKJL7DSX5.2,/data/wgs/KG0142_blood_HKJL7DSX5_L002_R1.fastq.gz,/data/wgs/KG0142_blood_HKJL7DSX5_L002_R2.fastq.gz
KG0142,XY,1,KG0142_tumour,HKJL7DSX5.3,/data/wgs/KG0142_tumour_HKJL7DSX5_L003_R1.fastq.gz,/data/wgs/KG0142_tumour_HKJL7DSX5_L003_R2.fastq.gz
```

### Why `lane` matters

Sarek aligns each lane row independently and merges afterwards. The read group it emits is
derived from sample and lane — approximately
`@RG ID:<sample>_<lane> SM:<sample> LB:<sample> PU:<lane> PL:ILLUMINA`.

<!-- UNVERIFIED: exact @RG ID construction. Confirm by reading
     $NXF_ASSETS/.repos/nf-core/sarek/clones/*/modules/nf-core/bwa/mem/ and the sarek `main.nf` meta handling,
     or just `samtools view -H` the first BAM out of a stub-free single-sample run. -->

Read groups are not cosmetic:

- **BQSR** models error covariates per read group. Pooling two flowcells into one read group
  averages away exactly the batch effect it is supposed to correct.
- **MarkDuplicates** uses the read group and the tile/x/y coordinates to distinguish optical from
  PCR duplicates. Wrong grouping distorts the duplicate rate.
- **Joint calling** downstream needs `SM:` to be stable and unique per biosample.

The concrete trap: two different flowcells both have a lane numbered `1`. If you write `1` for
both, you get two rows with the same derived read-group ID, and GATK will stop with
`Duplicate read group id` (or worse, a merge step silently keeps one). Always qualify the lane
with the flowcell: `HKJL7DSX5.1`, not `1`. Pull the flowcell ID out of the FASTQ header
(field 3 of a Casava 1.8 name line) rather than trusting the filename.

### Tumour–normal pairing

Pairing is expressed structurally, not by a column pointing at another row: two or more rows share
a `patient`, one carries `status 0`, another `status 1`. Somatic callers (Mutect2, Strelka2
somatic, ASCAT, MSIsensorPro, Manta somatic) then pair them automatically.

- Multiple tumours + one normal → each tumour is called against that normal.
- One tumour + no normal → tumour-only mode; Mutect2 runs without a matched normal and needs the
  gnomAD `germline_resource` and ideally a panel of normals. That resource is a `fetch` row in
  `refs.manifest.tsv` and is not present. Flag it before promising a somatic run.
- Two normals for one patient → ambiguous. Do not leave this to the pipeline; split into separate
  patients or drop one, and **say out loud which one you dropped**.

### Restarting from BAM / CRAM / VCF

You do not rebuild the sheet from scratch — you build a different sheet with different columns.
Match the columns to `--step`:

| `--step` | columns |
|---|---|
| `mapping` | `patient,sex,status,sample,lane,fastq_1,fastq_2` |
| `markduplicates` | `patient,sex,status,sample,bam,bai` |
| `prepare_recalibration` | `patient,sex,status,sample,cram,crai` |
| `recalibrate` | `patient,sex,status,sample,cram,crai,table` |
| `variant_calling` | `patient,sex,status,sample,cram,crai` |
| `annotate` | `patient,sample,vcf` (optionally `variantcaller`) |

Note that `lane` disappears once the lanes have been merged — read groups now live inside the BAM
header and the sheet stops describing them.

<!-- UNVERIFIED: sarek also accepts unaligned BAM at --step mapping (columns
     patient,sample,lane,bam,bai) and, in 3.5+, SPRING-compressed FASTQ via spring_1/spring_2.
     Confirm both against assets/schema_input.json for the pinned revision before using them. -->

**CRAM is reference-bound.** A CRAM can only be decoded against the exact FASTA it was compressed
against — matched by sequence MD5, not by filename. Restarting from someone else's CRAM with the
wrong `--fasta` gives you:

```
[E::cram_get_ref] Failed to populate reference for id 0
samtools view: error reading file "sample.cram"
```

On this host that means: a CRAM produced against `GRCh38gatk` (the no-ALT/no-HLA/no-decoy analysis
set) will not decode against `GRCh38` (UCSC hg38), even though both are "hg38". Check with
`samtools view -H x.cram | grep '^@SQ' | head` and compare `M5:` values against
`/refs/genomes/<BUILD>/fasta/genome.dict`. Which reminds you: neither build has a `.dict` yet.

---

## nf-core/differentialabundance — 1.5.0

Three files must agree with each other, and the failure mode when they do not is a cryptic R
error rather than a schema error.

### `--input` (the observations / sample metadata sheet)

Free-form CSV. Every column becomes a variable you can use in a contrast. One column identifies
the observation; its name is given by `--observations_id_col` (default `sample`).

```csv
sample,condition,batch,sex,rin
KOR_CTRL_01,control,B1,XX,8.4
KOR_CTRL_02,control,B2,XY,7.9
KOR_CASE_07,case,B1,XY,8.1
KOR_CASE_09,case,B2,XX,8.8
```

### `--matrix` (the counts matrix)

Coming out of nf-core/rnaseq, this is typically
`<rnaseq_outdir>/star_salmon/salmon.merged.gene_counts.tsv`. **Its column headers must be exactly
the values in the id column** — same strings, same case, no extra suffixes. rnaseq writes the
`sample` values from its own samplesheet as headers, so if the two sheets were built from the same
source they match; if a human retyped one of them they do not.

**Resolved 2026-08-10, run `20260810-differentialabundance-gln3-ibutanol`, first run of this
pipeline on this host.** `--matrix` takes the raw `salmon.merged.gene_counts.tsv`, paired with
`--transcript_length_matrix salmon.merged.gene_lengths.tsv` (same shape: `gene_id`, `gene_name`,
then one average-transcript-length column per sample) — not the length-scaled matrix on its own.
Confirmed against the pipeline's own `conf/test.config` (`matrix` + `transcript_length_matrix` +
`contrasts` + `gtf` + `input`, the exact combination it exercises in CI) and against
`workflows/differentialabundance.nf`'s `ch_transcript_lengths` channel, which is optional but
feeds `DESEQ2_NORM`/`DESEQ2_DIFFERENTIAL` directly when supplied. `nextflow run
nf-core/differentialabundance -r 1.5.0 --help` does not run standalone — it errors
`Input samplesheet not specified!` with no other params given; `nextflow_schema.json`'s
`abundance_values` group is the reliable source instead.

### `--contrasts` (contrasts.csv)

| column | required | meaning |
|---|---|---|
| `id` | yes | label for this comparison; ends up in output filenames, so keep it filesystem-safe |
| `variable` | yes | **must be a column name in the observations sheet** |
| `reference` | yes | the baseline level — **must be a value present in that column** |
| `target` | yes | the level being compared against baseline |
| `blocking` | no | `;`-separated covariates added to the design formula |

```csv
id,variable,reference,target,blocking
case_vs_control,condition,control,case,
case_vs_control_batchadj,condition,control,case,batch
case_vs_control_full,condition,control,case,batch;sex
```

The design becomes roughly `~ batch + sex + condition`, with the log2 fold change reported as
target relative to reference. Get `reference` and `target` backwards and the pipeline runs
perfectly and reports every sign inverted.

**Resolved 2026-08-10.** No `schema_contrasts.json` (or any other JSON schema for the contrasts
file) exists in `assets/` at 1.5.0 (commit `3dd360fed0`) — `assets/` there holds only
`schema_input.json`, which validates `--input`, not `--contrasts`. Contrasts validation happens in
R, inside the `VALIDATOR` process (`validate_fom_components.R`) and the DESeq2/limma modules
themselves, which is why a bad `variable`/`reference`/`target` surfaces as the R error text quoted
below rather than a schema rejection. `blocking` is confirmed real and load-bearing — read
directly off `modules/nf-core/deseq2/differential/templates/deseq_de.R`, which adds it to the
design formula. No `pairing`, `exclude_samples_col` or `exclude_samples_values` columns exist at
this revision; do not add them speculatively.

Failure modes specific to this pipeline:

- A `variable` naming a column that does not exist, or a `reference`/`target` naming a level that
  does not exist, fails inside the R validator with something like
  `Error: contrast variable 'Condition' not found in observations` — note the capital C. Matching
  is case-sensitive.
- Metadata values containing spaces, hyphens, or a leading digit are rewritten by R's
  `make.names()` (`case-1` → `case.1`), after which the contrast lookup fails. Sanitise the
  metadata, not the contrast.
- A column whose values are all identical, or one that is perfectly confounded with the contrast
  variable (every case in batch B1, every control in B2), makes the design matrix rank-deficient.
  DESeq2 stops with `the model matrix is not full rank`. That is a study-design problem, not a
  samplesheet problem — report it and stop.

---

## nf-core/fetchngs — 1.12.0

`--input` is an accession list: **one accession per line, single column, no header.**

```
PRJNA818734
SRR15498316
SRR15498317
GSE214215
```

**Confirmed at 1.12.0 (run 20260810-fetchngs-citest, first execution of this pipeline on this
host): no header row is tolerated.** `subworkflows/local/utils_nfcore_fetchngs_pipeline/main.nf`
reads `--input` with `.splitCsv(header:false, sep:'', strip:true)` and validates every line
against the accession regex via `isSraId()`; a literal `id` (or any other header word) does not
match it, so `isSraId()` raises `Mixture of ids provided via --input: id` and the run aborts
before any download. Do not add a header line — not even `id`, and not even to make the file
self-documenting.

`bin/preflight.sh`'s `== samplesheet ==` section and `scripts/check-samplesheet.sh`'s file-hygiene
section both special-case `fetchngs` and count every non-blank line as an accession (no line is
treated as a header), so their reported count is the true accession count for this pipeline.

Accepted accession families:

| family | prefixes |
|---|---|
| SRA (NCBI) | `SRR` run, `SRX` experiment, `SRS` sample, `SRP` study |
| ENA (EBI) | `ERR`, `ERX`, `ERS`, `ERP` |
| DDBJ | `DRR`, `DRX`, `DRS`, `DRP` |
| BioProject | `PRJNA`, `PRJEB`, `PRJDB` |
| BioSample | `SAMN`, `SAMEA`, `SAMD` |
| GEO | `GSE` series, `GSM` sample |

Study-level accessions (`PRJNA*`, `SRP*`, `GSE*`) expand to every run underneath. A GEO series with
400 samples will happily start 400 downloads; check the expansion before you launch.

Useful parameters:

- `--nf_core_pipeline rnaseq` makes fetchngs emit a ready-to-use downstream samplesheet under
  `<outdir>/samplesheet/samplesheet.csv`. **Review it, do not just pipe it onward.** Sample IDs
  come from SRA metadata and are frequently ugly, occasionally non-unique across runs of the same
  biosample, and strandedness is written as whatever `--nf_core_rnaseq_strandedness` says
  (default `auto`).
- `--download_method` (`ftp` | `sratools` | `aspera`). ENA FTP is the fastest and needs no
  toolkit; fall back to `sratools` when ENA has no FTP path for the run.
- Everything here requires network. Under `NXF_OFFLINE=true` fetchngs is pointless by
  construction.

---

## The remaining stocked pipelines

Same verification rule applies. Confirm each against `assets/schema_input.json`.

### nf-core/methylseq — 3.0.0

`sample,fastq_1,fastq_2`

```csv
sample,fastq_1,fastq_2
BS_CTRL_01,/data/wgbs/BS_CTRL_01_R1.fastq.gz,/data/wgbs/BS_CTRL_01_R2.fastq.gz
BS_CASE_04,/data/wgbs/BS_CASE_04_R1.fastq.gz,/data/wgbs/BS_CASE_04_R2.fastq.gz
```

<!-- UNVERIFIED: methylseq 3.x may accept an additional per-row `genome` column (useful for
     lambda / spike-in controls). Verify before relying on it. -->

The bismark index is a `build` manifest row and does not exist. First run pays it; use
`--save_reference` so the second run does not.

### nf-core/atacseq — 2.1.2

`sample,fastq_1,fastq_2,replicate`

```csv
sample,fastq_1,fastq_2,replicate
LCL_CTRL,/data/atac/LCL_CTRL_rep1_R1.fastq.gz,/data/atac/LCL_CTRL_rep1_R2.fastq.gz,1
LCL_CTRL,/data/atac/LCL_CTRL_rep2_R1.fastq.gz,/data/atac/LCL_CTRL_rep2_R2.fastq.gz,2
LCL_TREAT,/data/atac/LCL_TREAT_rep1_R1.fastq.gz,/data/atac/LCL_TREAT_rep1_R2.fastq.gz,1
```

`replicate` is an integer and must be unique within a `sample`. Replicate numbering restarts per
sample. Consensus peaks and the merged-replicate track set are built from this grouping, so
mislabelling replicates changes the biology of the output, not just its names.

### nf-core/chipseq — 2.1.0

`sample,fastq_1,fastq_2,replicate,antibody,control,control_replicate`

```csv
sample,fastq_1,fastq_2,replicate,antibody,control,control_replicate
CTCF_LCL,/data/chip/CTCF_LCL_rep1_R1.fastq.gz,/data/chip/CTCF_LCL_rep1_R2.fastq.gz,1,CTCF,INPUT_LCL,1
CTCF_LCL,/data/chip/CTCF_LCL_rep2_R1.fastq.gz,/data/chip/CTCF_LCL_rep2_R2.fastq.gz,2,CTCF,INPUT_LCL,2
INPUT_LCL,/data/chip/INPUT_LCL_rep1_R1.fastq.gz,/data/chip/INPUT_LCL_rep1_R2.fastq.gz,1,,,
```

Control rows must leave `antibody`, `control` and `control_replicate` **empty**. `control` names
the `sample` value of the input row and `control_replicate` its `replicate` number; both must
resolve to an actual row or peak calling silently drops the pairing.

### nf-core/cutandrun — 3.2.2

`group,replicate,fastq_1,fastq_2,control`

```csv
group,replicate,fastq_1,fastq_2,control
H3K27me3,1,/data/cnr/H3K27me3_rep1_R1.fastq.gz,/data/cnr/H3K27me3_rep1_R2.fastq.gz,igg
H3K27me3,2,/data/cnr/H3K27me3_rep2_R1.fastq.gz,/data/cnr/H3K27me3_rep2_R2.fastq.gz,igg
igg,1,/data/cnr/IgG_rep1_R1.fastq.gz,/data/cnr/IgG_rep1_R2.fastq.gz,
```

Note this one uses `group`, not `sample`. `control` names another row's `group` value.

### nf-core/scrnaseq — 2.7.1

`sample,fastq_1,fastq_2` plus optional `expected_cells`, `seq_center`

```csv
sample,fastq_1,fastq_2,expected_cells
PBMC_KOR_01,/data/sc/PBMC_KOR_01_S1_L001_R1_001.fastq.gz,/data/sc/PBMC_KOR_01_S1_L001_R2_001.fastq.gz,8000
PBMC_KOR_01,/data/sc/PBMC_KOR_01_S1_L002_R1_001.fastq.gz,/data/sc/PBMC_KOR_01_S1_L002_R2_001.fastq.gz,8000
PBMC_KOR_02,/data/sc/PBMC_KOR_02_S2_L001_R1_001.fastq.gz,/data/sc/PBMC_KOR_02_S2_L001_R2_001.fastq.gz,8000
```

**Do not swap R1 and R2.** For 10x, `fastq_1` is the barcode+UMI read (26–28 bp) and `fastq_2` is
the cDNA read. Swapping them does not error — the aligner finds almost no valid barcodes and you
get a near-empty matrix after several hours. The length asymmetry makes this trivially checkable
before launch (see the checker below).

### nf-core/ampliseq — 2.18.0

`schema_input.json` at this pin defines **two mutually exclusive column sets** via `oneOf` with an
explicit `not: anyOf` on the other set's names — a sheet mixing `sampleID` with `fastq_1`, or
`sample` with `forwardReads`, fails schema validation outright, not just a lint warning:

| form | required | optional |
|---|---|---|
| legacy | `sampleID`, `forwardReads` | `reverseReads` |
| standardized | `sample`, `fastq_1` | `fastq_2` |

Both forms also accept `run` (tags which sequencing batch a **different** sample's row belongs to
— per-run DADA2 error models, not a way to repeat a sample; see uniqueness below — defaults to
`"1"` if omitted) and `control`/`quant_reading` (only used by the decontam module, gated behind
`--filter_extra_data`/related params). `reverseReads`/`fastq_2` are optional — single-end amplicon
designs are supported.

```csv
sample,fastq_1,fastq_2
gut_ctrl_01,/data/16s/gut_ctrl_01_R1.fastq.gz,/data/16s/gut_ctrl_01_R2.fastq.gz
gut_case_04,/data/16s/gut_case_04_R1.fastq.gz,/data/16s/gut_case_04_R2.fastq.gz
```

**ID uniqueness**: the schema enforces `uniqueEntries` on **both** `sample` and `sampleID`
independently, per-field — not a composite with `run`, and not left to a downstream dedup step the
way rnaseq merges duplicate sample IDs across lanes. Confirmed empirically (`nextflow -preview` on
a two-row sheet with the same `sample` and different `run` values): `Detected duplicate entries:
[sample:S1]`, hard failure. **`run` does not license repeating a `sample`/`sampleID` value** — it
tags which sequencing batch a distinct sample's row came from, matching the pipeline's own docs
("sample: required, **Unique** sample identifiers" — `docs/usage.md`), so re-sequencing the same
biological sample needs a distinct `sample`/`sampleID` value per row regardless of `run`.
`scripts/check-samplesheet.sh --pipeline ampliseq` fails on any duplicate before Nextflow starts.

**Silent-failure note**: `--FW_primer`/`--RV_primer` do not validate against the actual read
content — a wrong primer pair passes schema validation and launches cleanly, then cutadapt
discards nearly every read at the trimming step. This surfaces in `overall_summary.tsv`'s
`cutadapt_passing_filters_percent` column, not as an error; check it is not near-zero before
trusting anything downstream.

### nf-core/mag — 5.5.0

`schema_input.json` at this pin, re-read against the pinned clone (2026-08-12):

| column | required | notes |
|---|---|---|
| `sample` | yes | `meta.id`. `^\S+$` |
| `group` | yes | `meta.group`. String or integer; co-assembly/co-binning grouping key |
| `run` | no | `meta.run`. Tags which sequencing run a **multirun** sample's row belongs to (co-assembled per sample, kept separate for per-run QC) — not a way to repeat a `sample` value; see uniqueness below |
| `short_reads_1` | one of `short_reads_1` / `long_reads`, per row | `.f(ast)?q\.gz$` |
| `short_reads_2` | no | requires `short_reads_1` present on the same row |
| `short_reads_platform` | required if `short_reads_1` present | enum: `ILLUMINA`, `BGISEQ`, `LS454`, `ION_TORRENT`, `DNBSEQ`, `ELEMENT`, `ULTIMA`, `VELA_DIAGNOSTICS`, `GENAPSYS`, `GENEMIND`, `TAPESTRI` |
| `long_reads` | no | one of `short_reads_1` / `long_reads` per row; `.f(ast)?q\.gz$` |
| `long_reads_platform` | required if `long_reads` present | enum: `OXFORD_NANOPORE`, `OXFORD_NANOPORE_HQ`, `PACBIO_CLR`, `PACBIO_HIFI` |

All four `dependentRequired`/`anyOf` constraints above are **per row**, not per sheet or per
column — confirmed empirically (`nextflow -preview`, 2026-08-12): a sheet whose `long_reads`
column exists in the header but is empty for every row validates cleanly as long as
`short_reads_1`/`short_reads_platform` are populated on those rows. Checking "does this
column exist" instead of "does this row have a value" is the wrong question and
`scripts/check-samplesheet.sh --pipeline mag` checks values, not column presence.

```csv
sample,group,short_reads_platform,short_reads_1,short_reads_2,long_reads
gut_ctrl_01,0,ILLUMINA,/data/mgx/gut_ctrl_01_R1.fastq.gz,/data/mgx/gut_ctrl_01_R2.fastq.gz,
gut_case_04,0,ILLUMINA,/data/mgx/gut_case_04_R1.fastq.gz,/data/mgx/gut_case_04_R2.fastq.gz,
```

**ID uniqueness**: the schema's top-level `"uniqueEntries": ["sample", "run"]` is a
**composite key**, not per-field independent uniqueness the way ampliseq's is — confirmed
empirically (`nextflow -preview`, 2026-08-12, three fixtures): the same `sample` with
*different* `run` values passes (this is the pipeline's own supported "multirun" shape — a
sample re-sequenced across lanes/runs, co-assembled together but QC'd per run — and its own
`conf/test.config` fixture does exactly this); the same `sample`+`run` pair repeated fails
with `Detected duplicate entries: [sample:S1, run:1]`; the same `sample` repeated with `run`
omitted entirely on both rows also fails, on `[sample:S1]` alone (both rows collapse onto the
same implicit key when neither carries a real one). `scripts/check-samplesheet.sh --pipeline
mag` checks the `sample`+`run` pair when a `run` column is present.

**Silent-failure note**: none of the four `dependentRequired`/`anyOf` violations above (a
`short_reads_2` with no `short_reads_1`, a `short_reads_1` with no
`short_reads_platform`, etc.) are silent — nf-schema rejects them before the pipeline runs
any task. The actual silent-failure risk with mag is downstream of the samplesheet: BUSCO
(`--run_busco`, on by default) auto-selects a lineage unless `--busco_db_lineage` is pinned,
and a shallow/low-diversity assembly can legitimately produce zero bins for every binner
without any schema or launch-time error — see
`runs/20260812-mag-drr027580-realsample/handoff.md` for a real example (74 contigs, all
< 1500 bp, zero bins from any of three binners, pipeline still exits 0). Check
`GenomeBinning/*/bins/` is non-empty before trusting a "successful" mag run produced any MAGs
at all.

---

### nf-core/taxprofiler — 2.0.1

Two CSVs, not one. `--input` (`assets/schema_input.json`) and `--databases`
(`assets/schema_database.json`), both re-read against the pinned clone (2026-08-12).

#### `--input`

| column | required | notes |
|---|---|---|
| `sample` | yes | `meta.id`. String or integer, `^\S+$` |
| `run_accession` | yes | tags which sequencing run this row is — required (unlike mag's optional `run`), and part of the composite uniqueness key below |
| `instrument_platform` | yes | enum: `ABI_SOLID`, `BGISEQ`, `CAPILLARY`, `COMPLETE_GENOMICS`, `DNBSEQ`, `HELICOS`, `ILLUMINA`, `ION_TORRENT`, `LS454`, `OXFORD_NANOPORE`, `PACBIO_SMRT` |
| `fastq_1` | **no** | `.f(ast)?q\.gz$`. Not in the schema's `required[]` — see silent-failure note below |
| `fastq_2` | no | `.f(ast)?q\.gz$`. Leave empty for single-end/long-read rows |
| `fasta` | no | `.(fasta|fas|fna|fa)\.gz?$` — an already-assembled contig set can be profiled directly instead of/alongside reads |

```csv
sample,run_accession,instrument_platform,fastq_1,fastq_2
gut_ctrl_01,ERR000001,ILLUMINA,/data/mgx/gut_ctrl_01_R1.fastq.gz,/data/mgx/gut_ctrl_01_R2.fastq.gz
gut_ctrl_01,ERR000002,ILLUMINA,/data/mgx/gut_ctrl_01_resequenced_R1.fastq.gz,/data/mgx/gut_ctrl_01_resequenced_R2.fastq.gz
```

The second row is the pipeline's own supported shape for "same biological sample,
resequenced" — same `sample`, different `run_accession`, merged downstream if
`--perform_runmerging true`.

**ID uniqueness**: `"uniqueEntries": ["sample", "run_accession"]` is a **composite key**,
same shape as mag's `[sample, run]` — confirmed empirically (`nextflow -preview`,
2026-08-12): the same `sample` with a *different* `run_accession` passes; the same
`sample`+`run_accession` pair repeated fails with `Detected duplicate entries:
[sample:S1, run_accession:R1]`. Because `run_accession` is schema-required here (mag's `run`
is optional), there is no "collapses to sample-only uniqueness" fallback case to worry about.
**Separately, and unlike mag**: `fastq_1`, `fastq_2`, and `fasta` are each their **own
independent per-field `uniqueEntries`**, confirmed empirically — two rows with different
`sample`/`run_accession` but pointing at the *same* `fastq_1` file both fail schema
validation (`Detected duplicate entries: [fastq_1:/path/...]`). Reusing one FASTQ across two
sheet rows, which is unremarkable in mag or rnaseq, is a hard schema error here.
`scripts/check-samplesheet.sh --pipeline taxprofiler` checks both the composite key and the
three per-field uniqueness constraints.

**Silent-failure note**: `fastq_1`/`fastq_2`/`fasta` are all schema-optional, and a row with
*none* of the three **validates cleanly** — confirmed empirically (`nextflow -preview` on a
sheet with only `sample`/`run_accession`/`instrument_platform` columns: `completed=0
failed=0`, no error). The schema alone will not catch a metadata-only row with nothing for
the pipeline to actually profile; `scripts/check-samplesheet.sh --pipeline taxprofiler`
**FAILS** both shapes — a sheet with none of the three columns present at all, and any
individual row that has the columns but leaves every one empty. A mixed sheet where only some
rows are empty would otherwise still exit 0 and print `PASS` overall while the pipeline
silently schedules nothing for the empty row (Codex review, PR #36) — not treated as a
plausible-placeholder case worth a mere warning, given a warning-tolerant or automated launch
would sail straight through it.

#### `--databases`

| column | required | notes |
|---|---|---|
| `tool` | yes | enum: `bracken`, `centrifuge`, `diamond`, `ganon`, `kaiju`, `kmcp`, `kraken2`, `krakenuniq`, `malt`, `metaphlan`, `motus`, `sylph`, `melon`, `metacache` |
| `db_name` | yes | free string, unique per `tool` (`"uniqueEntries": ["tool", "db_name"]` — composite, so the same `db_name` can be reused across different `tool` values) |
| `db_path` | yes | file or directory, must exist |
| `db_params` | no | extra CLI args passed to that tool; **no quote characters allowed** (`^[^"']*$`) |
| `db_type` | no | enum `short` / `long` / `short;long`, default `short;long` — restricts which read type this DB applies to |

```csv
tool,db_name,db_path,db_params,db_type
kraken2,k2standard08gb,/refs/db/kraken2/k2_standard_08gb,,short
```

A `--run_<tool> true` flag with no matching row in `--databases` for that `tool` is **not an
error** — it is silently a no-op for that tool. The `--databases` CSV, not the `--run_*`
boolean flags, is what actually determines whether classification happens; check both are
consistent before launch.

### nf-core/raredisease — 3.1.2

`assets/schema_input.json` re-read at this pin (2026-08-12). `required[]` = `sample`,
`sex`, `phenotype`, `case_id` on every row. Read source (`fastq_1`, `spring_1`, or `bam`+`bai`)
is NOT in `required[]` at the schema's top level — see the no-op uniqueness note below before
assuming a sheet with none of them is caught.

| column | required | notes |
|---|---|---|
| `sample` | yes | `meta.id`. String, `^\S+$` |
| `sex` | yes | closed enum `0` / `1` / `2` / `other` — PED convention (`0`=unknown, `1`=male, `2`=female), NOT the free-text `XX`/`XY`/`NA` other pipelines here use |
| `phenotype` | yes | closed enum `0` / `1` / `2` — PED convention (`0`=missing, `1`=unaffected, `2`=affected), not free text |
| `case_id` | yes | groups rows into one family/case; repeating it across rows is the pipeline's normal shape (see uniqueness note) |
| `fastq_1`/`fastq_2` | no | one read-source family; `lane` present on a row triggers `dependentRequired{lane:[fastq_1]}` |
| `spring_1` | no | alternate compressed-read format; `lane` present triggers `dependentRequired{lane:[spring_1]}` instead |
| `bam`/`bai` | no | pre-aligned entry point (this repo's raredisease procurement used this); `bam` present requires `bai` (`dependentRequired{bam:[bai]}`) |

```csv
sample,sex,phenotype,case_id,bam,bai
SRR26793256,0,0,SRR26793256_case,/data/rd/SRR26793256.md.bam,/data/rd/SRR26793256.md.bam.bai
```

**ID uniqueness — a documented no-op, not a composite key.** The schema declares
`"uniqueEntries": ["case_id"]`, but places the keyword *inside* `items`, not at the array's
own top level (contrast mag/taxprofiler, where the array-level placement makes their
composite keys real constraints). nf-schema's `UniqueEntriesEvaluator` only evaluates against
an array node; a keyword nested under `items` is evaluated once per object element and never
sees the array, so it short-circuits to success unconditionally. Confirmed empirically
(`nextflow -preview`, 2026-08-12): the pipeline's own shipped test fixture, which repeats
`case_id` across every row of a multi-member family on purpose, validates cleanly — and so
does a sheet with two fully identical rows. **Do not flag repeated `case_id` as a duplicate
row** — that is the intended shape (one `case_id` shared by every member of a family/case),
not something to warn on. `scripts/check-samplesheet.sh --pipeline raredisease` checks
`sex`/`phenotype` enum membership and read-source presence, but deliberately does not attempt
a `case_id` uniqueness check.

**Silent-scheduling note**: a sheet with none of `fastq_1`/`spring_1`/`bam` present is not
caught by the JSON schema alone (no top-level `required` entry forces one), the same shape of
gap as taxprofiler's fastq-optional rows. `scripts/check-samplesheet.sh` fails a sheet missing
all three read-source families.

### nf-core/nanoseq — 3.1.0

**`assets/schema_input.json` is NOT what this pipeline validates against — confirmed empirically
2026-08-13.** That file (present in the pinned clone) describes `sample`/`fastq_1`/`fastq_2`,
but grepping the entire clone's `workflows/`, `subworkflows/`, `modules/` for
`schema_input|validateParameters|fromSamplesheet|nf-validation|nf-schema` returns nothing — it
is never referenced by any `.nf` file at this pin, purely vestigial nf-core-template
boilerplate. The samplesheet nanoseq actually validates at runtime is checked by its own
bundled Python script, `bin/check_samplesheet.py`, run through the `SAMPLESHEET_CHECK` module
(`subworkflows/local/input_check.nf` calls it, then `.splitCsv` on *its* reformatted output —
not the user's raw sheet). Every rule below is read directly out of that script, not out of the
unused JSON schema.

| column | required | notes |
|---|---|---|
| `group` | yes | becomes `{group}_R{replicate}` as the internal sample id; no literal spaces allowed |
| `replicate` | yes | bare integer; ids must run `1..N` contiguously per group (no gaps, no repeats) |
| `barcode` | no | bare integer if given (zero-padded to `barcodeNN` internally); leave empty for an already-demultiplexed FASTQ |
| `input_file` | no* | `.fastq.gz`, `.fq.gz`, `.bam`, or an existing ONT run directory (fast5+fastq, for nanopolish); **every** `input_file` value across the whole sheet must share one extension family — mixing e.g. `.bam` and `.fastq.gz` rows fails the whole sheet, not just the mismatched row |
| `fasta` | no | per-sample reference genome: plain `.fa`/`.fasta` (gzip optional) or an iGenomes shorthand key (e.g. `GRCh37`) — this repo's convention is always the standard manifest absolute path, never the shorthand |
| `gtf` | no | `.gtf`/`.gtf.gz`, needed only for cDNA/directRNA transcript quantification |

\* At least 3 of the 6 columns must be non-empty per row (`check_samplesheet.py`'s
`MIN_COLS=3`) — `group`+`replicate` count as 2 of those 3, so in practice at least one of
`barcode`/`input_file`/`fasta`/`gtf` must also carry a value.

```csv
group,replicate,barcode,input_file,fasta,gtf
SRR25466853,1,,/work/staging/nanoseq-realsample/SRR25466853.fastq.gz,/refs/genomes/ECOLI_K12/fasta/genome.fa,
```

This is the exact sheet from `runs/20260813-nanoseq-srr25466853/samplesheet.csv` — a single
already-basecalled FASTQ given directly as `input_file`, `--skip_demultiplexing true` at the
pipeline level (no `barcode`/`--input_path`/`--barcode_kit` needed), a plain per-sample
reference FASTA, no transcript GTF (DNA protocol).

**ID uniqueness/dedup rule — group/replicate pairs, not a `sample` column.** There is no
`sample` column at all; the internal sample id is derived as `{group}_R{replicate}`.
`check_samplesheet.py` hard-errors on a repeated `group`/`replicate` pair ("Same replicate id
provided multiple times!") and on a group whose replicate ids are not a contiguous `1..N` run
starting at 1 ("Replicate ids must start with 1..<num_replicates>!") — both confirmed by reading
the script directly (`bin/check_samplesheet.py`, `nanoseq` clone at this pin) and reproduced via
`scripts/check-samplesheet.sh --pipeline nanoseq` against a synthetic bad sheet (duplicate
`S3`/`1` pair, and a non-contiguous `S2`/`S3`/`S4` replicate run, both correctly flagged FAIL).

**Silent-failure note — the multi-extension-family rule is whole-sheet, not per-row.** A sheet
where every individual `input_file` value has a valid extension can still fail entirely if two
rows use *different* families (one `.bam`, one `.fastq.gz`) — `check_samplesheet.py`'s
`"All input files must have the same extension!"` check runs once over the whole sheet after
every row is otherwise valid. `scripts/check-samplesheet.sh --pipeline nanoseq` reproduces this
same whole-sheet check, not just a per-row suffix check.

---

### nf-core/rnasplice — 1.0.4

**`assets/schema_input.json` is NOT what this pipeline validates against for the `fastq` source
(the only source this repo stocks) — confirmed empirically 2026-08-14, same class of finding as
nanoseq above.** That file describes `sample`/`fastq_1`/`fastq_2`/`strandedness`/`condition`, but
grepping the whole clone's `workflows/`, `subworkflows/`, `modules/` for
`schema_input|validateParameters|nf-validation|nf-schema` returns nothing wired to it. The
samplesheet actually enforced at runtime is the pipeline's own `bin/check_samplesheet_fastq.py`,
run through the local `SAMPLESHEET_CHECK` module. Every rule below is read directly out of that
script.

| column | required | notes |
|---|---|---|
| `sample` | yes | non-empty; spaces get silently replaced with `_` |
| `fastq_1` | yes | must end `.fq.gz` or `.fastq.gz` |
| `fastq_2` | header yes, value no | **header must exist even for single-end rows** — `required_columns` is checked against the header set, not per-row; value may be empty |
| `strandedness` | yes | enum `unstranded`/`forward`/`reverse` **only** — `auto` is REJECTED ("unrecognized value"), unlike `rnaseq`'s `strandedness` column which accepts it |
| `condition` | yes | free-form group label, loosely validated — accepted if it starts with a letter, OR starts with a dot followed by a letter/dot/underscore, OR ends with a literal dot (`.foo`, `1.`, `WT_ctrl` all pass; `1bad`, `_bad` do not); see `scripts/check-samplesheet.sh`'s comment on this column for the full derivation against the pipeline's actual `re.search` semantics |

```csv
sample,fastq_1,fastq_2,strandedness,condition
WT_ctrl_rep1,/work/rawdata/.../ERR3450098_1.fastq.gz,/work/rawdata/.../ERR3450098_2.fastq.gz,reverse,WT_ctrl
WT_ctrl_rep2,/work/rawdata/.../ERR3450099_1.fastq.gz,/work/rawdata/.../ERR3450099_2.fastq.gz,reverse,WT_ctrl
WT_ibuoh_rep1,/work/rawdata/.../ERR3450100_1.fastq.gz,/work/rawdata/.../ERR3450100_2.fastq.gz,reverse,WT_ibuoh
WT_ibuoh_rep2,/work/rawdata/.../ERR3450101_1.fastq.gz,/work/rawdata/.../ERR3450101_2.fastq.gz,reverse,WT_ibuoh
```

Excerpted from `runs/20260814-rnasplice-scer-gln3-ibutanol/samplesheet.csv` (8 rows, 4 conditions
× 2 replicates total) — strandedness was fixed at `reverse` (a measured fact carried over from a
prior `nf-core/rnaseq` run on the identical FASTQ files, per that run's own RSeQC/Salmon-agreement
result), not `auto`, and not re-inferred.

**ID uniqueness rule — the `(sample, fastq_1)` PAIR, not `sample` alone.**
`validate_unique_samples()` allows the *same* `sample` value to repeat across *different*
`fastq_1` values (the pipeline's supported multi-run-per-sample merge shape — rows get
auto-suffixed `_T1`/`_T2`/...), but hard-errors ("The pair of sample name and FASTQ must be
unique.") on a duplicated `(sample, fastq_1)` pair. Confirmed empirically via `-stub-run`
(`SAMPLESHEET_CHECK` has no `stub:` block, so it runs for real even under `-stub-run`): a
constructed sheet with the identical `(sample, fastq_1)` pair on two rows aborted with exactly
that message.

**A documented pipeline rule that is actually dead code — `check_condition_replicates()`.**
`check_samplesheet_fastq.py`'s `check_samplesheet()` function calls
`checker.validate_unique_samples()` then `check_condition_replicates(reader)` — but `reader` is
the same `csv.DictReader` the preceding `for i, row in enumerate(reader): ...` loop has *already
fully consumed*. `check_condition_replicates()` then does
`[row["condition"] for row in samplesheet]` over the exhausted iterator, gets an empty list, and
`all(v > 1 for k, v in Counter([]).items())` is vacuously `True` — the assertion never fires, for
any input. **Confirmed empirically 2026-08-14** via `-stub-run`: a 3-row sheet with one
`condition` value appearing on only one row passed `SAMPLESHEET_CHECK` cleanly, producing a valid
`samplesheet.valid.csv` with the singleton condition intact — no error at all. `scripts/
check-samplesheet.sh --pipeline rnasplice` flags a singleton condition as a **WARN, not a FAIL**,
for exactly this reason: the constraint is real and matters for any downstream contrast/DE step
that needs replicates, but nothing in the pipeline at this pin will actually stop a run that
violates it.

---

### nf-core/isoseq — 2.0.0

**`assets/schema_input.json` IS what this pipeline validates against — a contrast with nanoseq
and rnasplice above.** At this pin, `subworkflows/local/utils_nfcore_isoseq_pipeline/main.nf`
calls `samplesheetToList(params.input, ..., "$projectDir/assets/schema_input.json")` directly;
there is no bundled `bin/check_samplesheet*.py` anywhere in the clone. So for isoseq, unlike the
last two pipelines stocked here, the JSON schema is the real, authoritative validator.

| column | required | notes |
|---|---|---|
| `sample` | yes | schema's only `required[]` entry; free-form string |
| `bam` | no* | raw PacBio subreads BAM (`.bam`) — needed when `--entrypoint isoseq` (default); pattern `^\S+\.bam$` or the literal string `None` |
| `pbi` | no* | that BAM's **PacBio index** (`.bam.pbi`) — **not** a samtools `.bai`; pattern `^\S+\.bam\.pbi$` or `None` |
| `reads` | no* | already-processed FLNC fasta (`.fa.gz`) — needed only when `--entrypoint map`; pattern `^\S+\.fa\.gz$` or `None` |

\* None of `bam`/`pbi`/`reads` is in the schema's `required[]` — only `sample` is. Which pair a
row actually needs is decided by the **pipeline-wide** `--entrypoint` param (`isoseq`, the
default, or `map`), not by anything in the CSV itself: `entrypoint: isoseq` reads `bam`+`pbi`
and ignores `reads`; `entrypoint: map` reads `reads` and ignores `bam`/`pbi`. The literal string
`None` is the pipeline's own placeholder for "not applicable to this entrypoint" — both bundled
example sheets (`assets/samplesheet.csv`, `assets/samplesheet_map_entrypoint.csv`) use it this
way. `scripts/check-samplesheet.sh --pipeline isoseq` treats `None` as a valid placeholder for
these three columns specifically (and only these three), and separately flags a row where `bam`
is set but `pbi` is `None` (or vice versa) as a FAIL even though the schema's own per-column
patterns each pass individually — `PBCCS` needs both together at runtime.

```csv
sample,bam,pbi
alz,/work/staging/isoseq-realsample/alz.1perc.subreads.10000.bam,/work/staging/isoseq-realsample/alz.1perc.subreads.10000.bam.pbi
```

This is the exact sheet from `runs/20260814-isoseq-alz-chr19/samplesheet.csv` — `entrypoint:
isoseq` (the default, so the column is omitted from the CSV/params and only `bam`/`pbi` are
populated). The `map` entrypoint's own bundled example, for reference:

```csv
sample,bam,pbi,reads
alz,None,None,/home/sguizard/Work/Dev/github/nf-core/isoseq/assets/long_reads.fa.gz
```

**Why this repo stocks `entrypoint: isoseq`, not `map`, as the default.** `map` looks lighter
(skip CCS generation) the way nanoseq's `--skip_demultiplexing` is lighter — but it is not the
same shape of "lighter." `map`'s `reads` column wants a **fully-processed FLNC fasta**: the
product of CCS + primer removal (LIMA) + chimera detection (`ISOSEQ_REFINE`) + polyA cleanup
(`GSTAMA_POLYACLEANUP`) — i.e. `entrypoint: isoseq`'s own output, not raw CCS/HiFi reads. No
public SRA/ENA PacBio Iso-Seq deposit ships an FLNC fasta directly; producing one outside the
pipeline to feed back in as `map` input would mean hand-running the pipeline's own tool chain
externally, which this repo's hard rules forbid. `entrypoint: isoseq` is stocked because it is
the only entry point obtainable from an unmodified public deposit.

**ID uniqueness — no `uniqueEntries` keyword anywhere in the schema.** Unlike mag/taxprofiler
(composite `[sample, run]`/`[sample, run_accession]` keys) or ampliseq (hard per-field
uniqueness), isoseq's `schema_input.json` declares no uniqueness constraint on `sample` or any
other column at all — confirmed by reading the file directly, no `uniqueEntries`/`unique` key
present anywhere in it. A repeated `sample` value is not a schema error at this pin;
`scripts/check-samplesheet.sh`'s generic identifier check (no isoseq-specific override needed)
only WARNs on it, same as the pipelines with no stricter rule.

### nf-core/bacass — 2.6.1

**`assets/schema_input.json` IS what this pipeline validates against** — same class of finding
as isoseq, a contrast with nanoseq/rnasplice. `subworkflows/local/utils_nfcore_bacass_pipeline/
main.nf:105` calls `samplesheetToList(input, "$projectDir/assets/schema_input.json")` directly;
`bin/` in the clone holds only `csv_to_yaml.py`/`find_common_reference.py`/
`kmerfinder_summary.py`/`multiqc_to_custom_csv.py`, none a samplesheet validator.

| column | required | notes |
|---|---|---|
| `ID` | yes | schema's only `required[]` entry; pattern `^\S+$`; `"unique": false` explicitly — see below |
| `R1` | no | short-read mate 1, `.fq.gz`/`.fastq.gz`; empty string or the literal `NA` both mean "not supplied" |
| `R2` | no | short-read mate 2, same pattern/placeholder rules as `R1` |
| `LongFastQ` | no | long (ONT) reads, same pattern/placeholder rules |
| `Fast5` | no | path to a FAST5 directory for polishing; pattern `^(\/[\S\s]*|NA)$`, empty or `NA` also accepted |
| `GenomeSize` | no | size hint to Unicycler/Canu, e.g. `2.8m` — pattern `\d+\.\d+m`; empty or `NA` accepted |

**Comma-delimited `.csv`, not the tab-delimited `.tsv` the pipeline's own docs/CI fixture use —
confirmed empirically, not assumed.** The `--help` text and `conf/test.config` both call this a
"tab-separated sample sheet" and the CI fixture is a real `.tsv` file, but nf-schema's
`samplesheetToList()` sniffs the delimiter from the file's own **extension**, not from its
content. This repo's `bin/preflight.sh`/`cmd.sh` convention always names the file
`samplesheet.csv`, so a `.csv`-named sheet must actually be comma-delimited to parse — verified
2026-08-16 via `-preview` (a comma-delimited synthetic sheet at the CI fixture's own URLs parsed
cleanly; a tab-delimited copy would not have been sniffed as tab under a `.csv` name).

```csv
ID,R1,R2,LongFastQ,Fast5,GenomeSize
SRR2589044,/work/staging/bacass-realsample/SRR2589044_1.fastq.gz,/work/staging/bacass-realsample/SRR2589044_2.fastq.gz,NA,NA,4.6m
```

This is the exact sheet from `runs/20260816-bacass-srr2589044-realsample/samplesheet.csv`.
`R1`/`R2`/`LongFastQ` may also legitimately be `http(s)://` URLs — the pipeline's own CI fixture
(`bacass_short_reseq.tsv`) uses raw GitHub URLs directly, not local paths; `NA` is 'not supplied
for this row', consistent across all three read-source columns and `Fast5`.

**ID uniqueness — schema says `"unique": false`, and the pipeline's own CI fixture exercises
the repeat as a real, working shape.** `bacass_short_reseq.tsv` repeats `ID=ERR044595` across
two different R1/R2 pairs (rows 1 and 3) as its normal re-sequencing-merge input — confirmed
empirically via `-preview` on both the real fixture and a synthetic duplicate-ID sheet (clean,
no error either time). `scripts/check-samplesheet.sh --pipeline bacass` does not flag a repeated
`ID` at all, unlike the generic identifier check's WARN for pipelines with no stated merge rule.

**No read source at all is a schema-legal row — the schema alone will not catch it.** A row with
`R1`/`R2`/`LongFastQ`/`Fast5` all `NA` validates cleanly (confirmed via `-preview`,
`completed=0 failed=0`, no error) even though the pipeline then has nothing to assemble for that
row. Same class of gap as taxprofiler/mag/raredisease's "no read source" rows —
`check-samplesheet.sh` FAILs this per row, the schema does not.

**`check-samplesheet.sh --pipeline bacass` enforces `R1` specifically, not "R1 or LongFastQ" —
this is a repo-scope rule layered on top of the pipeline's own looser schema, not the schema
itself.** The upstream schema is satisfied by `R1` alone, `LongFastQ` alone, or both (any
combination that is not all-`NA`/all-empty). But the checker has no way to see
`--assembly_type` (a pipeline-wide run param, not a sheet column), and this repo's **only
stocked bacass configuration is `assembly_type: short`** (`config/pipelines.tsv`), which needs
`R1` and never consumes `LongFastQ` at all (confirmed by reading `workflows/bacass.nf`'s
`assembly_type`-gated channel construction). A `LongFastQ`-only sheet therefore validates
against the upstream schema but is **rejected by this repo's checker** — it has no usable read
source under the only scope this repo actually runs. A future procurement that stocks
`assembly_type: long` or `hybrid` would need to revisit this check alongside that scope change,
not assume the current strict-R1 behavior still applies.

**`GenomeSize` without a trailing `m` fails as a TYPE mismatch, not just a pattern mismatch.**
A bare decimal cell like `2.8` (no `m` suffix) gets parsed by the CSV reader as a numeric value,
and the schema expects a string — confirmed via `-preview`: `Value is [number] but should be
[string, null]` alongside the pattern-mismatch error. Always quote/spell the trailing `m`.

### nf-core/viralrecon — 3.0.0

**`assets/schema_input.json` IS what this pipeline validates against** — same class of finding
as isoseq/bacass. `subworkflows/local/utils_nfcore_viralrecon_pipeline/main.nf:100/122` calls
`samplesheetToList(params.input, "${projectDir}/assets/schema_input.json")` directly; `bin/` in
the clone holds only `fastq_dir_to_samplesheet.py`, a samplesheet *generator*, not a validator.

| column | required | notes |
|---|---|---|
| `sample` | yes | schema's only `required[]` entry; pattern `^\S+$`, type `["string","integer"]`, `meta:["id"]` |
| `fastq_1` | no (schema) / yes (this repo's illumina-only stocked scope) | `.fq.gz`/`.fastq.gz`, `format:file-path,exists:true` — see below |
| `fastq_2` | no | same pattern as `fastq_1`; empty/absent means single-end |
| `barcode` | no | **nanopore branch only** — bare integer, zero-padded into `barcode01` etc; not used at all on the illumina branch this repo stocks |

```csv
sample,fastq_1,fastq_2
SAMPLE_01,/work/nxf/viralrecon-realsample-fastq/SAMPLE_01_R1.fastq.gz,/work/nxf/viralrecon-realsample-fastq/SAMPLE_01_R2.fastq.gz
```

This is the exact sheet from `runs/20260818-viralrecon-sample01-realsample/samplesheet.csv`. The
pipeline's own CI fixture also legitimately uses `http(s)://` URLs in `fastq_1`/`fastq_2`
directly (`samplesheet_test_amplicon_illumina.csv`, `nf-core/test-datasets` `viralrecon` branch)
— nf-schema's `exists:true` check recognises a remote scheme and does not require local
readability, same shape as bacass's `R1`/`R2`/`LongFastQ` columns.

**`sample` uniqueness — no `uniqueEntries` in the schema, and the pipeline's own CI fixture
exercises the repeat as a real, working shape.** The CI illumina-amplicon fixture's own
`SAMPLE3_SE` appears twice, across two different `fastq_1` values, both single-end (`fastq_2`
empty) — the illumina branch's `.groupTuple()` (keyed on `meta.id`) merges them as a supported
multi-run/multi-lane shape, same pattern as mag/rnasplice. `validateInputSamplesheet()` rejects
only ONE thing about a repeated `sample`: rows that disagree on single-end vs paired-end
(mixing a `fastq_2`-populated row with a `fastq_2`-empty row under one sample name) —
`error("Please check input samplesheet -> Multiple runs of a sample must be of the same
datatype...")`. That failure is a bare Groovy `error()`, not a schema-validation message, so
`-preview` will not surface it as a per-row problem; `check-samplesheet.sh --pipeline
viralrecon` checks for it directly, per sample name, ahead of launch.

**No read source at all is a schema-legal row for `fastq_1` — the schema alone will not catch
it.** `fastq_1` is not in `required[]`; a row with it empty/absent validates cleanly and reaches
the illumina branch's `.map{}` with a `null` read source (confirmed by reading
`utils_nfcore_viralrecon_pipeline/main.nf:98-117`). Same class of gap as taxprofiler/mag/
raredisease/bacass's "no read source" rows. This repo's stocked scope is illumina-only
(`config/pipelines.tsv`), so `check-samplesheet.sh --pipeline viralrecon` enforces `fastq_1`
specifically, the same "repo-scope rule layered on the looser upstream schema" pattern as
bacass's `R1` enforcement — a `barcode`-only (nanopore-shaped) sheet is schema-legal upstream
but has no usable read source under this repo's illumina-only stocked configuration.

---

## Common breakages, with the text you will actually see

### Relative path

Sheet says `data/S1_R1.fastq.gz`, you launched from `/work/nxf/<runid>`.

```
ERROR ~ Validation of pipeline parameters failed!

The following invalid input values have been detected:

* --input (samplesheet.csv): Validation of file failed:
        -> Entry 1: Error for field 'fastq_1' (data/S1_R1.fastq.gz): the file or
           directory 'data/S1_R1.fastq.gz' does not exist
```

Fix: absolute paths. `awk -F, 'NR>1 && $2 !~ /^\//' sheet.csv` finds them.

### CRLF line endings

The `\r` is glued onto the last field. If the last column is a path you get a "does not exist"
error for a file that `ls` clearly shows. If it is an enum you get an enum failure on a value that
looks correct:

```
        -> Entry 1: Error for field 'strandedness' (reverse): Instance does not match
           any allowed value
```

<!-- UNVERIFIED: exact nf-schema wording for enum failures varies by nf-schema version; the
     giveaway is an error naming a value that is visibly in the allowed list. -->

Fix: `sed -i 's/\r$//' sheet.csv`. Prevent it with `*.csv text eol=lf` in `.gitattributes` and by
not editing sheets in Notepad.

### UTF-8 BOM from Excel

Excel's "CSV UTF-8" writes `EF BB BF` before the first header, so the header is `\ufeffsample`,
not `sample`:

```
        -> Entry 1: Missing required field(s): sample
```

Fix: `sed -i '1s/^\xEF\xBB\xBF//' sheet.csv`. Better: stop round-tripping samplesheets through
Excel.

### Uncompressed FASTQ

```
        -> Entry 2: Error for field 'fastq_1' (S2_R1.fastq): string [S2_R1.fastq] does
           not match pattern ^\S+\.f(ast)?q\.gz$
```

Fix: `pigz -p 12 *.fastq`. There is no `--allow_plain_fastq`; the pattern is the pattern.

### Spaces or non-ASCII in filenames

A space breaks the `^\S+$` half of the pattern outright. Korean characters pass the regex but then
travel through container bind mounts, `publishDir` paths and MultiQC sample names, where
locale-dependent things go wrong in ways that are painful to debug. Rename the files (or make an
ASCII symlink farm on ext4 and point the sheet at that) before starting.

### R1/R2 swapped

**No error at all.** The run completes. Symptoms: alignment rate collapses in an unstranded-looking
way, or for RNA-seq the inferred strandedness flips relative to every other sample, or for 10x you
get almost no cells. The only defence is a pre-flight header check — the Casava 1.8 name line's
second field starts with `1:` for read 1 and `2:` for read 2.

### Mixed single-end and paired-end rows for one sample

```
ERROR: Please check input samplesheet -> Multiple runs of a sample must be of the same
datatype i.e. single-end or paired-end
Line: 'KOR_CTRL_01,KOR_CTRL_01_L002_R1.fastq.gz,,reverse'
```

<!-- UNVERIFIED: older revisions raise this from check_samplesheet.py with exactly this wording;
     newer ones raise an equivalent Groovy error. The constraint itself has not changed. -->

Mixing across *different* samples is allowed in rnaseq; mixing *within* one sample is not.

### Duplicate sample IDs

Context-dependent, and this is where technicians most often "fix" something that was correct:

- **rnaseq / atacseq / chipseq / scrnaseq**: repeated IDs are the documented way to declare
  technical replicates or extra lanes. They get merged. Leave them. Only the *metadata* must
  agree across those rows — for rnaseq that means `strandedness`:
  `ERROR: Please check input samplesheet -> Multiple runs of a sample must have the same strandedness`
- **sarek**: the unique key is `patient` + `sample` + `lane`. A repeated triple means duplicated
  read groups, which is always a mistake.
- **differentialabundance**: a repeated value in the observations id column is always fatal.

### Missing mate file

Present in the sheet, absent on disk, or a zero-byte stub left by a failed `rsync`. Nextflow's
`exists: true` check catches the missing case; it does not catch the zero-byte case, which fails
much later inside the aligner with an empty-input error.

### Truncated gzip

A copy that died partway. `zcat` reads it fine until the end, then:

```
gzip: /data/wgs/KG0142_blood_R2.fastq.gz: unexpected end of file
```

Only caught by decompressing the whole file — the `--deep` mode of the checker below. On 30× WGS
that costs real minutes, and it is still cheaper than eight hours of alignment.

---

## Pre-flight checklist

Run all of this **before** `nextflow run`, every time, including on sheets you generated yourself.

1. Schema read from the pinned revision's `assets/schema_input.json`; column set matches.
2. LF endings, no BOM, ASCII only.
3. Header present, no duplicated column names, no comment lines, no blank rows in the middle.
4. Every row has the same field count as the header.
5. Every path column is absolute, exists, is readable, and is non-empty.
6. Every `.gz` is at minimum a valid gzip by magic bytes; ideally a full `gzip -t`.
7. R1/R2 orientation confirmed from the first read header of each pair.
8. Mate record counts equal, and each divisible by 4 (`--deep`).
9. ID uniqueness rules applied *for the pipeline in question* (see above — they differ).
10. Enum columns (`strandedness`, `status`, `sex`) contain only allowed values, and are consistent
    across rows that share a sample.
11. For differentialabundance: matrix headers ⊇ observation ids; every contrast `variable`,
    `reference` and `target` resolves against the observations sheet.
12. Total input size measured, and free space on the target filesystem is at least 1.5× the run
    estimate.

---

## The checker

`scripts/check-samplesheet.sh` ships with the repo. Invoke it; never restate it and never overwrite
it. Read-only, safe to re-run. Exit 0 = clean, 1 = problems found, 2 = usage error.

Run it as the last thing before launching, and again after any hand-edit:

```bash
bash "$BIOINFO_HOME/scripts/check-samplesheet.sh" --deep --pipeline "$PIPE" "$RUNDIR/samplesheet.csv"
```
