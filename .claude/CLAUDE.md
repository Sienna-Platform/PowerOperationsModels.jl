# PowerOperationsModels.jl — Claude Guide

Platform-wide Sienna conventions (performance, type stability, formatter, environments, code style) live in `.claude/Sienna.md` — read it too. This file is repo-specific and does not restate them.

## Purpose & place in the stack

POM is the **collection of operational optimization models for power systems**: the concrete device, service, and network formulations plus the `PowerOperationModel` problem-type chain. It builds JuMP models from PowerSystems components.

Abstraction hierarchy (low → high level of generality):

- **InfrastructureSystems (IS)** — domain-agnostic base: optimization key types (`VariableKey`, `ConstraintKey`, …), time series, generic component abstractions. (`InfrastructureSystems.Optimization` = `ISOPT`.)
- **InfrastructureOptimizationModels (IOM)** — domain-neutral optimization infrastructure: `OptimizationContainer`, `DeviceModel{D,F}` / `ServiceModel{S,F}` / `NetworkModel{N}`, `ProblemTemplate`, `DecisionModel{M}` / `EmulationModel{M}` (parameterized over the single abstract tag `IOM.AbstractOptimizationProblem`), both stores, settings, the generic `add_*!` builders, objective/initial-condition infra. Reusable beyond power systems.
- **POM (this repo)** — the "what": device formulations (`ThermalBasicUnitCommitment`, `RenewableFullDispatch`, `StaticBranch`, storage, HVDC, …), variable/constraint/expression/parameter types, network formulations, service models, and the concrete problem taxonomy.

PSI (the old PowerSimulations.jl) ≈ POM + IOM. Many ports into POM originate from PSI PRs.

IS and IOM are **external package dependencies** (resolved via `Project.toml`/`[sources]`), not subdirectories.

### The IOM/POM split (PR #104 "Redistribute operation models")

IOM was made domain-neutral. The power-flavoured taxonomy was **moved out of IOM into POM** (`src/core/problem_types.jl`):

- POM owns `PowerOperationModel <: IOM.AbstractOptimizationProblem`, then `DecisionProblem`/`EmulationProblem`, `DefaultDecisionProblem`/`DefaultEmulationProblem`, `GenericOpProblem`/`GenericEmulationProblem`. POM dispatches on `DecisionModel{<:PowerOperationModel}` etc. The no-type-param `DecisionModel(template, sys)` default + the EmulationModel update chain live in POM (`src/operation/`).
- IOM removed `OperationModel`, `DecisionProblem`, `EmulationProblem`, the `Generic*`/`Default*` problem types, and the `Simulation*` stubs. The old `OperationModel` abstract → `IOM.AbstractOptimizationModel`. `validate_time_series!` / `validate_template` are stubs on the neutral abstract.
- **Gotcha:** when a symbol seems "not defined in IOM", check whether #104 moved it to POM — define/dispatch on the POM chain, do **not** re-add it to IOM.

## Optimization Model Construction Conventions

### `add_*!()` methods must not return collections
Methods that create variables, constraints, or expressions (`add_variables!`, `add_constraints!`, `add_expressions!`, etc.) must always end with a bare `return` (i.e., return `nothing`). They must never return dicts or collections of JuMP objects. Instead, instantiate the appropriate container via `add_*_container!` and store all created objects there.

### Inline expressions when possible
Expression construction should be inlined at the point of use. Only store an expression in a container when it is intended to be reused across multiple constraints or objective terms. Avoid creating expression containers solely as intermediate computation steps.

## Device construction: two-stage `construct_device!`

Every device/service/network formulation implements `construct_device!` (or `construct_service!` / `construct_network!`) for **two** dispatch stages:

- `ArgumentConstructStage` — add variables, parameters, expressions, feedforward arguments.
- `ModelConstructStage` — add constraints, feedforward constraints, objective terms, constraint duals.

`add_expressions!` must run before `add_constraints!` that consume those expressions. Not all device formulations are compatible with all network models — check existing method signatures before adding a new pair.

## Repository Structure

> Maintenance note: keep this current. Stale structure docs cause bad planning assumptions.

```
src/
  PowerOperationsModels.jl        # Main module: all imports, includes (load order), exports
  area_interchange.jl             # Area interchange balance
  core/                           # Type definitions (no heavy logic)
    definitions.jl, physical_constant_definitions.jl
    problem_types.jl              # PowerOperationModel chain (moved from IOM, PR #104)
    interfaces.jl                 # incl. PowerFlowEvaluator wrapping PF models
    variables.jl, auxiliary_variables.jl, constraints.jl, expressions.jl, parameters.jl
    formulations.jl, network_formulations.jl   # native DCP/ACP/PTDF/CopperPlate/Area structs
    bilinear_configs.jl, reserve_traits.jl
    initial_conditions.jl, feedforward_interface.jl
    default_interface_methods.jl, problem_template.jl
  common_models/                  # Shared builders: add_expressions/add_parameters/add_to_expression,
                                  #   objective_function, make_system_expressions, reserve_range_constraints,
                                  #   quadratic_converter_loss, network_conditional, market_bid_*
  initial_conditions/             # add_initial_condition, device_initial_conditions, update_*, initialization
  static_injector_models/         # thermal/renewable/hydro/load/source/reactivepower + *_constructor.jl
  energy_storage_models/          # storage_models.jl + storage_constructor.jl
  hybrid_system_models/           # hybrid_systems.jl + hybridsystem_constructor.jl
  ac_transmission_models/         # AC_branches.jl, security_constrained_branch.jl (MODF SC), branch_constructor.jl
  twoterminal_hvdc_models/        # TwoTerminalDC_branches.jl
  mt_hvdc_models/                 # HVDCsystems.jl (multi-terminal) + constructor
  services_models/                # reserves, reserve_group, transmission_interface, service_slacks; agc.jl is
                                  #   currently NOT included (TODO: needs _get_ace_error)
  network_models/                 # network_reductions, instantiate_network_model, copperplate, area_balance,
                                  #   powermodels_interface, pm_translator, dcp_model, acp_model, hvdc_networks,
                                  #   network_slack_variables, network_constructor
  operation/                      # build_problem, decision_model, emulation_model, template_validation
  utils/                          # psy_utils, generate_valid_formulations, print
  InfrastructureModels/           # Embedded submodule adapted from InfrastructureModels.jl (core/)
  PowerModels/                    # Embedded submodule adapted from PowerModels.jl (core/ form/ prob/ util/)
ext/PowerFlowsExt/                # PowerFlows.jl weakdep extension: PowerFlowsExt.jl, pf_data_update.jl,
                                  #   pf_headroom.jl, pf_input_mapping.jl, pf_solve_and_aux.jl
test/                            # ParallelTestRunner; test_*.jl auto-discovered; test_utils/ shared helpers
scripts/formatter/               # formatter_code.jl + Project.toml
docs/                            # make.jl, make_tutorials.jl, src/
```

The embedded `PowerModels/` submodule provides AC (ACP/ACR/ACT), DC (DCP), LPAC, SDP (WR/WRM), and branch-flow (BF/IV) formulations without an external PowerModels.jl dependency. `InfrastructureModels/` provides the generic optimization base it builds on.

## Imports / aliases

POM uses `import X as Y` and `const Y = X` aliases declared **in the main module** — do not introduce per-file aliases. Canonical: `PM = PowerModels`, `IS = InfrastructureSystems`, `ISOPT = InfrastructureSystems.Optimization`, `PSY = PowerSystems`, `PNM = PowerNetworkMatrices`, `IOM = InfrastructureOptimizationModels`. In the extension: `IOM`, `PFS = PowerFlows`. POM re-exports `PTDF`/`VirtualPTDF` from PNM. Native `DCPPowerModel`/`ACPPowerModel` are **POM structs** in `core/network_formulations.jl`, not PowerModels re-exports.

## Commands (verified)

All Julia invocations use `--project=test` (deps live in `test/Project.toml`); never bare `julia`/`--project`.

```sh
# Full test suite (ParallelTestRunner: each top-level test_*.jl runs in its own Malt worker)
julia --project=test test/runtests.jl
# Filter by file name (startswith), cap parallelism, or list:
julia --project=test test/runtests.jl test_model_decision
julia --project=test test/runtests.jl --jobs=8
julia --project=test test/runtests.jl --list
# Run one test file directly (loads shared preamble first):
julia --project=test -e 'include("test/includes.jl"); include("test/test_native_dcp_acp_models.jl")'

# Formatter (run after EVERY task, before reporting done)
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'

# Docs
julia --project=docs docs/make.jl
```

Solvers: `HiGHS` (LP/MILP), `Ipopt` (NLP), `SCS` (SDP) — helpers `HiGHS_optimizer`/`ipopt_optimizer` in `test/test_utils/solver_definitions.jl`. Test systems come from `PowerSystemCaseBuilder` (PSB). Aqua checks are in `test/test_aqua.jl`.

### ParallelTestRunner specifics
- Discovers only top-level `test/test_*.jl`; `includes.jl`, `test_utils/`, `test_data/` are shared infra (not run as tests) — no need to edit `runtests.jl`/`includes.jl` to add a test file.
- Per-worker env sets `HDF5_USE_FILE_LOCKING=FALSE` (PSB reads a shared serialized-system HDF5 store concurrently) and `RUNNING_SIENNA_TESTS=true`.
- Each test runs in a **fresh module, not `Main`** — surfaces `Main`-only bugs. If a test fails only under the parallel runner, suspect module-context issues (`Symbol(T)`/`string(T)` dict keys, `getfield(Main, …)`); prefer `nameof`. Wall-clock is bound by the slowest single file (`test_device_hvdc` is the long pole).
- The old serial runner's global "no Error-level log events" `MultiLogger` assertion was **dropped** — it doesn't carry to per-worker isolation. Per-`@test`/`@testset` assertions still gate results.
- Warnings inside `build!` go to the build's `operation_problem.log` (wrapped in `with_logger`) — `@test_logs` at the call site can't see them; assert by reading the log file.

## POM-specific conventions, invariants, gotchas

- **Layer boundaries:** device/network formulations + `PowerOperationModel` chain live in POM; `OptimizationContainer`/`DecisionModel`/settings/generic builders in IOM; base key/TS types in IS. Don't push power-specific logic down into IOM.
- **`network_reduction` must always be populated** by POM's `instantiate_network_model!` for every network model (CopperPlate/AreaBalance set an identity reduction). It is `Union{Nothing,...}` on the IOM side. Concrete `BranchReductionOptimizationTracker` + `get_constraint_map_by_type` live in POM `network_models/network_reductions.jl`; IOM keeps only the abstract `AbstractBranchReductionTracker`. IOM evaluators must be `<:IOM.AbstractEvaluator`; POM wraps PF models in `PowerFlowEvaluator` (`core/interfaces.jl`).
- **Parallel branches** between the same `(from_bus, to_bus)` pair are reduced to one equivalent branch by PowerNetworkMatrices **before** reaching POM. Index branch-pair-keyed variables (LPAC cosine vars, voltage approximations) by branch name directly — do not add dedupe bookkeeping; it's a non-problem at this layer.
- **Security-constrained N-1 uses MODF** (Modified Outage Distribution Factors: PNM `VirtualMODF`/`ContingencySpec`), in `ac_transmission_models/security_constrained_branch.jl`. The old LODF-based `network_models/security_constrained_models.jl` and all generator-side (G-1) SC have been **removed** — do not reintroduce LODF or gen-side MODF. `NetworkModel.MODF_matrix`, `DeviceModel.outages`, and `supports_outages` (default false; POM specializes `true` for `AbstractSecurityConstrainedStaticBranch`) live in IOM.
- **Units (IS4/psy6 rework) — the highest-risk silent-failure class.** The stateful `SYSTEM_BASE` normalization is gone (`temp_set_units_base_system!` is removed/commented out upstream). Every `PSY` getter read during model build must pass the intended unit system **explicitly**: optimization models are all system base, so use `PSY.SU`. PNM aggregators already return system base (no `PSY.SU` needed). If objective/limit/rating values come out wrong post-refactor, suspect units first. Known traps: AC apparent-power rating RHS must be squared `(rating·factor)^2`; PSY setters reject bare `Float64` under psy6 (`set_rating_b!(line, 0.9*PSY.SU)`).
- **psy6 is a planned breaking release:** no compat shims, no deprecation framing, no serialization aliases for renamed enums — fix callers instead. Old serialized systems are expected to be regenerated. Never touch changelogs (unmaintained since 1.0).
- **No mid-project Project.toml version/compat bumps.** `[sources]` currently pin git branches: IS→`IS4`, PSY/PNM→`psy6`, IOM→`main`. Do the version/compat pass once at release time, not during cross-repo co-dev. Do not copy PSI Project.toml version bumps when porting PRs.
- **Method ambiguity:** the codebase relies on extensive multiple dispatch — check with `Test.detect_ambiguities` when adding overlapping signatures. Use parametric `where` signatures with abstract bounds for extensibility.

## DecisionModel test API (PowerSystems 6, verified)

- Status: `IOM.ModelBuildStatus.BUILT`, `IOM.RunStatus.SUCCESSFULLY_FINALIZED` (not `_FINISHED`).
- Results: `res = IOM.OptimizationProblemOutputs(model)` (not `OptimizationProblemResults`); `read_variable(res, "VarType__DeviceType"; table_format = TableFormat.WIDE)`. Keys use `"__"` delimiter (e.g. `"FlowActivePowerVariable__Line"`, `"VoltageAngle__ACBus"`). Base power: `IOM.get_model_base_power(res)`.
- Units gotcha: `FlowActivePowerVariable` output is MW (natural units, `convert_output_to_natural_units=true`); `VoltageAngle` is unitless. Native DC ohm law (pu): `p_pu == -imag(get_series_admittance(line, PSY.SU)) * (va_from - va_to - shift)`.
- Template helper `get_thermal_dispatch_template_network(NetworkModel(<Formulation>))` and reduction kwargs `NetworkModel(DCPPowerModel; reduce_radial_branches=true, reduce_degree_two_branches=true)` come from `test/test_utils/`.
- Reduction test systems: `c_sys5`/`c_sys14` reduce nothing (assert build+solve only). Use `case11_network_reductions` (purpose-built ~4 series arcs) or matpower cases for real reductions — but those lack forecast data, so a full `DecisionModel` `build!` errors; for white-box reduction tests build `NetworkReductionData` directly via `PNM.Ybus(sys; network_reductions=[...])` + `deepcopy(PNM.get_network_reduction_data(ybus))`.

## Cross-package coupling (summary)

- **PowerSystems (PSY):** data structures (devices/services/networks) consumed by every formulation. psy6/IS4 units rework is in flight — see the units gotcha above.
- **InfrastructureOptimizationModels (IOM):** `OptimizationContainer`, `DecisionModel`/`EmulationModel`, settings, generic `add_*!`/store/objective infra. POM dispatches its problem-type chain on IOM abstracts. Watch for symbols moved POM-side by PR #104 / PNM-decoupling.
- **PowerNetworkMatrices (PNM):** PTDF/LODF/MODF, branch reductions, rating aggregators (system base). Reduction happens before POM sees branches.
- **InfrastructureSystems (IS):** key types, time series, units engine (`ISOPT` = `InfrastructureSystems.Optimization`). IS4 made units domain-agnostic (`relative_units`, `IS.convert_cost_coefficient`, `_unitful` getters).
- **PowerFlows (PFS):** optional weakdep, wired through `ext/PowerFlowsExt/` (power-flow-in-the-loop, headroom, signed-injection PF data update). Code must work when PF is not loaded.

## Debugging

- Debug logging: `ENV["SIIP_LOGGING_CONFIG"] = "debug"`; use `LOG_GROUP_*` constants for targeted output.
- Leave edits **unstaged** in the working tree (user reviews via plain `git diff`); use `git add -N` for new files so they show. Never `git commit` unless explicitly told.
