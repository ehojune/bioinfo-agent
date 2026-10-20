# sarek: exact stub gate

Read only for this pipeline, after [common stub isolation](../../runbook.md#4-preview-then-stub).
This is a partial gate at the documented revision, never permission to waive another error.
Re-check the pin in `config/pipelines.tsv`; a version change requires fresh evidence.

**`nf-core/sarek`, `-stub-run`, and `--tools haplotypecaller` without a dbsnp/known_indels
resource.** Re-verified 2026-08-10 (`20260810-sarek-srr26793256-revalidate`) against the pin this
file's own table names, `3.5.1` (commit `5fe5cdff171e3baed603b3990cab7f7fd3fcb992`). This store has
no GATK resource bundle (`config/genomes.config`'s `GRCh38gatk` `dbsnp`/`known_indels`/
`germline_resource` rows are all `[!] fetch`, still unbuilt as of this writing), so any germline
run through `--tools haplotypecaller` routes into
`subworkflows/local/bam_variant_calling_germline_all/main.nf`'s single-sample filtering branch,
which — unless `--skip_tools haplotypecaller_filter` is set — calls
`subworkflows/local/vcf_variant_filtering_gatk`, i.e. `GATK4_CNNSCOREVARIANTS` then
`GATK4_FILTERVARIANTTRANCHES`. The `GATK4_CNNSCOREVARIANTS` module
(`modules/nf-core/gatk4/cnnscorevariants/main.nf`) **has no `stub:` block at 3.5.1**, so this is
the same "real script fed a deliberately-empty stub upstream output" shape as the rnaseq and
differentialabundance cases in their respective stub cards: it runs for real against HaplotypeCaller's placeholder stub VCF
and GATK dies with `A USER ERROR has occurred: Cannot read file://<sample>.haplotypecaller.vcf.gz
because no suitable codecs found` (exit 2). Confirmed revision-specific, not host- or
config-specific: the `3.9.0` clone from the prior sarek run on this host
(`b97952e5bac68d5deb93d4a3349a45f146be9830`, `runs/20260729-sarek-srr26793256/`) **does** carry a
`stub:` block in the same module — this was added upstream sometime between 3.5.1 and 3.9.0, and
silently regresses whenever the pin in `config/pipelines.tsv` points at an older tag than what a
prior run validated.

**The stub-only fix, always required at this pin, independent of the bundle:** add
`haplotypecaller_filter` to `--skip_tools` **for the `-stub-run` invocation**. **A CLI
`--skip_tools` *replaces* whatever value a params file or config already set — it does not merge
with it.** On this no-bundle store, `--skip_tools baserecalibrator` is already required (see
[sarek card](../sarek.md)'s `--skip_tools baserecalibrator` row); pass one combined,
comma-joined value — `--skip_tools baserecalibrator,haplotypecaller_filter` — not a second
`--skip_tools` flag with only `haplotypecaller_filter` in it, which would silently re-enable
BaseRecalibrator against resources the store does not have.
`workflows/sarek/main.nf` reads `params.skip_tools` for `haplotypecaller_filter` specifically to
gate the whole `VCF_VARIANT_FILTERING_GATK` call, so this skips `CNNSCOREVARIANTS`/
`FILTERVARIANTTRANCHES` outright — it removes the reason the unstubbed module runs at all, rather
than routing around it. Verified clean end to end (`completed=10 failed=0 cached=0`,
`20260810-sarek-srr26793256-revalidate`). **This is a property of the 3.5.1 module, not of whether
a GATK bundle exists** — `GATK4_CNNSCOREVARIANTS` has no `stub:` block regardless of what
`--dbsnp`/`--known_indels` you pass, so it still runs for real (and still gets fed the same empty
placeholder VCF) under `-stub-run` even once the bundle is fetched and a real run passes those
flags. **Keep this skip in the stub invocation permanently, at this pin — do not remove it "once
the bundle exists."** (Codex flagged this exact trap in review: dropping it from the stub the day
the bundle lands reopens the same crash, because nothing about having `--dbsnp` changes whether the
module is stubbed.) If a later sarek revision adds the missing `stub:` block (as 3.9.0 already
has), re-check with the two-line `grep -rL --include='main.nf' 'stub:'` command in runbook section 4 before
carrying this forward again.

**What this stub-only skip does NOT cover:** with `haplotypecaller_filter` in `--skip_tools`, the
stub never instantiates `GATK4_CNNSCOREVARIANTS` or `GATK4_FILTERVARIANTTRANCHES` at all — their
channel wiring, output propagation into the rest of `vcf_variant_filtering_gatk`, and MultiQC's
consumption of their reports are never exercised by `-stub-run`, clean or not. The `completed=10
failed=0` result above proves the rest of the pipeline wires correctly; it says nothing about this
branch. The first real evidence that `VCF_VARIANT_FILTERING_GATK` is runnable is therefore the
first *real* command that does not carry `haplotypecaller_filter` in its own `--skip_tools` — but
the gate that run must clear depends on whether calibration resources were supplied, not on the
FILTER column alone:
- **Wiring gate, always required:** both `CNNSCOREVARIANTS` and `FILTERVARIANTTRANCHES` complete
  (`failed=0` on those two tasks) and the output VCF carries a `CNN_1D` key in its `INFO` field —
  `modules/nf-core/gatk4/cnnscorevariants/main.nf` calls GATK's `CNNScoreVariants` with no
  `--tensor-type` override, so it runs GATK's default 1D model and writes that annotation
  unconditionally, with or without `--dbsnp`/`--known_indels`. Its presence is what proves the
  branch is actually wired and running, not an artefact of calibration data existing.
- **Filtering gate, only once `--dbsnp`/`--known_indels` are supplied:** non-`.` values in the
  `FILTER` column. Without those resources `FilterVariantTranches` has nothing to calibrate
  against and legitimately leaves every record `.` — as already measured on this exact host
  (`runs/20260729-sarek-srr26793256/handoff.md`'s Ti/Tv row) — so requiring non-`.` on a
  no-bundle run would fail a correctly-wired branch forever, not catch a real defect.

Same discipline as the rnaseq and differentialabundance cases in their respective stub cards: name the concrete signal that
proves the branch ran, don't reuse a signal that depends on inputs this stub fix has nothing to do
with.

**Whether the *real* run also carries `haplotypecaller_filter` in `--skip_tools` is a separate,
explicit methods decision — not implied by the stub fix above, and not something this file
recommends by default.** Codex also flagged this in review, correctly: adding the skip to the real
command does not merely dodge a stub artefact, it removes `CNNSCOREVARIANTS`/
`FILTERVARIANTTRANCHES` from the actual pipeline, which changes the produced VCF (no CNN score
annotations, no `FilterVariantTranches` pass at all, however uninformative that pass would have
been). The "this changes nothing material" reasoning only holds while the store genuinely has no
`--dbsnp`/`--known_indels` to give `FilterVariantTranches` anything to calibrate against (confirmed
for a 3.9.0 run, `runs/20260729-sarek-srr26793256/handoff.md`'s Ti/Tv row — FILTER came out `.` on
every record regardless) — it stops holding the moment a run actually passes real `--dbsnp`/
`--known_indels`. Decide and record this per run, in that run's own `plan.md`, as a bounded choice
with the reasoning stated, not by copying `--skip_tools` wholesale from this section. Two concrete
cases:

- **Bundle still absent** (this store's state as of this writing): `FilterVariantTranches` will not
  filter anything either way. Adding `haplotypecaller_filter` to the real run only saves the two
  wasted process invocations — legitimate, but still a choice to state, not a default to inherit
  silently.
- **Bundle present, real `--dbsnp`/`--known_indels` supplied**: do **not** carry
  `haplotypecaller_filter` into the real run's `--skip_tools` — that would silently discard working
  GATK filtering for no reason connected to the stub problem. Keep it in the stub invocation only;
  the real command runs the full `VCF_VARIANT_FILTERING_GATK` branch as sarek intends.
