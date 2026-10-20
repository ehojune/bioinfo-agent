# Workflow chaining

Read only when a deliverable needs several runs. Each launch keeps its own plan and gates.

## 5. Chaining patterns

### 5.1 fetchngs → rnaseq

```bash
# 1. retrieve
nextflow run nf-core/fetchngs -r 1.12.0 ... \
  --input ids.csv \
  --nf_core_pipeline rnaseq \
  --nf_core_rnaseq_strandedness auto \
  --outdir "$OUT/fetch"

# 2. INSPECT AND EDIT. Do not skip this.
#    - sample names are accessions; rename to something a human can read
#    - add the condition/group columns the study actually has (they are not in SRA metadata)
#    - verify single vs paired end matches reality
column -s, -t "$OUT/fetch/samplesheet/samplesheet.csv" | less -S

# 3. run
nextflow run nf-core/rnaseq -r 3.18.0 ... \
  --input "$OUT/fetch/samplesheet/samplesheet.csv" \
  --outdir "$OUT/rnaseq"
```

The `--nf_core_pipeline rnaseq` flag is what makes the samplesheet drop-in compatible. Without it
you get a generic samplesheet and have to reshape it by hand.

### 5.2 rnaseq → differentialabundance

```bash
nextflow run nf-core/differentialabundance -r 1.5.0 \
  -profile docker,rnaseq \
  -c "$BIOINFO_HOME/config/local.config" \
  --input  samples_with_metadata.csv \
  --contrasts contrasts.csv \
  --matrix "$OUT/rnaseq/star_salmon/salmon.merged.gene_counts.tsv" \
  --transcript_length_matrix "$OUT/rnaseq/star_salmon/salmon.merged.gene_lengths.tsv" \
  --gtf    "$BIOINFO_REFS/genomes/GRCh38/gtf/genes.gtf.gz" \
  --outdir "$OUT/da"
```

`--transcript_length_matrix` is optional per the schema but is what the pipeline's own CI profile
pairs with the raw matrix — include both; see the [differentialabundance card](pipelines/differentialabundance.md).

Three things break this chain, in order of frequency:

1. **Column names in the matrix header do not match the sample ids in `--input`.** They must match
   exactly, including case. Check with `head -1` on the matrix against `cut -d, -f1` on the input.
2. **The contrast `variable` is not a column in `--input`.**
3. **`reference` / `target` levels are spelled differently** than the values in the metadata column.

Validate all three before launching. It costs ten seconds and saves a failed run.

### 5.3 sarek step restarts

Sarek is designed to be re-entered. The pattern is: run a step, take the CSV it wrote, feed it to
the next step with a **new `--outdir`**. The preprocessing step also feeds
[short-read STR preparation](repeat-expansion.md#61-the-working-pattern-for-short-read-strs-expansionhunter--hipstr).

```bash
# preprocessing only — no callers; also the STR preparation path linked above.
nextflow run nf-core/sarek -r 3.5.1 ... \
  --step mapping --skip_tools baserecalibrator \
  --input samplesheet.csv --outdir "$OUT/sarek_map"

# later: call germline variants from the CRAMs already produced
nextflow run nf-core/sarek -r 3.5.1 ... \
  --step variant_calling --tools haplotypecaller \
  --input "$OUT/sarek_map/csv/markduplicates_no_table.csv" \
  --outdir "$OUT/sarek_hc"

# later still: annotate an existing VCF without recalling anything
nextflow run nf-core/sarek -r 3.5.1 ... \
  --step annotate --tools vep \
  --input "$OUT/sarek_hc/csv/variantcalled.csv" \
  --outdir "$OUT/sarek_annot"
```

`--step` restart and `-resume` solve different problems. `-resume` reuses cached tasks within a
logically identical run. `--step` starts a *different* run from an intermediate file. Use `-resume`
when a run crashed; use `--step` when you are deliberately adding a stage. Never use `--step` as a
substitute for `-resume` after a crash — you will lose the cache and redo work.

### 5.4 atacseq / chipseq → differentialabundance

The consensus-peak featureCounts matrix from atacseq or chipseq is a feature × sample count matrix
and DESeq2 works on it. You can feed it to differentialabundance, but:

- do **not** use `-profile rnaseq` — its defaults assume gene features and a GTF-derived annotation;
- supply the consensus peak annotation as the features file instead of `--gtf`;
- the reported "genes" are peaks, so every label in the report needs reinterpreting.

<!-- UNVERIFIED: the exact combination of --features / --features_type / --observations_type that
     makes peak-level input work cleanly. Stub-run it and inspect before committing. -->

This is a defensible shortcut, not the pipeline's designed path. Say so in the handoff.

### 5.5 What does not chain

There is no supported chain from methylseq, cutandrun, or scrnaseq into differentialabundance.
Differential methylation, differential CUT&RUN binding, and single-cell DE all need models the
pipeline does not implement. Hand off the per-cytosine calls / peaks / h5ad and stop there.
