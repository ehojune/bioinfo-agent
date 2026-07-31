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
KOR_CTRL_01,/refs/../data/rna/KOR_CTRL_01_L001_R1.fastq.gz,/refs/../data/rna/KOR_CTRL_01_L001_R2.fastq.gz,reverse
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

<!-- UNVERIFIED: whether to pass salmon.merged.gene_counts.tsv plus
     --transcript_length_matrix salmon.merged.gene_lengths.tsv, or the length-scaled matrix
     directly. Check `nextflow run nf-core/differentialabundance -r 1.5.0 --help | grep -i matrix`
     and the pipeline's usage docs in the cloned asset dir. -->

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

<!-- UNVERIFIED: 1.5.x may also accept `pairing`, `exclude_samples_col` and
     `exclude_samples_values` columns. Verify with
     `cat $NXF_ASSETS/.repos/nf-core/differentialabundance/clones/*/assets/schema_contrasts.json`
     (filename may differ — list assets/ if it is not there). -->

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

<!-- UNVERIFIED: whether 1.12.x tolerates or requires an `id` header row. Check
     assets/schema_input.json before the first run; adding a header when none is expected turns
     the word "id" into an accession and produces a confusing lookup failure. -->

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
