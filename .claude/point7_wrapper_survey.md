# Point 7 — static_injector_models wrapper survey (Task D)

Scope: `src/static_injector_models/*.jl` (POM, branch `ivr-native`).
Method: enumerate every `add_constraints!` / `add_variables!` **method definition**
(not call site) in the directory, read each body, and classify:

- **DELEGATE-IDENTICAL** — body is a single call to a shared common_models/IOM builder,
  identical across a group modulo the *device* type parameter `V`.
- **DELEGATE-VARIANT** — delegates to a builder but with different arguments, a guard
  (`has_semicontinuous_feedforward`, `get_attribute(model, "reservation")`), or a
  different builder per formulation `W`.
- **INLINE** — real constraint math (`JuMP.@constraint` loops, `add_constraints_container!`
  with hand-written expressions).

Collapse rule (from brief + global-constraints): collapse ONLY a DELEGATE-IDENTICAL group
whose members unify through an **existing abstract bound** in the type hierarchy. **No
`Union`-typed dispatch signatures.** If a group unifies only via `Union` (or via an existing
abstract that would over-broaden to sibling formulations needing different handling), record
it here and do NOT collapse.

## Verdict histogram

| Verdict | Count |
|---|---|
| INLINE | 40 |
| DELEGATE-VARIANT | 18 |
| DELEGATE-IDENTICAL (collapsible) | 0 |
| DELEGATE-IDENTICAL (record-only, no legal unifier) | 4 (2 groups × 2) |
| **Total method defs surveyed** | **62** |

**Collapses performed: 0.** Honest outcome = high-value survey, no source edits.
Every literal-duplicate group unifies only through a `Union` or an over-broad existing
abstract — both forbidden. `Test.detect_ambiguities(PowerOperationsModels)` = 0 (unchanged).

## Method census by file

### source.jl
| line | method | verdict | body |
|---|---|---|---|
| 75 | `add_constraints!(PowerVariableLimitsConstraint, VariableType/ExpressionType; Source, AbstractSourceFormulation)` | DELEGATE-VARIANT | branches on `get_attribute(model,"reservation")` → `add_reserve_range_constraints!` else `add_range_constraints!` |
| 95 | `add_constraints!(ImportExportBudgetConstraint; Source)` | INLINE | weekly import/export budget `@constraint` |
| 144 | `add_constraints!(ActivePowerOutVariableTimeSeriesLimitsConstraint; Source)` | DELEGATE-VARIANT | `add_parameterized_upper_bound_range_constraints` w/ `ActivePowerOutTimeSeriesParameter` |
| 168 | `add_constraints!(ActivePowerInVariableTimeSeriesLimitsConstraint; Source)` | DELEGATE-VARIANT | same builder, `ActivePowerInTimeSeriesParameter` (differs from 144 by parameter/constraint type) |

### renewable_generation.jl
| line | method | verdict | body |
|---|---|---|---|
| 64 | `add_constraints!(ReactivePowerVariableLimitsConstraint, ReactivePowerVariable; RenewableGen, AbstractDeviceFormulation)` | DELEGATE-VARIANT | `add_range_constraints!` |
| 79 | `add_constraints!(ReactivePowerVariableLimitsConstraint; RenewableGen, RenewableConstantPowerFactor)` | INLINE | `q == p*pf` power-factor equality |
| 106 | `add_constraints!(ActivePowerVariableLimitsConstraint, VariableType/RangeExprUB; RenewableGen, AbstractRenewableDispatch)` | DELEGATE-VARIANT | `add_parameterized_upper_bound_range_constraints` (UB path) |
| 130 | `add_constraints!(ActivePowerVariableLimitsConstraint, RangeExprLB; RenewableGen, AbstractRenewableDispatch)` | DELEGATE-VARIANT | `add_range_constraints!` (LB path; different builder from 106 → not identical) |

### electric_loads.jl
| line | method | verdict | body |
|---|---|---|---|
| 218 | `add_constraints!(ReactivePowerVariableLimitsConstraint; ControllableLoad, AbstractControllablePowerLoadFormulation)` | INLINE | power-factor `@constraint` |
| 250 | `add_constraints!(ActivePowerVariableLimitsConstraint, VariableType; ControllableLoad, PowerLoadDispatch)` | **DELEGATE-IDENTICAL (record)** | see Group L1 |
| 270 | `add_constraints!(ActivePowerVariableLimitsConstraint, VariableType; ControllableLoad, PowerLoadInterruption)` | **DELEGATE-IDENTICAL (record)** | see Group L1 |
| 290 | `add_constraints!(ActivePowerVariableLimitsConstraint, OnVariable; ControllableLoad, PowerLoadInterruption)` | INLINE | `power <= on*pmax` |
| 317 | `add_constraints!(ShiftedActivePowerBalanceConstraint; ShiftablePowerLoad, PowerLoadShift)` | INLINE | shift balance + optional interval balances |
| 415 | `add_constraints!(RealizedShiftedLoadMinimumBoundConstraint; ShiftablePowerLoad, PowerLoadShift)` | INLINE | `realized_load >= 0` |
| 440 | `add_constraints!(NonAnticipativityConstraint; ShiftablePowerLoad, PowerLoadShift)` | INLINE | cumulative down-up `@constraint` |
| 470 | `add_constraints!(ShiftUpActivePowerVariableLimitsConstraint; ShiftablePowerLoad, PowerLoadShift)` | DELEGATE-VARIANT | `add_parameterized_upper_bound_range_constraints` w/ `ShiftUpActivePowerTimeSeriesParameter` |
| 490 | `add_constraints!(ShiftDownActivePowerVariableLimitsConstraint; ShiftablePowerLoad, PowerLoadShift)` | DELEGATE-VARIANT | same builder, `ShiftDown...Parameter` (differs from 470 by constraint/parameter type) |

### shunt_models.jl / shunt_constructor.jl
| line | file | method | verdict | body |
|---|---|---|---|---|
| 123 | shunt_constructor.jl | `add_constraints!(ShuntReactivePowerConstraint; StaticInjection, ShuntSusceptanceDispatch)` | INLINE | `q == b*v²` per bus-voltage |

### reactivepower_device.jl
(no `add_constraints!`/`add_variables!` method defs — only trait getters.)

### thermal_generation.jl
| line | method | verdict | body |
|---|---|---|---|
| 313 | `add_constraints!(PowerVariableLimitsConstraint; ThermalGen, AbstractThermalDispatch)` | DELEGATE-VARIANT | guarded `add_range_constraints!` (`!has_semicontinuous_feedforward`) |
| 349 | `add_variables!(OnVariable/StartVariable/StopVariable; ThermalGen, AbstractThermalFormulation)` | INLINE | builds binary vars, skips must-run, warm start |
| 396 | `add_constraints!(PowerVariableLimitsConstraint; ThermalGen, AbstractThermalUnitCommitment)` | DELEGATE-VARIANT | `add_semicontinuous_range_constraints!` |
| 482 | `add_constraints!(ActivePowerVariableTimeSeriesLimitsConstraint; ThermalGen, AbstractThermalUnitCommitment)` | DELEGATE-VARIANT | `add_parameterized_upper_bound_range_constraints` |
| 513 | `add_constraints!(ActivePowerVariableLimitsConstraint, VariableType; ThermalMultiStart, ThermalMultiStartUC)` | INLINE | PGLIB constraint-10 on/off/lb |
| 591 | `add_constraints!(ActivePowerVariableLimitsConstraint, RangeExprLB; ThermalMultiStart, ThermalMultiStartUC)` | INLINE | expression LB `@constraint` |
| 635 | `add_constraints!(ActivePowerVariableLimitsConstraint, RangeExprUB; ThermalMultiStart, ThermalMultiStartUC)` | INLINE | expression UB on/off `@constraint` |
| 703 | `add_constraints!(ActiveRangeICConstraint; ThermalGen, AbstractCompactUC)` | INLINE | IC range `@constraint` |
| 767 | `add_constraints!(CommitmentConstraint; ThermalGen, AbstractThermalUC)` | INLINE | on/off logic `@constraint` |
| 1032 | `add_constraints!(RampConstraint; ThermalGen, AbstractThermalUC)` | DELEGATE-VARIANT | `add_semicontinuous_ramp_constraints!` w/ `ActivePowerVariable` |
| 1055 | `add_constraints!(RampConstraint; ThermalGen, AbstractCompactUC)` | DELEGATE-VARIANT | `add_semicontinuous_ramp_constraints!` w/ `PowerAboveMinimumVariable` (differs by var arg) |
| 1078 | `add_constraints!(RampConstraint; ThermalGen, ThermalCompactDispatch)` | DELEGATE-VARIANT | `add_linear_ramp_constraints!` w/ `PowerAboveMinimumVariable` |
| 1090 | `add_constraints!(RampConstraint; ThermalGen, AbstractThermalDispatch)` | DELEGATE-VARIANT | `add_linear_ramp_constraints!` w/ `ActivePowerVariable` (differs by var arg) |
| 1106 | `add_constraints!(RampConstraint; ThermalMultiStart, ThermalMultiStartUC)` | DELEGATE-VARIANT | `add_linear_ramp_constraints!` w/ `PowerAboveMinimumVariable` |
| 1143 | `add_constraints!(StartupTimeLimitTemperatureConstraint; ThermalMultiStart)` | INLINE | start-type down-time `@constraint` |
| 1215 | `add_constraints!(StartTypeConstraint; ThermalMultiStart)` | INLINE | start-type sum `@constraint` |
| 1264 | `add_constraints!(StartupInitialConditionConstraint; ThermalMultiStart)` | INLINE | startup IC ub/lb `@constraint` |
| 1377 | `add_constraints!(DurationConstraint; ThermalGen, AbstractThermalUC)` | DELEGATE-VARIANT | branches params → `device_duration_parameters!` / `device_duration_retrospective!` |
| 1416 | `add_constraints!(DurationConstraint; ThermalGen, ThermalMultiStartUC)` | DELEGATE-VARIANT | branches params → `device_duration_parameters!` / `device_duration_compact_retrospective!` (differs from 1377 by retrospective builder) |

### hydro_generation.jl
| line | method | verdict | body |
|---|---|---|---|
| 476 | `add_variables!(...; HydroGen)` | INLINE | `add_variable_container!` + hand-built vars |
| 518 | `add_variables!(...; HydroGen)` | INLINE | `add_variable_container!` + hand-built vars |
| 567 | `add_constraints!(ActivePowerVariableLimitsConstraint, RangeLB; HydroGen, Union{RunOfRiver,RunOfRiverBudget})` | DELEGATE-VARIANT | guarded `add_range_constraints!` (existing Union already in source; not a Task-D-created signature) |
| 585 | `add_constraints!(... RangeUB; HydroGen, Union{RunOfRiver,RunOfRiverBudget})` | DELEGATE-VARIANT | `add_range_constraints!` + `add_parameterized_upper_bound_range_constraints` (2 calls → not single-call identical) |
| 614 | `add_constraints!(... RangeLB; HydroGen, HydroCommitmentRunOfRiver)` | DELEGATE-VARIANT | `add_semicontinuous_range_constraints!` |
| 626 | `add_constraints!(... RangeUB; HydroGen, HydroCommitmentRunOfRiver)` | DELEGATE-VARIANT | semicontinuous + parameterized UB (2 calls) |
| 648 | `add_constraints!(... RangeLB/UB; HydroTurbine, HydroTurbineEnergyCommitment)` | **DELEGATE-IDENTICAL (record)** | see Group H1 |
| 667 | `add_constraints!(... RangeLB/UB; HydroTurbine, HydroTurbineWaterLinearCommitment)` | **DELEGATE-IDENTICAL (record)** | see Group H1 |
| 773 | `add_constraints!(PowerVariableLimitsConstraint, Var/Expr; HydroGen, AbstractHydroUnitCommitment)` | DELEGATE-VARIANT | `add_semicontinuous_range_constraints!` (broad T/U; see H1 note) |
| 788 | `add_constraints!(PowerVariableLimitsConstraint, Var/Expr; HydroGen, AbstractHydroDispatch)` | DELEGATE-VARIANT | guarded `add_range_constraints!` |
| 812 | `add_constraints!(EnergyBalanceConstraint; HydroReservoir, HydroEnergyModelReservoir)` | INLINE | energy balance `@constraint` |
| 918 | `add_constraints!(EnergyTargetConstraint; ...)` | INLINE | `@constraint` |
| 976 | `add_constraints!(EnergyTargetConstraint; ...)` | INLINE | `@constraint` |
| 1029 | `add_constraints!(WaterTargetConstraint; ...)` | INLINE | `@constraint` |
| 1088 | `add_constraints!(HydroPowerConstraint; ...)` | INLINE | `@constraint` |
| 1172 | `add_constraints!(ReservoirInventoryConstraint; ...)` | INLINE | `@constraint` |
| 1264 | `add_constraints!(EnergyBudgetConstraint; ...)` | INLINE | `@constraint` |
| 1296 | `add_constraints!(EnergyBudgetConstraint; ...)` | INLINE | `@constraint` + aux |
| 1358 | `add_constraints!(EnergyBudgetConstraint; ...)` | INLINE | `@constraint` |
| 1402 | `add_constraints!(WaterBudgetConstraint; ...)` | INLINE | `@constraint` |
| 1442 | `add_constraints!(EnergyBalanceConstraint; ...)` | INLINE | `@constraint` |
| 1471 | `add_constraints!(ReservoirLevelLimitConstraint; ...)` | INLINE | `@constraint` |
| 1528 | `add_constraints!(ReservoirInventoryConstraint; ...)` | INLINE | `@constraint` |
| 1601 | `add_constraints!(ReservoirLevelTargetConstraint; ...)` | INLINE | `@constraint` |
| 1641 | `add_constraints!(ReservoirLevelTargetConstraint; ...)` | INLINE | `@constraint` |
| 1689 | `add_constraints!(ReservoirHeadToVolumeConstraint; ...)` | INLINE | `@constraint` |
| 1727 | `add_constraints!(TurbinePowerOutputConstraint; ...)` | INLINE | `@constraint` |
| 1784 | `add_constraints!(...; ...)` | INLINE | `add_constraints_container!` + `@constraint` |
| 2483 | `add_constraints!(... RangeLB; HydroPumpTurbine, HydroPumpEnergyDispatch)` | DELEGATE-VARIANT | reservation-guarded `add_range_constraints!` / `IOM.add_reserve_bound_range_constraints!` |
| 2504 | `add_constraints!(... RangeUB; HydroPumpTurbine, HydroPumpEnergyDispatch)` | DELEGATE-VARIANT | reservation-guarded (UB) |
| 2526 | `add_constraints!(... RangeLB; HydroPumpTurbine, HydroPumpEnergyCommitment)` | DELEGATE-VARIANT | semicontinuous / reserve+commitment bound (differs from 2483 by builder) |
| 2550 | `add_constraints!(... RangeUB; HydroPumpTurbine, HydroPumpEnergyCommitment)` | DELEGATE-VARIANT | semicontinuous / reserve+commitment bound (UB) |
| 2570 | `add_constraints!(InputActivePowerVariableLimitsConstraint, ActivePowerPumpVariable; HydroPumpTurbine, HydroPumpEnergyCommitment)` | DELEGATE-VARIANT | `add_semicontinuous_range_constraints!` |
| 2599 | `add_constraints!(ActivePowerPumpReservationConstraint; HydroPumpTurbine, AbstractHydroPumpFormulation)` | DELEGATE-VARIANT | `IOM.add_reserve_bound_range_constraints!` |
| 2616 | `add_constraints!(ActivePowerVariableTimeSeriesLimitsConstraint, RangeExprUB; HydroPumpTurbine, HydroPumpEnergyDispatch)` | DELEGATE-VARIANT | `add_parameterized_upper_bound_range_constraints` |

> Note: several hydro/source/thermal DELEGATE-VARIANT methods sit in near-mirror LB/UB or
> Dispatch/Commitment pairs. They are **not** collapsible because the LB and UB members call
> different builders (or add an extra parameterized-UB call), and the Dispatch/Commitment
> members call different builders — the divergence IS the point (mirror-structure rule).

## Record-only groups (literal duplicates with no legal unifier)

### Group L1 — controllable-load active-power TS limits
`electric_loads.jl:250` and `electric_loads.jl:270`. Bodies **byte-identical**
(`diff` empty). Signatures differ only in formulation `W` (and a cosmetic `::Type{…}` vs
`T::Type{…}` binding of the unused constraint arg):

```julia
# 250
function add_constraints!(
    container::OptimizationContainer,
    ::Type{ActivePowerVariableLimitsConstraint},
    U::Type{<:VariableType},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.ControllableLoad, W <: PowerLoadDispatch, X <: AbstractPowerModel}

# 270
function add_constraints!(
    container::OptimizationContainer,
    T::Type{ActivePowerVariableLimitsConstraint},
    U::Type{<:VariableType},
    devices::IS.FlattenIteratorWrapper{V},
    model::DeviceModel{V, W},
    ::NetworkModel{X},
) where {V <: PSY.ControllableLoad, W <: PowerLoadInterruption, X <: AbstractPowerModel}
```

Shared body (both):
```julia
    add_parameterized_upper_bound_range_constraints(
        container, ActivePowerVariableTimeSeriesLimitsConstraint, U,
        ActivePowerTimeSeriesParameter, devices, model, X)
    return
```

**Why NOT collapsed.** The only bound that subsumes both `PowerLoadDispatch` and
`PowerLoadInterruption` is `AbstractControllablePowerLoadFormulation`
(`src/core/formulations.jl:60`), whose third subtype is **`PowerLoadShift`**
(`:80`). `PowerLoadShift`'s constructor (`load_constructor.jl:523,574,684`) never issues
`ActivePowerVariableLimitsConstraint` — it uses `ShiftUp/ShiftDownActivePowerVariableLimitsConstraint`.
Widening `W` to the abstract would make this method newly dispatchable for `PowerLoadShift`,
a semantic broadening (currently no such method exists for Shift). The exact unifier is
`W <: Union{PowerLoadDispatch, PowerLoadInterruption}` — a new `Union` dispatch signature,
which the no-Unions rule forbids. **Verdict: record, do not collapse.**

### Group H1 — hydro-turbine unit-commitment active-power range
`hydro_generation.jl:648` and `hydro_generation.jl:667`. Bodies **byte-identical**
(single `add_semicontinuous_range_constraints!(container, T, U, devices, model, X)`).
Signatures differ only in `W` (`HydroTurbineEnergyCommitment` vs
`HydroTurbineWaterLinearCommitment`), both `V <: PSY.HydroTurbine`,
`T::Type{ActivePowerVariableLimitsConstraint}`,
`U::Type{<:Union{RangeConstraintLBExpressions, RangeConstraintUBExpressions}}`.

**Why NOT collapsed.** Both formulations are `<: AbstractHydroUnitCommitment`
(`formulations.jl:497,507`), but that abstract also covers `HydroCommitmentRunOfRiver`
(`:466`), and a broader method already exists at `hydro_generation.jl:773`
(`V <: PSY.HydroGen, W <: AbstractHydroUnitCommitment`,
`T <: PowerVariableLimitsConstraint`, `U <: Union{VariableType, ExpressionType}`).
Widening `W` to `AbstractHydroUnitCommitment` on the `HydroTurbine`-specific method would
(a) newly capture `HydroCommitmentRunOfRiver` for turbine devices and (b) create a dispatch
overlap with the `HydroGen`/`AbstractHydroUnitCommitment` method at 773 (more-specific `V`,
less-specific `W` vs less-specific `V`, equal `W`) — an ambiguity risk. The exact unifier is
`W <: Union{HydroTurbineEnergyCommitment, HydroTurbineWaterLinearCommitment}` — a new `Union`
dispatch signature, forbidden. **Verdict: record, do not collapse.**

## Recommendation (survey value, no code change)

If a future (non-`ivr-native`, non-surgical) refactor wants to eliminate L1 and H1 without a
`Union`, the trait-layer approach the codebase already uses (see global-constraints:
"extend the trait layer instead") is the right lever: introduce a predicate/marker abstract
that groups exactly `{PowerLoadDispatch, PowerLoadInterruption}` (a
`AbstractParameterizedControllableLoad` layer between `AbstractControllablePowerLoadFormulation`
and the two concretes) and, for hydro, an intermediate abstract grouping the two turbine-UC
formulations that excludes `HydroCommitmentRunOfRiver`. Both are hierarchy changes beyond the
surgical scope of this WIP branch and would ripple through the constructors and trait getters —
out of scope for Task D.
