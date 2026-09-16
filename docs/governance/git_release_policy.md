# Git and Release Policy

- Prepare publication changes in a dedicated worktree and branch based on the approved preview commit.
- Copy only an approved, hash-verified allowlist.
- Inspect the complete filesystem tree, including untracked files, before staging or committing.
- Separate source-snapshot and curated-evidence commits when approval permits commits.
- Do not rewrite the preview history merely to remove a file from the new tip; omission or deletion in a later commit preserves historical identity.
- Tags and public pushes require explicit owner approval after secret, path, license, vendor-payload, and reproducibility review.
- A commit or tag must not describe the baseline as released while Gate 0 or required acceptance items remain open.

This policy does not itself authorize an index update, commit, tag, push, or publication. Each such operation requires separate, task-specific owner approval after the applicable review gates pass.
