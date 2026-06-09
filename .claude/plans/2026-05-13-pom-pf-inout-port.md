# Port PowerSimulations `copilot/fix-input-output-active-power` to POM PowerFlowsExt

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the `ActivePowerInVariable` / `ActivePowerOutVariable` (and matching `ActivePowerInTimeSeriesParameter` / `ActivePowerOutTimeSeriesParameter`) support for power-flow in-the-loop, currently sitting on `PowerSimulations.jl/copilot/fix-input-output-active-power`, into POM's `PowerFlowsExt`. This makes Storage (BookKeeping) and Source (ImportExportSourceModel) participate correctly in PF data updates and in the headroom-proportional slack accumulator.

**Architecture:** The PS branch adds three new `:active_power_in` / `:active_power_out` input-key categories to `PF_INPUT_KEY_PRECEDENCES`. The corresponding `_update_pf_data_component!` dispatches write `+=` (out) and `-=` (in) into `bus_active_power_injections` (split rationale: a single component split between in/out variables nets to a *signed* injection at one bus; both halves contribute to the *same* matrix entry). The headroom accumulator gets a parallel branch `_accumulate_in_out_headroom!` that iterates the paired in/out keys, computes `net = p_out - p_in` per device-time, and accumulates `p_max_out - net` when net ≥ 0 (charging/idle → no upward slack). Three new in-the-loop tests cover the variable path (ImportExportSourceModel), headroom for the variable path, and the parameter path (FixedOutput on Source).

This plan is written **assuming Plan 1 (`2026-05-13-pom-evaluator-migration.md`) has merged** — uses `IOM.get_inner_data(pf_e_data)` (not `get_power_flow_data`), `evaluate!` (not `solve_power_flow!`), and `register_evaluator_data!`.

**Tech Stack:** Julia 1.10+, IOM (post-evaluator-migration), PowerFlows.jl, JuMP, HiGHS (test), Ipopt (test).

**Pre-flight:**
- Plan 1 must be merged (or applied on the same branch).
- POM already defines `ActivePowerInVariable`, `ActivePowerOutVariable`, `ActivePowerInTimeSeriesParameter`, `ActivePowerOutTimeSeriesParameter` (verified at `src/core/variables.jl:656`, `src/core/parameters.jl:26-31`, `src/PowerOperationsModels.jl:455-456, 735-736`).
- POM test util `make_5_bus_with_import_export` exists in `test/test_utils/iec_test_systems.jl:8`.
- POM uses `import PowerOperationsModels as POM` and `import PowerFlows as PFS` (consistent with the PSI tests, which we'll need to retype during the port).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `ext/PowerFlowsExt/pf_input_mapping.jl` | `PF_INPUT_KEY_PRECEDENCES` + `pf_input_keys` per PF-data trait | Add `:active_power_in` / `:active_power_out` categories and append them to each PF-data type that consumes active power |
| `ext/PowerFlowsExt/pf_data_update.jl` | `_update_pf_data_component!` dispatch + `update_pf_system!` reset loop | Add `Val{:active_power_out}` and `Val{:active_power_in}` overloads for `PowerFlowData` and for `PSY.Component`. Add a pre-loop reset of `comp.active_power = 0.0` for components touched by in/out before the additive updates. |
| `ext/PowerFlowsExt/pf_headroom.jl` | Headroom-proportional slack accumulator | Drop the Storage-skip TODO. Add `_accumulate_in_out_headroom!`, `_find_paired_out`, and `_accumulate_in_out_headroom_one_type!`. Wire them into `_update_headroom_participation_factors!`. Add `_pf_in_out_discharge_max` overloads for `Storage` and `Source`. Remove the now-unreachable `comp === nothing` continue inside `_accumulate_headroom!`. |
| `test/test_power_flow_in_the_loop.jl` | PF-in-the-loop tests | Add three testsets ported from PS: in/out variable path, in/out headroom path, FixedOutput parameter path. Use POM/PFS namespacing. |

**Out of scope:**
- `update_pf_system!` for `PSSEExporter` mode (the PS branch's reset loop touches only the `PowerFlowData` `update_pf_system!`). The PSSEExporter path uses the same `update_pf_system!` core; verify by inspection (Task 2 step 3).
- `pf_input_keys_hvdc_pst` extension — HVDC PSTs don't use in/out vars; no change needed.

---

## Task 1: Add `:active_power_in` / `:active_power_out` to `PF_INPUT_KEY_PRECEDENCES` and per-PF-type input keys

**Files:**
- Modify: `ext/PowerFlowsExt/pf_input_mapping.jl:7-24, 50-62`

- [ ] **Step 1: Append the two new precedence entries**

In `ext/PowerFlowsExt/pf_input_mapping.jl`, find the `PF_INPUT_KEY_PRECEDENCES` declaration (lines 7-24). Replace:

```julia
const PF_INPUT_KEY_PRECEDENCES = Dict(
    :active_power => [
        IOM.ActivePowerVariable,
        POM.PowerOutput,
        POM.ActivePowerTimeSeriesParameter,
    ],
    :reactive_power =>
        [POM.ReactivePowerVariable, POM.ReactivePowerTimeSeriesParameter],
    :voltage_angle_export => [POM.PowerFlowVoltageAngle, POM.VoltageAngle],
    :voltage_magnitude_export =>
        [POM.PowerFlowVoltageMagnitude, POM.VoltageMagnitude],
    :voltage_angle_opf => [POM.VoltageAngle],
    :voltage_magnitude_opf => [POM.VoltageMagnitude],
    :active_power_hvdc_pst_from_to =>
        [POM.FlowActivePowerFromToVariable, POM.FlowActivePowerVariable],
    :active_power_hvdc_pst_to_from =>
        [POM.FlowActivePowerToFromVariable, POM.FlowActivePowerVariable],
)
```

With:

```julia
const PF_INPUT_KEY_PRECEDENCES = Dict(
    :active_power => [
        IOM.ActivePowerVariable,
        POM.PowerOutput,
        POM.ActivePowerTimeSeriesParameter,
    ],
    :active_power_in =>
        [IOM.ActivePowerInVariable, POM.ActivePowerInTimeSeriesParameter],
    :active_power_out =>
        [IOM.ActivePowerOutVariable, POM.ActivePowerOutTimeSeriesParameter],
    :reactive_power =>
        [POM.ReactivePowerVariable, POM.ReactivePowerTimeSeriesParameter],
    :voltage_angle_export => [POM.PowerFlowVoltageAngle, POM.VoltageAngle],
    :voltage_magnitude_export =>
        [POM.PowerFlowVoltageMagnitude, POM.VoltageMagnitude],
    :voltage_angle_opf => [POM.VoltageAngle],
    :voltage_magnitude_opf => [POM.VoltageMagnitude],
    :active_power_hvdc_pst_from_to =>
        [POM.FlowActivePowerFromToVariable, POM.FlowActivePowerVariable],
    :active_power_hvdc_pst_to_from =>
        [POM.FlowActivePowerToFromVariable, POM.FlowActivePowerVariable],
)
```

**Note:** `IOM.ActivePowerInVariable` and `IOM.ActivePowerOutVariable` — IOM owns these variable types (POM exports them via `using IOM`). If `ActivePowerInVariable`/`ActivePowerOutVariable` actually live in POM's `src/core/variables.jl` (search to confirm), use `POM.` for the namespace. Run:

```bash
grep -n "struct ActivePowerInVariable\|struct ActivePowerOutVariable" /Users/jlara/cache/PowerOperationsModels.jl/src/core/variables.jl
```

If matches in POM, use `POM.ActivePowerInVariable` / `POM.ActivePowerOutVariable`. Otherwise:

```bash
grep -rn "struct ActivePowerInVariable\|struct ActivePowerOutVariable" /Users/jlara/cache/InfrastructureOptimizationModels.jl/src/
```

Use whichever package defines them. (Note: POM exports them at `src/PowerOperationsModels.jl:455-456`, but that doesn't tell us which package owns the struct — confirm with the grep above and adjust the precedence-list namespace accordingly. The rest of this plan uses `IOM.` placeholders; sub them out wholesale if POM owns the types.)

- [ ] **Step 2: Extend `pf_input_keys` for the four PF-data types**

Same file, lines 49-62. Replace:

```julia
# Trait that determines which types of information are needed for each type of power flow
pf_input_keys(::PFS.ABAPowerFlowData) =
    [:active_power]
pf_input_keys(::PFS.PTDFPowerFlowData) =
    [:active_power]
pf_input_keys(::PFS.vPTDFPowerFlowData) =
    [:active_power]
pf_input_keys(::PFS.ACPowerFlowData) =
    [:active_power, :reactive_power, :voltage_angle_opf, :voltage_magnitude_opf]
pf_input_keys(::PFS.PSSEExporter) =
    [:active_power, :reactive_power, :voltage_angle_export, :voltage_magnitude_export]
```

With:

```julia
# Trait that determines which types of information are needed for each type of power flow
pf_input_keys(::PFS.ABAPowerFlowData) =
    [:active_power, :active_power_in, :active_power_out]
pf_input_keys(::PFS.PTDFPowerFlowData) =
    [:active_power, :active_power_in, :active_power_out]
pf_input_keys(::PFS.vPTDFPowerFlowData) =
    [:active_power, :active_power_in, :active_power_out]
pf_input_keys(::PFS.ACPowerFlowData) =
    [
        :active_power,
        :active_power_in,
        :active_power_out,
        :reactive_power,
        :voltage_angle_opf,
        :voltage_magnitude_opf,
    ]
pf_input_keys(::PFS.PSSEExporter) =
    [
        :active_power,
        :active_power_in,
        :active_power_out,
        :reactive_power,
        :voltage_angle_export,
        :voltage_magnitude_export,
    ]
```

- [ ] **Step 3: Compile-check**

```bash
julia --project=. -e 'using PowerOperationsModels; using PowerFlows' 2>&1 | tail -10
```

Expected: clean precompile.

- [ ] **Step 4: Stage**

```bash
git add ext/PowerFlowsExt/pf_input_mapping.jl
```

---

## Task 2: Add `_update_pf_data_component!` dispatches and pre-loop reset

**Files:**
- Modify: `ext/PowerFlowsExt/pf_data_update.jl` (insert after line 22 and modify `update_pf_system!` at lines 155-178)

- [ ] **Step 1: Add the two `PowerFlowData` overloads after the existing `:active_power` ones**

In `ext/PowerFlowsExt/pf_data_update.jl`, find the existing block at lines 7-22:

```julia
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power},
    ::Type{<:PSY.StaticInjection},
    index,
    t,
    value,
) = (pf_data.bus_active_power_injections[index, t] += value)
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power},
    ::Type{<:PSY.ElectricLoad},
    index,
    t,
    value,
) = (pf_data.bus_active_power_withdrawals[index, t] -= value)
```

After it, insert:

```julia
# ActivePowerOutVariable / ActivePowerOutTimeSeriesParameter — positive contribution
# to bus injection (the same matrix entry as `:active_power`, additive).
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power_out},
    ::Type{<:PSY.StaticInjection},
    index,
    t,
    value,
) = (pf_data.bus_active_power_injections[index, t] += value)
# ActivePowerInVariable / ActivePowerInTimeSeriesParameter — withdrawal/charging,
# subtracted from the same injection entry.
_update_pf_data_component!(
    pf_data::PFS.PowerFlowData,
    ::Val{:active_power_in},
    ::Type{<:PSY.StaticInjection},
    index,
    t,
    value,
) = (pf_data.bus_active_power_injections[index, t] -= value)
```

- [ ] **Step 2: Add the two `_update_component!` overloads (system-update path used by `PSSEExporter`)**

Same file, after line 141 (after the existing `_update_component!(comp::PSY.ElectricLoad, ::Val{:reactive_power}, ...)` line and before the `_update_component!(comp::PSY.ACBus, ...)` ones).

Insert:

```julia
# ActivePowerOutVariable — positive contribution to comp.active_power (additive)
_update_component!(comp::PSY.Component, ::Val{:active_power_out}, value, sys_base) =
    (comp.active_power += value * sys_base / PSY.get_base_power(comp))
# ActivePowerInVariable — withdrawal/charging, subtracted
_update_component!(comp::PSY.Component, ::Val{:active_power_in}, value, sys_base) =
    (comp.active_power -= value * sys_base / PSY.get_base_power(comp))
```

- [ ] **Step 3: Add the pre-loop reset to `update_pf_system!`**

Same file, locate `update_pf_system!` at line 155. Currently:

```julia
function update_pf_system!(
    sys::PSY.System,
    container::OptimizationContainer,
    input_map::Dict{Symbol, <:Dict{OptimizationContainerKey, <:Any}},
    time_step::Int,
)
    for (category, inputs) in input_map
        @debug "Writing $category to (possibly internal) System"
        for (key, component_map) in inputs
            result = lookup_value(container, key)
            for (device_id, device_name) in component_map
                ...
```

Replace the function signature line through the first `for (category, ...)` line — insert a deduplicated reset loop after the signature and BEFORE the existing category loop. New body:

```julia
function update_pf_system!(
    sys::PSY.System,
    container::OptimizationContainer,
    input_map::Dict{Symbol, <:Dict{OptimizationContainerKey, <:Any}},
    time_step::Int,
)
    # Reset active_power to zero for components that use separate in/out variables
    # (e.g. storage, import/export sources) before the additive += / -= updates.
    # Collect unique (type, name) pairs to avoid resetting the same component twice
    # when both ActivePowerInVariable and ActivePowerOutVariable map to it.
    reset_components = Set{Tuple{DataType, String}}()
    for category in (:active_power_in, :active_power_out)
        haskey(input_map, category) || continue
        for (key, component_map) in input_map[category]
            for (_, device_name) in component_map
                push!(reset_components, (get_component_type(key), device_name))
            end
        end
    end
    for (comp_type, device_name) in reset_components
        comp = PSY.get_component(comp_type, sys, device_name)
        comp.active_power = 0.0
    end
    for (category, inputs) in input_map
        @debug "Writing $category to (possibly internal) System"
        for (key, component_map) in inputs
            result = lookup_value(container, key)
            for (device_id, device_name) in component_map
                injection_values = result[device_id, :]
                comp = PSY.get_component(get_component_type(key), sys, device_name)
                val = jump_value(injection_values[time_step])
                _update_component!(
                    comp,
                    Val(category),
                    val,
                    IOM.get_model_base_power(container),
                )
            end
        end
    end
end
```

- [ ] **Step 4: Compile-check**

```bash
julia --project=. -e 'using PowerOperationsModels; using PowerFlows' 2>&1 | tail -10
```

Expected: clean precompile.

- [ ] **Step 5: Stage**

```bash
git add ext/PowerFlowsExt/pf_data_update.jl
```

---

## Task 3: Add `_pf_in_out_discharge_max` helpers and replace the Storage-skip with the new accumulator

**Files:**
- Modify: `ext/PowerFlowsExt/pf_headroom.jl:20-32, 81-108, 120-193`

- [ ] **Step 1: Replace the Storage-skip TODO comment with a forward reference**

Lines 20-32. Find:

```julia
# TODO Storage participation in headroom-proportional slack needs charge/discharge
# accounting (StorageEnergy state, ActivePowerInVariable vs ActivePowerOutVariable).
# Skip storage devices for now; revisit when the bookkeeping is added.
_accumulate_headroom!(
    ::PFS.PowerFlowData,
    ::OptimizationContainer,
    ::PSY.System,
    ::OptimizationContainerKey{<:ISOPT.OptimizationKeyType, <:PSY.Storage},
    ::Dict{String, Int},
    ::Int,
    ::Matrix{PSY.ACBusTypes},
    ::Vector{Dict{Tuple{DataType, String}, Float64}},
) = nothing
```

Replace with:

```julia
# Storage uses split In/Out active power variables; its headroom contribution
# comes from `_accumulate_in_out_headroom!` below. These no-ops guard against any
# (currently-unused) `:active_power` mapping for Storage that would otherwise
# double-count an entry already booked through the in/out accumulator.
_accumulate_headroom!(
    ::PFS.PowerFlowData,
    ::OptimizationContainer,
    ::PSY.System,
    ::OptimizationContainerKey{<:ISOPT.OptimizationKeyType, <:PSY.Storage},
    ::Dict{String, Int},
    ::Int,
    ::Matrix{PSY.ACBusTypes},
    ::Vector{Dict{Tuple{DataType, String}, Float64}},
) = nothing
```

(Only the comment changes — the no-op body is intentionally kept. The "TODO" is now resolved.)

- [ ] **Step 2: Remove the now-unreachable `comp === nothing` guard**

Lines 81-83. Find inside the main `_accumulate_headroom!` body:

```julia
    for (device_name, bus_ix) in component_map
        comp = PSY.get_component(U, sys, device_name)
        comp === nothing && continue
        PFS.contributes_active_power(comp) || continue
```

Replace with:

```julia
    for (device_name, bus_ix) in component_map
        comp = PSY.get_component(U, sys, device_name)
        PFS.contributes_active_power(comp) || continue
```

(`component_map` is built from `get_available_components`, so `comp` is always non-nothing — matches the cleanup in PS PR.)

- [ ] **Step 3: Add `_pf_in_out_discharge_max` helpers**

Just before `_update_headroom_participation_factors!` (around line 110). Insert:

```julia
# Maximum discharge active power (system-base PU) for devices that use split
# `ActivePowerInVariable` / `ActivePowerOutVariable`. PFS's
# `get_active_power_limits_for_power_flow(::Source)` returns `(min=-Inf, max=Inf)`,
# which is unusable for headroom math, so we read the device-level limits directly.
_pf_in_out_discharge_max(comp::PSY.Storage) = PSY.get_output_active_power_limits(comp).max
_pf_in_out_discharge_max(comp::PSY.Source) = PSY.get_active_power_limits(comp).max
```

- [ ] **Step 4: Add `_accumulate_in_out_headroom!` and friends**

Just after the helpers in Step 3, insert:

```julia
"""
Accumulate headroom for devices that use split `ActivePowerInVariable` /
`ActivePowerOutVariable` (e.g. Storage `BookKeeping`, Source `ImportExportSourceModel`).

`net = p_out - p_in` is the device's signed contribution at time `t`. With net > 0 the
device is dispatching and its headroom is `p_max_out - net`; with net <= 0 the device is
charging (or idle) and contributes no upward slack.
"""
function _accumulate_in_out_headroom!(
    pf_data::PFS.PowerFlowData,
    container::OptimizationContainer,
    sys::PSY.System,
    in_inputs::Dict{OptimizationContainerKey, Dict{String, Int}},
    out_inputs::Dict{OptimizationContainerKey, Dict{String, Int}},
    n_time_steps::Int,
    bus_types::Matrix{PSY.ACBusTypes},
    computed_gspf::Vector{Dict{Tuple{DataType, String}, Float64}},
)
    for (in_key, in_cmap) in in_inputs
        out_key, out_cmap = _find_paired_out(out_inputs, get_component_type(in_key))
        _accumulate_in_out_headroom_one_type!(
            pf_data, container, sys,
            in_key, in_cmap, out_key, out_cmap,
            n_time_steps, bus_types, computed_gspf,
        )
    end
    return
end

function _find_paired_out(
    out_inputs::Dict{OptimizationContainerKey, Dict{String, Int}},
    comp_type::DataType,
)
    for (key, cmap) in out_inputs
        get_component_type(key) === comp_type && return (key, cmap)
    end
    error(
        "`:active_power_out` map missing for $comp_type — a formulation added " *
        "`ActivePowerInVariable` without a paired `ActivePowerOutVariable`.",
    )
end

# Function barrier: the parametric key types specialize `lookup_value` and `result[...]`
# indexing on the concrete component type `U`.
function _accumulate_in_out_headroom_one_type!(
    pf_data::PFS.PowerFlowData,
    container::OptimizationContainer,
    sys::PSY.System,
    in_key::OptimizationContainerKey{<:ISOPT.OptimizationKeyType, U},
    in_cmap::Dict{String, Int},
    out_key::OptimizationContainerKey{<:ISOPT.OptimizationKeyType, U},
    out_cmap::Dict{String, Int},
    n_time_steps::Int,
    bus_types::Matrix{PSY.ACBusTypes},
    computed_gspf::Vector{Dict{Tuple{DataType, String}, Float64}},
) where {U <: PSY.Component}
    result_in = lookup_value(container, in_key)
    result_out = lookup_value(container, out_key)
    for (device_name, bus_ix) in in_cmap
        comp = PSY.get_component(U, sys, device_name)
        PFS.contributes_active_power(comp) || continue
        PFS.active_power_contribution_type(comp) ==
        PFS.PowerContributionType.INJECTION || continue
        p_max_out = _pf_in_out_discharge_max(comp)
        for t in 1:n_time_steps
            bus_types[bus_ix, t] ∈ (PSY.ACBusTypes.REF, PSY.ACBusTypes.PV) || continue
            net =
                jump_value(result_out[device_name, t]) -
                jump_value(result_in[device_name, t])
            # Net <= 0 means charging or idle — per spec, no upward slack contribution.
            net < 0.0 && continue
            headroom = p_max_out - net
            headroom <= 0.0 && continue
            computed_gspf[t][(U, device_name)] = headroom
            pf_data.bus_active_power_range[bus_ix, t] += headroom
        end
    end
    return
end
```

- [ ] **Step 5: Wire `_accumulate_in_out_headroom!` into `_update_headroom_participation_factors!`**

Find the existing block at lines 147-163 of `pf_headroom.jl`:

```julia
    active_power_inputs = get(input_key_map, :active_power, nothing)
    active_power_inputs === nothing && return

    # Function barrier so `_accumulate_headroom!` specializes per concrete key type
    # encountered at runtime — the outer Dict iterates abstract `OptimizationContainerKey`s.
    for (key, component_map) in active_power_inputs
        _accumulate_headroom!(
            pf_data,
            container,
            sys,
            key,
            component_map,
            n_time_steps,
            bus_types,
            computed_gspf,
        )
    end
```

Replace with:

```julia
    # Function barrier so `_accumulate_headroom!` specializes per concrete key type
    # encountered at runtime — the outer Dict iterates abstract `OptimizationContainerKey`s.
    for (key, component_map) in input_key_map[:active_power]
        _accumulate_headroom!(
            pf_data,
            container,
            sys,
            key,
            component_map,
            n_time_steps,
            bus_types,
            computed_gspf,
        )
    end

    # Devices with split `ActivePowerInVariable` / `ActivePowerOutVariable`
    # (e.g. Storage `BookKeeping`, Source `ImportExportSourceModel`) accumulate
    # headroom from the net of out − in.
    _accumulate_in_out_headroom!(
        pf_data,
        container,
        sys,
        input_key_map[:active_power_in],
        input_key_map[:active_power_out],
        n_time_steps,
        bus_types,
        computed_gspf,
    )
```

**Why drop the `active_power_inputs === nothing` guard:** after Task 1, every PF-data type that calls `_update_headroom_participation_factors!` (i.e. the multi-period subtypes) declares all three of `:active_power`, `:active_power_in`, `:active_power_out` in `pf_input_keys`. The input-map builder creates an entry for every category, even when the category has zero keys. So `input_key_map[:active_power]` is always present. The bare indexing serves as a regression alarm.

- [ ] **Step 6: Update the docstring on `_update_headroom_participation_factors!`**

Find the docstring at lines 110-119:

```julia
"""
Recompute per-time-step headroom-proportional generator slack participation factors
using optimization results. Only runs if headroom proportional slack was enabled
during initialization.

For each generator at a REF or PV bus, headroom is `P_max(t) - P_setpoint(t)`, where
`P_setpoint(t)` comes from the optimization result and `P_max(t)` is the minimum of
the static device limit and any `ActivePowerTimeSeriesParameter` at time `t`. This
overwrites the PF-initialized values (which were computed once from static system
data) with time-varying factors.
"""
```

Replace with:

```julia
"""
Recompute per-time-step headroom-proportional generator slack participation factors
using optimization results. Only runs if headroom proportional slack was enabled
during initialization.

For each generator at a REF or PV bus, headroom is `P_max(t) - P_setpoint(t)`, where
`P_setpoint(t)` comes from the optimization result and `P_max(t)` is the minimum of
the static device limit and any `ActivePowerTimeSeriesParameter` at time `t`. Devices
that use split In/Out active power variables are handled separately via
`_accumulate_in_out_headroom!`. This overwrites the PF-initialized values (which were
computed once from static system data) with time-varying factors.
"""
```

- [ ] **Step 7: Compile-check**

```bash
julia --project=. -e 'using PowerOperationsModels; using PowerFlows' 2>&1 | tail -10
```

Expected: clean precompile.

- [ ] **Step 8: Stage**

```bash
git add ext/PowerFlowsExt/pf_headroom.jl
```

---

## Task 4: Port the three new testsets

**Files:**
- Modify: `test/test_power_flow_in_the_loop.jl` (append at the end of file)

Three testsets, each verifying a different code path:

1. **In/out variable path** — `Source` with `ImportExportSourceModel`, verifies `pf_data.bus_active_power_injections − bus_active_power_withdrawals` reflects `(p_out − p_in) / base_power`.
2. **In/out headroom path** — same system + `ACPowerFlow(distribute_slack_proportional_to_headroom=true)`, verifies `computed_gspf[t][(Source, "source")] == p_max_out − net` for non-charging time steps.
3. **In/out parameter path** — `Source` with `FixedOutput`, two `SingleTimeSeries` ("max_active_power_out", "max_active_power_in"), verifies the parameter map populates `:active_power_in` / `:active_power_out`.

The PSI tests use namespacing (`PSI.get_power_flow_evaluation_data`, `PSI.lookup_value`, `PSI.ActivePowerInVariable`, etc.). After Plan 1, POM's namespacing is `IOM` for the IOM-owned bits and `POM` for POM-owned bits. Specifically:
- `PSI.get_power_flow_evaluation_data(container)` → `values(IOM.get_evaluation_data(IOM.get_evaluations(container)))`
- `PSI.get_power_flow_data(pf_e_data)` → `IOM.get_inner_data(pf_e_data)`
- `PSI.get_input_key_map(pf_e_data)` → `get_input_key_map(pf_e_data)` (POM-extension-local; no namespace needed in tests if `using PowerFlowsExt` or via the test util wiring — confirm during port)
- `PSI.ActivePowerInVariable` / `PSI.ActivePowerOutVariable` → `IOM.ActivePowerInVariable` / `IOM.ActivePowerOutVariable` (or `POM.` if those structs live in POM — same grep as Task 1 step 1).
- `PSI.lookup_value` → `IOM.lookup_value`
- `PSI.jump_value` → `IOM.jump_value`
- `PSI.VariableKey(...)` / `PSI.ParameterKey(...)` → `IOM.VariableKey(...)` / `IOM.ParameterKey(...)`
- `PSI.get_time_steps` → `IOM.get_time_steps`
- `PSI.ActivePowerInTimeSeriesParameter` / `PSI.ActivePowerOutTimeSeriesParameter` → `POM.ActivePowerInTimeSeriesParameter` / `POM.ActivePowerOutTimeSeriesParameter` (verified `src/core/parameters.jl:26-31`)
- `PSI.ModelBuildStatus` / `PSI.RunStatus` → `IOM.ModelBuildStatus` / `IOM.RunStatus` (or `POM.`; confirm with one-liner grep at port time)
- `OptimizationProblemResults` / `read_variables` — POM/IOM-equivalent name TBD by grep at port time. Likely `IOM.OptimizationProblemResults`.

- [ ] **Step 1: Confirm POM/IOM names for the PSI symbols above**

```bash
grep -rn "struct ModelBuildStatus\|ModelBuildStatus =\|struct OptimizationProblemResults\|function read_variables" /Users/jlara/cache/PowerOperationsModels.jl/src/ /Users/jlara/cache/InfrastructureOptimizationModels.jl/src/ /Users/jlara/cache/InfrastructureSystems.jl/src/ 2>/dev/null
```

Record the owning package per symbol — substitute in the test code below.

- [ ] **Step 2: Append testset 1 — in/out variable path**

Append to `test/test_power_flow_in_the_loop.jl`:

```julia
@testset "Power Flow in the loop with separate in/out active power variables" begin
    sys = make_5_bus_with_import_export(; add_single_time_series = false)

    template = get_template_dispatch_with_network(
        IOM.NetworkModel(
            POM.PTDFPowerModel;
            PTDF_matrix = PNM.PTDF(sys),
            evaluations = let ec = IOM.EvaluationContainer()
                IOM.add_evaluator!(ec, PFS.PowerFlowEvaluationModel, PFS.PTDFDCPowerFlow())
                ec
            end,
        ),
    )
    IOM.set_device_model!(
        template,
        IOM.DeviceModel(
            PSY.Source,
            POM.ImportExportSourceModel;
            attributes = Dict("reservation" => false),
        ),
    )
    model = IOM.DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test IOM.build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test IOM.solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = IOM.get_optimization_container(model)
    pf_e_data =
        only(values(IOM.get_evaluation_data(IOM.get_evaluations(container))))
    input_key_map = get_input_key_map(pf_e_data)

    @test haskey(input_key_map, :active_power_in)
    @test haskey(input_key_map, :active_power_out)

    in_keys = collect(keys(input_key_map[:active_power_in]))
    out_keys = collect(keys(input_key_map[:active_power_out]))
    @test any(
        k ->
            IOM.get_entry_type(k) == IOM.ActivePowerInVariable &&
                IOM.get_component_type(k) == PSY.Source,
        in_keys,
    )
    @test any(
        k ->
            IOM.get_entry_type(k) == IOM.ActivePowerOutVariable &&
                IOM.get_component_type(k) == PSY.Source,
        out_keys,
    )

    data = IOM.get_inner_data(pf_e_data)
    base_power = PSY.get_base_power(sys)
    bus_lookup = PFS.get_bus_lookup(data)

    source = PSY.get_component(PSY.Source, sys, "source")
    source_bus_ix = bus_lookup[PSY.get_number(PSY.get_bus(source))]

    results = IOM.OptimizationProblemResults(model)
    vd = IOM.read_variables(results)
    p_out_results = vd["ActivePowerOutVariable__Source"]
    p_in_results = vd["ActivePowerInVariable__Source"]
    source_p_out = filter(row -> row[:name] == "source", p_out_results)[!, :value]
    source_p_in = filter(row -> row[:name] == "source", p_in_results)[!, :value]
    @test length(source_p_out) > 0
    @test length(source_p_in) > 0

    other_injection_at_bus = zeros(length(source_p_out))
    for (key, comp_map) in input_key_map[:active_power]
        result_data = IOM.lookup_value(container, key)
        for (dev_name, bus_ix) in comp_map
            bus_ix == source_bus_ix || continue
            for t in eachindex(other_injection_at_bus)
                other_injection_at_bus[t] += IOM.jump_value(result_data[dev_name, t])
            end
        end
    end
    source_net_pu = (source_p_out .- source_p_in) ./ base_power
    @test isapprox(
        data.bus_active_power_injections[source_bus_ix, :] .-
        data.bus_active_power_withdrawals[source_bus_ix, :],
        other_injection_at_bus .+ source_net_pu;
        atol = 1e-9,
    )
end
```

- [ ] **Step 3: Append testset 2 — in/out headroom path**

```julia
@testset "Headroom proportional slack with in/out active power variables (Source)" begin
    sys = make_5_bus_with_import_export(; add_single_time_series = false)

    template = get_template_dispatch_with_network(
        IOM.NetworkModel(
            POM.PTDFPowerModel;
            PTDF_matrix = PNM.PTDF(sys),
            evaluations = let ec = IOM.EvaluationContainer()
                IOM.add_evaluator!(
                    ec, PFS.PowerFlowEvaluationModel,
                    PFS.ACPowerFlow(;
                        distribute_slack_proportional_to_headroom = true,
                        correct_bustypes = true,
                    ),
                )
                ec
            end,
        ),
    )
    IOM.set_device_model!(
        template,
        IOM.DeviceModel(
            PSY.Source,
            POM.ImportExportSourceModel;
            attributes = Dict("reservation" => false),
        ),
    )
    model = IOM.DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test IOM.build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test IOM.solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = IOM.get_optimization_container(model)
    pf_e_data =
        only(values(IOM.get_evaluation_data(IOM.get_evaluations(container))))
    data = IOM.get_inner_data(pf_e_data)
    computed_gspf = PFS.get_computed_gspf(data)
    n_time_steps = length(IOM.get_time_steps(container))

    source = PSY.get_component(PSY.Source, sys, "source")
    p_max_out = PSY.get_active_power_limits(source).max

    in_key = IOM.VariableKey(IOM.ActivePowerInVariable, PSY.Source)
    out_key = IOM.VariableKey(IOM.ActivePowerOutVariable, PSY.Source)
    p_in_data = IOM.lookup_value(container, in_key)
    p_out_data = IOM.lookup_value(container, out_key)

    for t in 1:n_time_steps
        net =
            JuMP.value(p_out_data["source", t]) - JuMP.value(p_in_data["source", t])
        if net < 0.0
            @test !haskey(computed_gspf[t], (PSY.Source, "source"))
        else
            @test isapprox(
                computed_gspf[t][(PSY.Source, "source")],
                p_max_out - net;
                atol = 1e-10,
            )
        end
    end
    # Guard against a regression that silently drops the in/out accumulation path.
    @test any(haskey(d, (PSY.Source, "source")) for d in computed_gspf)
end
```

- [ ] **Step 4: Append testset 3 — FixedOutput parameter path**

```julia
@testset "Power Flow in the loop with Source FixedOutput (parameter path)" begin
    sys = make_5_bus_with_import_export(; add_single_time_series = true)
    source = PSY.get_component(PSY.Source, sys, "source")

    load = first(PSY.get_components(PSY.PowerLoad, sys))
    tstamp = TimeSeries.timestamp(
        PSY.get_time_series_array(PSY.SingleTimeSeries, load, "max_active_power"),
    )
    day_data = [
        0.9, 0.85, 0.95, 0.2, 0.0, 0.0,
        0.9, 0.85, 0.95, 0.2, 0.0, 0.0,
        0.9, 0.85, 0.95, 0.2, 0.0, 0.0,
        0.9, 0.85, 0.95, 0.2, 0.0, 0.0,
    ]
    ts_data = repeat(day_data, 2)
    ts_out = PSY.SingleTimeSeries(
        "max_active_power_out",
        TimeSeries.TimeArray(tstamp, ts_data);
        scaling_factor_multiplier = PSY.get_max_active_power,
    )
    ts_in = PSY.SingleTimeSeries(
        "max_active_power_in",
        TimeSeries.TimeArray(tstamp, ts_data);
        scaling_factor_multiplier = PSY.get_max_active_power,
    )
    PSY.add_time_series!(sys, source, ts_out)
    PSY.add_time_series!(sys, source, ts_in)
    PSY.transform_single_time_series!(sys, Dates.Hour(24), Dates.Hour(24))

    template = get_template_dispatch_with_network(
        IOM.NetworkModel(
            POM.PTDFPowerModel;
            PTDF_matrix = PNM.PTDF(sys),
            evaluations = let ec = IOM.EvaluationContainer()
                IOM.add_evaluator!(ec, PFS.PowerFlowEvaluationModel, PFS.PTDFDCPowerFlow())
                ec
            end,
        ),
    )
    IOM.set_device_model!(template, IOM.DeviceModel(PSY.Source, IOM.FixedOutput))
    model = IOM.DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test IOM.build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test IOM.solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = IOM.get_optimization_container(model)
    pf_e_data =
        only(values(IOM.get_evaluation_data(IOM.get_evaluations(container))))
    input_key_map = get_input_key_map(pf_e_data)

    @test haskey(input_key_map, :active_power_in)
    @test haskey(input_key_map, :active_power_out)

    in_keys = collect(keys(input_key_map[:active_power_in]))
    out_keys = collect(keys(input_key_map[:active_power_out]))
    @test any(
        k ->
            IOM.get_entry_type(k) == POM.ActivePowerInTimeSeriesParameter &&
                IOM.get_component_type(k) == PSY.Source,
        in_keys,
    )
    @test any(
        k ->
            IOM.get_entry_type(k) == POM.ActivePowerOutTimeSeriesParameter &&
                IOM.get_component_type(k) == PSY.Source,
        out_keys,
    )

    data = IOM.get_inner_data(pf_e_data)
    bus_lookup = PFS.get_bus_lookup(data)
    source_bus_ix = bus_lookup[PSY.get_number(PSY.get_bus(source))]
    n_time_steps = length(IOM.get_time_steps(container))

    in_param = IOM.lookup_value(
        container, IOM.ParameterKey(POM.ActivePowerInTimeSeriesParameter, PSY.Source),
    )
    out_param = IOM.lookup_value(
        container, IOM.ParameterKey(POM.ActivePowerOutTimeSeriesParameter, PSY.Source),
    )

    other_injection_at_bus = zeros(n_time_steps)
    for (key, comp_map) in input_key_map[:active_power]
        result_data = IOM.lookup_value(container, key)
        for (dev_name, bus_ix) in comp_map
            bus_ix == source_bus_ix || continue
            for t in 1:n_time_steps
                other_injection_at_bus[t] += IOM.jump_value(result_data[dev_name, t])
            end
        end
    end

    source_net = [
        IOM.jump_value(out_param["source", t]) - IOM.jump_value(in_param["source", t])
        for t in 1:n_time_steps
    ]
    @test isapprox(
        data.bus_active_power_injections[source_bus_ix, 1:n_time_steps] .-
        data.bus_active_power_withdrawals[source_bus_ix, 1:n_time_steps],
        other_injection_at_bus .+ source_net;
        atol = 1e-9,
    )
    @test !all(isapprox.(source_net, 0.0; atol = 1e-10))
end
```

- [ ] **Step 5: Ensure necessary imports/usings are in scope at the top of the test file**

```bash
grep -n "^import\|^using\|^const" test/test_power_flow_in_the_loop.jl | head -20
```

Confirm `IOM`, `POM`, `PFS`, `PSY`, `PNM`, `JuMP`, `TimeSeries`, `Dates`, and `HiGHS_optimizer` are all in scope. If `TimeSeries` or `Dates` is missing, add the import at the top of the file (or the runtests harness — whichever pattern the file already uses).

- [ ] **Step 6: Stage**

```bash
git add test/test_power_flow_in_the_loop.jl
```

---

## Task 5: Run the formatter

- [ ] **Step 1: Run POM formatter**

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
```

- [ ] **Step 2: Stage formatter diffs**

```bash
git add -u
```

---

## Task 6: Run the full test suite

- [ ] **Step 1: Run POM tests**

```bash
julia --project=test -e 'using Pkg; Pkg.test("PowerOperationsModels")' 2>&1 | tee /tmp/pom-tests-task6.log | tail -80
```

Expected: all tests pass, including the three new testsets ported from PS.

- [ ] **Step 2: If any of the three new tests fail, diagnose by symptom**

- `KeyError(:active_power_in)` or `KeyError(:active_power_out)` in `_update_headroom_participation_factors!` → Task 3 step 5 (the bare-indexing rewrite assumes Task 1 step 2 ran first).
- `MethodError` on `_pf_in_out_discharge_max(::PSY.Source)` → Task 3 step 3 not applied to the right place.
- Equality miss between `data.bus_active_power_injections - bus_active_power_withdrawals` and `(p_out − p_in) / base_power` in testset 1 → the additive `+= / -=` in Task 2 step 1 collided with another `:active_power` mapping that also touches the source bus. The PS test note "Net bus injection = injections − withdrawals; loads route to withdrawals under the same `:active_power` category and the difference folds them back in" applies. Walk the input map for the source bus and confirm no doubly-mapped key.
- `computed_gspf[t][(Source, "source")]` missing when net > 0 → Task 3 step 5 didn't actually call `_accumulate_in_out_headroom!`, or the PF data type isn't multi-period (verify with `PFS.supports_multi_period(pf_data)`).
- `transform_single_time_series!` argument-type mismatch in testset 3 → use the namespaced `PSY.transform_single_time_series!` and pass `Dates.Hour(24)` (not `Hour(24)`), unless `Dates` is exported into the test module.

- [ ] **Step 3: Final cross-reference against the PSI source**

Diff the new testset bodies against the PS originals:

```bash
diff <(sed -n '/@testset "Power Flow in the loop with separate in\/out/,/^end$/p' test/test_power_flow_in_the_loop.jl) <(cd /Users/jlara/cache/PowerSimulations.jl && git show copilot/fix-input-output-active-power:test/test_power_flow_in_the_loop.jl | sed -n '/@testset "Power Flow in the loop with separate in\/out/,/^end$/p')
```

Expect only namespacing differences (`IOM.` vs `PSI.`, `POM.` vs `PSI.`). No semantic divergence.

---

## Risks and follow-ups

- **Variable-type ownership.** Task 1 step 1 assumes `ActivePowerInVariable`/`ActivePowerOutVariable` live in IOM. If POM owns them (the `export` at `src/PowerOperationsModels.jl:455-456` is consistent with both), substitute the namespace globally before running. The grep at Task 1 step 1 resolves this.
- **`make_5_bus_with_import_export` parity.** The POM and PSI test utilities both define a function of this name (POM at `test/test_utils/iec_test_systems.jl:8`, PSI at `test/test_utils/iec_simulation_utils.jl:5`). Confirm the POM version supports the `add_single_time_series` kwarg used by testsets 1 and 3; if not, port the kwarg from the PSI version.
- **Storage tests.** This plan ports only Source-based tests from PS. PS's full branch also touches Storage (BookKeeping). POM does not yet have an in-tree Storage formulation that uses `ActivePowerInVariable`/`ActivePowerOutVariable` (check `src/static_injector_models/` — at the time of writing, no `storage_*.jl`). Storage in/out coverage is a follow-up once POM has the formulation; for now the headroom code is exercised through Source.
- **`active_power_inputs === nothing` removal.** Task 3 step 5 drops the legacy guard. Any external consumer that constructed a `PowerFlowEvaluationData` with a hand-built `input_key_map` *missing* `:active_power` will now `KeyError`. POM's only constructor is the one in `pf_input_mapping.jl`, which always populates all three keys after Task 1 — but flag this loud if a user reports it.

## Self-Review

**1. Spec coverage:**
- `PF_INPUT_KEY_PRECEDENCES` additions for `:active_power_in` / `:active_power_out` → Task 1 step 1.
- `pf_input_keys` extension for all five PF-data types → Task 1 step 2.
- `_update_pf_data_component!` for in/out + the `comp.active_power = 0.0` reset loop → Task 2.
- `_pf_in_out_discharge_max` + `_accumulate_in_out_headroom!` + wiring → Task 3.
- Tests for variable path / headroom path / parameter path → Task 4.
- Format + test → Tasks 5, 6.

**2. Placeholder scan:** the only deliberate placeholders are namespace TBDs in Task 4 (resolved by the grep in Task 1 step 1 and Task 4 step 1). All other code blocks are copy-pasteable.

**3. Type consistency:** `IOM.get_inner_data` / `IOM.get_evaluation_data` / `IOM.get_evaluations` are used consistently. The PSY-vs-IOM-vs-POM split for `ActivePowerInVariable` and `ActivePowerInTimeSeriesParameter` is flagged in two places (Task 1 step 1 and Task 4 step 1) so it doesn't drift mid-port.
