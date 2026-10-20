# Prior runs and intermediate reuse

Read during intake when matching run records or existing intermediates are found.

### Reading the run history

`$BIOINFO_RUNLOG` holds one directory per past analysis on this machine. It is local and
gitignored — it is the user's own record, not repository content.

Glance at it during intake. **`ls` alone does not find things** — run IDs are descriptive, not
indexed, and a sample often appears only inside the record. `docs/examples/20260805-scrnaseq-skin-cd3`
is `SRR21657609` and its name says neither. Search the contents:

```bash
grep -rl -- "$ACCESSION\|$SAMPLE" "$BIOINFO_RUNLOG"/*/handoff*.md 2>/dev/null
```

You are looking for three things, and nothing else:

| You notice | Say |
|---|---|
| This sample already went through this pipeline, and it completed | Say so before planning. Ask whether they want it re-run or want the existing results. Its measured numbers may replace your estimate — but only if the run was equivalent; see below. |
| A different assay on the same sample — DNA before, RNA now | Mention it once, as an option: the two together support analyses neither supports alone. Do not design the multi-omics study uninvited. |
| A prior run produced an artifact this one needs — a BAM, an index, a trimmed FASTQ | Say roughly where it should be and offer to use it. |

**A past run's numbers are only yours to reuse if the run was equivalent.** All four must match:

| | Why it invalidates the transfer |
|---|---|
| Pipeline **and pinned revision** | Process graphs change between releases |
| Entry step, and the caller/tool set actually enabled | sarek from `--step mapping` is not sarek from `--step markduplicates`; each extra caller is its own scatter |
| Reference build **and** what was prebuilt vs built during the run | An index built inside the run is hours and tens of GB that will not recur — or will |
| Input scale — read count, coverage, sample count | Peak disk tracks the largest intermediate, not the sample name |

If all four match, state the measured wall clock and peak disk as the estimate and say which run
they came from. If any differ, **calibrate rather than copy**: use the measurement to correct the
assumption it disproves, then estimate this run on its own terms. `preflight.sh` gates disk at
1.5× your estimate and the user approves against it — an estimate imported from a differently
shaped run makes both checks meaningless while looking authoritative.

**Keep it light.** One glance, one sentence if something is relevant, nothing if not. Do not
enumerate what the user has run, do not summarise their history back at them, and do not go
looking for patterns across it. Reading the log to save them a re-run is helpful; reporting on
their past work reads like being audited.

If `$BIOINFO_RUNLOG` is empty or unset, that is the normal state for a fresh install. Move on.

### Reusing what is already there

Finding prior outputs is good and you should look for them. What you do with them is the part that
goes wrong.

| Found | Wrong move | Right move |
|---|---|---|
| Recalibrated BAM/CRAM | run `samtools`/`gatk` on it and carry on manually | sarek `--step variant_calling`, `bam`/`bai` columns in the samplesheet |
| Duplicate-marked BAM | continue the hand pipeline | sarek `--step prepare_recalibration` |
| Coordinate-sorted BAM, no dedup | re-align from FASTQ — days of compute already spent | sarek `--step markduplicates` |
| Trimmed FASTQ | re-trim, or trim again by hand | feed as `fastq_1`/`fastq_2`, skip the trimming step by flag |
| VCF only | write bcftools one-liners | sarek `--step annotate` |
| An existing STAR/BWA index | rebuild it | point the manifest at it, add a row, resolve by standard path |

A header read narrows the row down; two of the three fields need corroborating before you act.

- **`@HD SO:`** — sort order. Says what it says.
- **`@RG`** — present and carrying `SM`/`PL`/`LB`/`PU`, or sarek will reject the input.
- **Reference identity.** Do **not** take `@PG CL:` for it: that field preserves a command line,
  and the path in it may since have been replaced or retargeted. Compare the BAM's `@SQ` `SN`+`LN`
  — and `M5` when the header carries it — against the standard reference's `.fai`/`.dict`. Any
  mismatch means the alignment and the calling reference are different genomes.
- **Dedup.** A missing MarkDuplicates `@PG` is a hint, not proof: `samtools markdup --no-PG` omits
  it and headers can be rewritten. Corroborate with the script or log that produced the file
  before choosing `--step markduplicates`; if nothing corroborates, say so in the plan and let the
  user decide between re-marking and an approved record-level check.

In every row the reuse happens **through the pipeline's own restart mechanism**, not by taking over
where a human left off. That is what makes the result reproducible and `-resume`-able.

If the existing outputs came from an unknown or hand-written pipeline, say so in the plan and let
the user decide whether to trust them. Do not silently adopt another pipeline's intermediates as if
they were yours — you cannot vouch for how they were produced.

