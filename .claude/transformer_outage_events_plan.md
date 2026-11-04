# Transformer outage events (DCP + StaticBranchBounds)

## Context
Commit 7d3d49e7 added `FixedForcedOutage` events for `PSY.Line` under
`DCPNetworkModel` + `StaticBranchBounds`: the line's Ohm's-law row gets its `va`
coefficients scaled by `AvailableStatusParameter` (via `IOM.add_parameter_coefficient!`),
plus status-scaled flow bounds; no reductions, no merged arcs, no islanding. Extend this to
`PSY.TwoWindingTransformer` and `PSY.ThreeWindingTransformer`, rejecting transformers whose
control is actually modeled under DCP (`ACTIVE_POWER_FLOW` → `PhaseShifterAngle`).
VOLTAGE/REACTIVE objectives are fixed taps under DCP and stay allowed.

Two things differ from Line:
1. **Fixed phase shift.** The DCP row is `p == b·(va_f − va_t − shift)`; a transformer
   with α ≠ 0 has a constant `b·shift` that must also vanish when open, otherwise the
   outaged row reads `0 == −b·shift` (infeasible).
2. **3W devices** own three winding arcs (`"$(name)_winding_$i"`, terminal → star bus).
   One device status drives all three rows; opening it isolates the star bus, which must not
   count as islanding.

## Changes

### `src/event_models/event_arguments.jl`
- `const _OUTAGE_BRANCHES = Union{PSY.Line, PSY.TwoWindingTransformer, PSY.ThreeWindingTransformer}`
  (define once, e.g. in `event_traits.jl`, and reuse).
- Generalize `add_event_arguments!` signature to
  `devices::Vector{T}, DeviceModel{T, StaticBranchBounds}, NetworkModel{DCPNetworkModel}`
  `where {T <: _OUTAGE_BRANCHES}`.
- New dispatch helper mapping a device to its arc (rep) names:
  `_outage_arc_names(d::Union{PSY.Line, PSY.TwoWindingTransformer}) = (PSY.get_name(d),)`;
  `_outage_arc_names(d::PSY.ThreeWindingTransformer) = ntuple(i -> "$(name)_winding_$i", 3)`.
- `_validate_line_events` → `_validate_branch_events(devices, device_model, network_model)`,
  iterating each device's reps from `_representative_branches(network_model, T, NetworkFlowConstraint)`:
  - existing reduction check, `DirectArc` provenance check, and
    `_constrains_angle_difference(rep)` (rep-based; false for transformers already);
  - new: `isempty(_controlled_circuit_names(rep, device_model, network_model))` else error
    ("…has a modeled control objective; outage events are not supported on controlled transformers").
    Reuses `RepresentativeBranch.jl:228`.
- `_check_line_events_keep_connectivity` → `_check_branch_events_keep_connectivity`: zero
  adjacency entries using `rep.arc` bus numbers (generic over all three types instead of
  `PSY.get_arc`), then count islands ignoring subnetworks that consist only of outaged 3W
  star buses (`PSY.get_number(PSY.get_star_bus(t))`). Dispatch a
  `_isolated_star_buses(devices)` helper: empty for Line/2W, star numbers for 3W.

### `src/event_models/event_constraints.jl`
- Generalize `add_event_constraints!` / `_add_line_outage_constraints!` →
  `_add_branch_outage_constraints!` over `T <: _OUTAGE_BRANCHES`. Constraint containers stay
  indexed by arc (rep) name; status read as `status[PSY.get_name(device), t]`, flow /
  Ohm's row / rating by arc name (`_flow_limits(rep, device_model).max`).
- Shift: for reps with `_dc_shift(rep) != 0`, move the constant onto status so it scales with
  it. Use dispatch on the parameter element type (no runtime `if`):
  `_scale_shift_by_status!(row, s::JuMP.VariableRef, c)` → `set_normalized_coefficient(row, s, c)` + `set_normalized_rhs(row, 0)`;
  `_scale_shift_by_status!(row, s::Float64, c)` → `set_normalized_rhs(row, -c·s)`.
  (`c = b·shift`, matching the sign in `AC_branches.jl:2236`.) Lines have shift 0 so this is
  a no-op for them.

### `src/event_models/event_traits.jl`
- `supports_events(::Type{<:PSY.TwoWindingTransformer}) = true`, same for `ThreeWindingTransformer`.

### `src/operation/template_validation.jl`
- Widen `_check_event_support` to `DeviceModel{<:_OUTAGE_BRANCHES}` (error) and
  `DeviceModel{<:_OUTAGE_BRANCHES, StaticBranchBounds}, NetworkModel{DCPNetworkModel}`
  (nothing); update error text to "Branch outage events require…". Keep the user's pending
  comment edit.

No constructor changes: `branch_constructor.jl` DCP SBB stages are already generic over
`T <: PSY.ACTransmission` and call `add_event_arguments!` / `add_event_constraints!`.

## Tests (`test/test_events.jl`)
Mirror the existing "A DCP line outage costs the same as removing the line" testset:
1. **2W, with phase shift:** `c_sys14`, `TwoWindingTransformer => StaticBranchBounds`,
   outage `Trans1` (meshed) with `PSY.set_α!(circuit, 0.05)`; status 0 → cost equals system
   with `Trans1` removed, flow 0; status 1 → intact cost.
2. **3W:** `_sys5_with_3w()` plus an extra `Line` from each terminal bus to the existing
   network so the outage doesn't island the terminals; same removed/intact comparisons;
   all three winding flows 0 when open.
3. **Rejections:** `_controlled_sys14(P_FLOW_CONTROL)` with an outage on the controlled
   transformer → build `FAILED`; 2W event under `StaticBranch` → `_check_event_support`
   throws; (optional) radial `Trans4` outage → islanding error.

## Verification
- `julia --project=test test/runtests.jl test_events > $SCRATCH/events.log 2>&1`
- Then transformer/branch files: `test_runtests … test_device_branch`, `test_transformer` (whatever `--list` shows).
- Formatter, then full suite `--jobs=8` captured to a scratch log.
- Leave edits unstaged.
