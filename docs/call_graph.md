# IOM + POM Function Call Graph

## Legend
- `[IOM]` = Defined in InfrastructureOptimizationModels.jl
- `[POM]` = Defined in PowerOperationsModels.jl
- `→` = calls
- `⇒` = extension point (IOM declares, POM implements)

---

## Main Execution Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           ENTRY POINTS                                          │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   User Code                                                                     │
│       │                                                                         │
│       ▼                                                                         │
│   solve! [IOM]                                                                  │
│       │                                                                         │
│       ├──→ build_if_not_already_built! [IOM]                                    │
│       │         │                                                               │
│       │         ▼                                                               │
│       │     build! [IOM]  ◄─────────────────────────────────────────┐           │
│       │         │                                                   │           │
│       │         ├──→ build_pre_step! [IOM]                          │           │
│       │         ├──→ build_impl! [IOM] ────────────────────────┐    │           │
│       │         └──→ add_recorders! [IOM]                      │    │           │
│       │                                                         │    │          │
│       └──→ _solve! [IOM]                                        │    │          │
│                │                                                │    │          │
│                └──→ JuMP.optimize!                              │    │          │
│                                                                 │    │          │
└─────────────────────────────────────────────────────────────────│────│──────────┘
                                                                  │    │
┌─────────────────────────────────────────────────────────────────▼────┴──────────┐
│                           BUILD IMPLEMENTATION                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   build_impl! [IOM] (core/optimization_container.jl:769-907)                    │
│       │                                                                         │
│       ├──→ initialize_system_expressions! [IOM]                                 │
│       ├──→ initialize_hvdc_system! [IOM]                                        │
│       │                                                                         │
│       │   ┌─────────────── LOOP 1: Devices (ArgumentConstructStage) ─────────-─┐│
│       │   │                                                                    ││
│       ├───┼──⇒ construct_device!(::ArgumentConstructStage) [POM]               ││
│       │   │         │                                                          ││
│       │   │         ├──→ add_parameters! [IOM]                                 ││
│       │   │         ├──⇒ add_variables! [POM]                                  ││
│       │   │         ├──⇒ add_to_expression! [POM]                              ││
│       │   │         ├──→ add_expressions! [IOM]                                ││
│       │   │         ├──→ initial_conditions! [POM]                             ││
│       │   │         │         │                                                ││
│       │   │         │         └──→ add_initial_condition! [IOM]                ││
│       │   │         │                    │                                     ││
│       │   │         │                    ├──⇒ initial_condition_variable [POM] ││
│       │   │         │                    └──⇒ initial_condition_default [POM]  ││
│       │   │         │                                                          ││
│       │   │         └──→ add_feedforward_arguments! [IOM]                      ││
│       │   │                                                                    ││
│       │   └────────────────────────────────────────────────────────────────────┘│
│       │                                                                         │
│       │   ┌─────────────── LOOP 2: Services (ArgumentConstructStage) ─────────┐│
│       │   │                                                                    ││
│       ├───┼──→ construct_services! [POM]                                       ││
│       │   │         │                                                          ││
│       │   │         └──⇒ construct_service! [POM] (per service model)         ││
│       │   │                    │                                               ││
│       │   │                    ├──⇒ add_variables! [POM]                       ││
│       │   │                    └──⇒ add_to_expression! [POM]                   ││
│       │   │                                                                    ││
│       │   └────────────────────────────────────────────────────────────────────┘│
│       │                                                                         │
│       │   ┌─────────────── LOOP 3: Branches (ArgumentConstructStage) ─────────┐│
│       │   │                                                                    ││
│       ├───┼──⇒ construct_device!(::ArgumentConstructStage) [POM]              ││
│       │   │         │ (for Line, Transformer2W, MonitoredLine, HVDC, etc.)    ││
│       │   │         │                                                          ││
│       │   │         └── [same pattern as device loop 1]                        ││
│       │   │                                                                    ││
│       │   └────────────────────────────────────────────────────────────────────┘│
│       │                                                                         │
│       │   ┌─────────────── LOOP 4: Devices (ModelConstructStage) ─────────────┐│
│       │   │                                                                    ││
│       ├───┼──⇒ construct_device!(::ModelConstructStage) [POM]                 ││
│       │   │         │                                                          ││
│       │   │         ├──⇒ add_constraints! [POM]                                ││
│       │   │         ├──⇒ objective_function! [POM]                             ││
│       │   │         ├──→ add_feedforward_constraints! [IOM]                    ││
│       │   │         └──→ add_constraint_dual! [IOM]                            ││
│       │   │                                                                    ││
│       │   └────────────────────────────────────────────────────────────────────┘│
│       │                                                                         │
│       ├──→ construct_network! [POM]                                            │
│       ├──→ construct_hvdc_network! [POM]                                       │
│       │                                                                         │
│       │   ┌─────────────── LOOP 5: Branches (ModelConstructStage) ────────────┐│
│       │   │                                                                    ││
│       ├───┼──⇒ construct_device!(::ModelConstructStage) [POM]                 ││
│       │   │                                                                    ││
│       │   └────────────────────────────────────────────────────────────────────┘│
│       │                                                                         │
│       │   ┌─────────────── LOOP 6: Services (ModelConstructStage) ────────────┐│
│       │   │                                                                    ││
│       ├───┼──→ construct_services! [POM]                                       ││
│       │   │         │                                                          ││
│       │   │         └──⇒ construct_service! [POM]                              ││
│       │   │                    │                                               ││
│       │   │                    └──⇒ add_constraints! [POM]                     ││
│       │   │                                                                    ││
│       │   └────────────────────────────────────────────────────────────────────┘│
│       │                                                                         │
│       ├──→ update_objective_function! [IOM]                                    │
│       │         │                                                               │
│       │         └──→ JuMP.@objective                                           │
│       │                                                                         │
│       ├──→ add_power_flow_data! [POM]                                          │
│       └──→ check_optimization_container [IOM]                                  │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Detailed Function Call Chains

### add_variables! Chain

```
add_variables! [IOM stub → POM implementation]
    │
    ├──→ add_variable! [IOM]
    │         │
    │         ├──→ add_variable_container! [IOM]
    │         ├──→ get_variable_upper_bound [POM]
    │         ├──→ get_variable_lower_bound [POM]
    │         └──→ JuMP.@variable
    │               │
    │               ├──→ JuMP.set_upper_bound
    │               ├──→ JuMP.set_lower_bound
    │               └──→ JuMP.set_start_value (if warm_start)
    │
    └──→ add_service_variable! [IOM]
              │
              └── [similar to add_variable!]
```

### add_constraints! Chain

```
add_constraints! [IOM stub → POM implementation]
    │
    ├──→ add_constraint_container! [IOM]
    │
    └──→ JuMP.@constraint (per device, per time step)
              │
              └──→ Container expressions from add_to_expression!
```

### add_to_expression! Chain

```
add_to_expression! [POM implementations only]
    │
    ├──→ get_expression [IOM]
    │
    ├──→ get_variable [IOM]
    │
    └──→ add_proportional_to_jump_expression! [IOM]
              │
              └──→ JuMP.add_to_expression!

Note: IOM provides generic JuMP helpers in add_expressions.jl:
  - add_constant_to_jump_expression!     (adds constant value)
  - add_proportional_to_jump_expression! (adds multiplier * variable)
  - add_linear_to_jump_expression!       (adds constant + multiplier * variable)
```

### objective_function! Chain

```
objective_function! [IOM stub → POM implementation]
    │
    ├──→ add_variable_cost! [POM]
    │         │
    │         ├──→ _add_proportional_cost! [IOM]
    │         ├──→ _add_quadratic_cost! [IOM]
    │         └──→ _add_pwl_cost! [IOM]
    |
    ├──→ add_to_objective_invariant_expression! [POM]
    └──→ add_to_objective_variant_expression! [IOM]
```

### add_initial_condition! Chain

```
add_initial_condition! [IOM generic, POM device-specific]
    │
    ├──→ add_initial_condition_container! [IOM]
    │
    └──→ get_initial_conditions_value [IOM generic, POM device-specific]
              │
              ├──→ get_initial_conditions_data [IOM]
              │
              ├──⇒ initial_condition_variable [POM]
              │         │
              │         └── Returns VariableType for given (ICType, Device, Formulation)
              │
              ├──→ has_initial_condition_value [IOM]
              │
              ├──⇒ initial_condition_default [POM]
              │         │
              │         └── Returns default Float64 for given (ICType, Device, Formulation)
              │
              └──→ get_initial_condition_value [IOM]

Note: Device-specific add_initial_condition! in POM handles must_run devices
by returning InitialCondition{D, Nothing} for must_run=true generators.

update_initial_conditions! [IOM stub → POM implementations]
    │
    └──→ Extends EmulationModelStore updates for specific IC types:
          - InitialTimeDurationOn
          - InitialTimeDurationOff
          - DevicePower
          - DeviceStatus
          - DeviceAboveMinPower
          - InitialEnergyLevel
```

---

## Extension Point Matrix

| Extension Point | Declared In | Implemented In | Purpose |
|----------------|-------------|----------------|---------|
| `construct_device!` | IOM | POM | Build device optimization model |
| `construct_service!` | IOM | POM | Build service optimization model |
| `add_variables!` | IOM | POM | Add device-specific variables |
| `add_constraints!` | IOM | POM | Add device-specific constraints |
| `add_to_expression!` | IOM (export only) | POM | Add to network balance expressions |
| `add_expressions!` | IOM | POM (extends) | Add expression containers |
| `add_*_to_jump_expression!` | IOM | - | JuMP expression helpers |
| `objective_function!` | IOM | POM | Add device costs to objective |
| `initial_condition_variable` | IOM | POM | Map IC type → variable type |
| `initial_condition_default` | IOM | POM | Provide default IC values |
| `add_initial_condition!` | IOM | POM | Add ICs (device-specific in POM) |
| `get_initial_conditions_value` | IOM | POM | Get IC values (device-specific) |
| `update_initial_conditions!` | IOM (stub) | POM | Update ICs in emulation store |
| `construct_network!` | IOM | POM | Build network constraints |

---

## File Locations

### IOM Key Files

| Function | File | Lines |
|----------|------|-------|
| `build!` | operation/decision_model.jl | 364-401 |
| `build_impl!` | core/optimization_container.jl | 769-907 |
| `construct_device!` (stub) | common_models/construct_device.jl | 5-29 |
| `add_variable!` | common_models/add_variable.jl | 28-150 |
| `add_constraints!` (stub) | common_models/add_constraints.jl | 4-15 |
| `add_expressions!` (generic) | common_models/add_expressions.jl | - |
| `add_*_to_jump_expression!` | common_models/add_expressions.jl | - |
| `add_initial_condition!` (generic) | initial_conditions/add_initial_condition.jl | - |
| `get_initial_conditions_value` (generic) | initial_conditions/add_initial_condition.jl | - |
| `update_initial_conditions!` (stub) | operation/initial_conditions_update_in_memory_store.jl | - |
| `initial_condition_variable` (stub) | initial_conditions/add_initial_condition.jl | - |
| `initial_condition_default` (stub) | initial_conditions/add_initial_condition.jl | - |

### POM Key Files

| Function | File | Device Types |
|----------|------|--------------|
| `construct_device!` | static_injector_models/thermalgeneration_constructor.jl | ThermalGen |
| `construct_device!` | static_injector_models/renewable_generation_constructor.jl | RenewableGen |
| `construct_device!` | static_injector_models/load_constructor.jl | Load |
| `construct_device!` | ac_transmission_models/branch_constructor.jl | Line, Transformer |
| `construct_device!` | twoterminal_hvdc_models/branch_constructor.jl | HVDCLine |
| `construct_service!` | services_models/services_constructor.jl | All services |
| `add_to_expression!` | common_models/add_to_expression.jl | All devices |
| `initial_condition_variable` | static_injector_models/thermal_generation.jl | ThermalGen |
| `initial_condition_default` | static_injector_models/thermal_generation.jl | ThermalGen |
| `add_initial_condition!` | initial_conditions/device_initial_conditions.jl | ThermalGen (must_run) |
| `get_initial_conditions_value` | initial_conditions/device_initial_conditions.jl | ThermalGen |
| `update_initial_conditions!` | initial_conditions/update_initial_conditions.jl | All IC types |

---

## Detailed Function Counts (IOM + POM only, excluding PSI)

### Entry Points

| Function | Definitions | Call Sites | Notes |
|----------|-------------|------------|-------|
| `build!` | IOM: 2 (DecisionModel, EmulationModel) | IOM: 3, Tests: ~50 | Main entry point |
| `build_impl!` | IOM: 3 (container, decision, emulation) | IOM: 3 | Internal implementation |
| `solve!` | IOM: 2 | Tests: many | Calls build! then JuMP.optimize! |

### Core Extension Points (IOM stubs → POM implementations)

| Function | IOM Definitions | POM Definitions | IOM Calls | POM Calls |
|----------|-----------------|-----------------|-----------|-----------|
| `construct_device!` | 2 (stubs) | 185 | 4 (in build_impl!) | ~60 (constructors call each other) |
| `construct_service!` | 2 (stubs) | 50 | 2 (in build_impl!) | ~27 |
| `add_variables!` | 2 (generic) | 36 | 0 | ~89 |
| `add_constraints!` | 1 (stub) | 216 | 0 | ~156 |
| `add_to_expression!` | 0 (export only) | ~245 | 0 | ~218 |
| `add_expressions!` | 3 (generic) | extends | ~3 | many |
| `objective_function!` | 1 (default) | 45 | 2 (in build_impl!) | ~28 |
| `add_parameters!` | 1 (generic) | 8 | 0 | ~47 |

### Initial Conditions Chain

| Function | IOM Definitions | POM Definitions | IOM Calls | POM Calls |
|----------|-----------------|-----------------|-----------|-----------|
| `initial_conditions!` | 0 | 10 | 0 | ~14 (in construct_device!) |
| `add_initial_condition!` | 1 (generic) | 1 (thermal w/ must_run) | 0 | ~19 |
| `get_initial_conditions_value` | 2 (generic) | 4 (thermal-specific) | 2 | ~4 |
| `initial_condition_variable` | 1 (stub) | 7 | ~6 | 0 |
| `initial_condition_default` | 1 (stub) | 6 | ~6 | 0 |
| `update_initial_conditions!` | 1 (stub) | 6 (per IC type) | ~2 | 0 |

### Feedforward Chain

| Function | IOM Definitions | POM Definitions | IOM Calls | POM Calls |
|----------|-----------------|-----------------|-----------|-----------|
| `add_feedforward_arguments!` | 3 | 2 | 0 | ~72 |
| `add_feedforward_constraints!` | 0 | 0 | 0 | ~86 |

### Lower-Level Infrastructure (IOM only)

| Function | Definitions | Call Sites | Called From |
|----------|-------------|------------|-------------|
| `add_variable!` | 2 | ~10 | add_variables! |
| `add_variable_container!` | ~5 | ~15 | add_variable! |
| `add_constraint_container!` | ~3 | many | add_constraints! |
| `get_expression` | ~10 | many | add_to_expression! |
| `get_variable` | ~5 | many | add_to_expression!, add_constraints! |

---

## Call Flow Summary

```
                                   DEFINITIONS                    CALL SITES
                               ─────────────────────         ─────────────────────
                                 IOM        POM                IOM        POM

build!                            2          0                  3         (tests)
  └─→ build_impl!                 3          0                  3          0
        │
        ├─→ construct_device!
        │     (ArgumentConstructStage)
        │                         2        185                 4         ~60
        │     │
        │     ├─→ add_variables!  2         36                 0         ~89
        │     │     └─→ add_variable!
        │     │                   2          0                ~10          0
        │     │
        │     ├─→ add_parameters! 1          8                 0         ~47
        │     │
        │     ├─→ add_to_expression!
        │     │                  68        177               ~84        ~134
        │     │
        │     └─→ initial_conditions!
        │                         0         10                 0         ~14
        │           └─→ add_initial_condition!
        │                         2          0                 0         ~19
        │                 ├─→ initial_condition_variable
        │                 │               1          7         9          0
        │                 └─→ initial_condition_default
        │                                 1          6         9          0
        │
        ├─→ construct_service!
        │                         0         50                 2         ~27
        │
        └─→ construct_device!
              (ModelConstructStage)
              │
              ├─→ add_constraints!
              │                   1        216                 0        ~156
              │
              └─→ objective_function!
                                  1         45                 2         ~28
```

---

## Key Observations

1. **Extension point pattern is clear**: IOM defines 1-2 stub methods, POM provides 10-200+ implementations
2. **add_to_expression! now fully in POM**: All ~245 implementations are in POM
   - IOM provides only: `add_expressions!` (generic container setup) and JuMP helpers
   - JuMP helpers: `add_constant_to_jump_expression!`, `add_proportional_to_jump_expression!`, `add_linear_to_jump_expression!`
3. **Initial conditions split cleanly**:
   - IOM provides generic infrastructure and stub functions
   - POM provides device-specific implementations (thermal must_run handling, IC updates)
   - Key functions: `add_initial_condition!`, `get_initial_conditions_value`, `update_initial_conditions!`
4. **Call sites concentrated in POM**: Most actual calls happen in POM's construct_device! implementations
5. **No direct POM→IOM calls for stubs**: POM extends, doesn't call the IOM stubs
