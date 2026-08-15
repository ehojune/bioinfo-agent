# Execution runbook

The exact sequence for getting an nf-core pipeline from "the user asked for X" to "here are the
results and here is the QC verdict", on this host. Deviating from the order below is how runs get
lost twelve hours in.

Host facts this runbook is written against: WSL2 `Ubuntu-24.04`, 24 logical cores, 63.5 GB host RAM,
Docker **engine** inside the distro, distro ext4 on `D:\wsl\ubuntu-24.04\ext4.vhdx` (1 TB max,
~955 GB free), `appendWindowsPath=false`, references under `$BIOINFO_REFS` (default `/refs`).

## Sequence at a glance

1. Pick pipeline + revision. Pin the revision.
2. Write the run plan to `$RUNDIR/plan.md`. Get approval if the estimate exceeds 24 h.
3. Write `samplesheet.csv`, `params.yaml`, `cmd.sh` into `$RUNDIR`.
4. Preflight. Any FAIL is a hard stop.
5. `-preview`, then `-stub-run`. Both must be clean — with exactly nine documented departures, the
   rnaseq `strandedness: auto` waived stub failure, the differentialabundance `--features`
   substitute stub, the sarek `haplotypecaller_filter` skip, the ampliseq `CUTADAPT_BASIC` true
   waiver, the mag `UNTAR`/local-modules-without-stubs finding, the nanoseq
   `SAMTOOLS_IDXSTATS`/`SAMTOOLS_FLAGSTAT` true waiver, the rnasplice
   `GTF_GENE_FILTER`/`RSEM_PREPAREREFERENCE` true waiver, the isoseq `ULTRA_INDEX` true waiver
   (confined to the `aligner: ultra` branch this repo does not stock), and the bacass `UNICYCLER`
   true waiver, all defined in section 4.
6. Launch on ext4 with reports and `-resume`, always through `tmux` (mandatory, not optional).
7. Monitor the trace, not the terminal.
8. On completion: read MultiQC, rsync results out to `/mnt/d`, write the handoff.
9. Leave the work dir alone for at least 7 days.

---

## 1. Directory layout

Two directories per run, one on each filesystem, sharing a run ID.

```
RUNID = <YYYYMMDD>-<pipeline>-<slug>          e.g. 20260728-rnaseq-koges-pilot

/mnt/d/bioinfo-agent/runs/$RUNID/            NTFS via drvfs — human-visible, small text + deliverables
  ├── plan.md                            written BEFORE launch, never edited after
  ├── samplesheet.csv
  ├── params.yaml
  ├── cmd.sh                             the literal command that was run
  ├── results/                           rsync target, populated at the END
  ├── reports/                           rsync target: report/trace/timeline per attempt
  └── handoff.md                         written at the END

$BIOINFO_WORK/nxf/$RUNID/              ext4 inside the distro — everything live  (BIOINFO_WORK defaults to /work)
  ├── work/                              -work-dir, task scratch
  ├── .nextflow/                         resume cache (LevelDB)  <-- must be ext4
  ├── .nextflow.log[.1.2…]
  ├── nextflow.stdout.log
  ├── nextflow.pid
  ├── results/                           --outdir during the run
  └── reports/
```

### Why the split, precisely

**The work dir must never be under `/mnt/*`.** Four independent reasons, any one of which is
sufficient:

- **STAR cannot run there at all.** drvfs has no FIFOs, and STAR builds one per read file:
  `could not create FIFO file … SOLUTION: … Windows partitions FAT, NTFS … re-run on a Linux
  partition`. It is a `FATAL ERROR` before a single read is processed, not a slowdown. Measured
  2026-08-07 on `-profile test` with `-work-dir /mnt/e/...` (`docs/examples/20260807-rnaseq-testprofile-e`).
  The pseudo-aligner path has no FIFOs and does complete on drvfs
  (`docs/examples/20260807-rnaseq-salmononly-e`) — which is the only reason the distinction is worth
  writing down rather than just saying "drvfs is forbidden".
- drvfs is 5–10× slower than ext4, and task scratch is the most I/O-intensive thing in the run.
- Nextflow's resume cache is a LevelDB under the *launch* directory. LevelDB needs real POSIX file
  locking; on drvfs it intermittently fails to acquire the lock, which does not just slow the run
  down, it makes `-resume` unreliable.
- The nf-core `docker` profile runs containers as `-u $(id -u):$(id -g)`. drvfs synthesises
  ownership from the mount options rather than storing it, so container-side `chown`/`chmod` inside
  the work dir behaves differently from ext4 and some modules fail on it.
- Hardlinks do not cross the ext4↔drvfs boundary. Nextflow stages inputs into task dirs by hardlink
  where it can and falls back to copying where it cannot; splitting the work dir across the boundary
  turns every stage-in into a full copy.

**The launch dir is also on ext4** — not only `-work-dir`. `.nextflow/cache` and `.nextflow.log` are
created relative to the current directory, so launching from `/mnt/d/...` puts the resume cache on
drvfs even when `-work-dir` is correct. Always `cd "$NXFDIR"` first.

**`--outdir` points at ext4 during the run**, and results are rsynced to `/mnt/d` once at the end.
nf-core's default `publish_dir_mode = 'copy'` means every published file is copied out of the work
dir as it is produced; doing that across drvfs, thousands of times, during the run, is pure waste.
One sequential rsync at the end costs a fraction of it. Corollary: never set
`publish_dir_mode = 'link'` or `'symlink'` with an outdir on `/mnt/d` — hardlinks cannot cross the
boundary and drvfs symlinks require Windows developer mode.

**You can still look at live results from Windows.** The distro's ext4 is browsable at
`\\wsl.localhost\<distro>\work\nxf\<RUNID>\` in Explorer — `<distro>` is `$BIOINFO_DISTRO` — and
MultiQC HTML opens fine from there. Windows-visibility is not a reason to put the outdir on drvfs.

**Input FASTQs may stay on `/mnt/d`.** They are read sequentially, once or twice, and drvfs
sequential throughput is adequate. If the trace shows alignment tasks pinned at low `%cpu` with high
`wa`, copy the FASTQs to `$BIOINFO_WORK/staging/$RUNID/` and re-point the samplesheet — but see the
`-resume` section first, because doing that mid-run changes input mtimes and busts the cache.

### One-time host setup

```bash
sudo mkdir -p "${BIOINFO_WORK:-/work}"/nxf "${BIOINFO_WORK:-/work}"/staging
sudo chown -R "$USER:$USER" "${BIOINFO_WORK:-/work}"
```

Put this in `~/.bashrc` (or the skill's env preamble):

```bash
export BIOINFO_HOME=/mnt/d/bioinfo-agent
export BIOINFO_REFS=/refs
export NXF_WORKROOT="${BIOINFO_WORK:-/work}/nxf"
export NXF_ASSETS="$BIOINFO_REFS/cache/nf-assets"    # pipeline clones live on ext4
export NXF_OPTS='-Xms1g -Xmx8g'                       # cap the launcher JVM (03-nextflow.sh sets this)
export NXF_ANSI_LOG=false                             # append-only log; ANSI redraws make it unreadable
```

Two Windows-side settings that decide whether a long run survives. Run these from PowerShell, not
from inside the distro — `appendWindowsPath=false` means `wsl.exe` and `powercfg.exe` are not on the
distro's `PATH` (reach them at `/mnt/c/Windows/System32/…` if you must).

- **WSL memory ceiling.** WSL2 defaults to roughly half of host RAM, i.e. ~31 GB here. That is below
  what a human STAR index build wants (~40 GB) and well below comfortable for sarek. Check inside
  the distro with `free -g`; if `total` is ~31, copy `config/wslconfig.example` to
  `%USERPROFILE%\.wslconfig` — it is the tested source for the VM budget — then `wsl --shutdown`
  from PowerShell and restart the distro. Leaving the balance to Windows is not optional; starving
  the host makes the whole machine unusable and does not speed up the run.
- **Sleep and updates.** A 30-hour sarek run does not survive S3 sleep or a Windows Update reboot.
  `powercfg /change standby-timeout-ac 0` and set Active Hours before launching anything long.

---

## 2. The run plan

Written to `$RUNDIR/plan.md` **before** anything is launched, and not edited afterwards — if
the plan changes, the run gets a new RUNID. It is the artifact the user approves.

Required fields:

| Field | Content |
|---|---|
| `pipeline` | `nf-core/<name>` |
| `revision` | exact tag from `config/pipelines.tsv`. Never `dev`, never blank |
| `question` | one sentence: what the user wants out of this |
| `samples` | count, layout (SE/PE), read length, per-sample input size, total GB |
| `reference` | build name from the manifest (`GRCh38`, `GRCh38gatk`, `KOREF1`) and the standard paths used |
| `params` | the full contents of `params.yaml`, inline |
| `missing` | every reference the manifest marks `build`/`fetch` that this run needs, and how it will be obtained |
| `disk_estimate` | work dir GB, published results GB, and the 1.5× gate figure |
| `time_estimate` | wall-clock hours, with the basis for the number |
| `bounded_choices` | anything narrowed: samples dropped, top-N, subsampling, a caller skipped |
| `approval` | required if `time_estimate > 24 h`; record the user's yes here |

### Estimation anchors

Every time and disk figure comes from `references/estimates.md`. Do not restate numbers here.

A single 30× WGS through sarek trips the 24-hour rule on its own. Say so in the plan and get an
explicit yes before launching; do not discover it at hour 25.

**Host-specific gotcha to put in the plan for any sarek run:** the manifest gives us a classic
**BWA** index for `GRCh38gatk`, not a bwa-mem2 index. Recent sarek defaults to `bwa-mem2`, whose
index *construction* for human peaks well above this machine's RAM. Set `aligner: bwa-mem` in
`params.yaml` to reuse the index we already have.
<!-- UNVERIFIED: confirm the aligner option name and accepted values for the pinned revision via
     `nextflow run nf-core/sarek -r <REV> --help` and `grep -n aligner $NXF_ASSETS/.repos/nf-core/sarek/clones/*/nextflow_schema.json` -->

### Samplesheet schema: re-derive it, do not trust a table

nf-core samplesheet columns and parameter names drift between revisions. Before writing the
samplesheet for a pipeline/revision combination you have not used before:

```bash
PIPE=rnaseq; REV=3.18.0                        # revision from config/pipelines.tsv
nextflow pull nf-core/$PIPE -r $REV
nextflow run nf-core/$PIPE -r $REV --help
cat "$(find "$NXF_ASSETS" -path "*nf-core/$PIPE*" -name schema_input.json | head -1)"
head -3 "$(find "$NXF_ASSETS" -path "*nf-core/$PIPE*" -name samplesheet.csv | head -1)"   # shipped example, if present
```

`schema_input.json` is authoritative: it lists required columns, allowed values (e.g. `strandedness`
enums), and filename patterns. Record in the run plan which revision the samplesheet was written
against.

---

## 3. Preflight

`bin/preflight.sh` ships with the repo. Invoke it; never restate it and never overwrite it.

```bash
RUNID=20260728-rnaseq-koges-pilot
RUNDIR=$BIOINFO_HOME/runs/$RUNID
bash "$BIOINFO_HOME/bin/preflight.sh" "$RUNDIR" 180      # 180 = estimated work-dir GB
```

Exit 0 = clean, exit 1 = at least one FAIL.

Any FAIL is a hard stop. The disk check is the 1.5× gate: with an estimate of 180 GB, preflight
demands 270 GB free on ext4 and refuses otherwise. Do not talk yourself past it — an out-of-disk
death at hour 18 costs more than the wait.

---

## 4. Preview, then stub

Two cheap gates, in this order. Never skip either.

**`-preview`** resolves params and builds the DAG without executing anything. It catches schema
violations, missing required params, and unresolvable reference paths in seconds.

```bash
NXFDIR=${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID   # same derivation everywhere
mkdir -p "$NXFDIR"          # the launch dir only — NOT work/, the real launch creates that
cd "$NXFDIR"
nextflow run nf-core/rnaseq -r 3.18.0 -profile docker \
  -params-file $RUNDIR/params.yaml \
  -c $BIOINFO_HOME/config/local.config \
  -preview
```

**`-stub-run`** actually walks the whole workflow, running each module's `stub:` block instead of
the real command. It creates empty output files, so it validates channel wiring, samplesheet
parsing, and the full topology end to end — in minutes, on kilobytes.

**That "minutes, on kilobytes" claim assumes every process defines a `stub:` block. It is a
per-process property, not a pipeline-wide guarantee, and Nextflow's own documented fallback for a
process with none is to run its real `script:` unchanged under `-stub-run`.** Measured on
nf-core/fetchngs 1.12.0 (run 20260810-fetchngs-citest): several of its download modules define no
stub, so the "stub" run genuinely downloaded 939 MB over ~7 minutes before any real launch — see
`references/pipeline-selection.md` §4.3 for the specifics and the sizing consequence. Before
trusting this step is cheap for a pipeline you have not stubbed before on this host, a quick check
for which modules are missing a `stub:` block is worth the 30 seconds it costs — `-L`
(capital, "files WITHOUT a match"), not `-l`, and restricted to `main.nf` so it does not also list
every `README`/`meta.yml` in the tree as if they were unstubbed processes:

```bash
grep -rL --include='main.nf' 'stub:' <clone>/modules/
```

```bash
NXFDIR=${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID   # same derivation everywhere
STUBROOT=${BIOINFO_WORK:-/work}/tmp/stub-$RUNID             # OUTSIDE the run tree, on purpose
STUBDIR=$STUBROOT/main         # one subdirectory PER stub attempt — see "two stubs" below
mkdir -p "$NXFDIR" "$STUBDIR"   # the launch dir only — NOT work/, the real launch creates that
cd "$NXFDIR"
nextflow run nf-core/rnaseq -r 3.18.0 -profile docker \
  -params-file $RUNDIR/params.yaml \
  -c $BIOINFO_HOME/config/local.config \
  -work-dir "$STUBDIR/work" \
  --outdir "$STUBDIR/results" \
  -stub-run -ansi-log false
```

**One `$STUBDIR` per attempt, never a shared one.** Two stub runs pointed at the same work and
results trees produce a *union* of their outputs, and a union can satisfy the output-tree
inspection below even when neither run produced everything on its own — which is precisely the
false pass a gate must not be able to give. It matters as soon as you run more than one stub, and
the `strandedness: auto` case below forces exactly that. Give each attempt its own subdirectory of
`$STUBROOT` and delete `$STUBROOT` once as the last step.

Use a **separate** stub work directory. Stub outputs are empty files; if they land in the real
work dir, a later `-resume` can cache-hit on them and you will ship a run full of zero-byte BAMs.

**Then read the result, and only then delete it — as a separate command, after you have decided
the stub passed:**

```bash
rm -rf "$STUBROOT"              # AFTER checking "Pass looks like" below, never before
```

It is a separate step on purpose. Appended to the snippet above it would run whichever way the
stub went — that block has no `set -e` and `nextflow`'s exit status is not checked — and it would
take the evidence with it: `$STUBDIR/results/` is what "Pass looks like" tells you to inspect, and
`$STUBDIR/work/<hash>/.command.{sh,err,log}` is where a *failed* stub's diagnosis lives. Deleting
before reading turns a cheap gate into no gate at all. If the stub failed, keep `$STUBROOT`, fix,
re-stub into a **new** subdirectory, and delete `$STUBROOT` only once you are done with all of it.

**`$STUBROOT` is deliberately not under `$NXFDIR`.** Putting it under the run tree makes its
deletion — the step that prevents those zero-byte BAMs — look exactly like deleting the run's
work directory, and `hooks/guard-workdir.sh` blocks it on that basis: the resolved form
`rm -rf /work/nxf/<runid>/stub-work` is refused for want of a `handoff.md` that cannot exist yet
because the run has not started, and the `$NXFDIR/stub-work` spelling is refused as an
unexpanded variable. Measured 2026-08-07 on run `20260807-rnaseq-scer-gln3-ibutanol`, both
forms, and the only way past was to `mv` the directories out of the run tree and delete them
from there. Keeping the stub artefacts outside `<root>/nxf/<runid>` from the start costs nothing,
puts more distance between the empty files and the resume cache, and needs no change to the
guard. Nothing else references `stub-work`/`stub-results`.

**Pass looks like:** the nf-core ASCII header, a params summary listing your reference paths, every
process reaching `[100%] N of N ✔`, `Completed at: …`, `Succeeded: N`, exit status 0, and
`$STUBDIR/results/` containing the expected directory tree of empty files.

**Fail looks like:**

| Symptom | Meaning |
|---|---|
| `ERROR ~ Validation of pipeline parameters failed` + a bullet list | schema rejection; the bullets name the offending param or samplesheet column |
| `Missing required parameter: --outdir` | params.yaml incomplete |
| `does not exist` on a `/refs/...` path | manifest gap; run `bootstrap/04-refs.sh`, do not hand-place the file |
| `Process 'X' doesn't have a stub block` | that module has no stub upstream. Not your bug; note it and rely on `-preview` plus a real 1-sample run for that branch |
| `ERROR ~ Text must not be null or empty` at `fastq_qc_trim_filter_setstrandedness/main.nf` | **rnaseq only, and it is the samplesheet, not the pipeline.** `strandedness: auto` cannot be stubbed — see the note below the table for what to do and what it does *not* cover |
| `Error in read.table(file = file, ...) : no lines available in input` inside `VALIDATOR (samplesheet.csv)`, container `r-shinyngs` | **differentialabundance only, when launched with `--gtf` (the documented, default path).** See the note below the table |
| `A USER ERROR has occurred: Cannot read file://<sample>.haplotypecaller.vcf.gz because no suitable codecs found`, process `CNNSCOREVARIANTS`, exit 2 | **sarek only, any `--tools haplotypecaller` stub-run at this pin (3.5.1) — with or without `--dbsnp`/`--known_indels` supplied.** The module has no `stub:` block regardless of bundle presence. See the note below the table |
| `Unable to pull docker image` | see failure taxonomy below; fix before the real launch, not during |

**`strandedness: auto` and `-stub-run`, and why two stubs cover less than one whole run.**
`getSalmonInferredStrandedness()` does `new JsonSlurper().parseText(json_file.text)` on salmon's
`lib_format_counts.json`, and `SALMON_QUANT`'s stub block emits that file empty, so the parse
throws. Confirmed at rnaseq 3.18.0 on 2026-08-07.

**This one failure is a waived exception to "a failed stub is a real failure", and it is the only
one in this file.** With `strandedness: auto` the first stub is *guaranteed* to exit nonzero
regardless of how correct your run is — there is nothing to fix and re-stubbing changes nothing.
Waiving it is only legitimate because it is identifiable rather than merely tolerated: the waiver
applies **only** when the error is exactly `Text must not be null or empty` raised from
`fastq_qc_trim_filter_setstrandedness/main.nf`, **and** the tasks before it all exited 0, **and**
the concrete-strandedness stub below then passes clean. Any other error, any earlier task failure,
or a concrete stub that does not pass, and the ordinary rule applies in full: fix it, re-stub,
do not launch.

The second stub is a **copy** of the samplesheet whose `strandedness` column is a concrete value;
`auto` stays in the real one. Both halves of the command matter: the source is in `$RUNDIR` (you
are `cd`'d into `$NXFDIR`, so a bare `samplesheet.csv` is not there), and `--input` must be
overridden on the command line — `$RUNDIR/params.yaml` carries the real, `auto` samplesheet and
the params file wins otherwise, so without the override this fails at the same parse. It also
gets its own `$STUBDIR`, per the rule above:

```bash
STUBDIR=$STUBROOT/concrete-strand          # NOT the same tree as the auto attempt
mkdir -p "$STUBDIR"
sed 's/,auto$/,reverse/' "$RUNDIR/samplesheet.csv" > "$STUBDIR/samplesheet.stub.csv"
# ... then re-run the -stub-run invocation above with the new $STUBDIR, plus:
#   --input "$STUBDIR/samplesheet.stub.csv"
```

**That is a partial gate, not an equivalent one, and the difference is not cosmetic.** The subworkflow branches on `meta.strandedness == 'auto'` and feeds only the
`auto_strand` branch into `FASTQ_SUBSAMPLE_FQ_SALMON`, so a concrete value leaves that branch
empty and the inference path — the one that failed — is never entered. Measured on the two stub
runs of `20260807-rnaseq-scer-gln3-ibutanol`, comparing `Submitted process` lines:

| stub | covers | does not reach |
|---|---|---|
| `auto` (fails) | `FQ_SUBSAMPLE`, `SALMON_INDEX`, `SALMON_QUANT` — the inference branch **is** entered and wired | everything downstream; it dies at the parse, 56 tasks in |
| concrete value | `STAR_ALIGN` → `TXIMETA_TXIMPORT` → `SE_*` → `DESEQ2_QC` → `MULTIQC`, 110 tasks | `FQ_SUBSAMPLE` and `SALMON_INDEX` never submit at all |

So run **both**, and know what neither gives you: the join of
`FASTQ_SUBSAMPLE_FQ_SALMON.out` back onto `auto_strand` and the strandedness assignment itself
are exercised for the first time by the real run. Treat the first real sample to clear
`FASTQ_SUBSAMPLE_FQ_SALMON` as the gate for that branch, and check the inferred value in
MultiQC's strand-check table rather than assuming a passing stub covered it.

A stub run that fails is a launch that would have failed after burning real hours. Fix, re-stub,
then launch.

**`nf-core/differentialabundance` 1.5.0, `-stub-run`, and `--gtf`.** First run of this pipeline on
this host, 2026-08-10 (`20260810-differentialabundance-gln3-ibutanol`). With the documented,
default input shape (`--gtf`, not `--features`), the DAG is
`GUNZIP_GTF → GTF_TO_TABLE → VALIDATOR → ...`. `GTF_TO_TABLE`'s stub block is a bare
`touch genes.anno.tsv` — it does not write a header or any rows — and `VALIDATOR` (module
`r-shinyngs`, script `validate_fom_components.R`) is not itself stubbed, so under `-stub-run` it
runs for real against that empty file and dies in `read.table()` with
`Error ... no lines available in input`. This is the same shape as the rnaseq
`strandedness: auto` case above (a real script fed a deliberately-empty stub upstream output) but
it is **not** a waived exception, because there is a clean workaround rather than a guaranteed
failure: the workflow reads features from `--features` *instead of* `--gtf` when both would
otherwise be derived from it (`workflows/differentialabundance.nf`, the `if (params.features) …
else if (params.gtf) … GTF_TO_TABLE(...)` branch), and `--features` skips `GTF_TO_TABLE` entirely.

```bash
# Stub-only substitute — the REAL run keeps --gtf, exactly as planned. Derive a small, genuinely
# non-empty feature table from the matrix itself (gene_id + gene_name columns are enough for the
# stub to validate against); do not hand-write one, and do not point --gtf at anything but the
# real reference.
STUBDIR=$STUBROOT/features-substitute      # NOT $STUBROOT/main -- that is the failed --gtf attempt;
mkdir -p "$STUBDIR"                        # reusing it would union this pass's outputs with the
                                            # failed one's, same rule as the rnaseq case above
MATRIX=$(grep -m1 '^matrix:' "$RUNDIR/params.yaml" | sed -E 's/^matrix:[[:space:]]*//; s/[[:space:]]+#.*$//' \
  | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")
# grep anchored to `^matrix:` picks the KEY, not any line merely containing the substring "matrix"
# elsewhere (e.g. transcript_length_matrix:). The first sed removes only the `matrix:` prefix and
# any trailing ` #comment` -- splitting on EVERY colon (an earlier version of this line did, via
# `awk -F':'`) truncates a path that legitimately contains one, such as `s3://bucket/counts.tsv`,
# to `s3`. The second sed strips one layer of YAML quoting (matrix: "/path" or matrix: '/path');
# left in place, `cut -f1,2 "$MATRIX"` fails to open a filename literally prefixed with a quote.
# Does not handle escaped quotes inside the path itself -- this repo's own params.yaml files never
# quote paths (see any existing runs/*/params.yaml), so an unquoted path remains the common case.
# `cut` below needs a coreutils-openable path (local ext4/drvfs), not a remote URI -- true of
# every --matrix this repo has ever passed (always an rnaseq run's own results/ output on
# $BIOINFO_WORK). The s3:// example above is there ONLY to prove the colon-splitting bug is
# fixed, not because this repo stages matrices from object storage; if that ever changes, stage
# the remote file locally first and point $MATRIX at the local copy.
cut -f1,2 "$MATRIX" > "$STUBDIR/stub_features.tsv"
sed "s#^gtf:.*#features: $STUBDIR/stub_features.tsv#" "$RUNDIR/params.yaml" > "$STUBDIR/stub_params.yaml"
# ... then run the -stub-run invocation with -params-file "$STUBDIR/stub_params.yaml" instead of
# $RUNDIR/params.yaml, and the usual --outdir/-work-dir pointed at $STUBDIR.
```

**Partial gate, same as the strandedness case**: this substitution means the stub never exercises
`GUNZIP_GTF`/`GTF_TO_TABLE` against the real `--gtf`, and `VALIDATOR` sees synthetic feature
metadata rather than what the real GTF conversion produces. Verified clean end to end with the
substitution (`completed=12 failed=0`, all downstream processes including `DESEQ2_DIFFERENTIAL`,
`SHINYNGS_APP`, `RMARKDOWNNOTEBOOK`, `MAKE_REPORT_BUNDLE` reached). The real run, using the real
`--gtf`, is what actually proves `GUNZIP_GTF`/`GTF_TO_TABLE` against real reference data — treat
`VALIDATOR`'s first real-run pass as the gate for that branch, same discipline as the rnaseq case.

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
differentialabundance cases above: it runs for real against HaplotypeCaller's placeholder stub VCF
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
`pipeline-selection.md`'s `--skip_tools baserecalibrator` row); pass one combined,
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
has), re-check with the two-line `grep -rL --include='main.nf' 'stub:'` command above before
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

Same discipline as the rnaseq and differentialabundance cases above: name the concrete signal that
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

**`nf-core/ampliseq`, `-stub-run`, and `CUTADAPT_BASIC` — a true waiver, upstream module bug.**
Confirmed 2026-08-10 (`20260810-ampliseq-testprofile-procurement`) against the pin this file's own
table names, `2.18.0` (commit `2723d4c298d48321594920d0324697e14d73ee94`). `-stub-run -profile
test,docker` fails immediately with `No such variable: outformat`. Read
`modules/nf-core/cutadapt/main.nf` in the pinned clone: the `output:` block references
`outformat`, a variable the `script:` block assigns (`outformat = task.ext.outformat ?: "fastq"`)
but the `stub:` block never sets — the output declaration throws before the stub body ever runs.
This is an upstream nf-core/modules defect in the CUTADAPT module's stub, not a wiring problem
introduced by this repo's config, and there is no substitute-input workaround: the crash happens
before any process logic executes, so no stub params file can route around it the way the
differentialabundance `--features` case does. **Waived as a true stub failure** — `-preview
-profile test,docker` (clean, `completed=0 failed=0`) is the only pre-launch gate this pipeline
gets; the real command (exercised by the run itself, `completed=113 failed=0 cached=12`) is what
actually proves `CUTADAPT_BASIC` and everything downstream of it.

**`nf-core/mag`, `-stub-run`, and two independent findings at this pin's `5.5.0`.** Confirmed
2026-08-12 (`20260812-mag-testprofile-procurement`, `20260812-mag-drr027580-realsample`) against
commit `56abab5b023ce953c9c43fe21090d156ad0e18af`.

*Finding 1 — a true waiver, upstream-in-mag module-patch bug, same shape as the ampliseq case
above.* `-stub-run -profile test,docker --skip_gtdbtk true` fails at `CATPACK_DB_UNTAR` with
`No such variable: output_dir`. Read `modules/nf-core/untar/untar.diff` in the pinned clone: mag
carries a **local patch** to the shared `UNTAR` module that changes the `script:` block's output
variable from `${prefix}` to `${output_dir}` (and adds a `basedir`/`output_dir` computation) but
never updates the `stub:` block, which still only sets `prefix`. The `output:` declaration
(`path("${output_dir}")`) is shared by both blocks, so it throws before the stub body ever runs —
the crash happens before any process logic executes, exactly like `CUTADAPT_BASIC` above, so there
is no substitute-input workaround. **Scope, confirmed by reading every call site
(`grep -rn UNTAR workflows/ subworkflows/`)**: `UNTAR` is only invoked when a `.tar.gz`/`.tgz`
reference database is supplied for CAT (`--cat_db`), BUSCO (`--busco_db`), CheckM (`--run_checkm`
with no local `--checkm_db`), or virus identification (`--genomad_db`, gated behind
`--run_virus_identification`, off by default). The **test profile** exercises it because it
supplies small mock tarballs for `cat_db` and `busco_db` to keep CI fixture data small; a
**default real run** — no `cat_db`, BUSCO left on its default `auto` lineage (which downloads its
own DB directly, not via `UNTAR`), CheckM/virus-ID off — never calls `UNTAR` at all. **Waived, 5th
documented departure** — `-preview` is clean; the real command is what actually proves this
pipeline, same reasoning as the ampliseq case.

*Finding 2 — broader and more consequential, and a different shape from every prior departure in
this section: not one process, a structural property of mag's own module set.*
`grep -rL --include='main.nf' 'stub:' <clone>/modules/local/` finds **20 of mag's 23 local
(non-nf-core-catalog) modules have no `stub:` block at all** — including `bowtie2_removal_align`
(the module that does phiX/host read removal), `bowtie2_assembly_build`/`bowtie2_assembly_align`
(binning-prep mapping), and both `quast_run`/`quast_bins`. Per Nextflow's documented no-stub
fallback (same mechanism already recorded for fetchngs 1.12.0 above), each of these runs its real
`script:` under `-stub-run`. `FASTP` (an nf-core-catalog module, stubbed) writes
`echo '' | gzip > *.fastp.fastq.gz` — a technically-valid, empty gzip stream, zero FASTQ records —
and `BOWTIE2_REMOVAL_ALIGN` then runs bowtie2 for real against it and aborts (exit 134,
`Error: reads file does not look like a FASTQ file`, confirmed by reading the bowtie2 log in the
stub work dir). This fires on **any** samplesheet with the default phiX removal on (i.e. almost
every real invocation), independent of what data is supplied — a from-FASTQ real-command stub
cannot get past `SHORTREAD_PREPROCESSING` without hitting it. Passing `--keep_phix true` for the
stub only (a legitimate stub-only substitute, same category as sarek's `--skip_tools` addition
below) routes around that one process and the stub proceeds four more stages, then dies again the
same way at `BOWTIE2_ASSEMBLY_BUILD`/`QUAST` on MEGAHIT's own empty stub contigs file. **This is
not a single bug to route around** — it is a chain, and no finite sequence of stub-only
substitutions clears the whole DAG, because the next unstubbed consumer of the next stubbed
process's placeholder output is always one more hop away. Treating `-stub-run` as authoritative
for mag beyond `SHORTREAD_PREPROCESSING` means an unbounded chase for a gate that fundamentally
cannot certify the parts of the pipeline that matter most (assembly, binning, bin QC). **Not a
waiver in the same sense as the other four departures — there is no single failing assertion to
waive.** Resolution: `-preview` (clean) is the pre-launch gate this pipeline actually gets past
`SHORTREAD_PREPROCESSING`, exactly the precedent already set for fetchngs's own no-stub download
modules; the real command is what proves the rest, and the first real run
(`20260812-mag-drr027580-realsample`, `completed=19 failed=2 cached=0`, both failures tolerated —
see that run's `handoff.md`) is that proof for this pin.

**`nf-core/nanoseq`, `-stub-run`, and `SAMTOOLS_IDXSTATS`/`SAMTOOLS_FLAGSTAT` — a true waiver,
upstream shared-module stub-coverage gap, same shape as the ampliseq case above.** Confirmed
2026-08-13 (`20260813-nanoseq-srr25466853`) against this pin's `3.1.0`. Both the CI `test` profile
and this procurement's own real command fail identically (`completed=24 failed=4` /
`completed=13 failed=2`), always at `BAM_STATS_SAMTOOLS:SAMTOOLS_IDXSTATS`/`SAMTOOLS_FLAGSTAT`
(`"failed to read header for ... .sorted.bam"`). Read the modules directly:
`modules/nf-core/samtools/sort/main.nf` HAS a `stub:` block (writes a header-less, touch'd empty
`.bam`), but `modules/nf-core/samtools/idxstats/main.nf` and `.../flagstat/main.nf` have **no**
`stub:` block at all — under `-stub-run` those two run for real against the fake empty BAM and
correctly refuse to read it, no substitute-input workaround possible (the crash is in reading the
stub's own placeholder output, not in anything this repo's config controls). **Waived, 6th
documented departure** — `-preview` (clean) is the pre-launch gate; the real command is what
actually proves this pipeline, `SAMTOOLS_STATS` (which does have a stub block) succeeds cleanly in
the same run.

**`nf-core/rnasplice`, `-stub-run`, and `GTF_GENE_FILTER`/`RSEM_PREPAREREFERENCE` — a true waiver,
upstream shared-module stub-coverage gap, same shape as the ampliseq/nanoseq cases above.**
Confirmed 2026-08-14 (`20260814-rnasplice-scer-gln3-ibutanol`) against this pin's `1.0.4`.
`modules/nf-core/gunzip/main.nf`'s `stub:` block does `touch $gunzip` — an empty placeholder file
— for whichever of `--fasta`/`--gtf` is gzipped, and the downstream
`modules/local/gtf_gene_filter.nf` + `modules/nf-core/rsem/preparereference/main.nf` have **no**
`stub:` block at all, so they run for real against that empty stub input. Reproduced both ways:
on the nf-core CI fixture (gzipped fasta, plain gtf), `filter_gtf_for_genes_in_genome.py`
extracts 0 chromosome names from the empty stub fasta and writes an empty GTF, then
`rsem-prepare-reference` fails with "The reference contains no transcripts!"; on this
procurement's own real-sample sheet (plain fasta, gzipped gtf) the fasta is real but the GTF
comes from `GUNZIP_GTF`'s empty stub, so `filter_gtf_for_genes_in_genome.py` instead extracts
0/0 lines and SUPPA's `GENERATE_EVENTS` fails with "No exons found" — same root cause, different
file triggers it depending on which input the samplesheet happens to gzip. No substitute-input
workaround possible, same reasoning as the ampliseq/nanoseq cases. **Waived, 7th documented
departure** — `-preview` (clean) is the pre-launch gate; the real (non-stub) `-profile
test,docker` command with the identical flag set completes cleanly (`completed=34 failed=0`).
**Separately** (not a stub artifact, found on the real 8-sample run, not covered by this waiver):
`SUPPA_SALMON:GENERATE_EVENTS_IOE` has a genuine infinite-loop bug in its own real script when
zero local splicing events exist for some event type — see `pipeline-selection.md` §4.15 and
`config/pipelines.tsv` for the full writeup; routed around with `--suppa_per_local_event false`,
which is now part of this pipeline's stocked default rather than an optional flag.

**`nf-core/isoseq`, `-stub-run`, and `ULTRA_INDEX` — a true waiver, upstream shared-module
stub-coverage gap, confined to a branch this repo does not stock.** Confirmed 2026-08-14
(`20260814-isoseq-alz-chr19`) against this pin's `2.0.0`, **only when run with the CI test
profile's own `aligner: ultra`**. `modules/nf-core/gnu/sort/main.nf`'s `stub:` block does
`touch ${output_file}` — an empty placeholder GTF — and `modules/nf-core/ultra/index/main.nf`
has **no** `stub:` block at all (confirmed by reading it directly), so it runs for real against
that empty GTF and crashes: `gffutils.exceptions.EmptyInputError: No lines parsed -- was an
empty file provided?`. `completed=12 failed=1`. No substitute-input workaround possible, same
reasoning as ampliseq/nanoseq/rnasplice. **Waived, 8th documented departure** — `-preview`
(clean) is the pre-launch gate for the `ultra` branch specifically. **This procurement's own
stocked config (`aligner: minimap2`) needs no waiver at all**: `-stub-run` on that exact flag
set passes cleanly on both the CI test data (`completed=11 failed=0`) and the real command
(`completed=81 failed=0`) — same class of clean pass as taxprofiler/raredisease, not a waiver.
**Separately** (not a stub artifact, found on the real run): the pipeline's own default
`--chunk 40` against a small (531-ZMW) input produced 29/40 empty per-chunk
`GSTAMA_COLLAPSE` outputs and crashed `GSTAMA_MERGE` (`tama_merge.py`, `IndexError: list index
out of range` reading an empty bed) — fixed with `--chunk 5` (matching `conf/test.config`'s own
value for the identical bam) and a `-resume` relaunch. **Also separately, a real (non-stub) bug
affecting every configuration**: `workflows/isoseq.nf`'s own `MULTIQC(...)` call passes bare,
non-`.collect()`'d `channel.empty()` for two of the module's plain `path` inputs, so `MULTIQC`
is invoked zero times regardless of flags — no MultiQC report is ever produced at this pin. See
`pipeline-selection.md` §4.16 and `config/pipelines.tsv` for the full writeup on all three
findings.

**`nf-core/bacass`, `-stub-run`, and `UNICYCLER` — a true waiver, upstream module authoring bug,
different shape from every prior case (a hardcoded literal, not a stub-coverage gap).** Confirmed
2026-08-16 (`20260816-bacass-testprofile-procurement`) against this pin's `2.6.1`, on the CI
`-profile test,docker` config unmodified (`assembly_type: short`, `assembler: unicycler`).
`modules/nf-core/unicycler/main.nf`'s `stub:` block reads, verbatim:
```
cat "" | gzip > ${prefix}.scaffolds.fa.gz
cat "" | gzip >  ${prefix}.assembly.gfa.gz
```
`cat ""` passes a literal empty string as a filename argument, which every prior case in this
list did not do — the ampliseq/mag/nanoseq/rnasplice/isoseq cases all involve a stub in one
module writing an empty PLACEHOLDER FILE that a downstream module with no `stub:` block then
reads for real; here the failing process's OWN stub script is malformed on its own, no
downstream module involved at all. `completed=8 failed=1`, exact error
(`Command error: cat: '': No such file or directory`), confirmed by reading the module source
directly. No substitute-input workaround possible — there is no shortreads/longreads-shaped
input that fixes a hardcoded `cat ""`. **Waived, 9th documented departure** — `-preview` (clean)
is the pre-launch gate; the full (non-stub) `-profile test,docker` command is what actually
proves this pipeline, see `pipeline-selection.md` §4.17 and `config/pipelines.tsv` for the full
writeup.

---

## 5. Launch

Write the invocation into `$RUNDIR/cmd.sh` verbatim so the exact command is recorded next to the
plan. **Launch it through the `tmux` recipe below — always, not just when you want to "detach."**
This is the only launch method that has survived every failure mode measured on this host,
including one that has nothing to do with WSL: an agent starting `nextflow run` as its own
backgrounded tool call and then separately waiting for it has twice been killed by SIGTERM the
moment the agent's own turn ended, even with the WSL session still open the whole time (see the
note in "Notes on the shape" below). `tmux`'s server process is independent of both the WSL
client session and whatever tracks an agent's own backgrounded tool calls, which is why it is the
one thing proven to survive both failure modes. Treat this as mandatory even for a run you expect
to finish in minutes — guessing wrong about which runs count as "long" is exactly how a run gets
lost.

```bash
#!/usr/bin/env bash
set -euo pipefail

RUNID=20260728-rnaseq-koges-pilot
PIPE=nf-core/rnaseq
REV=3.18.0                                  # from config/pipelines.tsv
RUNDIR=/mnt/d/bioinfo-agent/runs/$RUNID
NXFDIR=${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID   # same derivation as bin/preflight.sh
TS=$(date +%Y%m%d-%H%M%S)

mkdir -p "$NXFDIR/work" "$NXFDIR/results" "$NXFDIR/reports"
cd "$NXFDIR"                                # launch dir MUST be ext4: .nextflow/cache lives here

nextflow -log "$NXFDIR/.nextflow.log" \
  run "$PIPE" \
    -r "$REV" \
    -profile docker \
    -params-file "$RUNDIR/params.yaml" \
    -c /mnt/d/bioinfo-agent/config/local.config \
    --outdir "$NXFDIR/results" \
    -work-dir "$NXFDIR/work" \
    -with-report   "$NXFDIR/reports/report.$TS.html" \
    -with-trace    "$NXFDIR/reports/trace.$TS.txt" \
    -with-timeline "$NXFDIR/reports/timeline.$TS.html" \
    -with-dag      "$NXFDIR/reports/dag.$TS.html" \
    -ansi-log false \
    -resume \
  2>&1 | tee "$NXFDIR/nextflow.stdout.log"
```

**Launch `cmd.sh` inside `tmux` — not bare, not `nohup`, not your own agent-side backgrounded
tool call.** `tmux` keeps its own server process alive independent of whatever session or turn
started it, which is why it survives where every other shortcut has failed on this host:

```bash
# bootstrap/01-wsl-base.sh installs tmux. On a host bootstrapped some other way:
#   sudo apt-get install -y tmux

# Self-contained on purpose: RUNID and RUNDIR are assigned INSIDE cmd.sh, so a fresh shell
# (which is what the one-shot `wsl -d <distro> -- bash …` workflow always gives you) has
# neither. Left unset they expand to an empty session name and `bash /cmd.sh`.
RUNID=20260728-rnaseq-koges-pilot                  # the same id cmd.sh sets
RUNDIR=/mnt/d/bioinfo-agent/runs/$RUNID
# Same derivation as cmd.sh and bin/preflight.sh. A host that moves runs off the default root
# by setting BIOINFO_WORK would otherwise have the pid written somewhere cmd.sh never used,
# leaving the guard and the stop command reading a file that does not exist.
NXFDIR=${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID

# tmux(1) documents that a session name should avoid ':' and '.' -- both have target-syntax
# meaning ('.' separates session.window, ':' separates session:window) -- and a RUNID legitimately
# contains '.' (this file's own pkill examples use "study.v2"). Passing $RUNID straight to
# -s/-t risks tmux silently treating part of it as a window reference instead of the literal
# name, after which `tmux attach`/`capture-pane` using the same raw $RUNID can miss the session
# they just created. Derive a tmux-safe alias and use ONLY that for tmux's own -s/-t; $RUNID
# keeps naming the filesystem paths and the pid-file/pgrep matching below, which take it literally.
#
# The substitution alone is not injective: "study.v2" and "study_v2" both sanitise to the same
# string, and this recipe has no `set -e` to stop a second launch that silently collided with the
# first's session name -- it would run straight through pid detection and attach to the WRONG
# run's session without any error. The md5 suffix is taken from the ORIGINAL (pre-substitution)
# $RUNID specifically so two inputs that collide after substitution almost certainly do not
# collide after hashing.
TRUNID="$(printf '%s' "$RUNID" | tr -c 'A-Za-z0-9_-' '_')_$(printf '%s' "$RUNID" | md5sum | cut -c1-8)"

mkdir -p "$NXFDIR"                                 # cmd.sh creates it too, but the pid write below
                                                   # races the session start; do not depend on it

# A NEW tmux session inherits the tmux SERVER's global environment, captured whenever that
# server first started -- not this shell's current exports. If a server was already running
# from an earlier session (routine once tmux launch is the default), and this shell has since
# exported a different NXF_WORKROOT/BIOINFO_WORK (a host move, a different run's override) or
# re-sourced a refreshed ~/.config/bioinfo/env.sh, the new session would silently NOT see that:
# `bash '$RUNDIR/cmd.sh'` is a non-login shell and does not source it either. cmd.sh would then
# derive NXFDIR from a stale or default root -- different from the one bin/preflight.sh just
# checked disk space and ext4-ness against in THIS shell, moments ago.
#
# `-e VAR=value` (tmux >=3.2) sets the environment for the new session, overriding the server's
# stale global one. A HARDCODED list of `-e` flags here (an earlier version of this fix had one)
# is a maintenance trap: bootstrap/03-nextflow.sh's generated env.sh alone carries 12+ NXF_*/
# BIOINFO_* variables (NXF_HOME, NXF_WORK, NXF_TEMP, both container-cache dirs,
# NXF_SYNTAX_PARSER, ...), config/local.config separately reads BIOINFO_MAX_CPUS/MAX_MEMORY/
# MAX_TIME as scheduler ceilings, and NEITHER source is complete on its own -- host.env and
# ~/.bashrc contribute the rest. A short list silently omits whichever of these the list's
# author did not think of; a stale MAX_MEMORY can overcommit the current VM, a stale cache path
# can write to the wrong disk. Instead, capture and forward the SAME name-shaped set
# bootstrap/lib/host-env.sh already treats as the environment contract (BIOINFO_*, NXF_*,
# JAVA_HOME) directly from this shell's current exports -- complete by construction, no list to
# keep in sync as new variables are added upstream.
#
# PATH is added explicitly alongside that contract, not because host-env.sh treats it as part
# of it, but because bootstrap/03-nextflow.sh's generated env.sh prepends $HOME/.local/bin to
# it and cmd.sh calls `nextflow` bare, trusting PATH to resolve it -- exactly what
# bin/preflight.sh just validated in THIS shell. `bash '$RUNDIR/cmd.sh'` is a non-login shell
# and won't re-derive it, so a persistent server's older, PATH-less-prefix global environment
# would otherwise fail the run with "nextflow: command not found" despite preflight passing.
declare -A _te_seen=()
tmux_env_args=()
while IFS= read -r _te_var; do
  case "$_te_var" in
    BIOINFO_*|NXF_*|JAVA_HOME|PATH) tmux_env_args+=(-e "$_te_var=${!_te_var}"); _te_seen[$_te_var]=1 ;;
  esac
done < <(compgen -v)

# `-e VAR=value` above only OVERRIDES names this shell still has set. A name the server's
# global environment holds but this shell does NOT (env.sh explicitly `unset NXF_OFFLINE`,
# or an operator dropped an old NXF_WORKROOT) gets no -e flag at all -- tmux inherits the
# server's global env first and applies -e on top of it, so the omitted stale value survives
# untouched and a run can silently start offline or under the wrong work root. Find those by
# name against the SAME contract and drop them from the server's global environment before the
# session inherits it. `show-environment -g` errors harmlessly (no server started) when none is
# running yet, which is the common case for a first run.
while IFS='=' read -r _te_name _te_rest; do
  _te_name="${_te_name#-}"
  case "$_te_name" in
    BIOINFO_*|NXF_*|JAVA_HOME|PATH)
      [ -n "${_te_seen[$_te_name]:-}" ] || tmux set-environment -g -u "$_te_name" ;;
  esac
done < <(tmux show-environment -g 2>/dev/null)

tmux new-session -d -s "$TRUNID" "${tmux_env_args[@]}" "bash '$RUNDIR/cmd.sh'"

# Record the live pid. NOT optional: hooks/guard-workdir.sh reads this file to refuse
# deleting the work directory of a running run. Without it the guard falls through to the
# 7-day hold check, which an older run id passes — so a live run's work dir becomes deletable.
#
# `pgrep -f` takes a REGEX, not a substring, so the id is escaped once here and that escaped
# form is the only one that goes into a pattern — below, and in the stop command later.
# Unescaped, `study.v2` also matches `studyXv2` (a different experiment) and `a+b` matches
# nothing at all, not even its own run.
ERUNID=$(printf '%s' "$RUNID" | sed 's/[][\.*^$+?()|{}]/\\&/g')

# Delimited with the surrounding path separators, and exactly one match required. A bare
# "nextflow.*$RUNID" also matches a SIBLING whose id merely extends this one (…-study vs
# …-study-rerun): if this run's JVM has not appeared yet the file would hold the sibling's
# pid and the stop command would kill the wrong experiment; if both appear, the file holds
# two lines and `kill "$(cat …)"` fails on a multi-line operand.
#
# FILTER TO THE JVM, or this never records a pid at all. The Nextflow head process is always a
# java process; nothing else here is. Two non-JVM processes match the pattern anyway, and one of
# them is permanent:
#   * the TMUX SERVER. `tmux new-session -d -s … -e VAR=value … "bash '$RUNDIR/cmd.sh'"` becomes
#     the server's own command line and stays there for the life of the server. It carries
#     NXF_HOME=…/.nextflow from the -e forwarding block above and $RUNDIR/cmd.sh from the
#     command, so "nextflow.*/$RUNID/" matches it — and keeps matching it long after this run
#     ends, poisoning every later run started on the same server.
#   * the shell that ran this launcher, whose own command line names the run directory.
# The result was `found 3`, no pid file written, and therefore hooks/guard-workdir.sh's pid
# check — which the comment above calls NOT optional — reading a file that does not exist, on
# every run. Measured 2026-08-07, run 20260807-rnaseq-scer-gln3-ibutanol: pids 131512
# (`tmux: server`), 131517 (`java`, the real one), 131789 (`bash`). Note the interaction: the
# -e forwarding block above is a correct fix for the stale-server-environment problem, and it is
# what put the run id on the server's command line. Reading /proc/<pid>/comm settles it without
# either fix having to know about the other.
for _ in $(seq 30); do                             # up to ~30 s for the JVM to appear
  _pids=()
  while IFS= read -r _p; do
    [ -r "/proc/$_p/comm" ] && [ "$(cat "/proc/$_p/comm")" = java ] && _pids+=("$_p")
  done < <(pgrep -f "nextflow.*/$ERUNID/")
  [ "${#_pids[@]}" -ge 1 ] && break
  sleep 1
done
if [ "${#_pids[@]}" -eq 1 ]; then
  printf '%s\n' "${_pids[0]}" > "$NXFDIR/nextflow.pid"
else
  echo "WARNING: expected exactly one nextflow process for $RUNID, found ${#_pids[@]}." >&2
  echo "         No pid recorded; the work-dir guard falls back to its process scan." >&2
fi

tmux ls                                            # confirm it is there
tmux attach -t "$TRUNID"                           # watch;  Ctrl-b d to leave it running
```

Notes on the shape:

- `-log` is a **core** option and must appear before `run`; `-with-*`, `-resume`, `-profile` are
  **run** options and must appear after the pipeline name. Getting this backwards produces an
  unhelpful "Unknown option" error.
- `-resume` is on the first launch too. There is no cache yet so it does nothing, and it makes the
  command byte-identical on every attempt — which is the whole point.
- `-ansi-log false` turns the live-redraw display into append-only lines. Without it,
  `nextflow.stdout.log` is megabytes of escape sequences.
- `--outdir` is a pipeline param and could equally live in `params.yaml`; keep it in exactly one
  place, and if it is in the params file, drop it here.
- Reports are per-attempt. The alternative is `report.overwrite = true` / `trace.overwrite = true`
  in `local.config`; without one or the other, the second launch aborts because the report file
  already exists.
- Set `trace.raw = true` in `local.config`. The default trace writes durations as `1h 2m` and memory
  as `3.4 GB`, which is unsortable; raw writes milliseconds and bytes.
- **`nohup … &` does not detach a run from a Windows-driven `wsl.exe` invocation.** Inside a
  terminal you keep open it behaves as expected, but when the launching
  `wsl -d <distro> -- bash …` returns, WSL tears down the distro and the job dies with it —
  measured here: both `nohup … &` and `setsid nohup … &` were gone within seconds, with no
  log written and no process left. It also does not survive `wsl --shutdown`, Windows sleep,
  or a reboot. Run under `tmux` (installed by `bootstrap/01-wsl-base.sh`) so you can re-attach —
  this is section 5's mandatory launch method, not an alternative to keeping a session open; see
  the next bullet for why "just keep the session open" is not sufficient on its own either.
  A run launched fire-and-forget from Windows is a run you have silently lost.
- **A SEPARATE failure mode, specific to an agent driving this runbook: starting `nextflow run`
  as your own backgrounded tool call, then separately polling or waiting for it, is not safe
  even when the WSL session never closes.** Measured twice on this host (a methylseq run and a
  chipseq run, both hours into real work): the Nextflow process was killed by SIGTERM at the
  exact moment the agent's own turn ended, immediately after it had said something like "I'll
  wait for the background monitor to notify me." The WSL session was never torn down in either
  case — this is a distinct mechanism from the `nohup`/`wsl.exe` one above, tied to whatever
  tracks a background command's lifetime against the *agent turn* that started it, not against
  the shell session. "The session is still open, so backgrounding here is safe" is exactly the
  reasoning that caused both losses. `tmux` is unaffected by this because its server process is
  not a child of the agent's turn at all — this is why section 5 above now treats `tmux` launch
  as mandatory for an agent, not merely a convenience for detaching a human's terminal.

**Stopping cleanly:** Ctrl-C in the foreground session, or — under `tmux` — kill the pid the
launch recorded:

```bash
NXFDIR=${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID
kill -TERM "$(cat "$NXFDIR/nextflow.pid")"
```

Use the recorded pid, **not** `pkill -f "nextflow.*$RUNID"`. `-f` matches against the whole
command line, and the pattern is a regex — two separate ways to hit the wrong process. As a
substring, a run id that is a prefix of another (`20260804-rnaseq-study` and
`20260804-rnaseq-study-rerun`) matches both. As a regex, `study.v2` also matches `studyXv2`,
and `a+b` matches neither `studyXv2` nor its own run.

With no pid file, escape the id and delimit it with the path separators that surround it:

```bash
ERUNID=$(printf '%s' "$RUNID" | sed 's/[][\.*^$+?()|{}]/\\&/g')
pkill -TERM -f "nextflow.*/$ERUNID/"
```

Nextflow traps SIGTERM, kills running tasks, and flushes the cache — the run stays resumable.
`kill -9` leaves orphaned containers holding CPU and disk; if you must, follow with
`docker ps` and `docker kill <ids>`.

The pid file is written by the tmux recipe above and is not optional: `hooks/guard-workdir.sh`
reads it to refuse deleting a live run's work directory. A foreground launch has no `$!` to
record, so the guard also scans for a running `nextflow` process carrying the run id — either
signal is enough to block the deletion, and neither alone is reliable.

---

## 6. Monitoring

Four things to read, in decreasing order of usefulness.

**The trace file** is appended as tasks complete and is the only machine-readable live view. Resolve
columns by header name, not position — the field set is configurable and nf-core changes it.

```bash
NXFDIR=${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID   # same derivation everywhere
T=$(ls -t "$NXFDIR"/reports/trace.*.txt | head -1)

# status counts
awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next}{c[$h["status"]]++}END{for(s in c)print s, c[s]}' "$T"

# anything that did not finish clean
awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} $h["exit"]!="0" && $h["status"]!="RUNNING" \
  {print $h["name"], $h["status"], "exit="$h["exit"]}' "$T"

# peak memory per process (peak_rss, falling back to rss on older field sets)
awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)h[$i]=i; m=("peak_rss" in h)?h["peak_rss"]:h["rss"]; next}
            {printf "%-55s %s\n", $h["name"], $m}' "$T" | sort -k2 -h | tail -15
```

**`nextflow.stdout.log`** — `tail -f` it. With `-ansi-log false` you get one line per state change
plus the final summary block.

**`.nextflow.log`** — the real diagnostics. When a task fails, the error block names the work
directory; that is where you go next.

```bash
NXFDIR=${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID   # same derivation everywhere
grep -nE 'ERROR|WARN|Caused by|Command exit status|Work dir' "$NXFDIR/.nextflow.log" | tail -40
```

**The HTML execution report** is written at completion (success or failure), not incrementally.
Do not wait on it mid-run; the trace is the live source.

### Slow but healthy vs wedged

| Signal | Healthy | Wedged |
|---|---|---|
| `docker stats --no-stream` | at least one container with meaningful CPU% | all near 0% |
| `vmstat 5 3` | `r` non-zero, or `wa` high (I/O-bound but progressing) | `r`=0, `wa`=0, `si`/`so`=0 |
| `find "$NXFDIR/work" -newermt '-10 min' \| head` | files appearing | nothing for >10 min |
| `df -h "${BIOINFO_WORK:-/work}"` | shrinking slowly | pinned at 0% avail |
| trace last line timestamp | advancing | frozen |

Two specific slow-but-healthy states worth recognising before you kill anything: heavy **swap**
(`si`/`so` non-zero in `vmstat`, `free -g` showing swap used) means the memory ceiling is too low and
the run will finish, eventually, badly — lower concurrency rather than killing; and **drvfs read
stalls** (high `wa`, low CPU, all inputs under `/mnt/d`) means the inputs should have been staged to
ext4.

Genuinely wedged, with all four "wedged" signals true, is almost always the Docker daemon
(`docker ps` hangs → `sudo systemctl restart docker`) or an exhausted filesystem. Neither is fixed
by waiting.

---

## 7. Failure taxonomy

Always start at the work dir named in the error block:

```bash
cd <work-dir-from-error>
cat .command.sh    # the exact command, after interpolation
cat .command.err   # stderr — the actual reason, 90% of the time
cat .command.log   # stdout+stderr combined
bash .command.run  # re-run this one task standalone, in its container, to iterate
```

| Exit | Name | What it means here | Fix |
|---|---|---|---|
| 137 | 128+SIGKILL | OOM. On a single-node local executor this is usually the **WSL VM's** OOM killer, not a per-container cgroup limit | see below |
| 140 | walltime | task exceeded its `time` directive | raise `time` for that process in `local.config`, `-resume` |
| 143 | 128+SIGTERM | Nextflow terminated the task — a *different* task failed first, or you sent SIGTERM | find the real failure above it in the log |
| 1 | tool error | read `.command.err` | depends |
| 125/126/127 | docker layer | daemon rejected the run / binary not executable / not found in image | container or profile problem, not a data problem |

**137 / OOM.** Because Nextflow's local executor uses the `memory` directive for *scheduling*, not
as a hard container limit, an over-allocating task can get an innocent neighbour killed instead of
itself. Confirm who died before changing anything:

```bash
sudo dmesg -T | grep -iE 'out of memory|killed process' | tail
free -g
```
<!-- UNVERIFIED: whether the pinned Nextflow version applies a hard cgroup memory limit to
     local-executor docker tasks; confirm with `docker inspect <cid> --format '{{.HostConfig.Memory}}'`
     on a live task -->

Three fixes, in order of preference: raise the WSL memory ceiling in `.wslconfig` (if `free -g`
shows ~31 GB, this is the real bug); lower the effective concurrency so fewer heavy tasks co-run;
raise the `memory` directive for the offending process in `local.config`. Then `-resume`. Raising
`memory` alone does not invalidate the cache, so completed tasks are reused.

**Disk full.** `.command.err` contains `No space left on device`, or Nextflow reports a staging
failure. `df -h "${BIOINFO_WORK:-/work}"`. Recovery: free space *outside* the current work dir — old runs' work dirs
(section 9), `docker image prune`, `$BIOINFO_WORK/staging`. Never delete the current run's work dir to make
room; you lose the resume cache and start over. Then `-resume`. If there is genuinely no room, the
estimate was wrong: stop, re-plan, re-scope.

**Container pull failure.** `Unable to pull docker image` / `TLS handshake timeout` /
`toomanyrequests`. Test the daemon's network first, since WSL DNS breaks in a recognisable way:

```bash
docker run --rm quay.io/biocontainers/fastqc:0.12.1--hdfd78af_0 fastqc --version
cat /etc/resolv.conf
```

If DNS is the problem, `/etc/resolv.conf` is regenerated on every distro start unless
`generateResolvConf=false` is set in `/etc/wsl.conf`; write a working nameserver and pin it. If it
is Docker Hub rate-limiting, note that nf-core images come mostly from `quay.io` — the rate limit
usually only bites on a base image, and `docker pull` retried by hand succeeds. Pre-pull before a
long run: `nextflow inspect nf-core/<pipe> -r <REV> -profile docker` lists every image the run will
need.
<!-- UNVERIFIED: `nextflow inspect` availability and exact output shape on the installed Nextflow
     version; confirm with `nextflow inspect -help` -->

**Missing reference.** Do not hand-place the file. Add a manifest row in
`config/refs.manifest.tsv`, re-run `bootstrap/04-refs.sh`, re-run preflight, `-resume`. A file that
is not in the manifest is invisible to the next machine and to the next run.

**Samplesheet rejection.** The nf-schema error names the row and column. The three that actually
happen: CRLF line endings from a Windows editor (preflight catches this); a `strandedness` or
similar enum value not in `schema_input.json`; a path that exists but is relative to the wrong
directory. Fix the samplesheet, `-resume`. Because modern nf-core pipelines parse the samplesheet at
the DSL level rather than through a process, editing it does not by itself invalidate downstream
tasks whose own inputs are unchanged.

**One sample failing vs the whole run.** Decide deliberately, and say which you chose:

- *Fix and resume* — the sample is salvageable (truncated FASTQ re-copied, wrong path corrected).
  Preferred. `-resume` re-runs only that sample's branch.
- *Drop the sample* — remove its row from the samplesheet, `-resume`. Other samples cache-hit.
  This is a **bounded choice**: it goes in the handoff, named, with the reason.
- *Tolerate the failure* — add to `local.config`:
  ```groovy
  process { withName: '.*:SOME_PROCESS' { errorStrategy = 'ignore' } }
  ```
  Use sparingly. MultiQC will then be built from partial input, and the QC verdict must say so.

Never respond to a single failing sample by re-running the whole cohort from scratch.

---

## 8. `-resume` semantics

Nextflow hashes each task and skips it if a matching entry exists in the cache *and* the outputs are
still in the work dir. **Both** halves are required: `.nextflow/cache/<session-id>/` in the launch
dir, and `$NXFDIR/work/`. Lose either and resume degrades to a full re-run, silently.

Part of the hash:

- the task's command text **after interpolation** — so any param that reaches the command line, and
  `ext.args` in the config, and `${task.cpus}` where the tool takes a thread count;
- each input file's path, size and last-modified time (default caching mode);
- the container image reference, tag included;
- the module's own code, which is why bumping `-r` invalidates broadly.

**Not** part of the hash: the `memory` directive, `time`, `errorStrategy`, `maxRetries`. You can
raise memory and resume with the cache fully intact. `cpus` is the trap — it usually *does* appear
in the command (`-@ ${task.cpus}`), so changing it invalidates that process.

Things that quietly destroy the cache on this host:

- Changing `-work-dir`. Cache entries hold absolute paths; a different work dir is a different run.
- Relaunching from a different directory. `.nextflow/cache` is relative to the launch dir. Always
  `cd "$NXFDIR"` first.
- Copying or re-syncing input FASTQs. `cp` sets a new mtime, and the default cache mode reads mtime.
  If inputs live on drvfs, or you expect to move them, set `cache = 'lenient'` (path+size only) in
  `local.config` before the first run — not after.
- Editing `params.yaml` for a value that reaches a command line.
- A floating revision. `-r dev` or an unpinned branch changes under you.

Targeting a specific session:

```bash
nextflow log                                 # session IDs, run names, status
nextflow log <run-name> -f name,status,exit,workdir
nextflow run … -resume <session-id>          # resume a specific one, not just the last
```

**Standing rule: the work directory is never deleted while a run may still be resumed.** Not to free
disk, not to tidy up, not because the run "finished anyway". This rule has no exceptions inside the
7-day hold.

---

## 9. Cleanup

Reclaiming the work dir is safe only when **all** of these hold:

1. The run reached `Succeeded: N` with no `Failed`/`Ignored` you have not accounted for.
2. Results are rsynced to `/mnt/d` and verified — file count and `du -sh` match, MultiQC opens.
3. The handoff is written and the user has seen it.
4. At least 7 days have passed, or the user has explicitly said they are done with the run.

Never on a run that can still be resumed, and never as a mid-run fix for a full disk — free space
somewhere else instead (§7, Disk full).

The sync-out and the verification:

```bash
NXFDIR=${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}/$RUNID   # same derivation everywhere
rsync -a --info=progress2 "$NXFDIR/results/"  "$RUNDIR/results/"
rsync -a                  "$NXFDIR/reports/"  "$RUNDIR/reports/"
cp "$NXFDIR/.nextflow.log" "$RUNDIR/reports/nextflow.log"
diff <(cd "$NXFDIR/results" && find . -type f | sort) \
     <(cd "$RUNDIR/results"        && find . -type f | sort) && echo "results synced clean"
du -sh "$NXFDIR/work" "$NXFDIR/results"
```

Then, and only then:

```bash
nextflow log                                       # find the run name
nextflow clean -n -before <run-name>               # DRY RUN first, always
nextflow clean -f -before <run-name>               # removes work dirs + cache entries for older runs
```

Or, for one finished run, with the path RESOLVED — `hooks/guard-workdir.sh` reads the command
text before your shell expands it, so `rm -rf "$NXFDIR/work"` reaches it as an unexpanded
variable it cannot tie to a run, and it refuses rather than guess:

```bash
rm -rf /work/nxf/20260728-rnaseq-koges-pilot/work    # substitute the real root and run id
```

Keep `.nextflow/`, the logs and the reports — they are small and they are the record.

How much this frees: the work dir is typically 80–95% of a run's footprint. Concretely, ~90% of
~400 GB for a 30× WGS sarek run, ~90% of ~120 GB for a six-sample human RNA-seq run. Published
results are the small part.

**Deleting inside ext4 does not give the space back to Windows.** The VHDX grows and never shrinks
on its own; it will sit at its high-water mark on `D:`. To actually reclaim, from PowerShell:

```powershell
# PowerShell, not the distro. $BIOINFO_DISTRO does not exist here — it lives inside WSL, and
# `wsl --shutdown` has just torn that down anyway. Substitute the name, or set it first:
#   $env:BIOINFO_DISTRO = 'Ubuntu-24.04'      # whatever `wsl -l -v` shows
wsl --shutdown
wsl --manage $env:BIOINFO_DISTRO --set-sparse true   # WSL 2.0+; makes the VHDX auto-shrinking
```
<!-- UNVERIFIED: --set-sparse flag name/availability on the installed WSL version; check `wsl --help`.
     Fallback: diskpart → select vdisk file="D:\wsl\ubuntu-24.04\ext4.vhdx" → attach vdisk readonly
     → compact vdisk → detach vdisk -->

Docker's image cache also accretes. `docker system df` to see it; `docker image prune -a` only when
it exceeds ~100 GB, and understand it forces a re-pull of everything on the next run.

---

## 10. Concurrency policy

**One heavy pipeline at a time on this host.** A second heavy run is not a speedup, it is a slowdown
with extra failure modes.

- Two Nextflow processes do not know about each other. Each sizes its local executor pool from its
  own config, so each schedules up to the full pool in `config/local.config` — two runs put twice
  that many CPU-slots' worth of tasks on the VM, plus context-switch overhead.
- RAM is the hard wall, not CPU. The WSL VM has a fixed ceiling (`config/wslconfig.example`).
  Two STAR alignments at ~35 GB each do not fit, and the resulting OOM kill lands on
  whichever process the kernel picks — quite possibly the run you cared about.
- Both runs write to the same 1 TB VHDX. Disk-full kills both, and the disk estimate you approved
  was computed for one.
- Page cache thrash. Two runs streaming different multi-GB references evict each other's cache and
  both lose the benefit.
- Attribution. When the machine wedges, you cannot tell which run did it, and you have to kill both.

Budget: the Nextflow pool is set once in `config/local.config` and already sits below the WSL VM
ceiling. Do not override it per-run without saying why in the run plan.
<!-- UNVERIFIED: nf-core moved from `--max_cpus/--max_memory` to the `resourceLimits` directive
     around nf-core/tools 3.x; confirm which the pinned revision uses via
     `nextflow run nf-core/<pipe> -r <REV> --help | grep -iE 'max_cpus|resourceLimits'` -->

What *is* allowed alongside a heavy run: a stub run, a `-preview`, an `nf-core/fetchngs` download
(network-bound, near-zero CPU), or `nf-core/differentialabundance` on a counts matrix — each
explicitly capped, e.g. `-c` with a small override giving it 4 CPUs and 8 GB.

Enforce it rather than remembering it. Wrap the launch:

```bash
exec 9>${BIOINFO_WORK:-/work}/nxf/.heavy.lock
flock -n 9 || { echo "another heavy run holds the lock; not launching"; exit 1; }
# … launch here; the lock is released when this shell exits
```

---

## 11. Handoff

When the run completes, write `$RUNDIR/handoff.md`:

- run ID, pipeline, revision, wall-clock duration, exit status;
- where the results are (the `/mnt/d` path and the `\\wsl.localhost\…` path);
- MultiQC location and the **QC verdict**: per-sample pass / borderline / fail against stated
  thresholds, with the metric and the number;
- every bounded choice made, named — samples dropped, processes set to `ignore`, top-N cuts,
  a reference substituted;
- anything still missing from the reference store that limited the run;
- work dir path and the date it becomes eligible for cleanup.

The ceiling holds: report QC verdicts and file locations. "Sample 7 has 42% duplication and 18M
assigned reads, below the 25M we set as the floor" is the job. "Therefore *GENE* is upregulated in
the Korean cohort" is not.

---

## Stop conditions

Hard stops. Each requires the user, not a judgement call:

- Estimated wall clock > 24 h → explicit approval before launch.
- Free ext4 space < 1.5 × the disk estimate → refuse.
- Preflight FAIL → refuse.
- Stub run fails → refuse to launch the real run.
- A second heavy pipeline requested while one is running → queue it, do not co-run it.
- Any request to delete or clean a work dir that a run might still resume from → refuse and explain.
- A biological interpretation is being asked for → hand back the QC numbers and the file paths.
