# Sparse 3D service containers - scoping plan

Status: PR1 (3D refactor) implemented on branches `rh/dev_refactor_services` (POM) and
`rh/dev_service_refactor` (IOM); PR2 (4D AS offers) not started.
Driving repo: POM.
Also touches: IOM.
Date: 2026-07-19 (scoping); 2026-07-20 (PR1 implementation).

## PR1 progress log (2026-07-20)

Decisions applied: Q1 grouped construction; Q2 skip storage/hybrid internals (consumption
sites patched only); Q3 grouped results accepted; Q4 missing-TS handled per-type at the
parameter container; Q5 transmission interface deferred. 4D AS offers deferred to PR2.

Done:
- IOM (`rh/dev_service_refactor`): grouped 3D-sparse `add_service_variables!`
  (`common_models/add_variable.jl`); service dual path mirrors merged constraints
  (`common_models/add_constraint_dual.jl`); EmulationModelStore sparse `write_output!`
  (`operation/emulation_model_store.jl`) + unit test in `test/test_emulation_model_store.jl`.
  Full IOM suite green (1367 tests).
- POM (`rh/dev_refactor_services`): `construct_services!` groups reserves by
  `(service type, formulation)`; grouped reserve `construct_service!` methods; `reserves.jl`,
  `reserve_group.jl`, `service_slacks.jl` on merged containers; `add_to_expression.jl`
  reserve folds and `hydro_generation.jl` reserve folds updated; merged
  `RequirementTimeSeriesParameter` (`add_parameters.jl`); storage/hybrid consumption sites
  patched (`storage_models.jl`, `hybrid_systems.jl`). Env points at local IOM via
  `[sources]` path (root + test `Project.toml`).
- Tests: `test_services_constructor` shapes rewritten + new F1/F2 isolation test (two
  same-type services: no cross-service leakage, no objective double-count);
  `test_model_decision` NonSpinning key updated. `detect_ambiguities` = 0.
- Docs: `optimization_container_axes.md` merged-service-container section.

Deferred (not in PR1):
- D6 guardrail (no component-name meta on service-typed keys) - would false-positive on the
  deferred transmission-interface `"ub"/"lb"` metas and the still-meta-keyed ORDC cost
  params; add once those migrate.
- StepwiseCostReserve/ORDC cost params (`process_stepwise_cost_reserve_parameters!`) remain
  meta-keyed; entangled with the delta-PWL machinery PR2 reworks.
- Storage/hybrid reserve sub-containers (Phase 2), transmission interface (Phase 3),
  removing IOM's dead `export_pwl_vars` setting.

Before merge: revert `[sources]` IOM `path=` entries to the GitHub `main` rev (both root and
test `Project.toml`) once IOM's branch is pushed/registered.

## 1. Goal

Stop disambiguating multiple services of the same type by stuffing the service name into the `meta` field of container keys.
Instead, each (entry type, service type) pair gets ONE container that holds all services of that type:

- Device-indexed entries (`ActivePowerReserveVariable`, `ParticipationFractionConstraint`, `RampConstraint`, `ReservePowerConstraint`): one **3D sparse** container keyed `(service_name, device_name, t)`.
- Requirement-side entries (`ServiceRequirementVariable`, `RequirementConstraint`, `ReserveRequirementSlack`, `RequirementTimeSeriesParameter`, service duals): one **2D dense** container with axes `(service_names, time_steps)`.

`meta` remains for genuine sub-container disambiguation (`"ub"/"lb"`, `"hot"/"warm"`), never for component names.

## 2. Current state (verified 2026-07-19)

### The pattern

- `add_service_variables!` (IOM `common_models/add_variable.jl:82`) creates one 2D container per service: `add_variable_container!(container, T, U, service_name, device_names, time_steps)` - the positional String is the meta.
- Every service constraint builder in POM creates containers with `meta = service_name` (`services_models/reserves.jl:167, 234, 285, 332, 398, 437, 477`).
- Every consumer re-fetches with `get_variable(container, ActivePowerReserveVariable, SR, service_name)` - roughly 27 fetch sites and 17 build sites across `services_models/`, `common_models/add_to_expression.jl`, `hydro_generation.jl`, `storage_models.jl`, `hybrid_systems.jl`.
- Service duals: IOM `common_models/add_constraint_dual.jl:48-65` builds the dual container with `meta = service_name`.
- `ServiceModel` (IOM `core/service_model.jl:34`) carries `service_name::String`; templates register models keyed `(service_name, Symbol(D))`; `construct_services!` loops one `construct_service!` call per service.

### Two incompatible meta encodings exist today

- Core reserves: `meta = service_name` (bare).
- Storage and hybrid subcomponent reserve models: `meta = "$(typeof(service))_$(name)"` (`storage_models.jl:359, 642, 675, 707`; `hybrid_systems.jl:565`), because those containers are keyed by the DEVICE type, so the service type must ride along in meta.
- `storage_models.jl:737` mixes both in one function: the storage expression uses the composite id, the core reserve variable is fetched with the bare name.
This coupling forces storage fetch sites into the same phase as the core reserve change.

### What is already clean

- Device-side range expressions (`ActivePowerRangeExpressionUB/LB`) are aggregated with empty meta; only the reserve-variable lookup inside `add_to_expression!` uses name meta (`common_models/add_to_expression.jl:1991-1992`).
- `InterfaceTotalFlow` is already a single name-axis expression container (transmission interface is half-migrated).
- Service feedforwards are no-op stubs in POM (`core/feedforward_interface.jl:23-47`); no meta involvement yet.
- AGC is dead code (`services_constructor.jl:256-349` commented out); ignore it, port later with the new pattern.

### IOM infrastructure that already exists

- `sparse=true` on every `add_*_container!` produces a Dict-backed `JuMP.Containers.SparseAxisArray` with N-D tuple keys (`optimization_container.jl:662-705`, `jump_utils.jl:496-518`).
- 3D precedents: PWL variables `(name, segment, time)` (`optimization_container.jl:734-751`); POM security-constrained branches use raw `SparseAxisArray` keyed `(outage_id, name, t)` (`security_constrained_branch.jl:270-308`).
- The dimension guard explicitly allows 3+ dims (`optimization_container.jl:594-599`).
- DecisionModelStore has sparse and 3D-dense `write_output!` methods (`decision_model_store.jl:102-151`); sparse containers are flattened to 2D matrices with `"a__b"`-joined columns, last tuple element assumed to be time.
- Parameter machinery supports extra middle axes (`add_param_container_split_axes!`, `optimization_container.jl:909-942`) and has 2D/3D setter fast paths (`parameter_container.jl:310-476`).
- `expand_ixs` (`utils/indexing.jl:1-21`) pads missing middle dims with `Colon()`; time is always the last axis.

### IOM gaps (hard 2D assumptions)

1. EmulationModelStore has no sparse and no 3D `write_output!`; a 3D emulation variable is a `MethodError` (`emulation_model_store.jl:70-129`).
2. `to_dataframe` has no 3D-dense method; container-level `read_duals`/`read_expressions`/`read_parameters` would error on 3D dense (`jump_utils.jl:213-248`).
3. Sparse store flattening collapses the service axis into `"service__device"` column strings; the service dimension is not recoverable as a separate results column (`decision_model_store.jl:136-151`, `jump_utils.jl:83-103`).
4. WIDE table format errors for 3D outputs (`optimization_problem_outputs.jl:429-431`).
5. `get_column_names_from_axis_array` is dimension-typed; new axis combos need new methods (`jump_utils.jl:122-185`).
6. Initial-condition helpers silently drop `meta` (`optimization_container.jl:1208-1243`) - pre-existing, orthogonal, but adjacent.
7. Dataset accessors are enumerated for N in {1,2,3}; 4D would need new methods (`dataset.jl:117-199`).

### Downstream blast radius

Nothing consumes POM yet.
HydroPowerSimulations still depends on legacy PSI 0.36 and uses the meta pattern via `PSI.get_service_name`; it migrates when it moves to POM, out of scope here.
Legacy PSI is the origin, not a consumer.
Pre-1.0 with pinned `[sources]` branches: no deprecation bridge or version dance needed; land IOM additively, migrate POM, then delete the old IOM paths.

## 3. Scope challenge (pre-plan gate)

1. **Does this already exist?** The container machinery does (sparse N-D specs, 3D store writes, split-axes params). The missing pieces are the service-shaped conventions on top plus the store/results gaps above. Reuse is high.
2. **> 8 files?** Yes, unavoidably (~44 POM call sites + ~6 IOM files + tests). Mitigation is phasing, not shrinking.
3. **Minimum shippable slice?** Phase 0 + Phase 1 below: core reserve formulations on the new containers, storage fetch sites patched, everything else untouched. Ships value (one container per variable type, results no longer fragment per service) without touching hybrid/storage/interface internals.

## 4. Design

### D1. Container shapes

| Entry | Today (per service) | Target |
|---|---|---|
| `ActivePowerReserveVariable` | 2D (devices x t), meta=name | 3D sparse `(service, device, t)`, empty meta |
| `ParticipationFractionConstraint`, `RampConstraint`, `ReservePowerConstraint` | 2D (devices x t), meta=name | 3D sparse `(service, device, t)`, empty meta |
| `ServiceRequirementVariable` | 2D ([name] x t), meta=name | 2D dense `(services x t)`, empty meta |
| `RequirementConstraint` + its dual | 2D ([name] x t), meta=name | 2D dense `(services x t)`, empty meta |
| `ReserveRequirementSlack` | 2D ([name] x t), meta=name | 2D dense `(services x t)`, empty meta |
| `RequirementTimeSeriesParameter` | per-service param container, meta=name | one param container per service type, service-name axis |

Sparse for device-indexed entries because contributing-device sets are ragged per service; a dense 3D cube would be mostly holes of undef `VariableRef`s.
Dense for requirement-side entries because the axis (all modeled services of the type) is known from the template.

### D2. Axis order: `(service_name, device_name, t)`

Matches the security-constrained precedent `(outage_id, name, t)` and the store contract (last tuple element = time).
Groups results by service first, which is the natural read.

### D3. Service axis element: bare service name

The container key already carries the service component type, so names are unique within a container (PSY enforces per-type name uniqueness).
Storage/hybrid containers keyed by device type still need the service TYPE too; their axis element stays the composite `"$(ServiceType)_$(name)"` id in Phase 2 (open question Q2 below).

### D4. Construction: group services by (type, formulation)

Recommended: change `construct_services!` to group `ServiceModel`s by `(service_type, formulation)` and call `construct_service!` once per group with `Vector{ServiceModel}` (or the services themselves).
Rationale:

- Dense requirement-side containers need the full service-name axis up front.
- The objective and constraint builders then loop services internally, which kills the per-service-container sweep hazards (F2 below).
- Retrofitting grouping after a per-service lazy-fill interim doubles the churn on the same ~10 constructor methods.

Alternative (rejected): keep the per-service loop and `lazy_container_addition!` each slice.
Less churn per method but leaves half-filled containers between calls, needs the template threaded in to compute full axes anyway, and keeps the per-service objective sweep footgun.

`ServiceModel` itself is unchanged: it still carries `service_name`, feedforwards, attributes, and contributing-device maps per service; only container keying and constructor granularity change.

### D5. Results contract

- Store write for sparse 3D: extend IOM to preserve the leading dims so LONG format emits `DateTime, service, device, value` (`name`/`name2` columns) instead of a joined `"service__device"` name column.
  The 3D-dense write path already does this; the sparse path should match it.
- WIDE format for 3D: define it as columns joined `"service__device"` (what the current flatten already produces) and document it, replacing the current hard error.
- Result key names become `"ActivePowerReserveVariable__VariableReserve{ReserveUp}"` (no name suffix): one dataset per variable/service type instead of one per service.

### D6. Guardrail

After the POM migration, add a build-end validation: no container key whose component type is `<: PSY.Service` may carry a nonempty meta that names a component.
Prevents silent resurrection of the old pattern via `lazy_container_addition!` (F6 below).

## 5. Execution phases

### Phase 0 - IOM groundwork (additive, POM keeps building)

1. New grouped `add_service_variables!` creating the 3D sparse container; keep the old method until Phase 4.
2. EmulationModelStore: sparse + 3D `write_output!` and matching `read_outputs`.
3. Sparse store write preserves dims (D5); `to_outputs_dataframe`/`_read_outputs` emit `name`/`name2` for sparse 3D; WIDE = joined columns.
4. `to_dataframe` 3D-dense method (closes the dual/expression/parameter read gap).
5. `get_column_names_from_axis_array` methods for the new combos.
6. IOM unit tests: container create/fill/store/read round trip for `(String, String, Int)` sparse, decision + emulation stores, LONG/WIDE.

### Phase 1 - POM core reserves (the minimum shippable slice)

1. `construct_services!` grouping (D4); `construct_service!` signatures for RangeReserve, RampReserve, NonSpinningReserve, StepwiseCostReserve, GroupReserve take the group.
2. `reserves.jl`: all container builds/fetches to the new shapes; requirement/participation/ramp/reserve-power constraints loop `(service, contributing_devices)` explicitly - never slice the sparse container.
3. `reserve_group.jl`: fetch contributing reserves from merged containers by axis membership; `check_activeservice_variables` checks axis membership, not container existence.
4. `service_slacks.jl` reserve slacks to `(services x t)`.
5. `add_constraint_dual!` service path (IOM side): dual container merged per constraint container.
6. `common_models/add_to_expression.jl` reserve-to-device-expression folds (`:1978-2003` and the hydro twins in `hydro_generation.jl`).
7. `RequirementTimeSeriesParameter` to one container per service type.
8. Objective: `add_reserves_proportional_cost!` iterates only the given service's entries.
9. Patch the cross-convention fetch sites in `storage_models.jl` (`:737` and the two sibling methods) to the 3D lookup; storage-internal containers untouched.
10. Rewrite `test_services_constructor.jl` shape asserts; add a 2-services-same-type coefficient-level fixture (see test matrix).

### Phase 2 - storage and hybrid internals

`TotalReserveOffering`, `AncillaryServiceVariable{Charge,Discharge}`, `HybridThermalReserveVariable`, `HybridStorageSubcomponentReserveVariable{...}`, `HybridPCCReserveVariable{...}` move from composite-id meta to 3D sparse with a composite service-id axis (pending Q2).
Files: `storage_models.jl`, `storage_constructor.jl`, `hybrid_systems.jl`, `hybridsystem_constructor.jl`.

### Phase 3 - transmission interface

Merge `MinInterfaceFlowLimitParameter`/`MaxInterfaceFlowLimitParameter` and `InterfaceFlowSlackUp/Down` onto interface-name axes; `InterfaceFlowLimit` keeps `meta = "ub"/"lb"`.
Smaller and independent; can land any time after Phase 0.

### Phase 4 - cleanup

1. Delete the old per-service `add_service_variables!` and the service-name dual path from IOM.
2. Add the D6 guardrail check.
3. Docs: formulation library pages, results-reading docs (new key names, LONG `name2` column).
4. Update `.claude/CLAUDE.md` repo guide and the Sienna vault POM note.

### Out of scope

- HydroPowerSimulations / legacy PSI (migrate with the PSI-to-POM port; `pom_port_plan.md` porting rule applies).
- Service feedforward implementations (stubs today; they adopt the new shapes when ported).
- AGC revival.
- 4D containers (device x service x segment x time); if ORDC-per-service-per-segment ever needs it, dataset `{4}` methods are a known prerequisite (IOM `dataset.jl`).

## 6. Failure-mode analysis

| # | Codepath | Realistic failure | Test covers it? | Error handling? | User-visible? | Gap level |
|---|---|---|---|---|---|---|
| F1 | `RequirementConstraint` build over merged 3D container | Summing by slice instead of the service's contributing-device list lets service A's variables satisfy service B's requirement | no (current tests are single-service-per-name shapes) | none | no - model solves, dispatch wrong | **CRITICAL** -> Phase 1 test: 2 same-type services, coefficient-level constraint assert |
| F2 | `add_reserves_proportional_cost!` per-service call over merged container | Iterating the whole container per service multiplies reserve cost by the number of services | no | none | no - objective silently inflated | **CRITICAL** -> grouped construction (D4) + objective coefficient assert |
| F3 | Sparse store flatten / column decode | Service or device name containing `"__"` splits into wrong columns on read; axis values are not `check_meta_chars`-validated | no | none | no - misattributed results | **CRITICAL** -> validate axis values at container creation (IOM), test with adversarial name |
| F4 | Emulation store write of 3D container | `MethodError` on first emulation step with reserves | no | crash | yes (crash) | - (fixed in Phase 0.2, add test) |
| F5 | Merged dense `(services x t)` parameter with one service missing its time series | Existing silent TS-skip (`add_parameters.jl:~175`) leaves a NaN column that propagates into the requirement RHS | no | none | partially (solver may error on NaN) | **CRITICAL** -> convert the skip to a loud error for services in Phase 1 (aligned with repo debt note) |
| F6 | Any stale call site still passing `service_name` as meta after migration | `lazy_container_addition!` silently creates an orphan empty container; its variables never enter constraints | no | none | no - under-constrained model | **CRITICAL** -> D6 guardrail + grep sweep + `detect_ambiguities` pass |
| F7 | `check_activeservice_variables` (GroupReserve) | Checking container existence instead of axis membership passes when a contributing service was never built; group requirement silently sums fewer terms | no | none | no | **CRITICAL** -> rewrite to axis-membership check + group-reserve fixture with a missing contributor |
| F8 | Results read by future downstream (PowerGraphics/PowerAnalytics patterns) | Key `"...__ServiceName"` no longer exists; readers that string-match old keys get empty frames | n/a (no downstream on POM yet) | KeyError in typed API | yes | - (document in release notes / vault note) |

Every CRITICAL row maps to a Phase 1 test or an IOM validation; none is deferred.

## 7. Test matrix

| Repo | Test | Covers |
|---|---|---|
| IOM | 3D sparse container store round trip (decision + emulation), LONG/WIDE, column preservation | Phase 0, F3, F4 |
| IOM | axis-value validation rejects `"__"` in axis names | F3 |
| POM | `test_services_constructor.jl` rewrite: shapes `(service, device, t)`, one container per (entry, service type) | Phase 1 |
| POM | NEW: 2 `VariableReserve{ReserveUp}` services with overlapping contributing devices; coefficient-level asserts on requirement + participation constraints and objective (MODF-suite pattern) | F1, F2 |
| POM | NEW: GroupReserve with a contributor absent from the template errors loudly | F7 |
| POM | NEW: service missing `requirement` TS errors loudly | F5 |
| POM | Emulation model with reserves builds and writes results | F4 |
| POM | Existing storage/hybrid test files pass after Phase 1 (only fetch sites patched) then Phase 2 | coupling |
| POM | `Test.detect_ambiguities` after constructor signature changes | F6 |
| POM | Full suite `--jobs=8`, docs build | regression |

## 8. Release order

1. IOM Phase 0 lands on `Sienna-Platform/InfrastructureOptimizationModels#main` (additive).
2. POM Phases 1-3 land against the pinned `main` rev (bump the manifest rev, no compat/version churn per repo policy).
3. IOM Phase 4 removals land only after POM is green on the new paths.
4. Version/compat pass at release time only.

## 9. AS offer costs (ERCOTMarketParser P1) - 4D offer containers

Companion plan: `ERCOTMarketParser.jl/docs/superpowers/plans/2026-07-19-p1-as-offer-costs-pom.md` (targets the PSY6 sandbox clones, POM branch `rh/dev_services`, not this repo's branch).
P1 as written keys everything `(type, DeviceType, meta = service_name)` - the exact pattern this refactor removes.
This section scopes what P1's containers become if the 3D service design lands, and what a 4D sparse block-offer container requires.
Per Rodrigo: PWL offer variables are NOT exported to results, so no store/results/WIDE-LONG scoping for 4D.

### 9.1 Target shapes under the 3D service design

| P1 entity | P1 (meta) shape | 4D-native shape |
|---|---|---|
| `PiecewiseLinearBlockReserveOffer` vars | sparse `(device, seg, t)` per (DeviceType, meta=service) | one sparse `(service, device, seg, t)` per DeviceType |
| `PiecewiseLinearBlockReserveOfferConstraint` | dense `(device, t)` per (DeviceType, meta=service) | sparse `(service, device, t)` per DeviceType - same shape as the Phase 1 device-indexed service constraints |
| `ReserveOfferPWL{Slope,Breakpoint}Parameter` | 3D `(device, tranche, t)` per (DeviceType, meta=service) | 4D `(service, device, tranche, t)` per DeviceType (Q7: or keep per-service 3D+meta as a documented exception) |
| Award variable fetch (P1 seam B) | `get_variable(..., ActivePowerReserveVariable, SR, service_name)[device, t]` | `get_variable(..., ActivePowerReserveVariable, SR)[service, device, t]` |

Invariant to preserve everywhere: time is the LAST tuple element and the segment axis sits adjacent to it; the service axis leads (D2).

### 9.2 Main requirements (all small, IOM unless noted)

1. **Generalize the `SparseVariableType` container installer.** `_get_pwl_variables_container()` hardcodes `Dict{Tuple{String, Int, Int}, VariableRef}` (`optimization_container.jl:734-751`). Needs a key-shape trait (e.g. `sparse_key_type(::Type{<:SparseVariableType})`) so a 4-tuple `(String, String, Int, Int)` container can be installed. The dimension guard already allows any N >= 2.
2. **`add_pwl_variables_delta!` gains a leading key prefix** (`objective_function_pwl_delta.jl:44-77`): writes `var_container[(service, name, i, t)]`. This REPLACES P1 seam A (the `meta` kwarg threading through `add_pwl_variables_delta!` + `lazy_container_addition!`) - that seam is throwaway work under 4D.
3. **POM overload `add_reserve_pwl_constraint_delta!`** (P1 seam B, restated): fetch the 3D award container and index `[service, device, t]`. Note `add_pwl_constraint_delta!` forwards `axes(variables)...` to build its constraint container (`objective_function_pwl_delta.jl:197-203`) - `axes` is undefined on `SparseAxisArray`, so the overload must build the sparse `(service, device, t)` constraint container explicitly.
4. **`_get_raw_pwl_data` 4D variant** (`value_curve_cost.jl:199-230`): index `[service, name, seg, t]`, segment axis becomes `axes(arr)[3]`. Not needed if Q7 keeps params per-service.
5. **Param allocator variant**: `add_param_container_split_axes!` builds `(param_axs, additional_axs..., time)`; a leading service axis needs a variant or an axes-reorder. Not needed under Q7-per-service.
6. **Export gating - CORRECTED by smoke test (2026-07-20).** The gate exists, per-type in POM, not in IOM: `should_write_resulting_value(::Type{PiecewiseLinearCostVariable/BlockIncrementalOffer/BlockDecrementalOffer}) = false` at `src/core/variables.jl:832-834` (IOM's `export_pwl_vars` setting is dead as reported).
   DECIDED (Rodrigo, 2026-07-19): PWL offer variables ARE exported.
   The three gates were flipped to `true` and verified end-to-end on `c_sys5_pwl_uc` (DecisionModel + HiGHS): the sparse `(name, seg, t)` container flattens to `"name__seg"` columns in the store; LONG read gives `(DateTime, name, value)` with the joined name; WIDE gives one `"name__seg"` column per segment.
   Consequence for 4D: the same flatten path handles any N (generic `encode_tuple_to_column(::Tuple)` fallback), so 4D offers would export as `"service__device__seg"` columns with NO extra store work - the 9.3 exclusions below now apply only to first-class (unjoined) 4D result columns.
   Still open: POM forces slope/breakpoint params to `should_write_resulting_value = true` (`core/parameters.jl:247-248`), so 4D `ReserveOffer` param containers would also hit the store; decide their gate with Q7.
   Watch out: EmulationModelStore still has no sparse writer (gap 1 in §2) - an emulation model with PWL costs now crashes at write; no test exercises that today. Phase 0.2 closes it.
7. **Recurrent-solve parameter updates** (P1 blocker B4): POM has no `_update_parameter_values` implementations yet (simulation orchestration not ported). Forward requirement only: when that path lands, `_set_parameter_at!`/`_set_param_value_at!` (2D/3D today, `parameter_container.jl:310-476`) need 4D methods if params go 4D.

### 9.3 What the flatten path makes unnecessary

4D sparse containers export through the existing sparse flatten (joined `"service__device__seg"` columns) with no extra store work.
What is NOT scoped: first-class (unjoined) 4D result columns - that would need dataset `{4}` methods, a 4D column contract, and LONG `name3`; defer unless someone needs to unstack offers by service in results.
The D5 results work in Phase 0 stays 3D-only.

### 9.4 Why 4D-native beats meta for the offers

Under P1's meta approach, two services sharing a device type collide on `(name, seg, t)` keys unless the meta threading is exactly right everywhere (P1 explicitly guards this with a test).
Under 4D keys the collision is impossible by construction - the service element disambiguates.
The offer machinery also stops depending on `lazy_container_addition!` meta semantics (main-plan F6 territory).

### 9.5 Sequencing recommendation

Let the P1 prototype proceed meta-based in the PSY6 sandbox (validation-driven, EMP E2E pressure; its IOM delta is ~10 throwaway lines).
Upstream P1 (its task 10) lands 4D-native, after Phase 0/1 of this plan, on this repo's branches.
DONE (2026-07-20, this branch): the three POM PWL export gates flipped to `true` (`core/variables.jl:832-836`) and verified LONG + WIDE on `c_sys5_pwl_uc`; delete IOM's dead `export_pwl_vars` setting during Phase 0.

## 10. Open questions for Rodrigo

- **Q1 (D4):** grouped construction per (service type, formulation) - agreed? It is the bigger interim churn but the intended end state, and it eliminates F2 structurally.
- **Q2 (D3/Phase 2):** for device-type-keyed storage/hybrid containers, is the composite `"$(ServiceType)_$(name)"` axis id acceptable, or do you want a first-class `(service_type, service_name, device, t)` 4-tuple key (requires IOM dataset `{4}` methods and a 4-way column contract)?
- **Q3 (D5):** results contract sign-off: LONG gains a `name2` column for 3D entries; WIDE for 3D = `"service__device"` joined columns; result keys drop the service-name suffix. PowerAnalytics/PowerGraphics will need matching updates when they migrate.
- **Q4:** should the F5 fix (loud error on missing service TS) extend to the general device silent-skip in the same PR, or stay service-scoped to limit scope?
- **Q5 (Phase 3):** transmission interface merge in this effort, or defer? It is independent and could also be argued into a device-style model later.
- **Q6 (§9.5):** sequencing sign-off: P1 AS-offer prototype stays meta-based in the PSY6 sandbox; the upstreamed version is 4D-native after Phase 0/1. The export-gating fix ships immediately.
- **Q7 (§9.1):** offer slope/breakpoint parameters: 4D `(service, device, tranche, t)` (consistent, needs items 4-5 and future 4D update methods) vs per-service 3D with meta as a documented exception to the D6 guardrail (less IOM churn, keeps `_get_raw_pwl_data` untouched)?
