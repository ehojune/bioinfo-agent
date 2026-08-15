# Procuring a pipeline that is not stocked

The stocked set is the row set of `config/pipelines.tsv`: rnaseq, differentialabundance, fetchngs,
sarek, methylseq, atacseq, chipseq, cutandrun, scrnaseq, ampliseq, mag, taxprofiler, nanoseq,
raredisease, rnasplice, isoseq. Anything else goes through
this procedure before it touches real data. The
procedure exists because the expensive failure is not "no pipeline exists" — it is committing to an
unmaintained pipeline, discovering at hour six that it needs a reference nobody has, and having no
record of which revision produced the results.

Three outcomes are legitimate. Pick one explicitly and say which:

1. An nf-core pipeline fits → evaluate, pin, stub, run, then **stock it** (section 4).
2. An nf-core pipeline nearly fits → say what it does not cover, and get the user's decision
   before starting. Do not quietly answer an adjacent question.
3. Nothing fits → hand back a plan, not a run (section 6).

---

## 1. Discover what exists

```bash
nf-core pipelines list                    # nf-core/tools 3.x
nf-core list                              # nf-core/tools 2.x
nf-core pipelines list rna expression     # keyword filter, OR across terms
nf-core pipelines list --sort release     # {release, pulled, name, stars}
nf-core pipelines list --json             # machine-readable, for scripting
nf-core pipelines list --show-archived    # off by default -- turn it on when a name is missing
```

Output columns:

| column | means |
|---|---|
| Pipeline Name | the `nf-core/<name>` slug you pass to `nextflow run` |
| Stars | GitHub popularity. A weak proxy for maintenance, not a substitute for checking |
| Latest Release | the version tag you would pass to `-r`. Blank means **no release has ever been cut** |
| Released | how long ago. This is the number that matters |
| Last Pulled | when *this machine* last cached it into `$NXF_ASSETS`. Local state, not upstream state |
| Have latest release? | whether the local cache is current |

`nf-core pipelines list` needs network. Offline, the local cache is all you have:

```bash
ls "${BIOINFO_REFS:-/refs}/cache/nf-assets/.repos/nf-core/"
nextflow info nf-core/<name>      # prints the remote URL and every available revision
```

Before concluding nothing exists, also check:

- **nf-core/modules and nf-core/subworkflows.** A tool may have a maintained module even with no
  pipeline wrapping it. `nf-core modules list remote | grep -i <tool>`. That does not make it a
  pipeline, but it tells you the container is curated and the command line is known-good, which
  matters a lot for section 6.
- **Community Nextflow pipelines outside nf-core.** They run fine, but they get no nf-core
  guarantees: no standardised `-profile test`, possibly no containers, possibly no
  `--max_memory`-style resource handling. Treat one as a bespoke tool that happens to be written
  in Nextflow, and evaluate it under section 6, not section 2.

---

## 2. Evaluate a candidate before committing

Work down this list. Stop at the first hard failure and report it.

### 2.1 Is there a release?

No release tag → not eligible. Running `-r dev` or an unpinned default branch is disqualifying,
full stop (section 3). A pipeline with only a `dev` branch is a pipeline whose authors have not
yet claimed it works.

### 2.2 How old is the latest release?

| age | reading |
|---|---|
| < 12 months | normal |
| 12–24 months | probably fine, but expect Nextflow-version friction and stale container tags |
| > 24 months | assume it will need work. Check whether it still runs on the installed Nextflow before promising anything |

Age alone does not disqualify a pipeline — some are simply finished. Age plus a failing test
profile does.

### 2.3 Is it archived?

Archived pipelines are hidden from `nf-core pipelines list` unless you pass `--show-archived`, and
the GitHub repo is read-only. Archived means no fixes are coming. Use one only if the test profile
passes cleanly and you record in the run plan that it is unmaintained.

<!-- UNVERIFIED: which specific pipelines are archived changes over time. Confirm with
     `nf-core pipelines list --show-archived` rather than from memory. -->

### 2.4 Does it run on this host?

**Trust gate — before any command in this section.** Pin an exact release tag; never `dev`,
`master` or `main`. Confirm the repo is under the `nf-core` org, or that the user has explicitly
approved this one. `nextflow config` evaluates the repository's Groovy and `nextflow run` executes
its code: from here on, third-party code runs on this box. Neither nf-core nor approved → stop
and ask.

This is the only question with an actual answer rather than a judgement. Three escalating tests:

```bash
export NXF_ASSETS="${BIOINFO_REFS:-/refs}/cache/nf-assets"
P=nf-core/<name>; R=<tag>
nextflow pull "$P" -r "$R"

# (a) resolve config and parameters -- no pipeline tasks and no containers,
#     but the repo's Groovy is evaluated. Not a read-only step.
nextflow config "$P" -r "$R" -profile docker
nextflow run    "$P" -r "$R" --help

# (b) DAG + stub. Catches broken channel logic and missing required params in seconds.
nextflow run "$P" -r "$R" -profile test,docker -stub-run \
  --outdir "${BIOINFO_WORK:-/work}/scratch/stub-${P##*/}"

# (c) full test profile on the bundled miniature dataset. This is the gate.
nextflow run "$P" -r "$R" -profile test,docker \
  --outdir "${BIOINFO_WORK:-/work}/scratch/test-${P##*/}" \
  -work-dir "${BIOINFO_WORK:-/work}/nxf/test-${P##*/}/work"
```

All three run on **ext4 inside the distro**. Never point `-work-dir` at `/mnt/d`, `/mnt/c` or
`/mnt/e`, not even for a test run — drvfs turns a two-minute test into fifteen and produces
misleading timings.

Notes on reading the results:

- `-stub-run` only exercises modules that define a `stub:` block. Coverage in nf-core modules is
  good but not complete, so a stub failure in an odd corner is not automatically a real failure —
  read the error before concluding. A stub *pass* is also not proof the real run works; it proves
  the graph is wired and the parameters validate.
- `-profile test` downloads a small dataset from the internet on first use. Under network
  restriction, see section 5.
- If `-profile test` passes but `-profile test_full` is the only realistic profile, do not run
  `test_full` casually — those are AWS-scale and can be tens of hours.

### 2.5 Containers

We run `-profile docker` against the engine inside the distro (not Docker Desktop). Check:

```bash
# what images the pipeline will want
grep -rhoE "(quay\.io|docker\.io|community\.wave\.seqera\.io|ghcr\.io)/[A-Za-z0-9._/:@-]+" \
     "$(find "$NXF_ASSETS" -path '*nf-core/<name>*' -name modules -type d | head -1)" | sort -u
```

Two things go wrong. Older pipelines pin biocontainer tags that have since been retagged or
removed from quay.io — you find out at the first process, not at validation. Newer nf-core modules
resolve containers through `community.wave.seqera.io`, which builds on demand and therefore needs
network the first time even if you thought you had everything cached. Both are discovered by
actually running the test profile, which is why 2.4 is the gate.

### 2.6 Resources

Read `conf/base.config` in the cloned asset directory and map the process labels
(`process_low` / `process_medium` / `process_high` / `process_high_memory`) against the Nextflow
pool — **18 cores, 40 GB** (`process.resourceLimits` in `config/local.config` §2), not the 24-core
63.5 GB host. Anything asking for more than the pool will be clamped, and a process that genuinely
needs more will OOM; override it in `config/local.config` rather than editing the pipeline.

```bash
sed -n '/withLabel/,$p' "$(find "$NXF_ASSETS" -path '*nf-core/<name>*' -name base.config | head -1)"
```

### 2.7 References

Enumerate every reference the pipeline requires, then map each one to a row in
`config/refs.manifest.tsv`. Anything not already there is either `build` (we generate it, costs
time) or `fetch` (we download it, costs time and network). **Say so in the run plan, before the
run, in hours.** Rediscovering a missing GATK bundle twelve hours in is the failure this repo
exists to prevent.

```bash
jq -r '.["$defs"] // .definitions | to_entries[]
       | select(.key | test("reference|genome"; "i"))
       | .value.properties | keys[]' \
  "$(find "$NXF_ASSETS" -path '*nf-core/<name>*' -name nextflow_schema.json | head -1)"
```

<!-- UNVERIFIED: nextflow_schema.json switched from "definitions" to "$defs" across nf-core/tools
     versions; the jq above tries both. If it returns nothing, read the file. -->

### 2.8 Scale-up discipline

An unstocked pipeline has no entry in `estimates.md`, which means you have no estimate, which
means the 24-hour approval rule and the 1.5×-disk rule have nothing to evaluate against. Therefore:

1. test profile (minutes),
2. **one real sample**, timed and measured — peak work-dir size and wall clock,
3. extrapolate, write the estimate down, get approval if it crosses 24 h,
4. then the full cohort.

Never go from test profile straight to a 40-sample cohort on a pipeline this machine has never run.

---

## 3. Pin the revision

```bash
nextflow run nf-core/rnaseq -r 3.18.0 ...     # the pin comes from config/pipelines.tsv
```

`-r` takes a release tag, a branch name, or a commit SHA. Use a release tag. Reasons this is
non-negotiable, in order of how badly they bite:

- **Without `-r`, you get whatever the default branch is right now.** Nextflow caches the clone in
  `$NXF_ASSETS`, so the same command run on two machines, or on one machine two months apart, can
  execute different code with no visible difference in the command line.
- **`-resume` does not survive a revision change.** Change the pipeline and every task hash changes;
  the resume silently re-runs everything from scratch. You lose a day and it looks like a bug.
- **The version reported in MultiQC and `pipeline_info/software_versions.yml` becomes
  meaningless.** `dev` in a methods section is not a version.
- **A branch can be force-pushed.** A tag is (by convention) immutable. A SHA actually is.

The pin itself lives in `config/pipelines.tsv`. Every run then records it in three places:

1. the run plan handed to the user,
2. the launch command itself, kept in a run script next to the samplesheet,
3. `pipeline_info/` in the output directory — Nextflow writes the execution report, timeline, and
   `software_versions.yml` there automatically; do not delete that directory when tidying up.

Confirm the tag exists before using it:

```bash
nextflow info nf-core/<name>     # lists remote revisions; the local cache marks the current one
```

Never `-r dev`, never `-r master`, never unpinned. If a fix you need only exists on `dev`, that is
a conversation with the user about accepting an unreleased pipeline, not a decision to make quietly.

---

## 4. Stock it

A pipeline is stocked when the next person — or the next machine — can run it without redoing
sections 1–3. Six files, all in this repo.

### `config/pipelines.tsv`

**Stocking a pipeline means adding a row here.** One row: pipeline slug, the exact release tag,
the `schema_checked` date, and a note. This file is the only *authority* on the pin, and
`bin/preflight.sh` fails a `cmd.sh` whose `-r` disagrees with it. Revisions do appear elsewhere —
inside runnable example commands in docs and configs, roughly 35 of them — but those are copies,
not authorities: change a pin here and `grep -r` the old string. A pipeline without a row is not
stocked.

### `references/pipeline-selection.md`

Add a row keyed on the **analysis intent**, not the pipeline name, because that is how the request
arrives. Include:

- intent phrasing the user would actually use,
- the pipeline slug — the revision is cited from `config/pipelines.tsv`, never restated here,
- what it does *not* cover, and the nearest alternative,
- required references, flagged if not yet in the manifest.

### `references/samplesheets.md`

Add a section following the existing shape:

- column table **derived from `assets/schema_input.json` at the pinned revision** using the
  `schema_cols` helper at the top of that file — not transcribed from documentation, and not from
  memory,
- the `schema_checked` date written back to `config/pipelines.tsv`,
- a 2–3 row worked example using realistic human filenames,
- the pipeline's own ID-uniqueness rule (they differ: rnaseq merges duplicate sample IDs, sarek
  treats duplicate patient/sample/lane as an error, differentialabundance forbids duplicates
  outright),
- any pipeline-specific silent failure worth a paragraph.

### `scripts/check-samplesheet.sh`

Add the pipeline to the required-column `case` in section 2b. Without a row there,
`--deep --pipeline <name>` fails as "not stocked" even once `config/pipelines.tsv` has the pin.
Extend the enum and identifier sections too if the pipeline introduces new constrained columns.

### `references/estimates.md`

**Measured, not guessed.** From the single-sample run in 2.8, under the Nextflow pool this box
actually gives a run (18 cores, 40 GB; ext4 on the D: VHDX):

- wall clock per sample at a stated input size and coverage/depth,
- peak work-directory size per sample — separately from published output size, because the work
  dir is what fills the disk and it is never cleaned,
- peak single-process RAM, and which process,
- one-off costs paid on the first run only (index builds, cache downloads),
- how it scales: linear in samples, or does a joint/merge step dominate at cohort size.

### `config/refs.manifest.tsv`

One row per new reference, with the correct mode:

| mode | use for |
|---|---|
| `link` | sequentially-read files under `/mnt/d` — FASTA, GTF, BED, JSON catalogs |
| `copy` | random-access index files — materialise into ext4 or drvfs will dominate the runtime |
| `build` | anything a tool generates; SOURCE is the command hint |
| `fetch` | anything that must be downloaded; SOURCE is the URL or the nf-core param that pulls it |

Then `bootstrap/04-refs.sh` and confirm every row reports OK. Use standard paths in the pipeline
invocation — if a source filename appears anywhere in the command line, the manifest is missing a
row.

If the pipeline uses non-standard process labels or needs a resource override, add it to
`config/local.config`. Do not edit anything under `$NXF_ASSETS` — that directory is a cache and
will be overwritten by the next `nextflow pull`.

---

## 5. Offline / restricted-network path

```bash
nf-core pipelines download <name> \
  --revision <tag> \
  --outdir /refs/cache/nf-assets/offline/<name>-<tag> \
  --compress none \
  --download-configuration yes \
  --container-system singularity \
  --container-cache-utilisation amend \
  --parallel-downloads 4
```

(`nf-core download` without the `pipelines` prefix on tools 2.x.)

This produces a directory containing the pipeline source, a copy of nf-core/configs, and — for
singularity — the container images. Run it with a filesystem path instead of the `nf-core/<name>`
slug:

```bash
nextflow run /refs/cache/nf-assets/offline/<name>-<tag>/workflow -profile ... 
```

<!-- UNVERIFIED: the exact subdirectory layout under --outdir (workflow/ vs
     nf-core-<name>_<rev>/) has changed across nf-core/tools versions. `ls -R` the download before
     scripting the path. -->

Three things to know:

- **`--container-system` only supports singularity for image pre-download.** Our substrate is the
  docker engine, so `nf-core pipelines download` will not pre-pull docker images. Do it directly:

  ```bash
  grep -rhoE "(quay\.io|docker\.io|community\.wave\.seqera\.io|ghcr\.io)/[A-Za-z0-9._/:@-]+" \
       /refs/cache/nf-assets/offline/<name>-<tag> \
    | sed 's/[",)]*$//' | sort -u | xargs -r -n1 -P4 docker pull
  ```

  Run that once while the network is available. Verify with `docker image ls`.
  <!-- UNVERIFIED: the regex will occasionally catch a URL that is not an image reference; failed
       pulls are harmless, just noisy. -->

- **Wave-built containers (`community.wave.seqera.io`) are built on request.** They cannot be
  mirrored by grepping alone if the pipeline composes them dynamically. If the pull list looks
  suspiciously short for the number of modules, that is why — and it means the pipeline genuinely
  needs network on first run.

- **Then enforce offline mode** so a stray fetch fails loudly instead of hanging:

  ```bash
  export NXF_OFFLINE=true
  # and never pass -latest
  ```

  Set `NXF_HOME` and `NXF_ASSETS` explicitly in the launch script so the cache location is not
  dependent on whose shell started the run.

---

## 6. When nf-core is the wrong answer

### Signals

- **The task is one tool, not a workflow.** Genotyping 12 CRAMs with ExpansionHunter against
  `/refs/catalogs/str/eh_catalog.disease.GRCh38.json`. Running TRGT over a set of PacBio BAMs.
  Joining KoGES allele frequencies against a gnomAD release and computing a delta. These are
  scripts. Wrapping them in a pipeline framework adds a work directory, a container resolution
  step, and a samplesheet schema, and buys nothing you did not already have.
- **The only candidate has no release, is archived, or fails `-profile test` on this host** and
  fixing it is pipeline development, not analysis.
- **The data type is not supported.** Long-read repeat-expansion genotyping in particular has no
  stocked nf-core answer here; check `nf-core pipelines list --show-archived` before asserting
  that, but do not assume a pipeline exists because the field is active.
  <!-- UNVERIFIED: current nf-core coverage for long-read / STR workflows. Verify with a live
       `nf-core pipelines list` rather than asserting from this document. -->
- **The closest pipeline answers a different question.** This is the dangerous one, because it
  looks like success. Running sarek when the user wanted repeat-expansion genotyping produces a
  beautiful VCF that does not contain the answer.

### What to hand back

Do not improvise a pipeline. Do not run the nearest thing and caveat it afterwards. Return a
written handoff containing:

1. **The negative result, with evidence.** "No stocked pipeline covers this. Candidates considered:
   X (archived, last release 2022-11, test profile fails on Nextflow 24.x), Y (covers alignment but
   not genotyping), Z (no release tag)." Naming what you rejected and why is what makes the
   conclusion checkable.
2. **The tool chain that would do the job**, as a plan: tool, version, container URI (prefer one
   from nf-core/modules — curated and pinned), and the actual command shape for one input.
3. **The input inventory** — files found, their location, total size, and whether they are on
   `/mnt/d` (slow) or ext4.
4. **The reference rows that would need adding to `refs.manifest.tsv`**, with modes, and which of
   them are `build` or `fetch` (i.e. not free).
5. **A resource estimate** with the same discipline as `estimates.md`: wall clock, peak disk, peak
   RAM. If you cannot estimate it, say that and propose a one-input timing run.
6. **An explicit question**: "Do you want me to write a bespoke script for this?" Then wait. The
   24-hour approval rule and the "announce every bounded choice" rule both apply here — if the plan
   involves sampling, a top-N cutoff, or dropping an input, say so in the handoff, not in a
   footnote afterwards.

### If the user says yes to a bespoke script

- It lives in `scripts/`, is bash with `set -euo pipefail`, is idempotent, and takes absolute paths.
- It runs on ext4. Reference files come from `$BIOINFO_REFS` standard paths, never source filenames.
- It logs the version of every tool it invokes into the output directory, so the run is as
  reproducible as a pipeline run.
- It does **not** cosplay as a pipeline: no fake work directory, no `-resume` flag that does not
  resume, no MultiQC report implying QC that was not performed. If it can restart from partial
  output, implement that honestly and document it; if it cannot, say it cannot.
- The ceiling does not move. It reports what ran, where the output is, and the QC numbers. It does
  not interpret them.
