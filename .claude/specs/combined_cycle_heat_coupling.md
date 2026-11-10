# Spec: combined-cycle heat coupling (CT to steam turbine)

Status: proposal, 2026-11-04.
Scope: PowerOperationsModels only.
PowerSystems `psy6` already carries the data model; nothing upstream changes in phase 1.
Reference formulation: `shared_hrsg_model.md` in the WECC `hrsg/` notes (shared HRSG, N CT x M ST).

## Goal

Constrain steam turbine (CA) output by the heat its combustion turbines (CT) recover through a shared HRSG.
The CA carries an equivalent heat-input curve in MMBtu/h (or GJ/h) versus MW and no fuel price.
The optimizer commits the CA freely.
Once committed, the CA can only draw heat the HRSG delivers from the committed CTs, and heat is a shared pool when several CAs hang off one HRSG.

## What already exists

### PowerSystems `psy6` (`src/plant_attribute.jl`)

`CombinedCycleBlock <: PowerPlant <: SupplementalAttribute` holds everything the model needs:

| Field | Meaning |
|---|---|
| `heat_recovery_to_steam_factor` | HRSG efficiency `η`, dimensionless |
| `hrsg_ct_map` | HRSG number to CT unit ids (heat sources) |
| `hrsg_ca_map` | HRSG number to CA unit ids (heat sinks) |
| `configuration` | `CombinedCycleConfiguration` enum, informational |

`add_supplemental_attribute!(sys, gen, block; hrsg_number)` attaches a generator.
PSY rejects any prime mover other than `PrimeMovers.CT` or `PrimeMovers.CA`.
A CT or CA may feed or draw from several HRSGs.
`get_ct_hrsg_map` and `get_ca_hrsg_map` give the reverse maps.
Membership is by `IS.get_id`; the model resolves ids to devices with `IS.get_supplemental_attributes(CombinedCycleBlock, device)`.
The maps already express the N x M case per HRSG, so 1x1, 2x1 and 1x2 need no extra data.

### InfrastructureSystems `IS4`

`FuelCurve` is the right curve type on both sides: x in MW, y in `fuel_units` per hour, with `u"MMBtu"` defined in `commodity_units.jl` and `u"GJ"` native to Unitful.
`fuel_cost = 0.0` is legal.
A zero-priced `FuelCurve` is the honest representation of the CA: it consumes steam heat at zero marginal price, and the block constraint is the supply side.

### POM today

- `FuelConsumptionExpression` exists for Linear and Quadratic `FuelCurve`s, but it holds only the proportional term times `dt`. The constant term goes to the objective through `_onvar_cost`. The heat balance needs both terms, so it is built from the curves directly.
- Unit helpers `get_proportional_cost_per_system_unit` and `get_quadratic_cost_per_system_unit` (IOM) convert curve coefficients to system-base per-unit power.
- Commitment status under any formulation resolves through the existing `_get_sos_value` and `IOM._determine_bin_lhs` path (variable, parameter, or constant 1).
- The vault note for POM records the gap: `PowerPlant` attributes are inert today.

## Parameter mapping from the reference note

The note parameterizes each unit with a constant heat rate and a separate minimum heat input.
POM reads both from the unit's affine `FuelCurve{LinearCurve}` instead, so no new data fields are needed.

| Note symbol | Source in Sienna data | Units |
|---|---|---|
| `HR_g` | slope `a_g` of the CT `FuelCurve` | MMBtu/MWh |
| CT no-load heat | intercept `b_g` of the CT `FuelCurve` | MMBtu/h |
| `3.6 GJ/MWh` | `κ`, derived with Unitful from the block's `fuel_units` (3.412 MMBtu/MWh) | fuel/MWh |
| `η_HRSG` | `heat_recovery_to_steam_factor` | 1 |
| `HR_s` | slope `a_s` of the CA `FuelCurve` | MMBtu/MWh |
| `Q_min_s` | `a_s · Pmin_s + b_s`, the CA curve at its minimum stable load | MMBtu/h |
| `Pmin`, `Pmax` | `active_power_limits` of each unit | MW |

To reproduce a note-style unit with `HR_s` and a `Q_min_s` above `HR_s · Pmin_s`, set the intercept `b_s = Q_min_s − HR_s · Pmin_s`.

## Formulation

Sets for block `b` with efficiency `η_b` and HRSG `h`: CTs `G_h`, CAs `S_h`, time steps `t`.
Decision variables: `p` power (existing `ActivePowerVariable`), `u` commitment (existing `OnVariable`, or the commitment parameter under a feedforward, or 1 under a dispatch formulation), and the new heat allocation `q_s,t ≥ 0` per CA, in fuel units per hour.

```
(1) available heat, inlined, not stored:
    Q_h,t = η_b · Σ_{g ∈ G_h} ( (a_g − κ) · p_g,t + b_g · u_g,t )

(2) heat allocation:          Σ_{s ∈ S_h} q_s,t ≤ Q_h,t
(3) CA heat draw:             q_s,t ≥ a_s · p_s,t + b_s · u_s,t             for each s ∈ S_h
(4) aggregate minimum heat:   Q_h,t ≥ Σ_{s ∈ S_h} (a_s · Pmin_s + b_s) · u_s,t
(5) commitment link:          u_s,t ≤ Σ_{g ∈ G_h} u_g,t                     for each s ∈ S_h
(6) redundant tightening:     Σ_{s ∈ S_h} ( a_s · p_s,t + b_s · u_s,t ) ≤ Q_h,t
```

Correspondence to the note: (1) is its constraints 1 and 2 with the CT fuel curve in place of a constant heat rate, (2) is its 3, (3) is its 4 and 5 merged because the affine curve carries the minimum heat, (4) is its 6, (5) is its 7 generalized to several CTs, and (6) is the tightening from its implementation notes.
The note's 8 are the existing thermal range constraints.

Properties:

- Everything is linear; `q` is continuous. `dt` cancels, so all rows are rate balances in fuel units per hour.
- A CA in several HRSGs gets one `q` per (CA, HRSG) pair, and (3) sums its allocations.
- When every CT in the HRSG is off, `Q_h,t = 0`, so `b_s > 0` forces every CA off through (2) and (3). Constraints (4) to (6) are implied at integrality but tighten the LP relaxation, which is why they stay.
- The CA minimum-power constraint plus (4) forces the CTs to carry enough load, which is the "constrained to the accompanying CT output" behaviour requested. The note's worked floor `p_g ≥ Σ Q_min_s / (η (HR_g − κ))` falls out of (4).
- The CA's `FuelCurve` is also what the existing thermal builders see, so its heat draw is priced at zero through `fuel_cost = 0.0` and nothing else in the objective changes.

Alternative kept as a one-constant switch (decision D2): drop `κ`, so available heat is `η · fuel_in`.
That is a simpler data story when `η` already folds the exhaust fraction in.

## Where it lives: a plant model slot in the template

CT and CA are both `ThermalStandard`, so they share one `DeviceModel`.
The coupling is a cross-device relation with its own variable, like a service, not a device formulation.
Recommended: a POM-only `PlantModel`, parallel to `ServiceModel`.

```julia
template = PowerOperationsProblemTemplate(PTDFNetworkModel)
set_device_model!(template, ThermalStandard, ThermalStandardUnitCommitment)
set_plant_model!(template, CombinedCycleBlock, SharedHRSGHeatBalance)
```

- `PlantModel{P <: PSY.PowerPlant, F <: AbstractPlantFormulation}` in `src/core/`, fields `duals`, `attributes`, no feedforwards.
- `PowerOperationsProblemTemplate.plants::PlantsModelContainer`; `set_plant_model!`, `get_plant_models`.
- `construct_plant!(container, sys, stage, plant_model, device_models, network_model)` for both stages. The argument stage adds `q` right after the device argument loop in `build_problem.jl`, where services run today. The model stage adds (2) to (6) after the device model loop.
- `construct_plant!` iterates `PSY.get_supplemental_attributes(CombinedCycleBlock, sys)`, resolves CT and CA devices by id, and looks up `ActivePowerVariable` and `OnVariable` by each device's concrete type, so a `ThermalMultiStart` CT with a `ThermalStandard` CA works.
- New file family: `src/plant_models/combined_cycle.jl` and `combined_cycle_constructor.jl`, mirroring the `services_models/` layout.

Why not a thermal formulation variant or a `DeviceModel` attribute: both would hide a multi-device relation inside one device's constructor, need a variant per base formulation (Basic, Standard, MultiStart, Compact), and leave no home for the other `PowerPlant` couplings (shaft limits, penstocks, PCC limits) that will want the same slot.

## Core types

In `src/core/variables.jl`:

- `HRSGHeatAllocationVariable <: VariableType`, the note's `q_s,t`. One container per concrete CA device type, axis names `"<ca name>__hrsg<N>"`, lower bound 0, written to results in fuel units per hour.

In `src/core/constraints.jl`, all keyed on `PSY.CombinedCycleBlock`:

- `HRSGHeatAllocationConstraint`, row (2), axis `"<block>__hrsg<N>"`.
- `HRSGHeatDrawConstraint`, row (3), axis `"<block>__hrsg<N>__<ca name>"`.
- `HRSGMinimumHeatConstraint`, row (4), axis `"<block>__hrsg<N>"`.
- `CombinedCycleCommitmentConstraint`, row (5), axis `"<block>__hrsg<N>__<ca name>"`.
- Row (6) reuses `HRSGHeatAllocationConstraint` with `meta = "aggregate"`.

In `src/core/formulations.jl`:

- `abstract type AbstractPlantFormulation end`
- `struct SharedHRSGHeatBalance <: AbstractPlantFormulation end`

In `src/core/physical_constant_definitions.jl`: the MW to heat-rate constant, derived with Unitful rather than typed as `3.412` or `3.6`.

Duals: `PlantModel(...; duals = [HRSGHeatAllocationConstraint])` exposes the shadow price of recovered heat in currency per fuel unit.

## Validation (`src/operation/template_validation.jl`)

Checked at `build!`, before construction, all raising `IS.ConflictingInputsError`:

1. Every CT and CA id in a block resolves to an available device whose type has a `DeviceModel` in the template.
2. Every HRSG has at least one CT and one CA.
3. CT and CA variable cost is a `FuelCurve{LinearCurve}` with the same `fuel_units` across the block.
4. CA `fuel_cost == 0.0` and no `fuel_cost_time_series`. A priced CA double-counts the CT's fuel.
5. `heat_recovery_to_steam_factor > 0` and `a_g > κ` for every CT, otherwise exhaust heat is negative.
6. The device formulation is not a compact formulation (`PowerAboveMinimumVariable`); see phase 2.

Silent-failure guard, independent of whether a plant model is set:
a block whose CA has a zero-priced `FuelCurve` while no `PlantModel{CombinedCycleBlock}` covers it is free energy, so the build errors.
Blocks whose CAs carry a real price build with a warning in `operation_problem.log`.

## Results and analytics

- `HRSGHeatAllocationVariable__ThermalStandard` is the per-CA heat draw and the primary reporting quantity.
- `FuelConsumptionExpression__ThermalStandard` also reports the CA's proportional heat term, because the existing builder treats any `FuelCurve` the same way. Document this. Downstream fuel totals should filter on `prime_mover_type != CA`. A later `HeatInputExpression` split is listed under follow-ups.
- `HRSGHeatAllocationConstraint` duals are readable through the normal dual path.

## Tests (`test/test_plant_combined_cycle.jl`)

Fixture: the note's 1x2 numerical example on top of `c_sys5_uc`, built in `test/test_utils/add_components_to_system.jl`, in GJ so `κ = 3.6` is exercised.

| Unit | Pmax | Pmin | Curve | Note parameters reproduced |
|---|---|---|---|---|
| CT | 200 MW | 80 MW | `FuelCurve(LinearCurve(10.0, 0.0), u"GJ", fuel_cost)` | `HR_g = 10.0` |
| ST1, bus 1 | 60 MW | 20 MW | `FuelCurve(LinearCurve(7.5, 30.0), u"GJ", 0.0)` | `HR_s = 7.5`, `Q_min = 180` |
| ST2, bus 2 | 40 MW | 15 MW | `FuelCurve(LinearCurve(8.0, 24.0), u"GJ", 0.0)` | `HR_s = 8.0`, `Q_min = 144` |

Block: `η = 0.82`, all three on HRSG 1, STs on different buses so the network matters.

1. Build and solve with `ThermalStandardUnitCommitment` on `CopperPlateNetworkModel` and `PTDFNetworkModel`.
2. Coefficient-level check of rows (2) to (6) against hand-computed `a`, `b`, `κ`, `η` values (MODF-suite pattern).
3. Available-heat table from the note: fix CT output at 80, 120, 160 and 200 MW and assert `Q_h` equals 420, 630, 840 and 1050 GJ/h and the ST caps match.
4. Behaviour: force the CT off for a window; assert both STs are off, and elsewhere `Σ q ≤ Q_h` holds with `q` equal to each ST's curve value.
5. Shared pool: with CT held at 80 MW, both STs committed cannot exceed 420 GJ/h together, so their outputs trade off.
6. Dispatch formulation (`ThermalBasicDispatch`): rows (2), (3) and (6) present, (4) and (5) absent.
7. Validation: priced CA, compact formulation, HRSG with no CT, `a_g ≤ κ`, block with no plant model and a zero-priced CA, each raising `IS.ConflictingInputsError`.
8. Duals readable and nonnegative.
9. `Test.detect_ambiguities` and `test_dispatch_signatures.jl` cover the new `construct_plant!` signatures.

Build warnings land in `operation_problem.log`; assert by reading the file.

## Docs

- `docs/src/reference/formulation_library.md`: new "Plant formulations" section with rows (1) to (6), the parameter mapping table and the template snippet.
- `docs/src/reference/public.md`: register `PlantModel`, `set_plant_model!`, `SharedHRSGHeatBalance`, the variable and the constraint types.
- Docs must build.

## Phases

Phase 1 (this spec): `PlantModel` slot, `SharedHRSGHeatBalance` for linear fuel curves, standard and basic UC plus dispatch formulations, validation, tests, docs.

Phase 2, each a separate PR, in the order the note raises them:

- Fixed allocation fractions `α_s`: `q_s,t = α_s · Q_h,t` as an alternative formulation `FixedAllocationHRSGHeatBalance`. Needs an `α` field upstream in `CombinedCycleBlock`.
- Part-load HRSG efficiency `η(p_g) = η_0 + η_1 · p_g / Pmax_g`: the product `η(p_g) · p_g` is quadratic, so this needs a piecewise `η` or a PWL available-heat curve. Needs `η_0`, `η_1` upstream.
- Startup sequencing across several STs: at most one ST start per step, or a priority order.
- Compact and `ThermalMultiStart` formulations: express `p = Pmin · u + p_above` inside (1), (3) and (6).
- Piecewise-linear CT curves: reuse the PWL interpolation variables for (1), or offer the output-based link (`η · (HR_g − κ) · p_g` with a constant `HR_g`), which is the note's own form and is linear for any curve.
- Quadratic CT curves: the right side of (2) becomes convex on the wrong side of the inequality, so reject unless a conservative linearization is chosen.
- Reserve-aware balance using `ActivePowerRangeExpressionUB`, so CA reserve awards are backed by spare heat.
- `HeatInputExpression` for CAs, separate from `FuelConsumptionExpression`.
- `ThermalPowerPlant` shaft and `CombinedCycleFractional` exclusion constraints on the same `PlantModel` slot.
- PowerSystemCaseBuilder fixture once the test fixture settles.

## Decisions to confirm

- D1. `PlantModel` template slot (recommended) versus a `DeviceModel` attribute on the thermal model.
- D2. CT heat as `fuel_in − κ · p` (recommended, matches the note and keeps `η` physical) versus `fuel_in` only.
- D3. Errors, not warnings, for a zero-priced CA with no plant model.
- D4. Keep CA heat in `FuelConsumptionExpression` for phase 1 (recommended) versus splitting `HeatInputExpression` now.
- D5. Keep the explicit `q` allocation variable (recommended: reporting, duals per CA, and phase 2 needs it) versus projecting it out and keeping only row (6).
- D6. `Q_min_s` derived from the CA curve at `Pmin_s` (recommended, no new data) versus a dedicated field upstream.

## Out of scope

Simulation orchestration, emulation-model updates, and PSY schema changes.
The existing `SemiContinuousFeedforward` on thermal commitment already carries UC decisions into an ED that uses the same plant model.

## Implementation notes (2026-11-06)

Phase 1 landed on `ac/cc-heat-coupling` with these deviations from the proposal above.

- Row (3) is an equality, `q_s,t = a_s · p_s,t + b_s · u_s,t`.
  With `q` unpriced, the `≥` form leaves `q` loose between the curve value and the pool limit, so the reported allocation would be solver-dependent.
- Rows (4) and (6) are not built.
  Under (2) and (3) and the thermal range `p_s ≥ Pmin_s · u_s`, both are implied in the LP relaxation as well, so they would only duplicate rows.
  `HRSGMinimumHeatConstraint` does not exist; the `"aggregate"` meta is unused.
- Constraint containers are keyed on `PSY.ThermalGen`, not on `PSY.CombinedCycleBlock`.
  IOM's `add_constraints_container!` only accepts `IS.InfrastructureSystemsComponent` or container key types, and a supplemental attribute is neither.
  Widening that bound is an IOM change for a follow-up; `PSY.ThermalGen` is the family the rows couple, and `ConstraintKey` accepts an abstract component type.
  Results read as `HRSGHeatAllocationConstraint__ThermalGen`.
- D2 is a `PlantModel` attribute, `"subtract_electrical_output"` (default `true`).
- A device may belong to one block only, because the `q` axis is `"<ca>__hrsg<N>"` and HRSG numbers are per block.
- Dual sign follows JuMP: nonpositive on the `≤` pool row.
- The test fixture is in GJ as planned, but PSY's document export cannot serialize a `FuelCurve` in GJ, so the test models are built with `system_to_file = false`.
