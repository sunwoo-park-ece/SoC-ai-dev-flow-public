# Provenance and Publication Policy

Only project-owned material or material with a documented redistribution basis may enter a public snapshot. A repository-wide license must not be inferred to cover third-party or unresolved files.

The following remain excluded:

- vendor-generated HDL, IP collateral, GUI-project snapshots, and raw build products;
- machine-local paths, credentials, host identifiers, and license-server data;
- private task archives and uncurated run logs;
- `firmware/apps/benchmark_main.c`, `firmware/apps/dhrystone_main.c`, and `firmware/apps/dhrystone_t410n.c`.

Benchmark source exclusion is independent of benchmark-report publication. Any future performance report must receive a separate provenance, methodology, reproducibility, and naming review, and must clearly distinguish an official Dhrystone result from a project-specific Dhrystone-style workload.

Curated evidence should contain a human-readable summary, a machine-readable result, and hashes of the exact source/test/runner inputs. Private absolute paths must not appear in public evidence.
