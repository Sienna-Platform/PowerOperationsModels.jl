# Service container construction by density - implementation plan

Status: IMPLEMENTED (2026-07-21) via subagent-driven development. Per-type service API
(one `ServiceModel` per type, no name), per-type construction (no grouping), dense
service-indexed containers via reused device builders, sparse device-indexed per service,
per-service contributing devices from the nested `contributing_devices_map`, `use_slacks`
per type. Commits: IOM `4e1fefd` (rh/dev_service_refactor); POM `bd42c0c` (per-type API +
construction), `5fe3f17` (dense flips), `50eda7f` (regression tests) on
rh/dev_refactor_services. Deferred (still `meta`): storage/hybrid reserve sub-containers,
transmission-interface containers, ORDC piecewise cost params.
Date: 2026-07-20 (plan); 2026-07-21 (implemented).
Supersedes the "Option A / Option B" sketch previously in this file and the grouped
`Vector{Vector{PSY.Device}}` construction shipped in PR1
(`.claude/plans/sparse-service-containers.md`).

## API change: per-type service models (part of this effort)

`set_service_model!` becomes **type-keyed**, mirroring `set_device_model!`. A service type
has exactly one model; per-service-name models are removed. The user-facing call is
unchanged in shape (`set_service_model!(template, ServiceModel(VariableReserve{ReserveUp},
RangeReserve))`), it just no longer accepts a name.

The seed already exists: the no-name `ServiceModel(type, formulation)` constructor marks
`aggregated_service_model = true`, and `_populate_aggregated_service_model!` currently
**expands** each aggregated model into one per-name model per service (then
`_populate_contributing_devices!` fills each). The change is to **stop expanding** and keep
the single per-type model, constructing it directly over all services of the type.

Concrete changes:

- **`ServiceModel{D, B}` (IOM):** drop `service_name` (or leave a vestigial
  `NO_SERVICE_NAME_PROVIDED`); the no-name constructor becomes canonical. Since one model
  now represents every service of its type, `contributing_devices_map` becomes **per
  service**: `Dict{String, Dict{DataType, Vector{<:Component}}}` (service name -> device
  type -> devices). Accessors: `get_contributing_devices_map(model, service_name)` and
  `get_contributing_devices(model, service_name)` (flattened for one service), plus the
  existing whole-map accessor for finalize wiring.
- **`ServicesModelContainer` (IOM):** `Dict{Symbol, ServiceModel}` keyed by
  `Symbol(service_type)`, exactly like `DevicesModelContainer` (one formulation per service
  type). Replaces `Dict{Tuple{String, Symbol}, ServiceModel}`. `set_model!` keys by
  `Symbol(get_component_type(model))`.
- **`set_service_model!` (POM):** keep `(template, model)` and `(template, type,
  formulation)`; **remove** the `(template, name, ...)` variants and the `use_service_name`
  kwarg.
- **Contributing devices - built once at finalize, read from the map everywhere:** the
  per-service `contributing_devices_map` is populated **once** by
  `_populate_contributing_devices!` (one `PSY.get_contributing_device_mapping(sys)` sweep,
  filtered per service by available / modeled / not-incompatible, each device pushed to its
  concrete-type vector - no `convert` copies). Every consumer then reads references from the
  map per service: reserve construction (`get_contributing_devices(model, service_name)` for
  the sparse fill), the reserve->expression folds, and transmission-interface construction
  (`get_contributing_devices_map(model, interface_name)`). This is the "read once, pass
  around" ideal - the read happens once at finalize and is reused across both construct
  stages and all builders; nothing is re-read or copied during construction.
- **Template finalize (POM):** delete `_populate_aggregated_service_model!` (the model stays
  type-level, no expansion). Keep `_populate_contributing_devices!`, extended to fill the
  per-service nested map for **all** services of each type-model. `_add_services_to_device_model!`
  reads device types from the map as today.
- **Construction (POM):** no grouping. `construct_service!(model::ServiceModel{SR, F})` is
  called once per type; it iterates the type's services, builds the dense service-indexed
  containers over them, and populates the sparse device containers per service by reading
  each service's contributing devices from the map - the exact `construct_device!` shape.
  This is what makes the grouping in the earlier draft unnecessary: the template already
  holds one model per type.
- **Tests:** every `ServiceModel(T, F, "name")` becomes `ServiceModel(T, F)`; name-based
  `set_service_model!` calls drop the name. The PR1 container-count/shape assertions (one
  container per type) already reflect the merged shapes and largely stand.

`use_slacks`/attributes are then per-type by construction (one model per type) - see below.

## Guiding principle

Decide each service variable / constraint / parameter container by a single question:
**does it depend on the contributing-device axis?**

- **Device-dependent → SPARSE**, shared 3D container keyed `(service, device, time)`,
  populated **per service** via `lazy_container_addition!(...; sparse = true)`. Each
  service appends its own `(service, device, t)` slice directly from
  `get_contributing_devices(model)`. No intermediate `Vector{Vector{device}}`, no `convert`
  copies, no cross-service `unique!`.
- **Service-only (independent of contributing devices) → DENSE**, 2D container keyed
  `(service, time)`, built **once per service type** by **reusing the existing dense
  component infrastructure** with the services themselves as the axis-1 "components". This
  is the same battle-tested path devices use; nothing new to write for these.

The device-dependent containers are the only place a large (thousands-of-devices)
dimension appears, and they never leave the per-service path, so the construction cost is
proportional to the work each service already does - the performance concern that motivated
this revision is gone.

## Classification

| Container | Device-dependent? | Density | How it is built |
|---|---|---|---|
| `ActivePowerReserveVariable` | yes | sparse `(service, device, t)` | per-service lazy add |
| `ParticipationFractionConstraint` | yes | sparse `(service, device, t)` | per-service lazy add |
| `RampConstraint` | yes | sparse `(service, device, t)` | per-service lazy add |
| `ReservePowerConstraint` | yes | sparse `(service, device, t)` | per-service lazy add |
| `RequirementConstraint` | no | dense `(service, t)` | dense container once + reserve fill |
| group `RequirementConstraint` (ConstantReserveGroup) | no | dense `(group, t)` | dense container once + fill |
| `ReserveRequirementSlack` | no | dense `(service, t)` | reuse dense variable infra, once |
| `ServiceRequirementVariable` | no | dense `(service, t)` | reuse dense `add_variables!`, once |
| `RequirementTimeSeriesParameter` | no | dense `(service, t)` | reuse dense param infra, once |
| duals of the above constraints | mirror constraint | dense/sparse as its constraint | IOM `_assign_dual_from_existing!` |

## Dense path - reuse the device infrastructure

All dense containers are service-indexed, so a service is treated exactly like a component
whose name is the service name. Reuse (no new container code):

- **`ServiceRequirementVariable`**: call the existing device
  `add_variables!(container, ServiceRequirementVariable, services, formulation)`. It already
  dispatches `get_variable_binary(T, service_type, F)` / `get_variable_upper_bound(T,
  service, F)` / `get_variable_lower_bound(...)`, and those `(T, service, F)` methods
  already exist in `reserves.jl`. Being dense, `axes(variables)` works, so the ORDC
  delta-PWL `add_pwl_constraint_delta!` path is satisfied with no change (this is why it was
  forced dense in PR1 - here it is dense *by principle* and the reuse makes it free).
- **`ReserveRequirementSlack`**: same - build once over the type's services via the dense
  variable infra, then add the penalty objective terms.
- **`RequirementTimeSeriesParameter`**: reuse the dense parameter infrastructure
  (`add_param_container!` + dense `_set_parameter_at!` / `_set_multiplier_at!`, keyed by
  integer service index), one container per type over the service vector. (This is what the
  merged `_add_parameters!` added in PR1 already does; keep it. Sparse parameters remain
  unsupported in IOM and are not needed here.)
- **`RequirementConstraint`** and the group `RequirementConstraint`: no generic device
  constraint builder to reuse, but the dense *container* is created once via
  `add_constraints_container!(container, T, SR, service_names, time_steps)` (no meta) and
  filled per service (`constraint[service_name, t] = ...`) with the reserve-specific
  summation over the service's slice of the sparse `ActivePowerReserveVariable`.
- **Duals** mirror their (now dense) constraint container via IOM's existing
  `_assign_dual_from_existing!` dense branch.

### `use_slacks` and attributes are per-type (services mirror device models)

In the target design `set_service_model!(template, model)` registers one model per service
**type** (exactly like `set_device_model!`), so a type has a single `use_slacks`/attributes
selection - it is structurally impossible for `Service1` and `Service2` of the same type
(both `VariableReserve{ReserveUp}`) to differ. Therefore `use_slacks` is a **per-type**
property, handled exactly as for devices:

- Build `ReserveRequirementSlack` dense over **all** services of the type when the type uses
  slacks, and not at all otherwise. No per-service subset, no per-service check, no assert.
- attributes are likewise per-type.

Transition note: while the template still keys models per service name, the per-type
grouping (below) yields the type's model set and the type-level `use_slacks`/attributes are
read from it (identical across the set in the target design). Once `set_service_model!` is
type-keyed, the grouping collapses to one model per type and `construct_service!` mirrors
`construct_device!` directly - it queries all services of the type from the system, builds
the dense service-indexed containers over them, and populates the sparse device containers
per service.

## Sparse path - per-service population

`ActivePowerReserveVariable` and the three device constraints share one 3D sparse container
per `(entry type, service type)`. Each service, in its own construction step:

```julia
variable = lazy_container_addition!(container, T, SR, sparse = true)  # first service creates
for t in time_steps, d in get_contributing_devices(model)
    variable[(service_name, get_name(d), t)] = @variable(...)
end
```

`get_contributing_devices(model)` is the optimized per-service call; its result is consumed
in place. The container's key type (`Tuple{String, String, Int}`) is fixed at creation from
a representative axis, not from a materialized device-name union.

## Construction flow

With the per-type API, `construct_services!` iterates the template's type-models directly -
no grouping (the template already holds one model per service type). Each
`construct_service!(model::ServiceModel{SR, F})` handles the whole type, over
`services = get_available_components(model, sys)`:

- **ArgumentStage**: build the dense `RequirementTimeSeriesParameter` and dense
  `ServiceRequirementVariable` once over `services` (reused component infra); then per
  service populate the sparse `ActivePowerReserveVariable` from that service's contributing
  devices (read from the map), fold reserves into device range expressions, add feedforward
  arguments.
- **ModelStage**: build the dense `RequirementConstraint` (and, if the type uses slacks, the
  dense `ReserveRequirementSlack` over all the type's services) once; then per service fill
  the requirement column and populate the sparse device constraints and objective terms;
  then once, add the constraint duals.

Interfaces and the group reserve stay as today (Q5 defers the interface migration; the group
reserve is constructed last and reads the merged containers). The device dimension is only
ever touched per service, so there is no `Vector{Vector{device}}` and no `convert` copy.

## Changes from PR1-as-implemented

1. **API**: type-keyed `set_service_model!`; `ServiceModel` drops `service_name`;
   `ServicesModelContainer` becomes `Dict{Symbol, ServiceModel}`; `contributing_devices_map`
   becomes per-service nested (`Dict{String, Dict{DataType, Vector}}`), populated once at
   finalize and read by reference everywhere (reserve construction, folds, interface); remove
   `_populate_aggregated_service_model!` expansion and the per-name `set_service_model!`
   variants. (See the API section above.)
2. Construction: remove the grouping added in PR1 (`_group_reserve_service_models`,
   `_collect_reserve_group`); `construct_service!` runs once per type over all its services.
3. `add_service_variables!` (IOM): per-service signature
   `(container, ::Type{T}, service, contributing_devices, ::Type{F})` that lazily creates
   the shared sparse container and fills one service's slice. Drop the grouped
   `Vector{<:AbstractVector{V}}` signature and the `Vector{Vector{PSY.Device}}` it consumed.
4. Flip `RequirementConstraint`, `ReserveRequirementSlack`, group `RequirementConstraint`
   from sparse (PR1 convenience) to **dense**, created once per type via the reused dense
   component infrastructure (`add_variables!` / `add_constraints_container!`), filled per
   service.
5. `use_slacks` / `attributes`: per-type by construction (one model per type); slack built
   uniformly over the type's services when the type uses slacks.
6. Keep the sparse device containers (`ActivePowerReserveVariable`, participation, ramp,
   reserve-power) and the merged dense `RequirementTimeSeriesParameter` as-is in shape.

Net: no grouping - the per-type model *is* the group. The device dimension is handled
strictly per service (no `Vector{Vector{device}}`, no `convert` copy); the service-indexed
containers are dense and built once per type through the reused device infrastructure.

## Deferred follow-ups tied to the transmission-interface migration (Q5)

The transmission-interface containers are still `meta`-keyed and built per interface (their
container merge is deferred). When interfaces migrate to per-type merged containers like
reserves did, also do the following cleanup:

- **Retire the single-service `TimeSeriesParameter` `_add_parameters!`** (POM
  `common_models/add_parameters.jl`, the `service::U` method ~line 825). Its only live
  caller today is interface construction — `add_parameters!(container,
  Min/MaxInterfaceFlowLimitParameter, interface, model)` per interface
  (`services_constructor.jl:885-886`; both params are `<: TimeSeriesParameter`). It is NOT
  tied to ORDC (ORDC uses the `AbstractPiecewiseLinear*` path), so removing ORDC does not
  retire it. Once interfaces build their flow-limit params over the type's interfaces in one
  shot, switch those calls to the **vector** `_add_parameters!` (~line 875, currently used
  only by the merged reserve `RequirementTimeSeriesParameter`) and delete the single-service
  method — assuming no other per-service `TimeSeriesParameter` caller remains (grep to
  confirm before removing).

## Deferred: type-stability follow-ups (luke-kiernan PR #141 review)

Two build-time type-instability spots luke flagged. The low-risk parts are done; the
function-barrier / structural parts are deferred to revisit once the refactor settles.

- **Dual loop** (`add_constraint_dual.jl` service method). DONE: use `constraint_type`
  directly instead of the redundant `get_entry_type(key)` (IOM `4a11ebd`). DEFERRED: genuine
  stability is NOT reachable with a function barrier here — verified `@code_warntype` red on
  `key::ConstraintKey`, `existing::Any`, `dual_key::Any` even inside a concrete-typed barrier.
  Roots are structural: `OptimizationContainer.constraints::OrderedDict{ConstraintKey,
  JuMPArray}` has abstract key/value types, the `ConstraintKey` constructor doesn't infer
  concretely, and `duals::Vector{DataType}`. A real fix means concrete-parameterizing the
  container's dict key/value types (and the `duals` field) across DeviceModel/NetworkModel/
  ServiceModel — a broad IOM change touching a surface CLAUDE.md warns against churning, and
  this runs once per build over a handful of keys. Track as a separate structural issue if
  ever justified; the Dense-vs-Sparse dispatch that matters is already a multiple-dispatch
  barrier via `_assign_dual_from_existing!`. REJECTED: meta-registry (removes no dispatch;
  adds container bookkeeping).
- **Contributing-device flatten** (`get_contributing_devices`, `service_model.jl`). DONE:
  the model-skip guard no longer flattens (`isempty(get_contributing_devices_map(m))`, POM
  `ddbed2b`). DEFERRED: the per-type-group function barrier — iterate the map's
  `Dict{DataType, Vector}` groups (each runtime-concrete) and call the existing barriers
  (`add_service_variables!`, `_sum_service_reserves`, participation/ramp/reserve-power) once
  per homogeneous group, recovering stability for multi-type reserves. It's the correct
  shape (mirrors the fold at `add_to_expression.jl:2453`) but: (a) only helps mixed-type
  reserves — single-type is already stable and `add_service_variables!` is already a barrier;
  (b) build-time only, dispatch ~1.6% of per-device cost (JuMP `@variable` dominates ~60x);
  (c) changes the `lazy_container_addition!` merge cadence (one slice per service -> per
  group), needing test re-verification. Low priority; revisit when the refactor is ready.
  REJECTED: IS #505 typed-heterogeneous container + `@generated` (heavy, unjustified for a
  build-time path when the per-group barrier reuses existing machinery).

## Failure-mode analysis

| # | Codepath | Realistic failure | Covered? | Gap |
|---|---|---|---|---|
| F1 | dense `RequirementConstraint` fill | sums another service's device slice | existing 2-same-type-service isolation test (coefficient-level) | keep the test |
| F2 | per-service objective over sparse container | prices a variable more than once | existing objective-coefficient test | keep the test |
| G1 | per-type `use_slacks` dense slack | slack built/omitted inconsistently with the type setting | build the slack over all the type's services iff the type uses slacks (device-model pattern); multi-service build+solve with slacks on | per type, no assert |
| G2 | dense service container completeness | a modeled service missing from the dense axis (never filled) → NaN in requirement RHS / solver error | partial | build the dense axis from the same service list that drives the fill loop; add a same-type multi-service build+solve assert |
| G3 | sparse `ActivePowerReserveVariable` first-creation key type | container created from a service whose axis mis-infers the tuple type | none | create with an explicit `(String, String, Int)`-inducing axis; covered by any reserve build test |

## Test matrix

- Existing services suite (rewritten shapes) + the 2-same-type-service isolation test must
  stay green.
- New: a service type with `use_slacks = true` builds a slack column for every service of
  the type and wires it into each requirement constraint; with `use_slacks = false` no
  slack container exists (G1).
- New: two services of one type where one has strictly fewer contributing devices - dense
  requirement + sparse variable both build and solve; results columns present for both (G2).
- Reuse check: `ServiceRequirementVariable` built via the device `add_variables!` produces
  the same container shape/bounds as before (ORDC build+solve unchanged).
- `Test.detect_ambiguities` = 0; full POM + IOM suites; formatter.

## Open questions for Rodrigo

- **Q-A**: RESOLVED - `use_slacks`/attributes are per **type** (services mirror device
  models); slack built uniformly over the type's services when the type uses slacks, else
  omitted. No per-service option, no assert.
- **Q-B (scope)**: RESOLVED - the per-type `set_service_model!` API change is in this
  effort. Construction is written directly per type (no grouping), mirroring
  `construct_device!`; `ServiceModel` drops the per-name `service_name`; per-name
  `set_service_model!` is removed; tests migrate `ServiceModel(T, F, "name")` ->
  `ServiceModel(T, F)`.
- **Q-C**: reuse the device `add_variables!`/`add_constraints_container!` directly for the
  dense service containers (recommended), or add thin `add_service_*` dense wrappers for
  readability? Recommendation: reuse directly; add a wrapper only if a call site needs
  service-specific base names.
- **Q-D**: RESOLVED - **keep** `contributing_devices_map`, made per-service
  (`Dict{String, Dict{DataType, Vector}}`), populated once at finalize and read (by
  reference) everywhere - reserve construction, folds, and interface construction. This is
  the read-once/pass-around ideal without threading locals, and no `convert` copies.
- **Q-E (interface)**: RESOLVED by keeping the map - transmission-interface construction
  reads its per-interface contributing devices from
  `get_contributing_devices_map(model, interface_name)`, so the stored map serves the
  interface path directly. Interface still adapts to the type-keyed model (one model for all
  interfaces, construction iterates them), and its container merge still defers (Q5), but no
  compat shim and no read-at-build churn.
