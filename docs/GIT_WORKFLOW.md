# Git Workflow

The public repository is the source of truth for publishable engineering content. Create a feature branch and a worktree from its current approved baseline for each bounded change.

```bash
export SOC_ROOT=/path/to/soc
export PUBLIC_REPO="$SOC_ROOT/repos/SoC-ai-dev-flow-public"
git -C "$PUBLIC_REPO" worktree add "$SOC_ROOT/worktrees/feature-name" -b feature/feature-name
```

Implementation flow:

1. Chat and the developer settle the specification.
2. Codex implements RTL/FW in the feature worktree and runs open checks.
3. Antigravity prepares independent DV from the same specification.
4. Codex runs ModelSim/XSim or vendor CLI jobs using public source plus private bindings where required.
5. Raw outputs go to `$RUN_ROOT`; reviewed, sanitized evidence and reports may be committed.
6. Review source, tests, provenance, generated-file exclusions, and evidence before merge.

Never commit complete vendor projects, generated IP HDL, raw run directories, personal paths, credentials, host identifiers, or license-server details. A milestone vendor-project snapshot is kept separately in the private vault and is not a Git substitute for the public source history.
