# QC interpretation

This file defines what the technician is allowed to say about a finished run. It has two halves:
how to read the numbers, and where reading stops. The second half is the more important one.

**The ceiling, stated once:** the technician reports metrics, assigns pass/warn/fail against a
stated band, names the likely *technical* mechanism, and recommends an action. It does not decide
what the biology means, and it does not silently act on its own recommendation. Every
exclude/rerun/re-prep decision goes back to the user.

---

## 1. Where the report lands

Read the MultiQC HTML for the human-facing view, but pull numbers from `multiqc_data/` — the TSVs
are what you quote, not what you eyeball off a plot.

| Pipeline | MultiQC path (relative to `--outdir`) | Also read |
|---|---|---|
| rnaseq | `multiqc/<aligner>/multiqc_report.html` (e.g. `multiqc/star_salmon/`) | `star_salmon/deseq2_qc/`, `star_salmon/qualimap/`, `star_salmon/rseqc/`, `*/salmon.merged.gene_counts.tsv` |
| sarek | `multiqc/multiqc_report.html` | `reports/mosdepth/`, `reports/samtools/`, `reports/bcftools/`, `reports/vcftools/` |
| methylseq | `multiqc/<aligner>/multiqc_report.html` (`bismark` or `bwameth`) <!-- UNVERIFIED: confirm subdir with `ls <outdir>/multiqc` after the first run --> | `bismark/reports/`, `bismark/deduplicated/*M-bias*`, `methyldackel/` |
| atacseq | `multiqc/<peak_type>/multiqc_report.html` (`narrow_peak` \| `broad_peak`) | `bwa/merged_library/macs2/<peak_type>/qc/`, `.../deeptools/`, `.../picard_metrics/` |
| chipseq | `multiqc/<peak_type>/multiqc_report.html` | same shape as atacseq, plus `phantompeakqualtools/` |
| cutandrun | `multiqc/multiqc_report.html` <!-- UNVERIFIED: cutandrun also emits its own `04_reporting/` summary; confirm layout --> | `04_reporting/qc/`, spike-in scale factors |
| scrnaseq | `multiqc/multiqc_report.html` | aligner-native summary: `cellranger/*/outs/web_summary.html`, `starsolo/*/Summary.csv`, or alevin/`*_meta_info.json` |
| differentialabundance | **no MultiQC** — the deliverable is `report/*.html` | `tables/`, `plots/qc/` |
| fetchngs | **no MultiQC** — verify by checksum + row count of the emitted samplesheet | `samplesheet/samplesheet.csv`, `metadata/` |

Re-derive the layout rather than trusting this table after a version bump:

```bash
tree -L 3 "$OUTDIR" | head -60
ls "$OUTDIR"/multiqc/*/multiqc_data/
```

The general-stats table is the fastest per-sample overview:

```bash
column -t -s$'\t' "$OUTDIR"/multiqc/*/multiqc_data/multiqc_general_stats.txt | less -S
```

Table written against nf-core/rnaseq 3.14–3.18, sarek 3.4–3.5, atacseq/chipseq 2.x,
methylseq 2.6–3.x, scrnaseq 2.x, cutandrun 3.x. Paths drift. Check before quoting.

---

## 2. Triage order

Do these in order. Stopping early is correct when an early check fails — there is no point
discussing PCA outliers on a sample that was aligned to the wrong genome.

1. **Did every sample finish?** `nextflow log <run> -f process,status,exit` — a silently missing
   sample is worse than a bad one.
2. **Identity and orientation.** Sex check, strandedness agreement, species/build sanity (mapping
   rate). These catch swaps and setup errors, which are the failures that quietly poison
   everything downstream.
3. **Yield.** Reads in, reads usable after filtering. Everything else is conditional on there being
   enough data.
4. **Library quality.** Duplication, complexity, contamination, conversion efficiency — assay
   specific.
5. **Signal quality.** Enrichment metrics: FRiP, TSS enrichment, rRNA fraction, gene body coverage.
6. **Between-sample structure.** Correlation, PCA, replicate consistency, batch alignment.

---

## 3. Per-assay bands

Bands are working thresholds, not standards. They assume human, GRCh38, Illumina PE150 unless
stated. Where a published consortium standard exists (ENCODE for ATAC/ChIP) it is named. Always
report the observed number alongside the band, never the band alone.

### 3.1 RNA-seq (bulk, polyA, DE-oriented)

| Metric | Source | Pass | Warn | Fail | What a breach means |
|---|---|---|---|---|---|
| Total reads (PE pairs) | fastqc / fastp | ≥25 M | 10–25 M | <10 M | Below ~10 M assigned, low-expression genes fall out of testable range; the sample is not comparable to the others at equal power |
| Uniquely mapped % | STAR | ≥85% | 70–85% | <70% | Wrong build, adapter/rRNA carryover, or degraded input. <50% is almost always the wrong reference or a contaminated library |
| Multi-mapped % | STAR | <15% | 15–30% | >30% | rRNA/repeat dominance; effective depth is far below nominal |
| Salmon mapping rate | salmon `meta_info.json` | ≥70% | 50–70% | <50% | Transcriptome/annotation mismatch, or high intronic content (pre-mRNA / nuclear RNA) |
| Assigned to features % | featureCounts | ≥60% | 45–60% | <45% | Annotation mismatch, wrong strandedness, or heavy intronic signal |
| Duplication % | picard MarkDuplicates | <50% | 50–75% | >75% | RNA-seq is *expected* to duplicate — high expression duplicates legitimately. Judge it jointly with detected-gene count; 70% duplication with 15k genes detected is fine, 70% with 8k genes is a complexity failure |
| rRNA fraction | biotype plot / sortmerna / qualimap | <2% polyA, <10% riboZero | 10–25% | >25% | Pure depth loss. Recompute usable depth as `total × (1 − rRNA)` and re-check the yield row |
| Median 5′→3′ bias | picard `RnaSeqMetrics` / RSeQC geneBody_coverage | 0.7–1.4 | 0.5–0.7 or 1.4–2.0 | <0.5 or >2.0 | 3′ skew = degraded RNA (low RIN). Affects gene-length-dependent quantification; degraded and intact samples in the same comparison is a real confound |
| Detected genes (≥1 CPM) | count matrix | 12–17 k | 9–12 k | <9 k | Tissue-dependent — set the expectation from the *cohort median*, not from this table |
| Strandedness inferred vs declared | rnaseq strandedness check | agree | — | disagree | **Stop-the-line.** A reversed strand setting silently destroys assignment. Fix the samplesheet and re-run; do not proceed |
| Within-group Spearman r | `deseq2_qc/` | ≥0.90 | 0.85–0.90 | <0.85 | Candidate outlier — but check it against the yield and rRNA rows before calling it biological heterogeneity |
| PCA | `deseq2_qc/*pca*` | groups separate on PC1–PC3 | — | — | See §6 |

Note: nf-core/rnaseq's strandedness column accepts `auto`; when it does, the pipeline infers and
reports, and the disagreement check becomes an inference-confidence check instead.
<!-- UNVERIFIED: confirm `auto` support for your revision via `cat $NXF_ASSETS/nf-core/rnaseq/assets/schema_input.json` -->

### 3.2 WGS / WES (germline)

| Metric | Source | Pass | Warn | Fail | What a breach means |
|---|---|---|---|---|---|
| Mean coverage, WGS | mosdepth | ≥28× (for a 30× order) | 20–28× | <20× | Below ~20× het calls lose sensitivity; the sample cannot be pooled with 30× samples without a depth covariate |
| Mean on-target, WES | mosdepth / picard HsMetrics | ≥80× (for a 100× order) | 50–80× | <50× | Same logic, plus exome capture is uneven so mean flatters the tail |
| Genome ≥10× / ≥20× / ≥30×, WGS | mosdepth `*.thresholds.bed.gz` | ≥95% / ≥90% / ≥70% | — | ≥20× below 80% | The callable fraction, which is the number that actually governs sensitivity. Quote this in preference to mean coverage |
| Target ≥20×, WES | mosdepth region summary | ≥90% | 80–90% | <80% | Capture failure or insufficient depth |
| Fold-80 base penalty, WES | picard `CollectHsMetrics` <!-- UNVERIFIED: sarek reports mosdepth by default; confirm whether HsMetrics runs for your `--wes` config, otherwise substitute coverage CV --> | ≤1.7 | 1.7–2.5 | >2.5 | Uneven capture — you must raise mean depth substantially to rescue the low tail |
| Mapping rate | samtools stats | ≥98% | 95–98% | <95% | Contaminating organism, adapter, or wrong build. Pair with "% properly paired" ≥95% |
| Duplication % | MarkDuplicates | PCR-free WGS <10%; PCR WGS <20%; WES <30% | +10 pp over band | >2× band | Low library input over-amplified. Effective unique coverage is `mean × (1 − dup)` — recompute and re-check the coverage row |
| Insert size median / MAD | picard `CollectInsertSizeMetrics` | 300–500 bp, unimodal | broad | bimodal, or median <150 | Short inserts mean read-through into adapter and reduced mappability in repeats; bimodal means a mixed library |
| Contamination (FREEMIX) | VerifyBamID2 <!-- UNVERIFIED: not part of the sarek default set on all revisions; check `nextflow run nf-core/sarek -r <rev> --help \| grep -i verify` and add the tool explicitly if absent --> | <0.01 | 0.01–0.03 | >0.03 | Cross-sample contamination inflates heterozygosity and creates low-AF false positives. Above 0.03 do not use for anything allele-fraction sensitive |
| Ti/Tv | bcftools stats | WGS 2.0–2.1; WES 3.0–3.3 | ±0.15 | further | Low Ti/Tv = false-positive inflation; use it as a filter-quality thermometer, not a per-variant judgement |
| Het/hom ratio | bcftools stats | ancestry-dependent: ~1.4–1.7 East Asian, ~1.5–1.8 European, ~1.9–2.2 African | ±0.2 | further | High = contamination or a mixed sample; low = excessive filtering or ROH. **For Korean cohorts expect the low end — do not flag 1.5 as an anomaly** |
| SNV count | bcftools stats | WGS 3.4–4.3 M (East Asian) / up to 5.0 M (African); WES 20–25 k coding | ±15% | further | Cohort-relative is the real check: an outlier by count in an otherwise uniform cohort is the signal |
| Sex check | chrX/chrY normalised coverage + chrX het rate | matches recorded sex | ambiguous (possible XXY / mosaic / low depth) | contradicts record | **Highest-value single check.** A contradiction is a sample-swap or metadata error until proven otherwise. Report it, name both values, stop and ask |
| Kinship / identity | somalier or peddy on common SNPs <!-- UNVERIFIED: not in the sarek default set; run separately --> | matches expected pedigree | — | unexpected duplicate or relatedness | Same class of failure as the sex check, and it catches swaps that sex checks miss |

For anything STR / repeat-expansion oriented (ExpansionHunter, TRGT, HipSTR), the coverage row that
matters is *local* depth at the locus, not genome mean, and read length must be reported alongside —
a short-read caller cannot resolve an allele longer than the fragment. State both numbers; do not
report an expansion size as a finding.

### 3.3 Methylation (WGBS / RRBS / EM-seq)

| Metric | Source | Pass | Warn | Fail | What a breach means |
|---|---|---|---|---|---|
| Conversion efficiency (lambda spike-in) | align to lambda, `100 − %mCpG` | ≥99.0% | 98.0–99.0% | <98.0% | Unconverted C reads as methylated. At 97% conversion, a truly 0%-methylated CpG reports ~3% — small effect sizes become uninterpretable |
| Conversion proxy (no spike-in): %mCHH | bismark summary | ≤1.0% | 1.0–2.0% | >2.0% | Same conclusion, weaker evidence. **Caveat: real non-CpG methylation exists in neurons and ES cells** — in those tissues this proxy is invalid and you must say so rather than call a failure |
| Spike-in read fraction | lambda alignment | 0.1–2% | <0.05% | none | Without enough spike-in reads the conversion estimate has no precision. Report the read count behind the percentage |
| M-bias | Bismark M-bias plot / MethylDackel `--mbias` | flat across read body | edge deviation ≤10 bp | deviation across >20 bp | Set `--clip_r1/--clip_r2/--three_prime_clip_r1/--three_prime_clip_r2` and re-run. PBAT libraries deviate at both ends by design |
| Mapping efficiency | bismark | WGBS bismark 55–80%; bwameth 85–95% | −10 pp | <45% (bismark) | Bisulfite conversion genuinely lowers mappability; do not compare these to DNA-seq numbers |
| Duplication | deduplicate_bismark | WGBS <25% | 25–40% | >40% | **RRBS must NOT be deduplicated** — MspI fragments start at fixed positions, so apparent duplicates are real molecules. If dedup ran on RRBS, the run is wrong, not the sample |
| CpGs at ≥10× in all samples | coverage report | site-level DMC analysis needs this set to be most of the CpG universe you care about | — | — | Report the absolute number. This is the analysable denominator; a DMR/tiled analysis relaxes it to ≥5× per tile |
| Global mCpG | bismark summary | somatic tissue 70–82% | 65–70% or 82–88% | further | Off-band global methylation is usually conversion or contamination before it is biology — and deciding which is not the technician's call |

### 3.4 ATAC-seq

| Metric | Source | Pass | Warn | Fail | What a breach means |
|---|---|---|---|---|---|
| TSS enrichment (hg38 RefSeq) | deeptools / ataqv | ≥7 | 5–7 | <5 | ENCODE hg38 guidance. Below 5, signal-to-background is too poor for confident differential accessibility |
| FRiP | MACS2 peak QC | ≥0.20 | 0.10–0.20 | <0.10 | ENCODE guidance. Low FRiP with normal TSS enrichment usually means under-peak-calling, not a bad library — check peak count before condemning |
| Fragment size distribution | picard insert size / deeptools | visible NFR (<100 bp) + mono (~180–250) + di (~350–450) ladder | ladder faint | no periodicity | Over-transposition destroys the mono/di peaks (all NFR); under-transposition gives few NFR reads |
| Mitochondrial % | idxstats, pre-filter | Omni-ATAC 5–20% | 20–50% | >50% | Pure depth loss. Recompute usable reads and re-check the yield row before saying anything else |
| NRF / PBC1 / PBC2 | preseq / picard-derived | ≥0.9 / ≥0.9 / ≥3 | 0.8–0.9 / 0.8–0.9 / 1–3 | <0.8 / <0.8 / <1 | ENCODE library-complexity bottleneck. Sequencing deeper will not help a bottlenecked library |
| Usable reads (post-filter, non-chrM, dedup, PE) | samtools flagstat after filtering | ≥25 M (ENCODE min), ≥50 M preferred | 15–25 M | <15 M | Peak sensitivity scales with this, not with raw reads |
| Peak count (narrow) | MACS2 | 40 k–150 k | 20 k–40 k | <20 k at full depth | A low count at good depth with good TSS enrichment usually means a peak-calling parameter problem |
| Replicate consistency | consensus-peak count correlation / Jaccard | within-group r ≥0.85, Jaccard ≥0.5 | 0.7–0.85 | <0.7 | Candidate outlier or a genuine biological difference — the technician reports the number and does not choose between those two |

### 3.5 ChIP-seq and CUT&RUN

| Metric | Source | Pass | Warn | Fail | What a breach means |
|---|---|---|---|---|---|
| FRiP, TF ChIP | MACS2 QC | ≥0.05 | 0.01–0.05 (ENCODE floor 0.01) | <0.01 | Poor enrichment; peaks will be dominated by background structure |
| FRiP, broad histone | MACS2 broad | ≥0.05 typical, but genuinely lower for H3K27me3/H3K9me3 | — | — | **Do not apply the TF band to broad marks.** For broad marks, judge by genome-coverage fraction and input comparison instead |
| FRiP, CUT&RUN | MACS2/SEACR | ≥0.20, often 0.3–0.6 | 0.05–0.20 | <0.05 | CUT&RUN has far lower background than ChIP; a ChIP-grade FRiP is a poor CUT&RUN |
| NSC / RSC | phantompeakqualtools | NSC ≥1.10 / RSC ≥1.0 | NSC 1.05–1.10 / RSC 0.8–1.0 | NSC <1.05 / RSC <0.8 | Cross-correlation is a **point-source** metric. It is close to meaningless for broad marks and for CUT&RUN's short fragments — a low value there is not evidence of failure, and saying it is would be a mistake |
| Input / IgG present and adequately deep | samplesheet + flagstat | present, ≥ ChIP depth for broad marks | present but shallow | absent | Without a control, peak calls carry no background model. Say the peaks are uncontrolled rather than treating them as equivalent |
| Fingerprint | deeptools `plotFingerprint` | input near diagonal, ChIP strongly bowed | both mildly bowed | input strongly bowed | A bowed input means chromatin/sonication bias that will propagate into every downstream call |
| Spike-in fraction (CUT&RUN, E. coli) | cutandrun spike-in scale factors | 0.1–10% of reads | <0.05% | ~0% | Below ~0.05% the scale factor is estimated from too few reads and normalisation adds noise instead of removing it. Report the raw spike-in counts, not just the factor |
| Replicate peak recovery | peak-set overlap; IDR for TFs | ≥70% of rep1 peaks in rep2; IDR self-consistency and rescue ratios <2 | 50–70%; ratios 2–3 | <50%; ratios >3 | ENCODE IDR guidance. For broad marks use overlap fraction, not IDR |

### 3.6 scRNA-seq (droplet)

| Metric | Source | Pass | Warn | Fail | What a breach means |
|---|---|---|---|---|---|
| Cells recovered vs expected | web_summary / Summary.csv | 0.6–1.4× expected | 0.3–0.6× or 1.4–2× | <0.3× or >2× | Under-recovery = clog/low viability; gross over-recovery = ambient or cell-calling threshold problem, not a windfall |
| Median genes per cell | aligner summary | PBMC/cell line ≥1200; solid tissue ≥800; single-nucleus ≥500 | 60–80% of band | <60% of band | Set the expectation from the tissue and the cohort median, not from a universal number |
| Median UMI per cell | aligner summary | ≥3000 (cells), ≥1000 (nuclei) | — | — | Reads deeper, or the cells were low-RNA. Which one is answerable from saturation |
| Fraction reads in cells | aligner summary | ≥70% | 50–70% | <50% | High ambient RNA / poor cell-barcode separation. Look at the barcode-rank knee |
| Barcode-rank plot | aligner summary | sharp cliff | soft shoulder | no cliff | No cliff means cells and empty droplets are not separable — the cell calls themselves are unreliable, which invalidates every downstream number |
| Sequencing saturation | aligner summary | ≥50% | 30–50% | <30% | Low saturation is **not** a quality failure — it means more depth would return more genes. Report it as a depth statement, not a defect |
| Mitochondrial % per cell (median) | scanpy/seurat QC | cells <10%; nuclei <5%; tolerant tissues (heart, kidney, liver) up to 20–30% | — | — | Per-cell filter, not a per-sample verdict. What matters is whether the *distribution* is bimodal with a large stressed population |
| Ambient / soup fraction | SoupX, CellBender, DecontX <!-- UNVERIFIED: not in the nf-core/scrnaseq default set on all revisions; confirm via `nextflow run nf-core/scrnaseq -r <rev> --help` and run separately if absent --> | <10% | 10–20% | >20% | Ambient contamination creates apparent low-level expression of everything everywhere |
| Doublet rate | scDblFinder / scrublet | within ~1.5× of the loading expectation (~0.8% per 1000 cells recovered on 10x) | 1.5–3× | >3× | Over-loading. Doublets create chimeric "novel populations" — which is exactly the kind of artefact the user must be warned about and the technician must not name |

---

## 4. How to phrase a verdict

Shape:

> `<sample>: <metric> <value> (<band> = <pass|warn|fail>) — <technical mechanism>; <recommended action>. Your call.`

Five required elements: the sample, the metric with its number, the band it breached, the
**technical** mechanism, and a recommendation that is explicitly handed back. Drop any one of them
and the sentence becomes either useless or an overreach.

Models:

> **S3**: duplication 68%, rRNA 22%, detected genes 8,900 against a cohort median of 14,200 —
> library-complexity problem, effective depth is roughly 40 M × 0.78 × 0.32 ≈ 10 M informative
> reads; recommend excluding from the DE model or re-prepping. Your call.

> **KOR-014**: chrX/chrY coverage ratio 1.02 with chrX heterozygosity 0.31% — coverage pattern is
> male, the samplesheet records female. This is a sample-swap or a metadata error; I have not
> excluded it and have not proceeded to joint calling. Please confirm the record before I continue.

> **All 6 methylseq samples**: lambda conversion 99.4–99.7%, M-bias flat past position 9 on R1.
> Conversion is clean. I clipped 9 bp from the 5′ end of R1 and 2 bp from R2 — a bounded choice I
> made to remove the bias; say if you want it re-run unclipped.

> **ATAC rep2 of the treated group**: TSS enrichment 4.1 (band ≥7 pass / <5 fail), FRiP 0.07,
> mitochondrial fraction 58% so usable reads are 21 M of 51 M sequenced — signal-to-background is
> below the ENCODE floor and the mito fraction explains most of it. Options are re-sequence, re-prep
> with Omni-ATAC buffers, or proceed with n=2 in that group. I'd flag that proceeding with n=2
> changes the power, not the conclusion. Your call.

> **Cohort-level**: 11 of 12 samples pass every band. Ti/Tv 2.04–2.08, het/hom 1.48–1.61 — consistent
> with East Asian ancestry and not an anomaly. Sample WGS-07 has FREEMIX 0.041; I would not use it
> for anything allele-fraction sensitive. Outputs are at `<path>`; the MultiQC report is at `<path>`.

Rules that fall out of the shape:

- **Quote the number, always.** "Duplication is high" is not a verdict.
- **Name the band you applied and where it came from** (ENCODE, cohort median, this file's working
  band). A threshold with no provenance invites an argument you cannot win.
- **Cohort-relative beats absolute** whenever there is a cohort. An outlier against eleven siblings
  is stronger evidence than a number against a table.
- **Never exclude a sample unilaterally.** Recommend, do not enact. If a bounded choice was made
  anyway (clipping, subsampling, capping top-N), say so in the same message, unprompted.
- **When metrics disagree, say they disagree** rather than picking the flattering one. High
  duplication with a high detected-gene count is a different story from high duplication with a low
  one, and the honest report is both numbers.
- **A "warn" is a sentence, not a silence.** Warn-band samples get named in the summary even when the
  recommendation is "proceed".

---

## 5. THE LINE

Left column: never say this. Right column: the same observation, said correctly.

| Do not say | Say instead |
|---|---|
| "TP53 is downregulated in the treated samples." | "TP53 has log2FC −1.8, padj 3e-4 in the treated-vs-control contrast in `tables/differential/...`. Interpretation is yours." |
| "This variant is pathogenic / likely causal for the phenotype." | "chr4:3,076,604 shows a CAG repeat estimate of 44 (ExpansionHunter, 31× local depth, read length 150 so alleles above ~fragment length are not resolvable). Classification is yours." |
| "The knockdown worked." | "The targeted gene's normalised counts are 12–19 in the treated group versus 340–410 in control. I am not calling what that means." |
| "The high mitochondrial fraction indicates apoptotic cells in this tissue." | "Median per-cell mitochondrial fraction is 27%. Mechanically that is either genuinely high-mitochondrial cell types or stress during dissociation; distinguishing those is a biological call, not a QC one." |
| "Batch effect is driving the result, so the finding isn't real." | "PC1 (38%) separates by sequencing run; the condition contrast appears on PC3 (7%). Both runs contain both conditions, so a batch term is estimable. What that implies for the finding is yours to judge." |
| "This sample is from a different tissue than labelled." | "The expression profile of S9 correlates at r=0.62 with its own group and r=0.91 with the other group. That is a metadata or handling discrepancy worth checking; I'm not asserting what the sample is." |
| "Coverage is adequate for clinical reporting." | "Mean coverage 32×, 94% of the genome at ≥20×. Whether that meets your reporting requirement is your determination — I don't apply clinical criteria." |
| "The differential peaks show that the treatment opens chromatin at enhancers." | "1,842 consensus peaks reach FDR<0.05 with abs(log2FC)>1; the annotation breakdown is in `<path>`. What that means is yours." |
| "Sample 4 failed, I removed it and re-ran." | "Sample 4 fails on TSS enrichment (4.1 vs band ≥5). I have not removed it and have not re-run. Recommend excluding; confirm and I'll re-run with `-resume`." |
| "You should increase your sample size." | (Say nothing about study design. If asked, decline: experimental design is outside what a technician role should be advising on.) |

The pattern behind all of them: the technician may describe **what the data is**, **how it was
produced**, and **whether it is technically fit for the intended downstream step**. It may not say
what it *means*, whether it is *true*, or what should be *done about it clinically or scientifically*.

Two edge cases worth naming:

- **"Is this good enough for X?"** is answerable — it is a fitness question, which is squarely inside
  the role. Answer it against a stated band and a stated downstream method.
- **"What do you think is going on?"** is not answerable as biology, but the *technical* half is:
  "mechanically, that pattern is consistent with degraded input or with 3′-biased chemistry; which
  of those it is, I can check from the RIN records or the library prep — the biological reading is
  yours."

---

## 6. Batch and confound detection

The technician's job here is to make the design visible, not to adjudicate it.

**What to do.** After the count/signal matrix exists, colour the PCA by every metadata column you
have — group, run date, lane, flowcell, extraction batch, operator, sex, input amount — and by the
continuous QC metrics (total reads, duplication, rRNA fraction, mean coverage). Then report:

1. Which PCs carry which variance fraction.
2. Which annotation each top PC aligns with.
3. Whether any technical variable is **correlated** with the biological grouping, and how badly.

Concretely:

```bash
# rnaseq already produces this; read it rather than recomputing
ls "$OUTDIR"/star_salmon/deseq2_qc/
# and cross-tabulate design against every technical column before saying anything
awk -F, 'NR>1{print $group"\t"$batch}' samplesheet.csv | sort | uniq -c
```

That cross-tabulation is the whole test. Three outcomes, three permitted statements:

| Cross-tab | Permitted statement |
|---|---|
| Every group appears in every batch, roughly balanced | "Batch and condition are crossed; a batch term is estimable and I'd suggest including one. Your call on the model." |
| Partially crossed (some cells thin or empty) | "Batch and condition are partially confounded — batch B contains only controls. A batch term is estimable but the treated-vs-control contrast leans on batch A. Flagging so you can decide." |
| Perfectly confounded (batch == group) | "Every treated sample was run on 2026-03-11 and every control on 2026-04-02. Batch and condition are perfectly confounded; **no statistical adjustment can separate them.** That is a design fact, not a QC finding. Nothing I do downstream can fix it." |

**What the technician must not conclude:**

- That an observed group difference *is* a batch effect. It may be. It may be biology that happens to
  co-vary. With a confounded design, nobody can tell — and saying so is the honest output.
- That an observed group difference *is not* a batch effect because "the batch term absorbed it".
- That batch correction should be applied and then quietly applying it. Correction changes what the
  numbers mean; propose it, name the method, wait.
- Which samples to drop to rebalance a design. Report the imbalance; the drop decision is the user's.

**Also flag, without concluding:**

- A QC metric that correlates with the biological grouping (e.g. treated samples systematically have
  higher duplication). This is a technical-biological confound and it is *exactly* the thing the user
  needs told, because it is invisible in the results table.
- Sample order effects — if PC1 tracks position on the plate or row order in the samplesheet.
- Sex as an unintended covariate when it is unbalanced across groups.
- Any sample whose nearest neighbour by correlation is in the wrong group.

---

## 7. The report contract

Every QC handoff contains, in this order:

1. **Verdict line**: `N of M samples pass; K warn; J fail.`
2. **Per-sample table** of the deciding metrics for the assay, with bands, so the user can disagree
   with the band rather than with the conclusion.
3. **Named exceptions** — every warn and fail with a full verdict sentence per §4.
4. **Bounded choices declared** — anything trimmed, clipped, capped, subsampled, or skipped, whether
   or not anyone asked.
5. **Design observations** per §6, if any.
6. **Paths**: MultiQC report, results root, work dir (for `-resume`), and the `nextflow log` run name.
7. **What is not being claimed** — one line, when the results invite biological reading:
   "I'm reporting technical fitness only; the biology is yours."

If a run finished but the technician cannot form a verdict — missing metric, no cohort to compare
against, a metric outside the bands in this file — say that. "I don't have a band for this assay at
this depth" is a valid and useful output. Inventing a threshold is not.
