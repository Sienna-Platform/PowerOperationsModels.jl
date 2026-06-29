# POM port plan — PSI → PowerOperationsModels.jl

Scope: bring POM (`PowerOperationsModels.jl`, the **formulation** library) up to date with PSI
(`PowerSimulations.jl`), covering (1) missing formulation **tests**, (2) post-fork PSI **code**
changes that belong in POM, and (3) the **in-progress G-1** generator-contingency feature.

Companion file: `iom_port_plan.md` (generic optimization-core changes → InfrastructureOptimizationModels).

## Topology / ground rules
- Sienna porting is two-headed: **formulation specifics → POM**, **generic optimization core
  (optimization_container, dual_processing, settings, serialization, parameters, lifecycle,
  objective-function machinery, model-export) → IOM**. Check the right repo before porting.
- POM is a **restructured** port (e.g. PF logic lives in `ext/PowerFlowsExt/`; type-based dispatch
  `::Type{F}` vs PSI's instance-based). Verify by **symbol/behavior**, not file path; adapt, don't
  copy verbatim.
- Fork baseline ≈ PSI #1503 (POM/IOM forked 2026-01-03). Latest PSI PR swept = **#1640**.
- "Already ported" / "code present" claims below were symbol-verified against the local POM clone.

---

## Progress — branch `ac/sienna1-port` (updated 2026-06-28)

Committed (`2b74e93`, pushed): 18 files. **Full suite: 23,695 pass, exit 0** (was 19,875 pre-work).
Status legend: ✅ done · ⏭️ already correct in POM (no change) · 🟦 descoped/routed elsewhere · ⏳ deferred.

**Workstream M bugfixes:** ✅ #1519, ✅ #1527, ✅ #1587 · ⏭️ #1508 (already fixed),
⏭️ #1535 (VOM already `dt`-scaled via `IOM.add_proportional_cost_invariant!` — porting PSI's fix
would double-scale; only the test is worth adding).

**Workstream M features:** ✅ #1549, ✅ #1573, ✅ #1538, ✅ #1605, ✅ #1622, ✅ #1612 ·
⏭️ #1614 & #1566 (already present). ⏳ DLR (#1559/#1561) untouched (scope separately).

**Workstream T tests:** ✅ new tests for #1573/#1612/#1622; ✅ `test_services_constructor` 2→16;
✅ `test_network_constructors` 1→11. ⏳ remaining (see Workstream T section): MBC equivalence subset +
VOM-normalization test, curtailment-incentive (#1614) test, services slack/feedforward/GroupReserve/
AGC/hydro variants, PowerModels-nonlinear & whitebox-reduction network testsets.

**Workstream C event framework:** 🟦 **descoped → IOM.** `EventModel`/`AbstractEventCondition`/
`FixedForcedOutage`-projection/template-integration is generic lifecycle+template machinery (same
layer as `DeviceModel`/`ServiceModel`/`ProblemTemplate`), POM already owns its share (event
parameter/constraint types + per-formulation `add_event_*!` hooks), and it isn't on PSI `main`.
`test_events.jl` is consequently blocked → not on this branch. Track in `iom_port_plan.md`.
MBC tranche-count & concavity validation: ⏭️ already present (not blockers).

**Extra src fixes (beyond the PR list) to enable TransmissionInterface test coverage:**
- ✅ `core/problem_template.jl`: uncommented `_modify_device_model!` no-ops for
  `ServiceModel{TransmissionInterface, ConstantMaxInterfaceFlow/VariableMaxInterfaceFlow}` (the
  "define in PSI" note was stale — both are fully defined+exported in POM).
- ✅ `common_models/add_to_expression.jl`: widened `_is_interchanges_interfaces(::Dict)` (the narrow
  `Dict{Type{<:PSY.Component},…}` `MethodError`ed via `Dict` invariance vs the runtime
  `IS.InfrastructureSystemsComponent`-keyed map).

**Known src gaps surfaced (left for a later pass / IOM):**
- TransmissionInterface `use_slacks=true` build FAILS: no `add_variable_container!(…,
  InterfaceFlowSlackUp, TransmissionInterface, ::String, ::UnitRange)` method (IOM container-builder).
- GroupReserve: `_populate_contributing_devices!` errors on `ConstantReserveGroup` (members are
  services, not devices) — real feature gap.
- Concrete feedforward types (`LowerBoundFeedforward`, `FixValueFeedforward`, …) absent in POM/IOM.

**Test-port convention (PSI→POM):** dropped brittle exact `moi_tests` counts (PSI formulation
fingerprints differ post-split) for build/solve/objective/constraint-size/behavioral assertions;
`OptimizationProblemOutputs`, `IOM.ModelBuildStatus`/`RunStatus`, `evaluations =
power_flow_evaluations(...)`, `PSY.SU` on getters.

---

## Workstream G1 — in-progress generator contingency (PSI **open PR #1617**) — TIME-SENSITIVE
PR #1617 (`sm/g-1_monitored_c`, OPEN, not draft, `mergeable_state=blocked` on review; author
SebastianManriqueM) adds the **reserve/service-side** security-constrained contingency layer.
POM already carries the **branch-side** foundation (`src/ac_transmission_models/security_constrained_branch.jl`,
outage population in `src/operation/template_validation.jl`, `SecurityConstrainedStaticBranch`,
`PostContingencyBranchFlow/FlowRateConstraint`, slack vars). So the POM port ≈ the #1617 diff
re-applied onto POM's layout. The three older `g-1` branches are a stale lineage already merged to
PSI `main` (and into POM) — **do not** port from them.

Port from PSI branch `origin/sm/g-1_monitored_c`:
- **Formulations** (`core/formulations.jl`): `AbstractSecurityConstrainedReservesFormulation`,
  `SecurityConstrainedContingencyReserve`, `SecurityConstrainedRampReserve`.
- **Variables** (`core/variables.jl`): `AbstractContingencySlackVariableType`,
  `PostContingencyActivePowerReserveDeploymentVariable`; re-parent
  `PostContingencyFlowActivePowerSlackUpper/LowerBound` under the slack supertype.
- **Expressions** (`core/expressions.jl`): `PostContingencyActivePowerGeneration`,
  `PostContingencyAreaInterchangeFlow`, `PostContingencyAreaActivePowerDeployment`
  (+ `should_write_resulting_value`/`convert_result_to_natural_units`).
- **Constraints** (`core/constraints.jl`): `PostContingencyActivePowerGenerationLimitsConstraint`,
  `PostContingencyCopperPlateBalanceConstraint`, `PostContingencyGenerationBalanceConstraint`,
  `PostContingencyRampConstraint`.
- **Definitions**: `POST_CONTINGENCY_CONSTRAINT_VIOLATION_SLACK_COST = 1e5`.
- **ServiceModel** (`core/service_model.jl`): `outages::Dict{UUID,Dict{DataType,Set{String}}}` field
  + `get_outages` (outages attached as `PSY.Outage` supplemental attributes on the `PSY.Service`).
- **Template validation** (`operation/template_validation.jl`): `_build_service_model_outages!`,
  `_sc_reserve_service_models`, `_service_skips_outage` (dispatch on `PSY.PlannedOutage`/`PSY.Outage`),
  `_warn_outages_attached_to_unmodeled_services`; **widen `_monitored_components_by_modeled_type`
  to admit `PSY.AreaInterchange`** (POM's copy currently admits only `PSY.ACTransmission`).
- **Reserves** (`services_models/reserves.jl`): SC `get_default_time_series_names(::Reserve, ::AbstractSecurityConstrainedReservesFormulation)`.
- **New file**: `services_models/static_injection_security_constrained_models.jl` (sparse
  post-contingency containers keyed by `(outage_id, monitored_name, t)`; `construct_service!`
  paths for CopperPlate / AreaBalance / PTDF / AreaPTDF). Register in the POM module + exports.
- **New test**: `test/test_static_injection_security_constrained_models.jl` (~2,580 lines; both
  formulations × CopperPlate/AreaBalance/AreaPTDF/PTDF; slack on/off; parallel-circuit reduction;
  mixed branch formulations).

> Track #1617 to merge; if it changes in review, re-diff before porting.

---

## Workstream M — merged-PR code gaps in POM (symbol-verified ABSENT)
Bugfixes and small features that landed in PSI after the fork and are not yet in POM. Each line: PR — what — where in POM.

**Bugfixes (do first; small, low-risk):**
- **#1519** — TwoTerminalHVDC `AreaBalancePowerModel` `add_to_expression!` bug: uses
  `get_expression(container, T, PSY.ACBus)` (should be `PSY.Area`), undefined `network_reduction`/`W`.
  → `src/common_models/add_to_expression.jl:954`.
- **#1527** — `round(Float64, time_limits.up*steps_per_hour, RoundUp)` should drop the `Float64`
  positional arg (align with `RoundingMode`). → `src/static_injector_models/thermal_generation.jl:1364`.
- **#1535** — VOM cost missing resolution scaling (issue #1531): add
  `dt = Dates.value(resolution)/MILLISECONDS_IN_HOUR` to `_add_vom_cost_to_objective_helper!`.
  → `src/common_models/market_bid_plumbing.jl:555`. (Unblocks the VOM-normalization MBC tests.)
- **#1587** — improve parallel-branch interface error message (list offending branch names).
  → `src/common_models/add_to_expression.jl:2256` (minor).
- **#1508** — network-reduction/AreaInterchange fix: `modeled_branch_types`→`modeled_ac_branch_types`
  and the `device_names_with_branches` undefined-constraint bug (`device_names = PSY.get_name.(devices)`).
  → `src/area_interchange.jl` + reduction path. Adapt to POM's `instantiate_network_model.jl`.

**Small features:**
- **#1549** — Source default TS names: `get_default_time_series_names(::Type{<:PSY.Source}, …)`
  returns `Dict()` in POM; should map `ActivePowerOut/InTimeSeriesParameter => "max_active_power_out/in"`.
  → `src/static_injector_models/source.jl`.
- **#1573** — Source `FixedOutput` constructor (all POM Source constructors are `ImportExportSourceModel`).
  → `src/static_injector_models/source_constructor.jl`. (Unblocks "FixedOutput Source w/ PTDF+TS" test.)
- **#1538** — feedforward arguments for renewables: add `add_feedforward_arguments!` and
  `get_parameter_multiplier(::VariableValueParameter, ::PSY.RenewableGen, ::AbstractRenewableFormulation)`.
  → `src/static_injector_models/renewablegeneration_constructor.jl`, `renewable_generation.jl`.
- **#1614** — renewable curtailment incentive: flip `objective_function_multiplier(::AbstractRenewableDispatchFormulation)`
  from `OBJECTIVE_FUNCTION_NEGATIVE` to `POSITIVE` and feed `curtailment_cost` into the dispatch
  objective (not just the reporting `CurtailmentCostExpression`). → `src/static_injector_models/renewable_generation.jl:24`.
  (Unblocks "curtailment_cost incentive affects dispatch" test.)
- **#1605** — AreaPTDF + `InterconnectingConverter`: replace
  `error("AreaPTDFPowerModel doesn't support InterconnectingConverter")` with the area/DC-bus
  injection `add_to_expression!`. → `src/mt_hvdc_models/HVDCsystems.jl:284`.
- **#1566** — headroom-proportional slack **recompute from results**: `_update_headroom_participation_factors!`
  / `_accumulate_headroom!` / `get_active_power_limits_for_power_flow` absent. → `ext/PowerFlowsExt/` + network_models.
- **#1612 (POM part)** — split In/Out headroom-proportional slack: data-map is ported, but
  `_accumulate_in_out_headroom!` / `_find_paired_out` / `_pf_in_out_discharge_max` absent (old
  `# Skip storage devices for now` TODO still present). → `ext/PowerFlowsExt/pf_headroom.jl`.
- **#1622** — route reactive-power TS to AC PF on active-power-only network models: add
  `_add_pf_only_time_series_parameters!` + `PF_ONLY_TS_PARAMS_BY_CATEGORY`, thread `template` into
  `add_power_flow_data!` (currently `add_power_flow_data!(container, transmission_model, sys)` at
  `src/operation/build_problem.jl:157`). → `ext/PowerFlowsExt/pf_input_mapping.jl`. (Unblocks "reactive power on PTDFPowerModel" test.)

**Large feature — Dynamic Line Ratings (DLR), SPLIT POM+IOM:**
- **#1559 + #1561** — DLR entirely absent in both clones (distinct from the static
  branch-rating-time-series feature POM already has). POM part: `DynamicBranchRatingTimeSeriesParameter`,
  default `"dynamic_line_ratings"`, DLR network-reduction handling, `get_dynamic_branch_rating_min_max_limits`,
  `get_equivalent_dynamic_branch_rating`. IOM part: generic param-type registration (see iom plan).
  Substantial; scope as its own effort.

**Verify (not symbol-pinned — diff-review before deciding):**
- **#1509** (remove old N-1/G-1 code — arch diverged), **#1613** (network bugfixes), **#1619** (pnm/pf
  logic; mostly version bumps = PSI-only). Confirm whether anything material is missing.

---

## Workstream T — formulation TEST ports (code present in POM)
These are test-only ports against existing POM code (biggest coverage win, low risk). Land one PR
per file. Annotated where a test is **code-blocked** by a Workstream M/C item.

- **`test_services_constructor.jl`** (~23 testsets): RangeReserve (thermal dispatch/UC, renewable),
  RampReserve, StepwiseCostReserve, reserves+slacks, participation-factor limits, service-level
  feedforwards, GroupReserve + errors, ConstantReserve, AGC; Transmission Interface (Constant/Variable
  MaxFlow, TS limits, feedforwards, validation-under-reductions, double-circuit, on AreaInterchange,
  with AreaBalance, with AreaPTDF). Code all present (incl. AGC, more complete than PSI).
- **`test_network_constructors.jl`** (~23 testsets): PowerModels iteration (All-PowerModels,
  CopperPlate, PTDF, NFA, ACR/ACT, DCPLL, Unsupported guard); Area networks (AreaBalance ±slacks
  ±TimeSeries, AreaPTDF ±DoubleCircuit ±TimeSeries); HVDC subnetworks; reductions (Ward, radial,
  PTDF StaticBranch/StaticBranchBounds, subnetwork, branch-filter edge cases, parallel/series bounds,
  full PowerModels×reduction matrix ±slacks). Code present.
- **`test_power_flow_in_the_loop.jl`** Source paths (~6): in/out variables, Source FixedOutput
  (⚠ needs #1573), reactive-on-PTDF (⚠ needs #1622), in/out headroom (⚠ needs #1612), LCC HVDC.
- **`test_market_bid_cost.jl`** equivalence subset: no-TS vs constant-TS (Thermal/Renewable/PowerLoad),
  RenewableDispatch MBC, Renewable-vs-Thermal compare, time-varying slopes/breakpoints/min-gen/everything
  (⚠ tranche-count + concavity need Workstream C), VOM normalization (⚠ needs #1535), 3d results,
  heterogeneous TS names, single TS.
- **Small device drops**: MonitoredLine asymmetric flow limits (#1604 test path exists — confirm/port),
  renewable curtailment incentive (⚠ needs #1614), FixedOutput Source+PTDF+TS (⚠ needs #1573).

---

## Workstream C — Tier-0 code blockers in POM (port code, then test)
- **Event framework** — POM has **no `core/event_model.jl`**, no `EventModel`/`FixedForcedOutage`
  machinery (only the `AvailableStatusParameter` type exists). Port the event framework
  (`AbstractEventCondition` family, FixedForcedOutage time-series application, event extension hooks,
  outage projection into decision models), **then** port `test_events.jl` (all 13 testsets).
- **MBC variable-tranche-count** and **MBC concavity/convexity validation** — absent; small code adds
  that unblock the remaining time-varying-tranche and validation MBC tests.

---

## Out of scope for POM (PSI-only — do NOT port)
Simulation orchestration (`test_simulation_*`, simulation_state/partitions/store/results-IO),
`test_model_emulation`, `test_recorder_events`, `test_print`, `test_jump_utils`, docs/tutorials,
CI, version bumps, org renames. PSI template-library helpers (`_copy_template_for_build`,
"provided templates", namespace-stable keys) are architecture-specific to PSI; `modeled_ac_branch_types`
is tracked in POM as the `branches_modeled` trait (already present).

---

## Suggested execution order  (see Progress block at top for actual status)
1. ✅ **Workstream M bugfixes** (#1519, #1527, #1587; #1508/#1535 already correct).
2. ✅ **Workstream M small features** (#1549, #1573, #1538, #1605, #1622, #1612; #1614/#1566 present).
3. ✅ **Workstream T (partial)** — services 2→16, network 1→11, + PF-source/FixedOutput tests.
   ⏳ remaining: MBC equivalence/VOM/curtailment tests + the deferred services/network variants.
4. **Workstream G1** (#1617) — separate branch (out of scope here).
5. 🟦 **Workstream C** — event framework descoped → IOM; `test_events.jl` blocked. MBC
   tranche/concavity already present.
6. ⏳ **DLR (#1559/#1561)** and the **verify** items — scope separately.
