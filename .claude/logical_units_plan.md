# Logical Unit Formulations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Model `PSY.LogicalGenerationUnit` in POM with four formulations, `LogicalUnitBasicDispatch`, `LogicalUnitStandardDispatch`, `LogicalUnitBasicCommitment` and `LogicalUnitStandardCommitment`, that reuse the thermal math.

**Architecture:** The logical formulations get their own abstract type, `AbstractLogicalUnitFormulation`.
The thermal leaf methods (variable bounds, expressions, constraints, costs, initial conditions) dispatch on `(device <: PSY.ThermalGen, formulation <: AbstractThermal*)`.
Their bounds widen to unions that also admit logical units and logical formulations.
The thermal `construct_device!` bodies move into shared private helpers.
Thermal and logical constructors both call them, and the logical constructors live in `src/static_injector_models/logical_units.jl`.
Each logical formulation is checked against its thermal twin: the same system with every `ThermalStandard` replaced by an equivalent `LogicalGenerationUnit` must reach the same objective.

**Tech Stack:** Julia, JuMP, HiGHS, POM on IOM `main`, PSY `rh/logical-generation-unit` (`8b738ffb9`), PowerSystemCaseBuilder test systems.

**Spec:** Progress page https://claude.ai/artifact/F3NvWcTGm971JQhGXNukHh (part 2), plus these decisions from 2026-11-03.
Logical units are their own device type with their own formulations.
Four formulations mirror `ThermalBasicDispatch`, `ThermalStandardDispatch`, `ThermalBasicUnitCommitment` and `ThermalStandardUnitCommitment`.
They sit under their own abstract type, not under the thermal abstracts.
No exclusion rules and no links to physical units yet.

## Global Constraints

- Branch `rh/logical-units` from POM `origin/main` at `5f93b6a3`, worktree `/Users/rhenriqu/PSY6/PowerOperationsModels.jl-lgu`.
- Do not commit. Leave edits unstaged and run `git add -N` on new files, per `.claude/CLAUDE.md`.
- Every Julia command uses `--project=test`.
- Every PSY getter on a convertible field passes `u"SU"` (or `PSY.SU`), as the thermal code does.
- Run the formatter after every task: `julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'`.
- No version or compat bumps. The co-dev `[sources]` pins from Task 1 are reverted before any PR.
- New exported types need docstrings and an entry in `docs/src/reference/formulation_library.md`. Docs must build.
- `add_*!` methods end with a bare `return`.
- Do not change thermal behavior. Every existing test must keep passing.

## Review Focus

1. **Must-run logical units** (`commitment_mode = MUST_RUN`): no on, start or stop variables, and the same objective as a must-run `ThermalStandard`. Pinned in Task 5.
2. **Mixed systems:** `ThermalStandard` and `LogicalGenerationUnit` in one system, each with its own device model, build with no key collisions. Pinned in Task 5.
3. **A logical unit under a thermal formulation**, such as `DeviceModel(LogicalGenerationUnit, ThermalStandardUnitCommitment)`, must fail loudly at `build!`, not build an empty model. Pinned in Task 5.
4. **Per-hour limits:** a `max_active_power` time series mapped to `ActivePowerTimeSeriesParameter`, as ERCOTMarketParser's `thermal_device_model` does, adds `ActivePowerVariableTimeSeriesLimitsConstraint` for logical units. Pinned in Task 7.
5. **Missing optional data:** units with `ramp_limits = nothing` or `time_limits = nothing` under the Standard formulations build and solve, as thermal units do. Pinned in Tasks 5 and 6.

---

### Task 1: Co-dev environment

**Files:**
- Create: `/Users/rhenriqu/PSY6/PowerOpenAPIModels-lgu` (git worktree, local branch `rh/logical-generation-unit`, never pushed)
- Modify: `test/Project.toml` (`[sources]`, and `[deps]` if `PowerOperationsOpenAPIModels` is missing)

**Interfaces:**
- Produces: a test environment where `PSY.LogicalGenerationUnit` exists.

- [ ] **Step 1: Create the bindings worktree.**
  From `/Users/rhenriqu/PSY6/PowerOpenAPIModels`, run `git worktree add -b rh/logical-generation-unit ../PowerOpenAPIModels-lgu origin/main`.
  Then run `make generate SCHEMA_DIR=/Users/rhenriqu/PSY6/SiennaSchemas-lgu` with Julia 1.13 on `PATH` (`/Applications/Julia-1.13.app/Contents/Resources/julia/bin`).
  Expected: only `PowerOperationsOpenAPIModels.jl` changes (`LogicalGenerationUnit` model files, `register.jl`, `units.jl`, the module file).
  Commit locally: `git commit -am "Regenerate for LogicalGenerationUnit (co-dev only)"` after `git add -A`.
- [ ] **Step 2: Pin the test environment.**
  In `test/Project.toml` `[sources]`, set `PowerSystems = {path = "../../PowerSystems.jl-lgu"}`.
  Add `PowerOperationsOpenAPIModels = {path = "../../PowerOpenAPIModels-lgu/PowerOperationsOpenAPIModels.jl"}`, with its UUID `a372b6d7-45a2-44c2-8199-6a724b72e8ff` under `[deps]` if absent.
  Mark both lines with `# co-dev pin: revert before PR`.
- [ ] **Step 3: Verify.**
  Run: `julia --project=test -e 'using Pkg; Pkg.instantiate(); using PowerOperationsModels; const PSY = PowerOperationsModels.PSY; @assert isdefined(PSY, :LogicalGenerationUnit); println("ok")'`
  Expected: `ok`.

### Task 2: Formulation types and union aliases

**Files:**
- Modify: `src/core/formulations.jl` (after the thermal formulations, line 57)
- Modify: `src/PowerOperationsModels.jl` (exports, next to the thermal formulation exports)
- Modify: `docs/src/reference/formulation_library.md` (abstract-type table near line 524, formulation table near line 534)
- Test: `test/test_logical_unit_constructors.jl`

**Interfaces:**
- Produces, exported:
  `abstract type AbstractLogicalUnitFormulation <: AbstractDeviceFormulation`,
  `abstract type AbstractLogicalUnitDispatch <: AbstractLogicalUnitFormulation`,
  `abstract type AbstractLogicalUnitCommitment <: AbstractLogicalUnitFormulation`,
  `struct LogicalUnitBasicDispatch <: AbstractLogicalUnitDispatch`,
  `struct LogicalUnitStandardDispatch <: AbstractLogicalUnitDispatch`,
  `struct LogicalUnitBasicCommitment <: AbstractLogicalUnitCommitment`,
  `struct LogicalUnitStandardCommitment <: AbstractLogicalUnitCommitment`.
- Produces, not exported:
  `const ThermalOrLogicalUnit = Union{PSY.ThermalGen, PSY.LogicalGenerationUnit}`,
  `const ThermalOrLogicalFormulation = Union{AbstractThermalFormulation, AbstractLogicalUnitFormulation}`,
  `const ThermalOrLogicalCommitment = Union{AbstractThermalUnitCommitment, AbstractLogicalUnitCommitment}`,
  `const ThermalOrLogicalDispatch = Union{AbstractThermalDispatchFormulation, AbstractLogicalUnitDispatch}`.

- [ ] **Step 1: Write the failing test.**

```julia
@testset "Logical unit formulation types" begin
    @test LogicalUnitBasicDispatch <: AbstractLogicalUnitDispatch
    @test LogicalUnitStandardDispatch <: AbstractLogicalUnitDispatch
    @test LogicalUnitBasicCommitment <: AbstractLogicalUnitCommitment
    @test LogicalUnitStandardCommitment <: AbstractLogicalUnitCommitment
    @test !(LogicalUnitStandardCommitment <: AbstractThermalFormulation)
    @test PSY.LogicalGenerationUnit <: PowerOperationsModels.ThermalOrLogicalUnit
end
```

- [ ] **Step 2: Run it and see it fail.** `julia --project=test test/runtests.jl test_logical_unit` fails with `UndefVarError: LogicalUnitBasicDispatch`.
- [ ] **Step 3: Add the types, aliases, exports and docstrings.** Each docstring names its thermal twin, for example "`ThermalStandardUnitCommitment` for `PSY.LogicalGenerationUnit`".
- [ ] **Step 4: Run it and see it pass.** Same command, PASS.
- [ ] **Step 5: Formatter, then `git add -N test/test_logical_unit_constructors.jl`.**

### Task 3: Widen the thermal leaf methods

A pure signature change: no new behavior and no thermal change.

**Files (signatures only):**
`src/static_injector_models/thermal_generation.jl`,
`src/static_injector_models/thermalgeneration_constructor.jl` (only `_handle_common_thermal_parameters!` and `_has_ramp_and_duration_constraints`),
`src/common_models/add_to_expression.jl`, `src/common_models/min_active_power.jl`, `src/common_models/objective_function.jl`, `src/common_models/add_parameters.jl`, `src/common_models/add_expressions.jl`,
`src/services_models/reserves.jl`, `src/initial_conditions/device_initial_conditions.jl`, `src/event_models/event_constraints.jl`, `src/utils/psy_utils.jl`, `src/operation/parameter_time_series_store.jl`.

**Interfaces:**
- Consumes: the Task 2 aliases.
- Produces: every leaf method a thermal constructor reaches also accepts `PSY.LogicalGenerationUnit` with an `AbstractLogicalUnitFormulation`.

**Rule, in method signatures and `where` clauses only:**

| Replace | With |
|:-- |:-- |
| `PSY.ThermalGen` | `ThermalOrLogicalUnit` |
| `AbstractThermalFormulation` | `ThermalOrLogicalFormulation` |
| `AbstractThermalUnitCommitment` | `ThermalOrLogicalCommitment` |
| `AbstractThermalDispatchFormulation` | `ThermalOrLogicalDispatch` |

**Keep unchanged:**
- Every thermal `construct_device!` signature. Logical units build only through `logical_units.jl`.
- `get_initial_conditions_device_model` for thermal (`thermal_generation.jl:214-240`). It returns thermal formulations, and Task 5 adds the logical ones.
- The `requires_initialization` lines (`thermal_generation.jl:30-35`).
- Bounds on concrete thermal formulations or the Compact, NoMin and MultiStart abstracts.
- `src/core/formulations.jl` definitions and the export list.

- [ ] **Step 1: Apply the rule.** Afterwards, `grep -rn "PSY.ThermalGen\b" src` lists only `construct_device!` and `get_initial_conditions_device_model` signatures.
- [ ] **Step 2: Check for ambiguities.**
  Run: `julia --project=test -e 'using PowerOperationsModels, Test; a = Test.detect_ambiguities(PowerOperationsModels); println(length(a))'`
  Expected: the same count as on `origin/main` (record the baseline before Step 1).
- [ ] **Step 3: Thermal regression.**
  Run: `julia --project=test test/runtests.jl test_device_thermal test_market_bid test_min_active_power test_initial_conditions test_services test_events test_aqua`
  Expected: all PASS.
- [ ] **Step 4: Formatter.**

### Task 4: Move the thermal constructor bodies into shared helpers

A pure refactor: the thermal `construct_device!` methods keep their signatures and become one-line calls.

**Files:**
- Modify: `src/static_injector_models/thermalgeneration_constructor.jl`

**Interfaces:**
- Produces, each with two methods, `NetworkModel{<:AbstractNetworkModel}` and `NetworkModel{<:AbstractActivePowerModel}`, holding the moved bodies verbatim:
  - `_add_commitment_arguments!(container, devices, device_model::DeviceModel{T, D}, network_model) where {T, D}`: today's body at lines 97-217 and 328-435.
  - `_add_commitment_constraints!(container, sys, devices, device_model::DeviceModel{T, D}, network_model) where {T, D}`: lines 227-323 and 436-515.
  - `_add_standard_dispatch_arguments!` and `_add_standard_dispatch_constraints!`: lines 516-662 and 663-783.
  - `_add_dispatch_arguments!` and `_add_dispatch_constraints!`: lines 784-924 and 925-1040.
- Inside the helpers, the formulation type comes from `D`, where the bodies use `D`, `U` or a literal `ThermalStandardDispatch` today.
  Example: `add_variables!(container, ActivePowerVariable, devices, D, ...)` and `initial_conditions!(container, devices, D())`.
- Each helper ends with a bare `return`.

- [ ] **Step 1: Move the bodies.**
- [ ] **Step 2: Thermal regression.** Run the same command as Task 3, Step 3. Expected: all PASS.
- [ ] **Step 3: Formatter.**

### Task 5: Logical unit commitment (Basic and Standard)

**Files:**
- Create: `src/static_injector_models/logical_units.jl`, included from `src/PowerOperationsModels.jl` right after `thermalgeneration_constructor.jl`
- Create: `test/test_utils/logical_unit_systems.jl`, included from `test/includes.jl` next to the other `test_utils` includes
- Test: `test/test_logical_unit_constructors.jl`

**Interfaces:**
- Consumes: Task 4 helpers, Task 2 types.
- Produces, in `logical_units.jl`:
  - `construct_device!(container, sys, ::ArgumentConstructStage, model::DeviceModel{PSY.LogicalGenerationUnit, D}, network_model::NetworkModel{<:AbstractNetworkModel}) where {D <: AbstractLogicalUnitCommitment}`, calling `_add_commitment_arguments!`.
  - The `ModelConstructStage` method, calling `_add_commitment_constraints!`.
  - `_has_ramp_and_duration_constraints(::Type{LogicalUnitBasicCommitment}) = false`.
  - `requires_initialization(::LogicalUnitStandardCommitment) = true` and `requires_initialization(::LogicalUnitBasicCommitment) = false`.
  - `initial_conditions!(container, devices::Vector{PSY.LogicalGenerationUnit}, formulation::LogicalUnitBasicCommitment)`, mirroring `thermal_generation.jl:943-952`.
  - `get_initial_conditions_device_model(::IOM.AbstractOptimizationModel, ::DeviceModel{PSY.LogicalGenerationUnit, <:AbstractLogicalUnitCommitment})`, returning `DeviceModel(PSY.LogicalGenerationUnit, LogicalUnitBasicCommitment)`.
- Produces, in `test/test_utils/logical_unit_systems.jl`:
  - `replace_thermals_with_logical_units!(sys::PSY.System; names = nothing) -> PSY.System`, where `names` limits the conversion to those unit names.
    Each `ThermalStandard` becomes a `LogicalGenerationUnit` with the same name, bus, limits, ramps, time limits, `status`, `time_at_status`, `commitment_mode`, `operation_cost`, `base_power`, services and time series.
    Use `start_types = 1`, `prime_mover_type = PrimeMovers.CC`, and `nothing` for `power_trajectory` and `start_time_limits`.
  - `logical_unit_objective(sys, ::Type{F}; network = CopperPlateNetworkModel) -> Float64`.
    Builds `get_thermal_dispatch_template_network(network)` with `LogicalGenerationUnit => F` in place of the `ThermalStandard` model, builds and solves with `HiGHS_optimizer`, and returns `IOM.get_optimization_container(model).optimizer_stats.objective_value`.
  - `thermal_objective(sys, ::Type{F}; network = CopperPlateNetworkModel) -> Float64`, the same for `ThermalStandard => F`.

- [ ] **Step 1: Write the failing tests.**

```julia
@testset "Logical unit commitment matches its thermal twin" begin
    for (lf, tf) in ((LogicalUnitBasicCommitment, ThermalBasicUnitCommitment),
                     (LogicalUnitStandardCommitment, ThermalStandardUnitCommitment)),
        network in (CopperPlateNetworkModel, PTDFNetworkModel)
        thermal = PSB.build_system(PSITestSystems, "c_sys5_uc")
        logical = replace_thermals_with_logical_units!(PSB.build_system(PSITestSystems, "c_sys5_uc"))
        @test isempty(PSY.get_components(PSY.ThermalStandard, logical))
        @test logical_unit_objective(logical, lf; network) ≈ thermal_objective(thermal, tf; network) rtol = 1e-6
    end
end

@testset "Must-run and missing ramps match thermal" begin
    thermal = PSB.build_system(PSITestSystems, "c_sys5_uc")
    first_unit = first(PSY.get_components(PSY.ThermalStandard, thermal))
    PSY.set_commitment_mode!(first_unit, PSY.CommitmentModes.MUST_RUN)
    PSY.set_ramp_limits!(first_unit, nothing)
    logical = replace_thermals_with_logical_units!(deepcopy(thermal))
    @test logical_unit_objective(logical, LogicalUnitStandardCommitment) ≈
          thermal_objective(thermal, ThermalStandardUnitCommitment) rtol = 1e-6
end

@testset "Logical units next to thermal units" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    # Convert two of the five units; the rest stay ThermalStandard.
    # Build with both device models set; expect BUILT and both
    # OnVariable__ThermalStandard and OnVariable__LogicalGenerationUnit in the container.
end

@testset "A thermal formulation on logical units fails loudly" begin
    logical = replace_thermals_with_logical_units!(PSB.build_system(PSITestSystems, "c_sys5_uc"))
    # Template with DeviceModel(PSY.LogicalGenerationUnit, ThermalStandardUnitCommitment).
    # Expect build! to not return IOM.ModelBuildStatus.BUILT.
end
```

  The mixed-system test converts the units named `"Alta"` and `"Brighton"` with a `names` keyword on `replace_thermals_with_logical_units!` (default: every `ThermalStandard`).
  It asserts on `IOM.VariableKey(OnVariable, PSY.ThermalStandard)` and `IOM.VariableKey(OnVariable, PSY.LogicalGenerationUnit)`.
  The last test checks the build status, not a specific exception, because POM logs build errors to `operation_problem.log`.

- [ ] **Step 2: Run them and see them fail.** `julia --project=test test/runtests.jl test_logical_unit` fails with a `MethodError` for `construct_device!` on `LogicalGenerationUnit`.
- [ ] **Step 3: Write `logical_units.jl` and the test utilities.**
- [ ] **Step 4: Run them and see them pass.** Same command, all PASS.
- [ ] **Step 5: Formatter, then `git add -N` the new files.**

### Task 6: Logical unit dispatch (Basic and Standard)

**Files:**
- Modify: `src/static_injector_models/logical_units.jl`
- Test: `test/test_logical_unit_constructors.jl`

**Interfaces:**
- Consumes: Task 4 dispatch helpers, Task 5 test utilities.
- Produces:
  - `construct_device!` for both stages on `DeviceModel{PSY.LogicalGenerationUnit, LogicalUnitBasicDispatch}` (calls `_add_dispatch_*!`) and `DeviceModel{PSY.LogicalGenerationUnit, LogicalUnitStandardDispatch}` (calls `_add_standard_dispatch_*!`), for any `AbstractNetworkModel`.
  - `requires_initialization(::LogicalUnitStandardDispatch) = true` and `requires_initialization(::LogicalUnitBasicDispatch) = false`.
  - `get_initial_conditions_device_model` for `<:AbstractLogicalUnitDispatch`: `LogicalUnitBasicCommitment` when `supports_milp(get_optimization_container(model))`, else `LogicalUnitBasicDispatch`, as `thermal_generation.jl:214-224` does.

- [ ] **Step 1: Write the failing test.**

```julia
@testset "Logical unit dispatch matches its thermal twin" begin
    for (lf, tf) in ((LogicalUnitBasicDispatch, ThermalBasicDispatch),
                     (LogicalUnitStandardDispatch, ThermalStandardDispatch)),
        network in (CopperPlateNetworkModel, PTDFNetworkModel)
        thermal = PSB.build_system(PSITestSystems, "c_sys5_uc")
        logical = replace_thermals_with_logical_units!(PSB.build_system(PSITestSystems, "c_sys5_uc"))
        @test logical_unit_objective(logical, lf; network) ≈ thermal_objective(thermal, tf; network) rtol = 1e-6
    end
end
```

  Add a case with `ramp_limits = nothing` on one unit under `LogicalUnitStandardDispatch`.
- [ ] **Step 2: Run it and see it fail.** `MethodError` for `construct_device!`.
- [ ] **Step 3: Add the methods.**
- [ ] **Step 4: Run it and see it pass.**
- [ ] **Step 5: Formatter.**

### Task 7: Market offers, per-hour limits and reserves

ERCOT logical units carry `MarketBidCost` offers with hot, warm and cold start costs, per-hour limits and reserve offers.

**Files:**
- Modify: `src/common_models/market_bid_overrides.jl:77-95`. Widen `PSY.ThermalMultiStart` to `Union{PSY.ThermalMultiStart, PSY.LogicalGenerationUnit}` in `_validate_startup_eltype`.
- Test: `test/test_logical_unit_constructors.jl`

**Interfaces:**
- Consumes: `add_mbc!` and `extend_mbc!` from `test/test_utils/add_market_bid_cost.jl`, and the Task 5 utilities.

- [ ] **Step 1: Write the failing tests.**
  - `"Logical units with MarketBidCost match thermal"`:
    Put the same market bid on both systems with the existing `add_mbc!` helper.
    Expect the same objective (rtol 1e-6) for `LogicalUnitStandardCommitment` and `ThermalStandardUnitCommitment`.
  - `"Startup stages on logical units do not warn"`:
    A `MarketBidCost` whose `start_up` is a `(hot, warm, cold)` tuple.
    Expect no `_validate_startup_eltype` warning in `operation_problem.log`.
  - `"Per-hour max power on logical units"`:
    Attach a `max_active_power` series to each logical unit, and map `ActivePowerTimeSeriesParameter => "max_active_power"` in the device model.
    Expect `IOM.ConstraintKey(ActivePowerVariableTimeSeriesLimitsConstraint, PSY.LogicalGenerationUnit, "ub")` in the built container.
  - `"Logical units provide reserves"`:
    On `PSB.build_system(PSITestSystems, "c_sys5_uc"; add_reserves = true)`, add `ServiceModel(OnlineReserve{ReserveUp}, RangeReserve; use_slacks = true)` to both templates, as `test/test_services_constructor.jl:75-84` does.
    `replace_thermals_with_logical_units!` must carry each unit's services.
    Expect the same objective as the thermal twin (rtol 1e-6).
- [ ] **Step 2: Run them and see the startup-stage test fail.** The other tests may already pass after Task 3.
- [ ] **Step 3: Widen `_validate_startup_eltype`.**
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Formatter.**

### Task 8: Full verification

- [ ] **Step 1: Full suite.** `julia --project=test test/runtests.jl --jobs=8`. Expected: all PASS.
- [ ] **Step 2: Ambiguities.** Same count as the Task 3 baseline.
- [ ] **Step 3: Docs.** `julia --project=docs docs/make.jl` builds with the four formulations listed.
- [ ] **Step 4: Formatter.** No diff after running it.
- [ ] **Step 5: Report.** List the unstaged files, and note that the Task 1 pins must be reverted before a PR, once PSY and the 0.4.1 bindings are released.
