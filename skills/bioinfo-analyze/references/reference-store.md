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
no ALT/HLA/decoy, BWA-indexed — use this for sarek), `KOREF1` (Korean reference assembly).

## The manifest

`config/refs.manifest.tsv` in the repo is the source of truth. `bootstrap/04-refs.sh` reads it and
materialises the tree. Four modes:

| mode | what happens | when to use |
|---|---|---|
| `link` | ext4 symlink → source under `/mnt/d` | sequential reads: FASTA, GTF, BED, JSON |
| `copy` | real copy into ext4 | random-access-heavy: BWA/STAR index files |
| `build` | nothing; a tool must generate it | STAR/salmon/bismark indexes, `.dict` |
| `fetch` | nothing; must be downloaded | GATK bundle, VEP cache |

**The `link` vs `copy` split is not cosmetic.** `/mnt/d` goes through Windows drvfs and is roughly
5–10× slower than ext4. A 3 GB FASTA read once per process survives that; a BWA index doing
scattered reads across 2.9 GB does not. If a run is inexplicably slow, check whether a hot file is
still a symlink and promote it to `copy`.

## Rules

1. **Never write into `genomes/*/fasta/` or anything with mode `link`.** Those are symlinks into the
   user's own directories. Writing through them mutates their originals.
2. Generated indexes go under `index/` with mode `build`, and are real files on ext4.
3. When a pipeline can save what it built, let it: `--save_reference` on rnaseq/methylseq writes the
   index where the next run can reuse it. Building a human STAR index costs about an hour and ~40 GB
   RAM. Do it once.
4. New reference file arrives → add a manifest row, re-run `04-refs.sh`. Do not hand-place files in
   `/refs`; anything not in the manifest is invisible to the next machine.
5. `04-refs.sh` is idempotent and reports every row as OK / MISSING / STALE. Run it whenever a run
   fails with a missing-reference error, before doing anything else.

## Reading the manifest at run time

```bash
refpath() { awk -F'\t' -v k="$1" '$1==k{print ENVIRON["BIOINFO_REFS"] "/" $1}' \
            "$BIOINFO_HOME/config/refs.manifest.tsv"; }
```

In Nextflow configs, reference `params.refs` (wired in `config/genomes.config`) rather than
composing paths inline.

## What is genuinely missing right now

`GRCh38gatk` has no sequence dictionary and no GATK resource bundle. Sarek's BQSR and
HaplotypeCaller steps need both. The dictionary is a two-minute `gatk CreateSequenceDictionary`;
the bundle is a real download (dbsnp + known_indels ≈ several GB, gnomAD af-only more). Flag this in
the run plan before promising a variant-calling run — do not discover it twelve hours in.

No STAR or salmon index exists, so the first RNA-seq run pays the index-build cost. Say so in the
estimate.
