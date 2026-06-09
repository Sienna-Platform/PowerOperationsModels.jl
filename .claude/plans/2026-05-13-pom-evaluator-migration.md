# POM Migration to IOM EvaluationContainer Abstraction

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate POM's PowerFlows extension off the soon-to-be-removed `AbstractPowerFlowEvaluationModel` / `AbstractPowerFlowEvaluationData` / `solve_power_flow!` / `get_power_flow_data` / `power_flow_evaluation_data` API in IOM, onto the new generic `AbstractEvaluator` / `AbstractEvaluationData` / `EvaluationContainer` abstraction. Make the PowerFlow evaluator behave as a single, self-contained object whose lifetime, state, and methods all live in POM (with PFS supplied as the concrete `evaluator` config).

**Architecture:** IOM is concurrently dropping the PowerFlows-specific shims (`AbstractPowerFlowEvaluationModel`, `solve_power_flow!`, `power_flow_evaluation_data` field) in favor of a generic `EvaluationContainer` holding two parallel dicts keyed by concrete evaluator type: `evaluators::Dict{DataType, Any}` (configs — currently `Dict{DataType, AbstractEvaluator}` in IOM; see Task 1's loosening) and `evaluation_data::Dict{DataType, AbstractEvaluationData}` (runtime state). On the NetworkModel side the user registers an evaluator config (e.g. `PFS.PTDFDCPowerFlow()`) keyed by its abstract supertype `PFS.PowerFlowEvaluationModel`. On the OptimizationContainer side, POM's PowerFlowsExt populates `evaluation_data[PFS.PowerFlowEvaluationModel] = PowerFlowEvaluationData(...)` during build. IOM's generic `calculate_aux_variables!` calls `evaluate!(data, container, system)` per registered entry. POM provides the concrete `evaluate!` / `reset!` / `is_solved` / `get_inner_data` / `initialize_evaluation_data` methods.

The evaluator config (`PFS.PowerFlowEvaluationModel` subtree) is **used directly** — POM does **not** wrap it in a new struct. The container's `evaluators` dict has its value-type loosened in IOM (`Dict{DataType, Any}`) so the foreign type fits without modifying PFS. Only the runtime `AbstractEvaluationData` side is subtyped by POM's `PowerFlowEvaluationData`.

**Tech Stack:** Julia 1.10+, InfrastructureOptimizationModels.jl (working tree under `../InfrastructureOptimizationModels.jl`, branch `ac/psi-costexp-parambroad-pfslack`), InfrastructureSystems.jl, PowerFlows.jl (weak dep via `PowerFlowsExt`), JuMP, HiGHS (test), Ipopt (test).

**Pre-flight:** The IOM working tree at `/Users/jlara/cache/InfrastructureOptimizationModels.jl` has uncommitted changes implementing the new abstraction. Plan must consume those. The local clone at `PowerOperationsModels.jl/InfrastructureOptimizationModels.jl/` is stale (at `e19f4a1`); the sibling tree is at `033363e` plus uncommitted diff. Resolution: dev-dev the sibling tree into POM (Task 0) so changes are visible to POM tests.

---

## File Structure

Files to create / modify in POM (no new files; this is a renaming + retypification refactor):

| File | Responsibility | Change |
|---|---|---|
| `Project.toml` / `Manifest.toml` | Pin IOM to local working tree | Dev-dev `../InfrastructureOptimizationModels.jl` |
| `src/PowerOperationsModels.jl` | Top-level imports/exports | Replace `is_from_power_flow` with `is_from_evaluator` |
| `src/core/auxiliary_variables.jl` | PF aux-var trait override | Rename `is_from_power_flow` → `is_from_evaluator` |
| `src/core/interfaces.jl` | Fallback for `add_power_flow_data!` | Rewrite signature against `EvaluationContainer`; new name `register_evaluator_data!` |
| `src/initial_conditions/initialization.jl` | Reset evaluator vector on IC sub-template | Use `IOM.EvaluationContainer()` instead of `AbstractPowerFlowEvaluationModel[]` |
| `src/operation/build_problem.jl` | Build pipeline entry to PF data init | Call `register_evaluator_data!` on the new container |
| `ext/PowerFlowsExt/PowerFlowsExt.jl` | Extension imports + `PowerFlowEvaluationData` struct | Subtype `IOM.AbstractEvaluationData`; drop removed imports; add accessor methods |
| `ext/PowerFlowsExt/pf_input_mapping.jl` | Build PF data + aux var containers + input map | Replace `container.power_flow_evaluation_data = ...` with `IOM.add_evaluation_data!(...)`. Iterate IOM evaluators dict. |
| `ext/PowerFlowsExt/pf_solve_and_aux.jl` | `solve_power_flow!`, `latest_solved_power_flow_evaluation_data`, aux-var calculators | Rename `solve_power_flow!` → `evaluate!`. Read from `IOM.get_evaluation_data(IOM.get_evaluations(container))`. Replace `get_power_flow_data` calls with `IOM.get_inner_data`. |
| `ext/PowerFlowsExt/pf_data_update.jl` | Update PF data from container values | Replace `get_power_flow_data` calls with `IOM.get_inner_data` |
| `ext/PowerFlowsExt/pf_headroom.jl` | Headroom-proportional slack accumulator | No surface change beyond what callers pass — already takes `pf_data` directly |
| `test/test_power_flow_in_the_loop.jl` | PF-in-the-loop integration tests | Replace `get_power_flow_evaluation_data(container)` and `get_power_flow_data(...)` with new accessors |
| `../InfrastructureOptimizationModels.jl/src/core/external_evaluation.jl` | IOM dict typing | One-line loosening to accept foreign-typed evaluator configs (see Task 1) |

**Out of scope** (handled by the in-progress IOM refactor or by Plan 2):
- IOM internal renames (`pf_aux_var_keys` → `evaluator_aux_var_keys`, `power_flow_evaluation` field → `evaluations`, `is_from_power_flow` → `is_from_evaluator`)
- `AbstractPowerFlowEvaluationModel`/`AbstractPowerFlowEvaluationData` deletion from `InfrastructureSystems.jl`
- Active-power in/out variable wiring through PF (Plan 2)

---

## Task 0: Dev-dev sibling IOM into POM

**Files:**
- Modify: `Project.toml` (no — done via Pkg)
- Modify: `Manifest.toml` (no — done via Pkg)

- [ ] **Step 1: Dev-dev sibling IOM**

Run from the POM working tree:

```bash
julia --project=. -e 'using Pkg; Pkg.develop(path="/Users/jlara/cache/InfrastructureOptimizationModels.jl")'
```

Expected: Pkg resolves successfully and rewrites `Manifest.toml`. If IOM's sibling tree itself has unresolved deps (e.g. its own `InfrastructureSystems.jl` working tree), `Pkg.develop(path=...)` those too.

- [ ] **Step 2: Verify the dev pin landed**

```bash
julia --project=. -e 'using Pkg; Pkg.status("InfrastructureOptimizationModels")'
```

Expected output includes a line like:

```
[bed98974] InfrastructureOptimizationModels v0.1.0 `~/cache/InfrastructureOptimizationModels.jl`
```

- [ ] **Step 3: Sanity-load POM (expect compile errors)**

```bash
julia --project=. -e 'using PowerOperationsModels' 2>&1 | tail -20
```

Expected: at least one error about an undefined symbol such as `AbstractPowerFlowEvaluationModel`, `is_from_power_flow`, `solve_power_flow!`, `get_power_flow_evaluation_data`. These errors are the starting work for the rest of the plan; don't fix them here.

- [ ] **Step 4: Stage and commit (no remote push)**

```bash
git add Project.toml Manifest.toml
git status --short
```

(per CLAUDE.md — never commit unless asked. Just stage.)

---

## Task 1: Loosen IOM evaluator-dict value type (one-line patch in IOM working tree)

**Files:**
- Modify: `/Users/jlara/cache/InfrastructureOptimizationModels.jl/src/core/external_evaluation.jl` (current lines 35-45, 47)

**Why this is in POM's plan:** the user chose to store `PFS.PowerFlowEvaluationModel` instances **directly** (no POM wrapper). PFS does not subtype `IOM.AbstractEvaluator`. To make the type fit, IOM's `EvaluationContainer.evaluators` field must accept `Any` on the value side. The data-side dict (`Dict{DataType, AbstractEvaluationData}`) keeps its tight typing because POM's `PowerFlowEvaluationData <: IOM.AbstractEvaluationData`.

- [ ] **Step 1: Open the file and locate the field**

Read `/Users/jlara/cache/InfrastructureOptimizationModels.jl/src/core/external_evaluation.jl` lines 35-50. Confirm the struct definition matches:

```julia
mutable struct EvaluationContainer
    evaluators::Dict{DataType, AbstractEvaluator}
    evaluation_data::Dict{DataType, AbstractEvaluationData}
end
```

- [ ] **Step 2: Loosen the evaluators-dict value type**

Edit the struct and the constructor body:

```julia
mutable struct EvaluationContainer
    evaluators::Dict{DataType, Any}
    evaluation_data::Dict{DataType, AbstractEvaluationData}
end

function EvaluationContainer()
    return EvaluationContainer(
        Dict{DataType, Any}(),
        Dict{DataType, AbstractEvaluationData}(),
    )
end
```

Also update `add_evaluator!`:

```julia
add_evaluator!(ec::EvaluationContainer, T::DataType, ev) = (ec.evaluators[T] = ev)
```

(drop the `::AbstractEvaluator` annotation on the third arg).

- [ ] **Step 3: Verify IOM still compiles**

```bash
julia --project=/Users/jlara/cache/InfrastructureOptimizationModels.jl -e 'using InfrastructureOptimizationModels'
```

Expected: clean precompile, no errors.

- [ ] **Step 4: Stage in IOM tree**

```bash
git -C /Users/jlara/cache/InfrastructureOptimizationModels.jl add src/core/external_evaluation.jl
```

---

## Task 2: Rename `is_from_power_flow` → `is_from_evaluator` in POM core

**Files:**
- Modify: `src/PowerOperationsModels.jl:125`
- Modify: `src/core/auxiliary_variables.jl:91-93`

- [ ] **Step 1: Update POM's IOM-import block**

In `src/PowerOperationsModels.jl`, find line 125 (inside the `import InfrastructureOptimizationModels: ...` block):

```julia
    calculate_aux_variable_value!,
    is_from_power_flow,
```

Change to:

```julia
    calculate_aux_variable_value!,
    is_from_evaluator,
```

- [ ] **Step 2: Update the POM trait override**

In `src/core/auxiliary_variables.jl` around lines 89-93, find:

```julia
"Whether the auxiliary variable is calculated using a `PowerFlowEvaluationModel`"
# Default is_from_power_flow(::Type{<:AuxVariableType}) = false is in IOM interfaces.jl
is_from_power_flow(::Type{<:PowerFlowAuxVariableType}) = true
```

Change to:

```julia
"Whether the auxiliary variable is calculated using an external evaluator (e.g. a `PFS.PowerFlowEvaluationModel`)"
# Default is_from_evaluator(::Type{<:AuxVariableType}) = false is in IOM common_models/interfaces.jl
is_from_evaluator(::Type{<:PowerFlowAuxVariableType}) = true
```

- [ ] **Step 3: Compile-check**

```bash
julia --project=. -e 'using PowerOperationsModels' 2>&1 | tail -15
```

Expected: now errors about `AbstractPowerFlowEvaluationModel`, `solve_power_flow!`, or `get_power_flow_evaluation_data` — but NOT about `is_from_power_flow`. If `is_from_power_flow` is still mentioned, grep again and fix.

```bash
grep -rn "is_from_power_flow" src/ ext/ test/
```

Expected: zero matches.

- [ ] **Step 4: Stage**

```bash
git add src/PowerOperationsModels.jl src/core/auxiliary_variables.jl
```

---

## Task 3: Rewrite the `add_power_flow_data!` POM-core fallback against `EvaluationContainer`

**Files:**
- Modify: `src/core/interfaces.jl:146-162`

This file holds the no-PFS-loaded fallback. After this task it will:
- Be renamed `register_evaluator_data!`
- Accept an `IOM.EvaluationContainer` (the one held by the NetworkModel)
- Error only if the container is non-empty AND no concrete `initialize_evaluation_data` method exists for any registered evaluator

- [ ] **Step 1: Replace the fallback**

In `src/core/interfaces.jl`, find lines 146-162:

```julia
"""
Default fallback for `add_power_flow_data!`: a no-op when no evaluators are present.
The PowerFlows extension provides the concrete method that handles real evaluators.
If evaluators are passed without the PowerFlows extension loaded, this errors with
guidance to load it.
"""
function add_power_flow_data!(
    ::IOM.OptimizationContainer,
    evaluators::Vector{<:IOM.AbstractPowerFlowEvaluationModel},
    ::IS.ComponentContainer,
)
    isempty(evaluators) || error(
        "PowerFlows extension not loaded; add `using PowerFlows` to enable " *
        "power flow in-the-loop.",
    )
    return
end
```

Replace with:

```julia
"""
Default fallback for `register_evaluator_data!`: a no-op when the network model
has no evaluators registered. The PowerFlows extension provides the concrete
method that handles `PFS.PowerFlowEvaluationModel` evaluators. If evaluators are
registered but no extension method matches, this errors with guidance.
"""
function register_evaluator_data!(
    container::IOM.OptimizationContainer,
    evaluations::IOM.EvaluationContainer,
    ::IS.ComponentContainer,
)
    isempty(evaluations) && return
    error(
        "Evaluators registered on the NetworkModel ($(collect(keys(IOM.get_evaluators(evaluations))))) " *
        "but no matching `register_evaluator_data!` extension method is loaded. " *
        "If these are `PFS.PowerFlowEvaluationModel` subtypes, add `using PowerFlows` " *
        "before building the model.",
    )
end
```

- [ ] **Step 2: Compile-check** (will still error on other call sites)

```bash
julia --project=. -e 'using PowerOperationsModels' 2>&1 | tail -10
```

Expected: errors now about `add_power_flow_data!` call site in `build_problem.jl` and/or `AbstractPowerFlowEvaluationModel` in `initialization.jl`. The interfaces.jl rewrite itself should not be flagged.

- [ ] **Step 3: Stage**

```bash
git add src/core/interfaces.jl
```

---

## Task 4: Update `build_problem.jl` to route through the new API

**Files:**
- Modify: `src/operation/build_problem.jl:156-162`

The build pipeline currently calls `add_power_flow_data!(container, get_power_flow_evaluation(transmission_model), sys)`. After IOM's rename, `get_power_flow_evaluation` is gone; the replacement is `IOM.get_evaluations(transmission_model)` which returns an `EvaluationContainer`.

- [ ] **Step 1: Swap the build-time call**

In `src/operation/build_problem.jl` lines 156-162, find:

```julia
    TimerOutputs.@timeit BUILD_PROBLEMS_TIMER "Power Flow Initialization" begin
        add_power_flow_data!(
            container,
            get_power_flow_evaluation(transmission_model),
            sys,
        )
    end
```

Replace with:

```julia
    TimerOutputs.@timeit BUILD_PROBLEMS_TIMER "External Evaluator Initialization" begin
        # Wire the OptimizationContainer's evaluations field to the same
        # EvaluationContainer instance held by the NetworkModel, then let the
        # PowerFlows extension (or any other registered evaluator extension)
        # initialize each evaluator's runtime data.
        evaluations = IOM.get_evaluations(transmission_model)
        container.evaluations = evaluations
        register_evaluator_data!(container, evaluations, sys)
    end
```

- [ ] **Step 2: Compile-check**

```bash
julia --project=. -e 'using PowerOperationsModels' 2>&1 | tail -10
```

Expected: errors should now be confined to `initialization.jl` (uses `AbstractPowerFlowEvaluationModel`) and the PowerFlowsExt files.

- [ ] **Step 3: Stage**

```bash
git add src/operation/build_problem.jl
```

---

## Task 5: Update `initial_conditions/initialization.jl` to use the new field name

**Files:**
- Modify: `src/initial_conditions/initialization.jl:20-21`

- [ ] **Step 1: Swap the IC sub-template wiring**

In `src/initial_conditions/initialization.jl` lines 20-21, find:

```julia
    # Initialization does not support PowerFlow evaluation - use empty vector
    network_model.power_flow_evaluation = AbstractPowerFlowEvaluationModel[]
```

Replace with:

```julia
    # Initialization does not support evaluator-coupled aux vars — use an empty container.
    network_model.evaluations = IOM.EvaluationContainer()
```

- [ ] **Step 2: Compile-check**

```bash
julia --project=. -e 'using PowerOperationsModels' 2>&1 | tail -10
```

Expected: POM core compiles cleanly. Remaining errors should all be inside `PowerFlowsExt` (deferred — only triggers when `using PowerFlows` is loaded).

- [ ] **Step 3: Stage**

```bash
git add src/initial_conditions/initialization.jl
```

---

## Task 6: Rebuild `PowerFlowsExt.jl` for the new IOM interface

**Files:**
- Modify: `ext/PowerFlowsExt/PowerFlowsExt.jl` (full file, 95 lines)

This file declares the extension's imports and the `PowerFlowEvaluationData` struct. Five things change:
1. Drop the import of `AbstractPowerFlowEvaluationData` (gone from IOM).
2. Drop the import of `get_power_flow_evaluation_data` (gone from IOM).
3. Drop `import IOM: solve_power_flow!, get_power_flow_data` (gone from IOM).
4. Change the supertype on `PowerFlowEvaluationData` to `IOM.AbstractEvaluationData`.
5. Add new accessors: `IOM.is_solved`, `IOM.reset!`, `IOM.get_inner_data` on `PowerFlowEvaluationData`. Also define `IOM.initialize_evaluation_data(::PFS.PowerFlowEvaluationModel, container, system)` — see Task 7 for its body; declare the import here.

- [ ] **Step 1: Rewrite the imports block**

In `ext/PowerFlowsExt/PowerFlowsExt.jl` lines 14-39, find the `using InfrastructureOptimizationModels: ...` block plus the `import InfrastructureOptimizationModels: solve_power_flow!, get_power_flow_data` line. Replace the entire block with:

```julia
using InfrastructureOptimizationModels:
    OptimizationContainer,
    OptimizationContainerKey,
    AbstractEvaluationData,
    VariableKey,
    ParameterKey,
    AuxVarKey,
    AuxVariableType,
    add_aux_variable_container!,
    lookup_value,
    has_container_key,
    get_time_steps,
    get_entry_type,
    get_component_type,
    get_component_name,
    get_component_names,
    get_attributes,
    get_aux_variable,
    get_aux_variables,
    get_parameter,
    get_parameters,
    get_variables,
    get_evaluations,
    get_evaluators,
    get_evaluation_data,
    add_evaluation_data!,
    jump_value

# These IOM generics get concrete methods registered below.
import InfrastructureOptimizationModels:
    evaluate!,
    reset!,
    is_solved,
    get_inner_data,
    initialize_evaluation_data
```

- [ ] **Step 2: Rewrite the struct supertype and constructor**

In the same file, lines 41-85, find the struct and constructor. Replace with:

```julia
"""
Runtime state for a power-flow evaluator. Wraps a `PFS.PowerFlowContainer`
together with the input map describing where each PF input category is read
from in the `OptimizationContainer`. Subtypes `IOM.AbstractEvaluationData` so
the generic evaluator pipeline in IOM can dispatch on it.
"""
mutable struct PowerFlowEvaluationData{T <: PFS.PowerFlowContainer} <:
               AbstractEvaluationData
    power_flow_data::T
    """
    Records which keys are read as input to the power flow and how the data are mapped.
    The `Symbol` is a category of data: `:active_power`, `:reactive_power`, etc. The
    `OptimizationContainerKey` is a source of that data in the `OptimizationContainer`. For
    `PowerFlowData`, leaf values are `Dict{String, Int64}` mapping component name to matrix
    index of bus; for `SystemPowerFlowContainer`, leaf values are
    `Dict{Union{String, Int64}, Union{String, Int64}}` mapping component name/bus number to
    component name/bus number.
    """
    input_key_map::Dict{Symbol, <:Dict{<:OptimizationContainerKey, <:Any}}
    is_solved::Bool
end

check_network_reduction(::PFS.SystemPowerFlowContainer) = nothing

function check_network_reduction(pfd::PFS.PowerFlowData)
    nrd = PFS.get_network_reduction_data(pfd)
    if !isempty(PNM.get_reductions(nrd))
        throw(
            IS.NotImplementedError(
                "Power flow in-the-loop on reduced networks isn't supported. Network " *
                "reductions of types $(PNM.get_reductions(nrd)) present.",
            ),
        )
    end
    return
end

function PowerFlowEvaluationData(
    power_flow_data::T,
) where {T <: PFS.PowerFlowContainer}
    check_network_reduction(power_flow_data)
    return PowerFlowEvaluationData{T}(
        power_flow_data,
        Dict{Symbol, Dict{OptimizationContainerKey, Any}}(),
        false,
    )
end

# IOM.AbstractEvaluationData interface impls
is_solved(ped::PowerFlowEvaluationData) = ped.is_solved
reset!(ped::PowerFlowEvaluationData) = (ped.is_solved = false; return)
get_inner_data(ped::PowerFlowEvaluationData) = ped.power_flow_data
get_input_key_map(ped::PowerFlowEvaluationData) = ped.input_key_map
```

(The `initialize_evaluation_data` method lives in `pf_input_mapping.jl` — Task 7 — because it needs the helpers defined there.)

- [ ] **Step 3: Compile-check** (will still fail until Task 7 due to removed `add_power_flow_data!`)

```bash
julia --project=. -e 'using PowerOperationsModels; using PowerFlows' 2>&1 | tail -15
```

Expected: the only remaining errors should reference `add_power_flow_data!`, `power_flow_evaluation_data`, `solve_power_flow!`, or `latest_solved_power_flow_evaluation_data` — all in the four `pf_*.jl` files. None should reference `AbstractPowerFlowEvaluationData`.

- [ ] **Step 4: Stage**

```bash
git add ext/PowerFlowsExt/PowerFlowsExt.jl
```

---

## Task 7: Rebuild `pf_input_mapping.jl` to register evaluator data through `EvaluationContainer`

**Files:**
- Modify: `ext/PowerFlowsExt/pf_input_mapping.jl:317-363`

Two changes:
1. Rename `add_power_flow_data!(container, evaluators::Vector, sys)` to `register_evaluator_data!(container, evaluations::IOM.EvaluationContainer, sys)` and adjust the body to iterate `IOM.get_evaluators(evaluations)`. Write results via `IOM.add_evaluation_data!(evaluations, key, pf_e_data)` instead of pushing to a vector.
2. Replace the existing iteration over `get_power_flow_evaluation_data(container)` (line 359) with `values(IOM.get_evaluation_data(evaluations))`.

- [ ] **Step 1: Open file and locate `add_power_flow_data!`**

Read `ext/PowerFlowsExt/pf_input_mapping.jl` lines 317-363. Confirm the function starts with:

```julia
function POM.add_power_flow_data!(
    container::OptimizationContainer,
    evaluators::Vector{<:PFS.PowerFlowEvaluationModel},
    sys::PSY.System,
)
```

- [ ] **Step 2: Replace the function**

```julia
"""
Entry point for the build pipeline. Called via `POM.register_evaluator_data!`
once the NetworkModel's `EvaluationContainer` has been pointed at the
OptimizationContainer. Iterates registered `PFS.PowerFlowEvaluationModel`
evaluator configs and:
  * builds each PF data container,
  * wraps it in a `PowerFlowEvaluationData`,
  * registers all branch/bus PF-driven aux-variable containers,
  * computes the per-evaluator input map.
"""
function POM.register_evaluator_data!(
    container::OptimizationContainer,
    evaluations::IOM.EvaluationContainer,
    sys::PSY.System,
)
    isempty(evaluations) && return
    branch_aux_var_components =
        Dict{Type{<:AuxVariableType}, Set{Tuple{<:DataType, String}}}()
    bus_aux_var_components = Dict{Type{<:AuxVariableType}, Set{Tuple{<:DataType, <:Int}}}()
    n_time_steps = length(get_time_steps(container))
    for (key_type, evaluator) in IOM.get_evaluators(evaluations)
        evaluator isa PFS.PowerFlowEvaluationModel || continue
        evaluator = _with_time_steps(evaluator, n_time_steps)
        @info "Building PowerFlow evaluator using $(evaluator)"
        pf_data = PFS.make_power_flow_container(evaluator, sys)
        pf_e_data = PowerFlowEvaluationData(pf_data)

        my_branch_aux_vars = branch_aux_vars(pf_data)
        my_bus_aux_vars = bus_aux_vars(pf_data)
        my_branch_components = _get_branch_component_tuples(sys)
        for branch_aux_var in my_branch_aux_vars
            to_add_to = get!(
                branch_aux_var_components,
                branch_aux_var,
                Set{Tuple{<:DataType, String}}(),
            )
            push!.(Ref(to_add_to), my_branch_components)
        end
        my_bus_components = _get_bus_component_tuples(pf_data)
        for bus_aux_var in my_bus_aux_vars
            to_add_to =
                get!(bus_aux_var_components, bus_aux_var, Set{Tuple{<:DataType, <:Int}}())
            push!.(Ref(to_add_to), my_bus_components)
        end
        add_evaluation_data!(evaluations, key_type, pf_e_data)
    end

    _add_aux_variables!(container, branch_aux_var_components)
    _add_aux_variables!(container, bus_aux_var_components)

    # Build input maps AFTER aux-var containers exist so output of one evaluator
    # can be consumed as input to another.
    for pf_e_data in values(IOM.get_evaluation_data(evaluations))
        pf_e_data isa PowerFlowEvaluationData || continue
        _make_pf_input_map!(pf_e_data, container, sys)
    end
    return
end

"""
Register the PowerFlow data initializer for a single `PFS.PowerFlowEvaluationModel`
under the IOM evaluator interface. POM's orchestrator (`register_evaluator_data!`
above) is what actually drives initialization today; this method exists so direct
`IOM.initialize_evaluation_data(ev, container, sys)` calls also work and so the
IOM interface surface is complete. It returns a freshly-built (still-unsolved)
`PowerFlowEvaluationData` whose input map has NOT yet been wired — the caller is
expected to either call the orchestrator or invoke `_make_pf_input_map!` itself.
"""
function initialize_evaluation_data(
    ev::PFS.PowerFlowEvaluationModel,
    container::OptimizationContainer,
    sys::PSY.System,
)
    n_time_steps = length(get_time_steps(container))
    ev = _with_time_steps(ev, n_time_steps)
    pf_data = PFS.make_power_flow_container(ev, sys)
    return PowerFlowEvaluationData(pf_data)
end
```

- [ ] **Step 3: Compile-check**

```bash
julia --project=. -e 'using PowerOperationsModels; using PowerFlows' 2>&1 | tail -15
```

Expected: errors now only in `pf_solve_and_aux.jl` and `pf_data_update.jl` (references to `solve_power_flow!`, `get_power_flow_data`, `get_power_flow_evaluation_data`).

- [ ] **Step 4: Stage**

```bash
git add ext/PowerFlowsExt/pf_input_mapping.jl
```

---

## Task 8: Rebuild `pf_solve_and_aux.jl` against `evaluate!` + `get_inner_data`

**Files:**
- Modify: `ext/PowerFlowsExt/pf_solve_and_aux.jl` (full file, 163 lines)

Two structural renames + accessor swaps:
1. `solve_power_flow!(pf_e_data, container, sys)` → `evaluate!(pf_e_data, container, sys)` (with `pf_e_data::PowerFlowEvaluationData` — multi-method dispatch on the abstract supertype `AbstractEvaluationData` already done in IOM).
2. `latest_solved_power_flow_evaluation_data(container)` reads from `IOM.get_evaluation_data(IOM.get_evaluations(container))` (a `Dict{DataType, AbstractEvaluationData}`) rather than the deleted `Vector`. Filter to `PowerFlowEvaluationData` and find the latest with `is_solved`; relies on Julia's Dict insertion-order preservation.
3. `get_power_flow_data(pf_e_data)` → `get_inner_data(pf_e_data)`.

- [ ] **Step 1: Rewrite `latest_solved_power_flow_evaluation_data`**

Lines 6-16. Replace:

```julia
"Fetch the most recently solved `PowerFlowEvaluationData`."
function latest_solved_power_flow_evaluation_data(container::OptimizationContainer)
    datas = get_power_flow_evaluation_data(container)
    idx = findlast(x -> x.is_solved, datas)
    # FIXME: AC PF convergence can fail when the optimization permits a
    # transmission scenario infeasible for the full AC equations; full handling
    # is pending a broader PF-failure design (kiernan, PR #112).
    isnothing(idx) &&
        error("No solved PowerFlowEvaluationData available; PF in the loop did not converge")
    return datas[idx]
end
```

With:

```julia
"Fetch the most recently solved `PowerFlowEvaluationData` registered on this container."
function latest_solved_power_flow_evaluation_data(container::OptimizationContainer)
    evaluation_data = IOM.get_evaluation_data(IOM.get_evaluations(container))
    # Julia Dict preserves insertion order; iterate to find the latest solved entry
    # whose runtime type is one we own (other evaluator extensions may share the dict).
    last_solved = nothing
    for data in values(evaluation_data)
        data isa PowerFlowEvaluationData || continue
        is_solved(data) && (last_solved = data)
    end
    # FIXME: AC PF convergence can fail when the optimization permits a
    # transmission scenario infeasible for the full AC equations; full handling
    # is pending a broader PF-failure design (kiernan, PR #112).
    isnothing(last_solved) &&
        error("No solved PowerFlowEvaluationData available; PF in the loop did not converge")
    return last_solved
end
```

- [ ] **Step 2: Rename `solve_power_flow!` → `evaluate!`**

Lines 18-38. Replace:

```julia
function solve_power_flow!(
    pf_e_data::PowerFlowEvaluationData,
    container::OptimizationContainer,
    sys::PSY.System,
)
    pf_data = get_power_flow_data(pf_e_data)
    if PFS.supports_multi_period(pf_data)
        update_pf_data!(pf_e_data, container)
        _update_headroom_participation_factors!(
            pf_data, container, sys, get_input_key_map(pf_e_data),
        )
        PFS.solve_power_flow!(pf_data)
    else
        for t in get_time_steps(container)
            update_pf_data!(pf_e_data, container, t)
            PFS.solve_power_flow!(pf_data)
        end
    end
    pf_e_data.is_solved = true
    return
end
```

With:

```julia
function evaluate!(
    pf_e_data::PowerFlowEvaluationData,
    container::OptimizationContainer,
    sys::PSY.System,
)
    pf_data = get_inner_data(pf_e_data)
    if PFS.supports_multi_period(pf_data)
        update_pf_data!(pf_e_data, container)
        _update_headroom_participation_factors!(
            pf_data, container, sys, get_input_key_map(pf_e_data),
        )
        PFS.solve_power_flow!(pf_data)
    else
        for t in get_time_steps(container)
            update_pf_data!(pf_e_data, container, t)
            PFS.solve_power_flow!(pf_data)
        end
    end
    pf_e_data.is_solved = true
    return
end
```

- [ ] **Step 3: Swap `get_power_flow_data` → `get_inner_data` in the remaining four call sites**

In the same file, lines 87-156 contain four occurrences of `pf_data = get_power_flow_data(pf_e_data)` (in the PSSEExporter no-op, in two `calculate_aux_variable_value!` methods, and one in the dispatch-guard fallback at ~line 156). Replace each with `pf_data = get_inner_data(pf_e_data)`. Use `replace_all = true` on the Edit call for `get_power_flow_data(pf_e_data)` → `get_inner_data(pf_e_data)` if any are identical.

After substitution, run:

```bash
grep -n "get_power_flow_data" ext/PowerFlowsExt/pf_solve_and_aux.jl
```

Expected: zero matches.

- [ ] **Step 4: Compile-check**

```bash
julia --project=. -e 'using PowerOperationsModels; using PowerFlows' 2>&1 | tail -10
```

Expected: only errors remaining should be in `pf_data_update.jl`.

- [ ] **Step 5: Stage**

```bash
git add ext/PowerFlowsExt/pf_solve_and_aux.jl
```

---

## Task 9: Update `pf_data_update.jl` accessors

**Files:**
- Modify: `ext/PowerFlowsExt/pf_data_update.jl:117,120,187,191`

Only the accessor swap (`get_power_flow_data` → `get_inner_data`). Two call sites at lines 117/120 (the `<:PFS.PowerFlowData` branch of `update_pf_data!`) and 187/191 (the `PFS.PSSEExporter` branch).

- [ ] **Step 1: Swap all `get_power_flow_data` calls**

Run a single `Edit` with `replace_all = true` on the file:
- `old_string`: `get_power_flow_data(pf_e_data)`
- `new_string`: `get_inner_data(pf_e_data)`

- [ ] **Step 2: Verify**

```bash
grep -n "get_power_flow_data" ext/PowerFlowsExt/pf_data_update.jl
```

Expected: zero matches.

- [ ] **Step 3: Compile-check the full POM + extension**

```bash
julia --project=. -e 'using PowerOperationsModels; using PowerFlows' 2>&1 | tail -10
```

Expected: clean precompile (perhaps a deprecation warning, but no errors). No reference to `AbstractPowerFlowEvaluationModel`, `AbstractPowerFlowEvaluationData`, `solve_power_flow!`, `get_power_flow_data`, `get_power_flow_evaluation_data`, `power_flow_evaluation_data`, `is_from_power_flow` anywhere in the POM source tree:

```bash
grep -rn "AbstractPowerFlowEvaluationModel\|AbstractPowerFlowEvaluationData\|solve_power_flow!\|get_power_flow_data\|get_power_flow_evaluation_data\|power_flow_evaluation_data\|is_from_power_flow" src/ ext/ test/
```

Expected: zero matches (or matches only in test files — those are fixed in Task 10).

- [ ] **Step 4: Stage**

```bash
git add ext/PowerFlowsExt/pf_data_update.jl
```

---

## Task 10: Fix test accessors in `test_power_flow_in_the_loop.jl`

**Files:**
- Modify: `test/test_power_flow_in_the_loop.jl` (~9 call sites visible from grep)

All call sites use one of:
- `get_power_flow_evaluation_data(container)` — must become `values(IOM.get_evaluation_data(IOM.get_evaluations(container)))` (and `only(...)` still works because each test registers exactly one PF evaluator).
- `get_power_flow_data(pf_e_data)` — must become `IOM.get_inner_data(pf_e_data)`.

- [ ] **Step 1: Enumerate the call sites**

```bash
grep -n "get_power_flow_evaluation_data\|get_power_flow_data" test/test_power_flow_in_the_loop.jl
```

Expected: ~9 matches across lines 20-21, 104-105, 148-149, 229-230, etc. (numbers may shift if upstream commits land first.)

- [ ] **Step 2: Replace `get_power_flow_evaluation_data` calls**

For each `pf_e_data = only(get_power_flow_evaluation_data(container))` (or similar), replace with:

```julia
pf_e_data = only(values(IOM.get_evaluation_data(IOM.get_evaluations(container))))
```

If the test file does not yet `import` IOM, add at the top (after other imports):

```julia
import InfrastructureOptimizationModels as IOM
```

- [ ] **Step 3: Replace `get_power_flow_data` calls**

Single `Edit` with `replace_all = true`:
- `old_string`: `get_power_flow_data(pf_e_data)`
- `new_string`: `IOM.get_inner_data(pf_e_data)`

- [ ] **Step 4: Verify**

```bash
grep -n "get_power_flow_evaluation_data\|get_power_flow_data" test/
```

Expected: zero matches.

- [ ] **Step 5: Stage**

```bash
git add test/test_power_flow_in_the_loop.jl
```

---

## Task 11: Run the formatter

**Files:**
- Run formatter on all modified files.

Per global CLAUDE.md: always run the formatter before considering any task complete.

- [ ] **Step 1: Run POM formatter**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
```

Expected: exits 0, may stage trivial reflow diffs.

- [ ] **Step 2: Run IOM formatter on the IOM tree**

```bash
julia --project=/Users/jlara/cache/InfrastructureOptimizationModels.jl/scripts/formatter -e 'cd("/Users/jlara/cache/InfrastructureOptimizationModels.jl"); include("scripts/formatter/formatter_code.jl")'
```

(If IOM doesn't have a `scripts/formatter` of its own, skip and note in the report.)

- [ ] **Step 3: Stage formatter changes**

```bash
git add -u
git -C /Users/jlara/cache/InfrastructureOptimizationModels.jl add -u
```

---

## Task 12: Run the test suite

**Files:** none (test execution only)

Per global CLAUDE.md: always run the full test suite after making changes and report results.

- [ ] **Step 1: Run POM tests**

```bash
julia --project=test -e 'using Pkg; Pkg.test("PowerOperationsModels")' 2>&1 | tee /tmp/pom-tests-task12.log | tail -60
```

Expected: all tests pass. Specifically, the PF-in-the-loop testset (`@testset "AC Power Flow in the loop with headroom-proportional slack"` and siblings) should pass with no errors about missing functions.

- [ ] **Step 2: If tests fail, diagnose by failure family**

Common breakage patterns and where to look:
- `KeyError(PFS.PowerFlowEvaluationModel)` in `latest_solved_power_flow_evaluation_data` → wrong key used in `add_evaluation_data!` (Task 7). The key must match what the user passed to `add_evaluator!` on the NetworkModel side. Default convention: the **abstract supertype** of the user's evaluator (i.e. `PFS.PowerFlowEvaluationModel`), so the user's call is `add_evaluator!(ec, PFS.PowerFlowEvaluationModel, PFS.PTDFDCPowerFlow())`.
- `AssertionError` in `calculate_aux_variables!` (`@assert isempty(evaluator_aux_var_keys) || !isempty(evaluation_data)`) → the build pipeline didn't wire `container.evaluations` to the same instance as the NetworkModel's; Task 4 step 1.
- `MethodError: no method matching reset!(::PowerFlowEvaluationData{...})` → Task 6 step 2 missed adding the `reset!` method.

- [ ] **Step 3: Final verification grep**

```bash
grep -rn "is_from_power_flow\|solve_power_flow!\b\|AbstractPowerFlowEvaluation\|get_power_flow_data\|get_power_flow_evaluation_data\|power_flow_evaluation_data\|power_flow_evaluation\b" src/ ext/ test/
```

Expected: only false-positive matches in comments referring to PFS's own `PFS.solve_power_flow!(pf_data)` (the PowerFlows-internal solver call). Verify each remaining hit by hand.

---

## Risks and follow-ups

- **Insertion order semantics.** `latest_solved_power_flow_evaluation_data` (Task 8) relies on `Dict` preserving insertion order. Julia ≥1.6 does, but two evaluators of *different* abstract supertypes that share the dict could re-order across registrations. Today there's only ever one `PowerFlowEvaluationData` entry per test, so this is fine; revisit when a second evaluator type joins.
- **`PFS.PowerFlowEvaluationModel` as the dict key vs. concrete subtype.** Task 7 keys by the abstract supertype the user passed. If a user wants two distinct PF evaluators in the same network model (e.g. PTDF + AC), they'd collide on the key. The current PSI behavior used a `Vector`, which allowed this; the new `EvaluationContainer` design effectively forbids it unless the user keys by concrete type. Worth a follow-up issue if this is a real use case.
- **`add_power_flow_data!` is gone — downstream callers will break.** Anyone outside POM/test importing `POM.add_power_flow_data!` needs to switch to `POM.register_evaluator_data!`. Run a global grep across `/Users/jlara/cache/` for `add_power_flow_data!` before merging.
- **IOM changes are uncommitted.** The `Pkg.develop` step in Task 0 pins POM to a working tree, not a Git rev. Before merging POM's PR, the IOM PR must merge and POM's `Project.toml` must be re-pinned to a release (or to a Git ref via `Pkg.add(url=..., rev=...)`).
- **Parallel branch test relevance.** Memory note: POM never sees parallel branches; PNM reduces them upstream. The aux-variable code in `pf_solve_and_aux.jl` (line 127 onwards in the current file) iterates `PNM.get_parallel_branch_map` — confirm with the IOM/PNM upgrade that this still has the expected shape after the eval refactor.

## Self-Review

**1. Spec coverage:** every user-requested element is addressed:
- "be aware of the new container for evaluators in IOM" → Tasks 1, 3, 4, 7 (consumes `IOM.EvaluationContainer`).
- "have the PowerFlow evaluator be a single object here in POM with its own methods" → Task 6 (`PowerFlowEvaluationData <: IOM.AbstractEvaluationData` with `evaluate!`, `reset!`, `is_solved`, `get_inner_data` registered).
- "PowerSimulations copilot/fix-input-output-active-power" → out of scope here; tracked in the sibling plan `2026-05-13-pom-pf-inout-port.md`.

**2. Placeholder scan:** no TBDs, no "implement later." Each code step shows the exact replacement text.

**3. Type consistency:** `register_evaluator_data!` introduced in Task 3, consumed in Task 4 and defined-concretely in Task 7 — all three uses agree on the signature `(container, evaluations, sys)`. `get_inner_data` consistently replaces every `get_power_flow_data` site. `IOM.AbstractEvaluationData` is the supertype used everywhere POM extends.
