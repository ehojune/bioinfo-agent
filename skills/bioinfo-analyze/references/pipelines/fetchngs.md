# fetchngs

Read this card after selection. `config/pipelines.tsv` owns the pin; examples below are revision-specific.
Host paths and budgets come from [host-runtime.md](../host-runtime.md), never from historical numbers.

- **Step 4:** No registered stub waiver. Preview and the full-command stub must pass; missing upstream stubs can execute real work.
- **Evidence lookup:** [procurement record](evidence/fetchngs.md); load only when its historical detail is needed.
- **Shared inputs/QC:** [samplesheets](../samplesheets.md), [QC thresholds](../qc-interpretation.md).

**For:** resolving public accessions to FASTQ files plus metadata plus a samplesheet already
shaped for the next pipeline. Handles SRA/ENA/DDBJ run and study accessions and GEO series.

**Not for:** anything with controlled access (dbGaP, EGA) — those need their own clients and
credentials. Not for downloading BAM/CRAM from ENA. Not a substitute for reading the paper's
methods: it retrieves whatever metadata the submitter uploaded, which is frequently wrong about
strandedness and sometimes wrong about pairing.

**Minimum input:** `--input ids.csv` — a file with one accession per line (`SRRxxxxxxx`,
`SRXxxxxxxx`, `SRPxxxxxx`, `PRJNAxxxxxx`, `GSExxxxxx`, `GSMxxxxxxx`). **No header row** — see
`references/samplesheets.md`; a header line makes the pipeline abort before any download.

**Confirmed working at 1.12.0** (run 20260810-fetchngs-citest, first execution of this pipeline
on this host — the GSE/GSM UNVERIFIED note this comment used to carry is now settled): both `GSE`
and `GSM` accessions resolve correctly and expand to the right per-run granularity — a `GSM`
mapping to several sequencing runs of the same biosample produced one samplesheet row per run, not
one collapsed row, matching the "occasionally non-unique" warning below.

**`-stub-run` is not free for this pipeline — budget it like a real run.** Several of the download
modules (`modules/local/sra_fastq_ftp`, `modules/nf-core/sratools/prefetch`,
`modules/nf-core/sratools/fasterqdump`) define no Nextflow `stub:` block. Under Nextflow's
documented fallback, `-stub-run` then executes their real `script:` unchanged — i.e. the
mandatory stub step in `references/runbook.md` §4 performs the actual FASTQ download for this
pipeline. Measured on 20260810-fetchngs-citest: the "stub" run downloaded the full 939 MB in
~7m18s.

**That download is only free for the real launch if you keep the stub's work directory around and
point the real run at it — which is the opposite of `references/runbook.md` §4's general "two
stubs" rule.** On 20260810-fetchngs-citest the real launch reused the stub's downloaded FASTQ via
`-resume`/cache in 26 s, but only because its `-work-dir` was left pointed at the same tree the
stub had used — not the isolated, later-deleted `$STUBROOT` §4 otherwise mandates. Follow §4's
general procedure (separate `$STUBROOT`, deleted after validation) as written and this reuse does
not happen: the real launch's `-work-dir` has nothing cached, and the full download runs a
**second** time. That general isolation rule exists to stop a *different* pipeline's empty stub
outputs from being cached into a real run — a failure mode that cannot occur here, since
fetchngs's stub outputs are real data, not empty placeholders. For fetchngs specifically, and only
because of that, it is reasonable to deliberately keep (not delete) the stub's `-work-dir` and
point the real launch's `-work-dir` at the same tree, to avoid paying for the download twice; if
you do, say so in the run plan, since it is a deviation from the documented default. If you follow
the default (isolated, deleted) stub procedure instead, budget the download time **twice**, not
once, when estimating a large accession list.

**Parameters that matter here:**

| param | value | why |
|---|---|---|
| `--nf_core_pipeline` | `rnaseq` \| `atacseq` \| `taxprofiler` \| `viralrecon` | **this is the whole point of the chain** — it emits a samplesheet with that pipeline's columns |
| `--nf_core_rnaseq_strandedness` | `auto` | seeds the strandedness column; do not trust submitter metadata |
| `--download_method` | `ftp` first | `aspera` is faster when it works; `sratools` is the fallback and the slowest |

**Reference-store paths:** none. This pipeline touches no genome.

**Key outputs:**

```
<outdir>/fastq/                                 the reads
<outdir>/samplesheet/samplesheet.csv            feed directly to the next pipeline's --input
<outdir>/samplesheet/id_mappings.csv            accession → sample name, keep this
<outdir>/metadata/                              full ENA/SRA metadata records
```

**Before chaining, always open `samplesheet.csv` and check it.** Sample names derived from
accessions are opaque; group assignment is not in there; and single-vs-paired can be mis-declared.
Editing this file by hand is normal and expected.

**Disk warning:** this is the one pipeline whose footprint is entirely outside your control. A
40-sample human RNA-seq study is 200–400 GB of FASTQ. A WGS study is terabytes. Estimate from the
ENA record before starting, and check free space against 1.5×.
