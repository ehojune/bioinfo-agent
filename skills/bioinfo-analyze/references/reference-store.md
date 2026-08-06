# Reference store standard

There is exactly one reference root: **`$BIOINFO_REFS`** (default `/refs`). Every pipeline
invocation resolves reference files through it. Never pass a raw path like
`/mnt/d/Research/references/hg38.fa` to a pipeline — if you find yourself typing a source
filename, the manifest is missing an entry. Fix the manifest instead.

## Why the indirection

Source files on this machine are named however whoever downloaded them felt like naming them
(`hg38.fa`, `Homo_sapiens_assembly38_noALT_noHLA_noDecoy.fasta`, `KOREF1-Gp-TTAGGA.fa`). Pipeline
configs that hardcode those names break the moment anything moves. The store normalises names so
that swapping a genome build is a one-word change and moving machines is a manifest edit.

## Layout

```
$BIOINFO_REFS/
├── genomes/<BUILD>/
│   ├── fasta/genome.fa            always this name, whatever the source was called
│   │        genome.fa.fai
│   │        genome.dict
│   ├── gtf/genes.gtf.gz
│   ├── bed/genes.bed
│   ├── index/{star,salmon,bwa,bismark,bowtie2}/
│   └── gatkbundle/                dbsnp, known_indels, germline_resource
├── catalogs/str/                  HipSTR, TRGT, ExpansionHunter catalogs
└── cache/
    ├── nf-assets/                 Nextflow pipeline clones (NXF_ASSETS)
    ├── containers/                image cache
    ├── vep/  snpeff/              annotation caches
    └── igenomes/                  anything pulled from AWS iGenomes
```

Builds currently defined: `GRCh38` (UCSC hg38 + GENCODE v50), `GRCh38gatk` (GATK analysis set,
no ALT/HLA/decoy, BWA-indexed — use this for sarek), `KOREF1` (Korean reference assembly),
`R64-1-1` (S. cerevisiae, Ensembl release-116 genebuild).

## The rnaseq alias

`genome.fa` / `genes.gtf.gz` is exactly the basename nf-core/rnaseq's own `main.nf` treats as
proof a reference came from AWS iGenomes — it sets `is_aws_igenome=true` by basename alone, no
parameter involved, and that flag routes the run onto a STAR-2.6.1d-only legacy path (2.6.1d
segfaults outright on at least one host this repo runs on). Since every build here is
normalised to exactly that basename, every fresh rnaseq run trips it — through *either*
invocation form: the explicit `--fasta`/`--gtf` form, and the compact `--genome <key>` form,
since the pipeline resolves `--genome <key>` to `params.genomes.<key>.fasta`/`.gtf` internally,
same two attributes.

`04-refs.sh` therefore also maintains, next to the canonical file, a second symlink named after
the build itself: `genomes/<BUILD>/fasta/<BUILD>.fa` and `genomes/<BUILD>/gtf/<BUILD>.gtf.gz`,
both pointing at the canonical file (same collision guard as every other `link` row — a real
file already at that path is left alone and reported, not overwritten, unless `--force`).
`genomes.config`'s `genomes.<BUILD>.fasta`/`.gtf` values point at this alias directly rather
than at a separate `fasta_alias`/`.gtf_alias` param, precisely so both invocation forms resolve
to the safe name without either one being able to fall through to the canonical path by
accident. No other pipeline or param is affected; the canonical `genome.fa` file itself is
untouched and stays what every manifest row, BWA index prefix and every non-rnaseq pipeline
actually reads — only the *value of the `fasta`/`gtf` param* changed, not the file on disk.

## The manifest

`config/refs.manifest.tsv` in the repo is the source of truth. `bootstrap/04-refs.sh` reads it and
materialises the tree. Four modes:

| mode | what happens | when to use |
|---|---|---|
| `link` | ext4 symlink → source under `/mnt/d` | sequential reads: FASTA, GTF, BED, JSON |
| `copy` | real copy into ext4 | random-access-heavy: the BWA index (`.bwt` 2.9 G, `.sa` 1.4 G) |
| `build` | nothing; a tool must generate it | STAR/salmon/bismark indexes, `.dict` |
| `fetch` | nothing; must be downloaded | GATK bundle, VEP cache |

**The `link` vs `copy` split is not cosmetic.** `/mnt/d` goes through Windows drvfs and is roughly
5–10× slower than ext4. A 3 GB FASTA read once per process survives that; a BWA index doing
scattered reads across 2.9 GB does not. If a run is inexplicably slow, check whether a hot file is
still a symlink and promote it to `copy`.

## Rules

1. **Never write through a mode-`link` path.** Those are symlinks into the user's own directories;
   writing through one mutates their original. Creating a *new* file beside them is fine — that is
   how `genome.dict` (mode `build`) lands in `genomes/<BUILD>/fasta/`.
2. Generated indexes go under `index/` with mode `build`, and are real files on ext4.
3. When a pipeline can save what it built, let it: `--save_reference` on rnaseq/methylseq writes the
   index where the next run can reuse it. Pay that cost once.
4. New reference file arrives → add a manifest row, re-run `04-refs.sh`. Do not hand-place files in
   `/refs`; anything not in the manifest is invisible to the next machine.
5. `04-refs.sh` is idempotent and reports every row as OK / MISSING / STALE (`--dry-run` reports
   without touching anything). Run it whenever a run fails with a missing-reference error, before
   doing anything else.

## Reading the manifest at run time

```bash
refpath() { awk -F'\t' -v k="$1" -v r="${BIOINFO_REFS:-/refs}" '$1==k{print r "/" $1}' \
            "${BIOINFO_HOME:-/mnt/d/bioinfo-agent}/config/refs.manifest.tsv"; }
```

In Nextflow configs, reference `params.refs` (wired in `config/genomes.config`) rather than
composing paths inline.

## What is genuinely missing right now

Every `build` and `fetch` row in the manifest is a cost paid before the run, not during it:

- `genome.dict` is `build` for **both** `GRCh38` and `GRCh38gatk`; neither exists. Two minutes each
  (`gatk CreateSequenceDictionary`), but sarek will not start without one.
- The GATK bundle is `fetch`: dbsnp + known_indels ≈ several GB, gnomAD af-only more. Sarek's BQSR
  and HaplotypeCaller need it.
- `$BIOINFO_REFS/genomes/GRCh38/index/` is **empty**. No STAR, salmon, bismark, bwameth or bowtie2
  index exists, so the first rnaseq/methylseq/atacseq/chipseq/cutandrun run pays the build (~1 h
  each; the STAR build wants ~40 GB RAM, which is the entire Nextflow pool).
- `genomes/GRCh38/bed/blacklist.bed` is a `fetch` row and the file is **not there** — only
  `genes.bed` is in that directory. atacseq/chipseq `--blacklist` needs it. Not a manifest gap:
  `bash bootstrap/04-refs.sh` fetches it.
- `KOREF1` is FASTA only on disk — no `.fai`, no `.dict`, no BWA index. The manifest *does* carry
  all three as `build` rows, so nothing needs adding; they just have to be produced (the BWA index
  is ~1.5 h) before anything runs end to end on that build.

**Row present ≠ file present, and this list has been wrong in both directions.** Ask the
filesystem instead of reading:

```bash
bash bootstrap/04-refs.sh --dry-run     # OK / NOT BUILT / MISSING / STALE, per row
```

Verified against that command on 2026-08-06: 44 rows, 18 OK, 15 not built, 11 fetch-missing.
Both `genomes/GRCh38/index/bowtie2/` and `genomes/GRCh38/bed/blacklist.bed` were listed here as
manifest gaps long after their rows were added — but the rows are all they ever got, and the
files are still absent today, which is why they are back on this list stated the other way round.
`pipeline-selection.md` section 9 tracks the *rows*; this section tracks the *files*.

Flag whichever of these a request touches in the run plan and in the estimate, before the run — do
not discover it twelve hours in.
