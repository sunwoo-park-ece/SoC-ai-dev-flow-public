# Source-of-Truth Policy

The public repository is the source of truth for publishable project-owned RTL, firmware, verification, specifications, scripts, and curated evidence.

Authority order:

1. Approved canonical English specifications under `spec/`.
2. `spec/baseline_cleanup.md` for cleanup status and acceptance dependencies.
3. Current implementation and reproducible public tests.
4. Curated evidence under `reports/evidence/`.
5. Historical notes, which never override the current contract.

Korean specification files are synchronized human-readable companions. Vendor projects, generated IP, raw run trees, private task prompts, and local migration reports are not source-of-truth content.

P10-HEX and P11-ADC cleanups are VERIFIED and merged into main. The current active cleanup milestone is P12-VGA-CDC-AES, addressing remaining VGA clock domain crossing (CDC) and AES peripheral closure.
