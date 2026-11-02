# Fuzz target constraints

The fuzz targets exercise simulation, validated-map queries, level transitions
and inventory rules. Their properties and regression examples live with the
corresponding target source; run those checks when changing game behavior.

## Native compiler constraints

`fuzz_map.roc` keeps `guard_dynamic_sectors` enabled, so a passing campaign does
not establish the disabled range assertion. `fuzz_level.roc` copies state lists
before calls into the level simulation to preserve the harness's inputs across
native calls. Keep these explicit constraints when interpreting results.

Before removing a guard or defensive copy, reproduce its case with the selected
compiler, compare native and interpreted results, and require a regression that
fails without the repair. Report unresolved compiler behavior in the appropriate
issue tracker rather than accumulating campaign logs in this guide.
