# Developer Guidelines

In order to contribute to `PowerSystems.jl` repository please read the following sections of
[`InfrastructureSystems.jl`](https://github.com/Sienna-Platform/InfrastructureSystems.jl)
documentation in detail:

 1. [Style Guide](https://sienna-platform.github.io/InfrastructureSystems.jl/stable/style/)
 2. [Contributing Guidelines](https://github.com/Sienna-Platform/PowerOperationsModels.jl/blob/main/CONTRIBUTING.md)

Pull requests are always welcome to fix bugs or add additional modeling capabilities.

**All the code contributions need to include tests with a minimum coverage of 70%**

## Optimization container axes

`add_variable_container!`/`add_constraints_container!`/`add_dual_container!`/`add_expression_container!`/`add_param_container!`
build a `JuMP.Containers.DenseAxisArray` (or `SparseAxisArray` when `sparse = true`) whose
dimensionality is exactly the number of axis arguments passed after the container type and
device type. **The vast majority of containers in POM are 2D, indexed `[device_name, time_step]`.** A handful of formulations legitimately build 1D or 3D containers instead;
this section documents all of them so a reader isn't left guessing whether a 1D container is
a bug or intentional (see issue #178 and the now-closed IOM issue #15, which originally
proposed rejecting 1D containers outright before we decided documentation + indexing
correctness was the better fix).

Two failure modes to watch for when touching any of these:

  - Indexing a container with fewer/more keys than it was created with. `DenseAxisArray`
    tolerates a trailing index of `1` (Julia's linear-indexing convention) without erroring,
    but any other extra index raises a `KeyError`.
  - Adding a new call site for one of the `ConstraintType`/`VariableType`/`ExpressionType`
    keys below without checking how the *existing* call sites index it — mirror the
    established pattern instead of guessing.

### 1D containers (axis: device/service name only)

Whole-horizon or end-of-horizon quantities that don't vary per time step, so there's no
second axis to index into. Always indexed downstream as `container[name]`.

| Container type                                                | File                                           | Notes                                                                                                                       |
|:------------------------------------------------------------- |:---------------------------------------------- |:--------------------------------------------------------------------------------------------------------------------------- |
| `StateofChargeTargetConstraint`                               | `energy_storage_models/storage_models.jl`      | End-of-horizon state-of-charge target; RHS references `time_steps[end]` but the constraint itself has one entry per device. |
| `StorageCyclingCharge` / `StorageCyclingDischarge`            | `energy_storage_models/storage_models.jl`      | Whole-horizon cycling budget (sum of charge/discharge over all time steps `<=` cycle allowance); one constraint per device. |
| `EnergyBudgetConstraint` / `WaterBudgetConstraint`            | `static_injector_models/hydro_generation.jl`   | Whole-horizon energy/water budget per device.                                                                               |
| `ReservoirLevelTargetConstraint`                              | `static_injector_models/hydro_generation.jl`   | End-of-horizon reservoir level target, analogous to `StateofChargeTargetConstraint`.                                        |
| `ImportExportBudgetConstraint` (`meta = "import"`/`"export"`) | `static_injector_models/source.jl`             | Whole-horizon import/export budget per device.                                                                              |
| `ActiveRangeICConstraint`                                     | `static_injector_models/thermal_generation.jl` | End-of-horizon initial-condition range constraint.                                                                          |

### 1D containers (axis: time step only, no device axis)

System-wide quantities with a single value per time step — there is no device axis because
they aren't indexed by device.

| Container type                                    | File                                | Notes                                                                                                                                                                                                                      |
|:------------------------------------------------- |:----------------------------------- |:-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SteadyStateFrequencyDeviation`                   | `services_models/agc.jl`            | System-wide AGC variable, one per time step.                                                                                                                                                                               |
| `ReserveRequirementSlack`                         | `services_models/service_slacks.jl` | Built via the `add_variable_container!(container, T, U, meta::String, axs...)` overload — the service name is passed positionally as `meta`, not as an axis, so the resulting container is genuinely 1D over `time_steps`. |
| `InterfaceFlowSlackUp` / `InterfaceFlowSlackDown` | `services_models/service_slacks.jl` | Same `meta`-as-name pattern as `ReserveRequirementSlack`.                                                                                                                                                                  |

### "Practically 1D" containers (2D at creation, but the 2nd axis is a true singleton)

These are genuinely 2D `[device_name, time_axis]` containers — not exceptions to the axis
count — but the second axis is always exactly one element (the terminal time step), so in
practice there is only ever one column. They're listed here because it's easy to mistake
them for the 1D containers above, or vice versa, when reading call sites. Always indexed
downstream as `container[name, time_steps[end]]` (never `container[name]`).

| Container type                                                               | File                                         | 2nd-axis expression                                 | Notes                                                                                                                           |
|:---------------------------------------------------------------------------- |:-------------------------------------------- |:--------------------------------------------------- |:------------------------------------------------------------------------------------------------------------------------------- |
| `StorageEnergyShortageVariable` / `StorageEnergySurplusVariable`             | `energy_storage_models/storage_models.jl`    | `last_time_range = time_steps[end]:time_steps[end]` | End-of-horizon energy-target slack variables.                                                                                   |
| `StorageChargeCyclingSlackVariable` / `StorageDischargeCyclingSlackVariable` | `energy_storage_models/storage_models.jl`    | `last_time_range = time_steps[end]:time_steps[end]` | End-of-horizon cycling slack variables (paired with the 1D `StorageCyclingCharge`/`StorageCyclingDischarge` constraints above). |
| `HybridEnergyShortageVariable` / `HybridEnergySurplusVariable`               | `hybrid_system_models/hybrid_systems.jl`     | `last_time_range = time_steps[end]:time_steps[end]` | Mirrors the storage slack variables above, keyed by `HybridSystem`.                                                             |
| `EnergyTargetConstraint`                                                     | `static_injector_models/hydro_generation.jl` | `[time_steps[end]]`                                 | End-of-horizon reservoir energy target.                                                                                         |
| `WaterTargetConstraint`                                                      | `static_injector_models/hydro_generation.jl` | `[time_steps[end]]`                                 | End-of-horizon reservoir water target.                                                                                          |
| `HydroUsageLimitParameter`                                                   | `static_injector_models/hydro_generation.jl` | `[time_steps[end]]`                                 | Parameter container for an aux-variable value; explicitly commented in-code as "a single column".                               |
| `ShiftedActivePowerBalanceConstraint` (default `meta`)                       | `static_injector_models/electric_loads.jl`   | `[time_steps[end]]`                                 | Explicitly commented in-code: "Keep this container 2D (name, terminal-time marker) to match standard indexing patterns."        |

**Not a singleton — don't misclassify:** `ShiftedActivePowerBalanceConstraint` built with
`meta = "additional"` (same file, `electric_loads.jl`) looks similar (`interval_end_steps`
as the 2nd axis) but is **not** a true singleton — its length depends on the device model's
`additional_balance_interval` attribute and can hold one column per sub-interval of the
horizon, not just the final one. It's still always 2D and indexed `container[name, t]` in a
loop, so no bug there; it just isn't part of the "always exactly one column" family above.

### 3D containers

| Container type                                                              | File                                           | Notes                                                                                                                          |
|:--------------------------------------------------------------------------- |:---------------------------------------------- |:------------------------------------------------------------------------------------------------------------------------------ |
| `HydroTurbineFlowRateVariable`                                              | `static_injector_models/hydro_generation.jl`   | Indexed `[turbine_name, reservoir_name, time_step]` — flow rate depends on both the turbine and which reservoir it draws from. |
| `StartupInitialConditionConstraint` (`meta = "ub"`/`"lb"`, `sparse = true`) | `static_injector_models/thermal_generation.jl` | `SparseAxisArray` indexed `[name, time_step, start_stage]`.                                                                    |

Everything else built via `add_*_container!` is 2D `[device_name, time_step]`, including the
practically-1D singleton-second-axis containers above — they're still 2 axes and follow the
normal `container[name, t]` indexing pattern.

#### MarketBidCost PWL block-offer variables: a 3D container that bypasses `add_*_container!`

Time-varying offer-curve costs (`MarketBidCost`, `ImportExportCost`, and the
`ReserveDemandCurve`/ORDC service cost) use a genuinely 3D structure — `(device_name, pwl_segment_index, time_step)` — but it is **not** built via the `add_*_container!` +
`Vararg` axes mechanism documented above. It's a `SparseAxisArray{JuMP.VariableRef}` keyed
by `Tuple{String, Int, Int}`, constructed as empty and populated per-`(name, t)` by IOM.
