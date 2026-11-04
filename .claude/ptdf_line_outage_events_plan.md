# Line outage events under PTDFNetworkModel (StaticBranchBounds)

## Context
Commit 7d3d49e7 added `FixedForcedOutage` events for `PSY.Line` under DCP + SBB. Each
outaged line's Ohm's-law `va` coefficients are scaled by `AvailableStatusParameter` through
IOM's `ParameterCoefficientTerm`, which sets `coef = base × status`.

Under PTDF, every monitored arc `m` (every SBB branch type, not only Lines) has a row
`flow_expr[m,t] − flow[m,t] (− slacks) == 0`, where `flow_expr = Σ_bus PTDF[m,bus]·balance[bus,t]`.
An outage changes the injection-variable coefficients in **every** row. The new values come
from the post-outage PTDF row `vmodf[arc_m, mod]`, where `mod` merges the
`NetworkModification`s of all lines out at `t`. That is not `base × status`, so:

- IOM's coefficient term becomes abstract. POM adds a PTDF term that recomputes rows from a
  `VirtualMODF` sharing the network's factor core.
- The term stores `ConstraintKey`s, not refs, so rows of branch types built later can join.
  Each SBB branch type registers its own rows during its PTDF `ModelConstructStage` and
  applies the current status immediately. Build order doesn't matter: every branch
  `ArgumentConstructStage` (where the term is created) runs before any branch `ModelConstructStage`.

Naive scope: one VirtualPTDF as usual. At build and on each `update_parameter_coefficients!`,
for each `t` whose outage set changed, swap the row coefficients from the old set's PTDF to
the new set's. When nothing is out, use the base PTDF row.

## IOM (`InfrastructureOptimizationModels.jl/transmission-events`)

### `src/core/parameter_container.jl` / `parameter_coefficients.jl`
- `abstract type AbstractParameterCoefficientTerm end`; `ParameterCoefficientTerm <: AbstractParameterCoefficientTerm`.
- Public interface `apply_parameter_coefficient!(container, term, parent_param)`. Rename the
  current `_set_parameter_coefficient!` to this, with the concrete `ParameterCoefficientTerm`
  method. POM extends it, so it must not be an `_` reach.
- `add_parameter_coefficient_term!(container, key, term)`: push the term, then apply it once.
  `add_parameter_coefficient!` builds a `ParameterCoefficientTerm` and calls this.
- Storage stays type-stable per key: the container field becomes
  `Dict{ParameterKey, AbstractVector{<:AbstractParameterCoefficientTerm}}`. The first push
  creates `Vector{typeof(term)}`; pushing a different term type under the same key errors
  (one mechanism per key per build). `update_parameter_coefficients!` passes the concrete
  vector through a function barrier, so the loop is dispatched at compile time.
- `get_parameter_coefficient_terms(container, key)` (public getter; returns `nothing` if absent).
- Export the new names. Update `test/test_parameter_coefficients.jl` for the rename, and add a
  test that a dummy term type dispatches through `update_parameter_coefficients!`.

## POM

### `src/event_models/ptdf_outage_terms.jl` (new, included after `event_constraints.jl`)
```julia
struct PTDFOutageCoefficientTerm{P, M} <: IOM.AbstractParameterCoefficientTerm
    ptdf::P                                   # network VirtualPTDF
    vmodf::M                                  # VirtualMODF(PNM.get_core(ptdf), sys; automatically_register_outages=false)
    line_mods::Vector{PNM.NetworkModification} # per event line, indexed like the status param rows
    line_rows::Vector{Int}                    # status-param row index of each event line
    rows::Vector{Tuple{ConstraintKey, Vector{String}, Vector{Tuple{Int,Int}}}}  # key, names, arcs
    applied::Vector{Vector{Int}}              # per t: indices (into line_rows) currently applied
end
```
- `IOM.apply_parameter_coefficient!(container, term::PTDFOutageCoefficientTerm, status)`: for
  each `t`, compute `out = [k for k in eachindex(line_rows) if jump_fixed_value(status[line_rows[k], t]) < 0.5]`.
  If `out == applied[t]`, skip. Otherwise, for every registered row, apply
  `_swap_ptdf_row!(row_ref, old_row, new_row, balance[:, t])` and set `applied[t] = out`.
  - `_merged_modification(term, out)`: `nothing` when empty (dispatch), otherwise
    `PNM.NetworkModification("events", reduce(vcat, collect.(getfield.(mods, :arc_modifications))))`.
  - `_post_row(term, arc, ::Nothing) = term.ptdf[arc, :]`;
    `_post_row(term, arc, mod::PNM.NetworkModification) = term.vmodf[arc, mod]`.
  - `_swap_ptdf_row!`: `delta = new − old`. For each bus with `|delta| > PTDF_ZERO_TOL`, add
    `delta[bus]·balance[bus,t]` into the row: `set_normalized_coefficient(row, v, current + d)`
    per variable, and move the constant into the RHS (`set_normalized_rhs(row, rhs − c)`).
    Coefficients are read from the constraint itself, so no base snapshot is needed, and the
    row's own terms (flow var, slacks, `−b·phase`, shift constant) stay untouched. Lines carry
    no shift, so the outaged arc's shift injection doesn't change.
- `_register_ptdf_outage_rows!(container, ::Type{T}, network_model)`: no-op unless a
  `PTDFOutageCoefficientTerm` exists under `ParameterKey(AvailableStatusParameter, PSY.Line)`.
  If it does, push `(ConstraintKey(NetworkFlowConstraint, T), names, rep arcs)` from
  `_representative_branches(network_model, T, NetworkFlowConstraint)`. Then apply the current
  status to just those new rows: their state is the base PTDF, so treat their `applied` as empty.
  To keep this simple, every newly registered row block gets its own per-`t` applied state.

### `src/event_models/event_arguments.jl`
- `add_event_arguments!(…, ::Vector{PSY.Line}, ::DeviceModel{PSY.Line, StaticBranchBounds}, ::NetworkModel{PTDFNetworkModel})`:
  validate, run `_add_status_event_arguments!`, then build the VirtualMODF and per-line
  `PNM.NetworkModification(vmodf, line)`. Register the term with
  `IOM.add_parameter_coefficient_term!` (no rows yet, so the initial apply is a no-op).
- Generalize `_validate_line_events` / `_check_line_events_keep_connectivity` over
  `NetworkModel{<:Union{DCPNetworkModel, PTDFNetworkModel}}`:
  - reduction check and `DirectArc` check are unchanged;
  - angle-limit check by dispatch: error under DCP, no-op under PTDF (PTDF SBB writes no
    angle constraints);
  - adjacency by dispatch, `_event_adjacency(network_model)`: DCP uses the Ybus
    `adjacency_data` as today. PTDF builds it from `PNM.get_core(ptdf).A` with the event arcs'
    rows dropped (`A_kept' * A_kept`) on the core's bus axis/lookup, then `PNM.find_subnetworks`.

### `src/event_models/event_constraints.jl`
- Split `_add_line_outage_constraints!` into:
  - `_add_line_outage_flow_bounds!`: the status-scaled `ActivePowerOutageConstraint` ub/lb,
    shared by DCP and PTDF;
  - the DCP-only Ohm's `add_parameter_coefficient!` loop.
- `add_event_constraints!(…, NetworkModel{PTDFNetworkModel})` adds only the flow bounds. The
  outaged arc's own row goes to zero through its MODF row.

### `src/ac_transmission_models/branch_constructor.jl`
- PTDF SBB `ArgumentConstructStage` (~1389): `add_event_arguments!(container, devices, device_model, network_model)`.
- PTDF SBB `ModelConstructStage` (~1410): after `add_constraints!(NetworkFlowConstraint…)`,
  call `_register_ptdf_outage_rows!(container, T, network_model)` and
  `add_event_constraints!(…)`. Both are generic over `T <: PSY.ACTransmission`, and the
  fallbacks are no-ops for non-Line types.

### `src/operation/template_validation.jl`
- `_check_event_support(::DeviceModel{PSY.Line, StaticBranchBounds}, ::NetworkModel{PTDFNetworkModel}) = nothing`.
- In `_build_device_model_events!`, when the network is PTDF and a Line has events, error if
  either of these holds:
  - any branch model is `StaticBranch` or `StaticBranchUnbounded`, because their flow limits
    or reported flows would silently use the pre-outage PTDF;
  - any branch model `supports_outages` (MODF SC rows aren't rewritten).

## Tests (`test/test_events.jl`)
1. **"A PTDF line outage costs the same as removing the line"**: mirror the DCP testset with
   `NetworkModel(PTDFNetworkModel)` on `c_sys5`, line `"1"`. Fix status to 0, call
   `update_parameter_coefficients!`, solve. Then check:
   - the outaged line's flow is 0;
   - the cost matches the system with line `"1"` removed;
   - restoring status to 1 gives the intact cost.
2. **Coefficient check**: after the outage, a monitored line's coefficient on one generator's
   power variable equals `Σ_bus vmodf_row[bus]·coef(gen in balance[bus])`, built independently
   from a fresh `PNM.VirtualMODF(sys)` row.
3. **Mixed types**: `c_sys14` with `TwoWindingTransformer => StaticBranchBounds` and a Line
   outage. The outaged cost equals the removed-line reference, which proves transformer rows
   were rewritten.
4. **Rejections**: PTDF with Line SBB events plus a `StaticBranch` transformer fails;
   an islanding outage under PTDF fails.

## Verification
- IOM: `julia --project=test test/runtests.jl` for the parameter-coefficient test, captured to a scratch log.
- POM: `julia --project=test test/runtests.jl test_events > $SCRATCH/events.log 2>&1`, then
  `test_device_branch` / PTDF network tests, formatter, then the full suite `--jobs=8` to a scratch log.
- Edits left unstaged; new files `git add -N`.
