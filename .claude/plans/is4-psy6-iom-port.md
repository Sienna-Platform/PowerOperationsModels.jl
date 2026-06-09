# Plan: Make `ac/psi-costexp-parambroad-pfslack` work with IS4 / PSY6 / IOM-main

## Situation (verified)

The branch is the POM-side of a cross-package **"units-domain-agnostic"** refactor that spans IS → PSY → IOM → POM. The PR already carries ~3800 lines of adaptation (cost expressions, parameter broadening, power-flow-in-the-loop, MT-HVDC quadratic converter, parallel-branch multipliers).

### Dependency topology (local checkouts)
| Pkg | Where | Branch needed | State found | Action taken |
|-----|-------|---------------|-------------|--------------|
| InfrastructureSystems | `./InfrastructureSystems.jl` (nested) | IS4 | was on `main`, 26 behind origin/IS4 | ✅ switched + ff to origin/IS4 (`1e755dbf`) |
| PowerSystems | `./PowerSystems.jl` (nested) | psy6 | psy6, up-to-date | ✅ ok |
| InfrastructureOptimizationModels | `./InfrastructureOptimizationModels.jl` (nested) | main | main, up-to-date | ✅ ok |
| PowerSystemCaseBuilder | `/Users/jlara/cache/PowerSystemCaseBuilder.jl` (sibling) | psy6 | psy6 | ✅ ok (test-only) |

Note: a *sibling* `/Users/jlara/cache/InfrastructureOptimizationModels.jl` exists on the WRONG branch (`lk/units-domain-agnostic`); the old test Manifest pointed at it. We will point sources at the **nested** copies instead.

### Critical compat findings (from registry + Project.tomls)
- **IOM main requires `PowerNetworkMatrices = "^0.20"`**, but POM pins `^0.19` and the stale Manifest has 0.19.1. → bump POM PNM compat to `^0.20`.
- Registered **PNM 0.21.1** needs `PowerSystems 5.10.0-5`, `IS 3` → matches psy6 (5.10.0) + IS4 (3.6.0). Resolver will select it (no local PNM needed).
- Registered **PowerFlows 0.17/0.18** need `PowerSystems 5.10`, `PNM 0.21` → matches. `test_power_flow_in_the_loop.jl` needs this; resolver picks 0.18.0 (no compat pin blocks it). No local PowerFlows needed.
- IOM main commit #91 uses `IS.convert_cost_coefficient` — only present in origin/IS4 (the units work). This is why the IS ff was mandatory.
- IS4 adds an internal `relative_units` submodule; no new external/unregistered dep. PSY psy6 adds `Unitful` (registered).

## Approach

Use `[sources]` with **local absolute paths** to the nested checkouts so any minor dependency edits propagate immediately. (For the eventual PR merge, these revert to git revs IS4/psy6/main once any dep edits are pushed upstream — noted in final report.)

### Steps
1. **Env setup**
   - POM `Project.toml`: `[sources]` → local paths for IS/PSY/IOM; bump `PowerNetworkMatrices = "^0.20"`.
   - POM `test/Project.toml`: `[sources]` → local paths for IS/PSY/IOM + PSCB sibling.
   - IOM `test/Project.toml`: IS source → local path (same editable IS4) so IOM's own suite uses it.
   - Delete stale `Manifest.toml` + `test/Manifest.toml`; instantiate test env.
2. **Compile gate**: `julia --project=test -e 'using PowerOperationsModels'`. Fix API-churn errors (units getters/setters, cost-curve accessors, dropped JSON3, renamed IS/PSY/IOM symbols) until clean.
3. **POM test suite**: `julia --project=test test/runtests.jl 2>&1 | tee /tmp/pom_test.log`. Fix to green.
4. **IOM test suite** (success criterion #2): run IOM's own suite against IS4. Fix to green.
5. **Formatter**: `julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'`.
6. **/simplify** on the changed code.

### Guardrails (per user)
- No hacks: no `get_x(...; default=nothing)`, no `try/catch` to swallow API breaks. Fix the real call site.
- Respect Julia include order for any new defs.
- Compile-check after each edit batch; full suite after a feature is whole.
- Stage only; never commit.

### Risks
- Units API is the big one: getters may now require explicit `units=` kwarg; bare `get_X` strips units. Many POM call sites compute on numeric magnitudes — need to confirm they read the right unit system.
- Cost-curve parametrization changed (CostCurve/FuelCurve parameterized on unit-system type; legacy enum names accepted). Objective-function code is the hotspot.
- Resolver may surface a deeper transitive conflict; if so, identify the single offending compat and patch the local dep minimally.
