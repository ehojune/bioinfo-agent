# Plan — 20260804-rnaseq-scer-verify

Purpose: verify PR #4 (bootstrap/04-refs.sh + config/genomes.config alias fix for
nf-core/rnaseq's AWS-iGenomes filename heuristic) using the repo-standard mechanism only,
via the `--genome R64-1-1` compact form specifically (previously the more vulnerable path).
No ad-hoc alias workaround this time.

**Pipeline**: nf-core/rnaseq -r 3.18.0 (pinned, config/pipelines.tsv)
**Data**: reused, already-validated — DRR220758/DRR220759 PE FASTQ,
  `/work/rawdata/20260803-rnaseq-scer-la-tolerant/` (same files as the 2026-08-03 run; not
  re-downloaded)
**Reference**: R64-1-1 (S. cerevisiae, Ensembl release-116/annotation build 63), already in
  `config/refs.manifest.tsv` and `config/genomes.config`. fasta/gtf: OK on disk, aliased
  (`genomes/R64-1-1/{fasta/R64-1-1.fa,gtf/R64-1-1.gtf.gz}` -> canonical files), confirmed via
  `bootstrap/04-refs.sh` this run (exit 0, both OK, no FATAL). STAR/salmon index: NOT BUILT yet
  — will be built fresh via `--save_reference` (genome ~12 Mb, expect minutes not hours).
**Command shape**: `--genome R64-1-1 --igenomes_ignore` (compact form, on the command line per
  genomes.config section 2's explicit warning that `--igenomes_ignore` must not be set via a
  `-c` file) — deliberately NOT `--fasta`/`--gtf` explicit form, since the compact form is what
  PR #4 specifically had to fix.
**Estimate**: wall clock ~10-15 min (previous run's real compute was 12m6s at this same data
  scale, plus first-time STAR/salmon index build for a 12 Mb genome, itself minutes). Peak disk
  ~3 GB. Well under the 24h/1.5x-disk gates.
**Bounded choices carried over unchanged from the 2026-08-03 run** (not re-litigated here,
  same dataset): strandedness `auto` in the samplesheet; STAR+salmon default (`star_salmon`);
  no `--skip_*` flags; sample names kept as SRA accessions.

**New-index promotion**: STAR/salmon built this run will be produced under
`--save_reference` into this run's own results dir, matching the manifest's `build` mode rows
for `genomes/R64-1-1/index/{star,salmon}/`. Not auto-promoted into `$BIOINFO_REFS` (04-refs.sh
does not do that step); left as a known gap per repo convention, same as last time.

Since this reuses a validated dataset/config combination and the only variable under test is
the repo mechanism itself, proceeding straight to preflight + stub-run + execution without a
separate approval pause (informational plan, per task instructions).
