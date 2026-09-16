# Quartus Tcl Contract

Phase 3 will add Tcl entry points that consume explicit `$PUBLIC_REPO`,
`$VENDOR_ROOT`, and `$RUN_ROOT` values. Tcl must reconstruct project state from
reviewed source/constraint manifests and private vendor bindings; it must not
depend on a checked-in GUI snapshot or a personal absolute path.

This directory is intentionally documentation-only in Phase 2.
