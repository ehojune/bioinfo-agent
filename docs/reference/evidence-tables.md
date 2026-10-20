# Evidence tables

Audit date: 2026-10-20. **Historical records, not a fresh scientific rerun.**
`R` = linked public run report; `N` = narrative in a maintained reference, with no
standalone report linked here; `U` = UNVERIFIED in this audit. Completion does not
imply acceptable QC or accuracy. A documented stub waiver is not a stub PASS.

## Table 1. Scope and validation

Pins follow [pipelines.tsv](../../config/pipelines.tsv). The local pipeline's version
comes from its [manifest](../../pipelines/pacbio-hifi-wgs/nextflow.config).
“Stub/test” reports only the cited configuration, not every upstream branch.

| Pipeline | Pin | Prepared scope | Stub / test evidence | Real input evidence | Truth accuracy |
|---|---|---|---|---|---|
| rnaseq | 3.18.0 | Bulk alignment/quantification | [R: revalidation](../examples/20260816-rnaseq-revalidate/handoff.md) | R: two yeast samples | U |
| differentialabundance | 1.5.0 | Count-matrix contrasts | N: conditional stub workaround | [N: outputs recorded](../../skills/bioinfo-analyze/references/pipelines/differentialabundance.md) | U |
| fetchngs | 1.12.0 | Public accessions → FASTQ | [R: test fixture; stub can download](../examples/20260810-fetchngs-citest/handoff.md) | Same public-accession fixture; independent cohort U | N/A: acquisition |
| sarek | 3.5.1 | Germline/somatic variant workflows | [R: 41 stub / 23 full-test tasks](../examples/20260816-sarek-revalidate2/handoff.md) | R: one reused CRAM, HaplotypeCaller scope | U |
| methylseq | 3.0.0 | RRBS/WGBS | [R: stub waiver; full test](../examples/20260816-methylseq-revalidate/handoff.md) | [R: two RRBS samples](../examples/20260805-methylseq-sle-rrbs-smoke/handoff.md); later cache-heavy resume | U |
| atacseq | 2.1.2 | Accessibility peaks/QC | [N: configuration observations](../../skills/bioinfo-analyze/references/pipelines/atacseq.md) | U: standalone run report needed | U |
| chipseq | 2.1.0 | ChIP peaks/QC | R: stub configuration findings | [R: four samples; signal FAIL](../examples/20260806-chipseq-vsmc-h3k27me3-smoke/handoff.md) | U |
| cutandrun | 3.2.2 | CUT&RUN/CUT&Tag | N: parser repair required | [N: 146-task CPM run](../../skills/bioinfo-analyze/references/pipelines/cutandrun.md) | U |
| scrnaseq | 2.7.1 | STARsolo counts/QC | R: setup/OOM findings | [R: one 10x lane](../examples/20260805-scrnaseq-skin-cd3/handoff.md) | U |
| ampliseq | 2.18.0 | 16S/ITS | N: waiver; CI-scale full run | [N: one DRR033717 sample](../../skills/bioinfo-analyze/references/estimates.md) | U |
| mag | 5.5.0 | Assembly/binning | [R: waiver; full test](../examples/20260812-mag-testprofile-procurement/handoff.md) | [R: shallow DRR027580, zero bins](../examples/20260812-mag-drr027580-realsample/handoff.md) | U |
| taxprofiler | 2.0.1 | Kraken2 prepared scope | [R: stub/full test, 14 toy profilers](../examples/20260812-taxprofiler-testprofile-procurement/handoff.md) | [R: one sample, 99.07% unclassified](../examples/20260812-taxprofiler-drr027580-realsample/handoff.md) | U |
| nanoseq | 3.1.0 | Already-basecalled ONT DNA | N: incomplete upstream stubs | [R: SRR25466853](../examples/20260813-nanoseq-srr25466853/handoff.md) | U |
| rnasplice | 1.0.4 | SUPPA2 per-isoform analysis | N: conditional stub waiver | [R: eight yeast samples; scoped resume](../examples/20260814-rnasplice-scer-gln3-ibutanol/handoff.md) | U |
| raredisease | 3.1.2 | Calling/QC; annotation/ranking excluded | N: narrow-scope stub PASS | [R: one reused WGS alignment](../examples/20260812-raredisease-srr26793256/handoff.md) | U |
| bacass | 2.6.1 | Short-read assembly/Prokka | [R: waiver; full test](../examples/20260816-bacass-testprofile-procurement/handoff.md) | [R: SRR2589044](../examples/20260816-bacass-srr2589044-realsample/handoff.md) | U |
| viralrecon | 3.0.0 | Illumina SARS-CoV-2 amplicons | N: conditional upstream waiver | [R: sample01, completeness FAIL](../examples/20260818-viralrecon-sample01-realsample/handoff.md) | U |
| isoseq | 2.0.0 | PacBio transcript models | N: conditional upstream waiver | [R: real CI subsample, chr19 reference](../examples/20260814-isoseq-alz-chr19/handoff.md) | U |
| spatialaxe | 1.0.1 | Xenium coordinate mode | [R: stub/full test](../examples/20260820-spatialaxe-testprofile-procurement/handoff.md) | [R: 23-cell tiny bundle](../examples/20260820-spatialaxe-realsample/handoff.md); not a whole slide | U |
| pacbio-hifi-wgs | 0.2.0 | HiFi germline; aligned tumor–normal somatic | [R: positive/negative stub suite](../examples/20260925-pacbio-somatic-cpu-validation/handoff.md) | R: 49 germline executions / 45 datasets; 13 somatic pairs | [R: 19 small-variant, 5 HG002 SV, 13 HG008 somatic evaluations](../examples/20260926-pacbio-hifi-wgs-giab-wholegenome/handoff.md) |

PacBio germline accuracy belongs to historical `48ec463` plus the documented
report-label patch; somatic evidence belongs to `f2de95e`. The cited record did
not rerun germline datasets on 0.2.0. SV accuracy covers HG002 only. Somatic
precision was read for two matched pairs; the other 11 use a borrowed normal.
Do not turn “49 executions” into “49 independent accuracy benchmarks.”

## Table 2. Failure interception and recovery

| Failure mode | Control / observed result | Evidence class and limit |
|---|---|---|
| Existing alignment/reference ambiguity | Inspect headers and manifest before selecting re-entry | [R: sarek reuse](../examples/20260816-sarek-revalidate2/handoff.md); no automated general mismatch-attestor benchmark |
| Invalid sample identities, paired/control structure | `check-samplesheet.sh` rejects malformed inputs | [Executable rules](../../scripts/check-samplesheet.sh); no aggregate production rejection rate |
| Invalid reference alias or missing index | Parameter/stub gates stop before real execution; explicit overrides unblock | [R: rnaseq alias verification](../examples/20260804-rnaseq-scer-verify/handoff.md) |
| Work/result capacity below the margin, or results on a different filesystem | Preflight compares available bytes with the required margin on each destination | [18 synthetic preflight tests](../../scripts/preflight.test.sh); omitted output estimate warns and is not a capacity PASS |
| STAR FIFO on drvfs | Failure motivated native-filesystem placement check | [R: failed test-profile run](../examples/20260807-rnaseq-testprofile-e/handoff.md); the failure was observed, not prevented in that historical run |
| Premature work deletion | Recognized cleanup denied while live, without handoff, or inside hold | [132 synthetic guard tests](../../hooks/guard-workdir.test.sh); not a kernel sandbox |
| Stale PID; collateral ABORTED tasks | Run-specific Java fallback; FAILED/ABORTED/non-clean separated | [77 synthetic triage tests](../../scripts/triage-run.test.sh); input byte preservation checked |
| STARsolo memory exhaustion | Task budget revised, resumed execution completed | [R: OOM then recovery](../examples/20260805-scrnaseq-skin-cd3/handoff.md); caps do not guarantee no OOM |
| Completed pipeline with poor signal | Technical QC reports FAIL rather than interpreting biology | [R: ChIP signal FAIL](../examples/20260806-chipseq-vsmc-h3k27me3-smoke/handoff.md), [viral completeness FAIL](../examples/20260818-viralrecon-sample01-realsample/handoff.md) |
| Interrupted stub / drifted upstream patch / malformed metadata | Detached gate state, hash-pinned patch refusal, strict schema checks | [Contract tests](../../scripts/run-contract.test.py); synthetic/fake Nextflow, not new scientific evidence |

No “38 real runs blocked/recovered” aggregate is asserted: the source set mixes
historical runs, test profiles, repeated attempts and unit fixtures.

## Table 3. Predicted versus observed resources and reuse

| Case | Prior estimate | Recorded observation | Interpretation / evidence |
|---|---|---|---|
| Two-sample yeast rnaseq | 10–15 min; ~3 GB combined | 9m9s; ~2.5 GB combined | [Plan](../examples/20260804-rnaseq-scer-verify/plan.md), [handoff](../examples/20260804-rnaseq-scer-verify/handoff.md); one case, not calibration accuracy |
| Sarek variant-calling re-entry | 2–8 h | 10h32m; 439 MB settled work + 226 MB results | [Plan](../examples/20260816-sarek-revalidate2/plan.md), [handoff](../examples/20260816-sarek-revalidate2/handoff.md); concurrent workload confounds time; settled disk is not peak |
| Bacass one bacterial sample | Single-digit to low tens of minutes; work well below 5 GB | 8m21s; 514 MB work + 102 MB results | [Plan](../examples/20260816-bacass-srr2589044-realsample/plan.md), [handoff](../examples/20260816-bacass-srr2589044-realsample/handoff.md); cached tool environment |
| Spatialaxe tiny real bundle | Similar to or shorter than ~3 min test; tens of MB | 2m23s; 27 MB work + 26 MB results | [Plan](../examples/20260820-spatialaxe-realsample/plan.md), [handoff](../examples/20260820-spatialaxe-realsample/handoff.md); 23-cell input only |
| Methylseq resume | No comparable clean-run counterfactual | 16/17 tasks cached; <5 MB new; seconds | [Handoff](../examples/20260816-methylseq-revalidate/handoff.md); task reuse, not measured speedup ratio |
| Rnasplice scoped recovery | No matched counterfactual | 38 cached, 2 completed, 0 failed on final attempt | [Handoff](../examples/20260814-rnasplice-scer-gln3-ibutanol/handoff.md); narrowed local-event scope disclosed |
| PacBio whole genome | No paired per-run plan estimates archived here | Germline 4.7–11.7 h; somatic 2.4–3.4 h | [Historical benchmark](../examples/20260926-pacbio-hifi-wgs-giab-wholegenome/handoff.md); job maxvmem is virtual, not RSS |
| 90-sample RNA cohort | **UNVERIFIED** paired plan/trace | #68 reports 321 GB input, 16.2 h, 705 GB work, 3.2 GB results | [Issue claim](https://github.com/ehojune/bioinfo-agent/issues/68); not promoted to measured table results without a public reproducibility bundle |
| Avoided repeated I/O / realignment | 10.7 h / 90–270 h mentioned in issue/session narrative | No matched rerun comparison in this audit | [#68](https://github.com/ehojune/bioinfo-agent/issues/68), [session illustration](../example-session.svg); estimates/observations of prior work, not demonstrated causal time savings |

For new measurements, record units, input and reference identity, cold/warm cache,
concurrency, attempt count, process peak RSS, disk measurement timing and observed
scope. Unknown is `null` in [run metadata](run-contract.md), not zero.
