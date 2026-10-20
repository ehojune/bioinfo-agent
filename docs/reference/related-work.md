# Related work: verified sources and comparison limits

Checked 2026-10-20. These sources motivate evaluation; none benchmarks bioinfo-agent.
The comparison column is our architectural interpretation.

| Source | What the source supports | Relevant comparison / next experiment |
|---|---|---|
| [BioFlowBench authors' repository](https://github.com/YufeiHouAnne/BioFlowBench) | Tool-use benchmark with syntax, workflow structure, execution, biological validity and recovery metrics | Evaluate workflow completion and recovery separately; no result on this benchmark is claimed here |
| [BixBench, arXiv:2503.00096v1](https://arxiv.org/html/2503.00096v1) | 53 analytical scenarios, 296 questions; open-ended data analysis and interpretation | bioinfo-agent limits its remit to execution and technical QC. Evaluate boundary violations separately from task completion |
| [Biomni, Huang et al., 2025](https://www.biorxiv.org/content/10.1101/2025.05.30.656746v1) | General biomedical agent combining retrieval-augmented planning with code execution | Compare freely composed analyses with pinned workflow execution only on matched tasks |
| [BIA authors' repository](https://github.com/biagent-dev/bia) and [paper DOI](https://doi.org/10.1101/2024.05.22.595240) | Natural-language bioinformatics workflow automation; repository verifies identity and paper link | Compare intake and provenance contracts; do not attribute an unverified FASTQ/BAM profiling benchmark to BIA |
| [Reproducibility as a service, 2023](https://onlinelibrary.wiley.com/doi/full/10.1002/spe.3202) | Containerized reproducibility, provenance and recovery of research code | Include non-agent workflow systems in the comparison; containers and recovery alone do not establish novelty |

## Corrections to issue #69

- `arXiv:2603.16880` is [NeuroNarrator](https://arxiv.org/abs/2603.16880), not BioFlowBench.
  Use the authors' BioFlowBench repository until its paper bibliography is verified.
- `arXiv:2601.21790` is a [marcasite–pyrite synthesis paper](https://arxiv.org/abs/2601.21790), not BIA.
  BIA's author-linked preprint DOI is `10.1101/2024.05.22.595240`.
- BixBench's 296 questions are nested in 53 scenarios, not 200+ independent scenarios.
- BixBench does not establish that this project's “The Line” policy prevents QC
  overconfidence. That is a testable design hypothesis.
- The presence of `schema_input.json` does not prove the pinned workflow invokes it.
  This repository records inactive schema files in nanoseq/rnasplice; inspect the
  actual call path before delegating validation to upstream schemas.

## Evaluation contract before claiming an advantage

Use the same pinned workflow/data, host, container cache state and timeout in each
arm: direct workflow operation, agent with protocol, agent with protocol plus
executable guards. Fix task/scenario units before collection; multiple attempts on
one dataset are not independent biological replicates.

Record completion, correct rejection, false rejection, recovery, state-report
accuracy, QC-boundary violations, wall time, peak RSS, disk and agent cost.
Predeclare expected outcomes; include negative controls and interrupted runs.
Report denominators and unavailable observations. Existing run records establish
feasibility, not comparative agent efficacy or patent novelty.
