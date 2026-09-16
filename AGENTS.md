# Repository Working Rules

- `spec/` is the canonical engineering contract; `spec/baseline_cleanup.md` is the cleanup tracker.
- Preserve the P08B Gate 0 STOP until the trap-vector/firmware endpoint policy is approved and implemented.
- Do not claim Clean Baseline release, board acceptance, or vendor timing closure without the corresponding public evidence.
- Vendor-generated IP, raw runs, private task archives, machine-local configuration, and credentials are outside this repository.
- `benchmark_main.c`, `dhrystone_main.c`, and `dhrystone_t410n.c` are intentionally excluded. Benchmark reports require separate provenance and terminology review before publication.
- Keep English canonical specifications and Korean companions synchronized for substantive contract changes.
- Do not commit, tag, push, publish, or resume P08B implementation without explicit owner approval.
