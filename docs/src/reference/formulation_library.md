# Formulation Library

## [Introduction](@id formulation_intro)

A `PowerOperationsModels` problem is assembled from three independent choices:

  - a **network formulation** (`NetworkModel{N}`) — how the transmission system is represented,
  - a **device formulation** (`DeviceModel{D, F}`) — how each component type is modelled,
  - a **service formulation** (`ServiceModel{S, F}`) — how each service is modelled.

Every formulation implements `construct_device!` (or `construct_service!` / `construct_network!`)
for **two dispatch stages**, and the split matters when reading the tables below:

| Stage                    | What it may add                                                         |
|:------------------------ |:----------------------------------------------------------------------- |
| `ArgumentConstructStage` | variables, parameters, expressions, feedforward arguments               |
| `ModelConstructStage`    | constraints, feedforward constraints, objective terms, constraint duals |

Expressions must be wired before the constraints that consume them, which is why the balance
expressions (`ActivePowerBalance`, `ReactivePowerBalance`) are populated during the argument
stage and only *closed* with an `== 0` constraint during the model stage.

Not every (device formulation, network formulation) pair is valid. Pairs that are rejected are
caught by template validation, which throws `IS.ConflictingInputsError` rather than failing deep
in the build. The tables mark unsupported pairs explicitly.

### How to read these tables

  - **Variables** are the JuMP variables the formulation creates.
  - **Constraints** are the constraint containers it creates.
  - **Expressions** are written as `Target ← Source`, meaning the source variable is added into
    the target balance expression.
  - **meta** lists the meta strings used to slice a single key type into several containers (see
    [When to use `meta` versus a new key type](@ref meta_vs_key_type) below).
  - **no-op** means a method exists and returns without emitting anything — the pair is legal but
    contributes nothing. This is distinct from *unsupported*, where no method exists.

## [Network Formulations](@id network_formulations)

### Network model type hierarchy

The abstract bounds that drive dispatch:

```
IOM.AbstractNetworkModel
├── AbstractActivePowerModel
│   ├── AbstractDCPNetworkModel
│   │   ├── DCPNetworkModel
│   │   ├── AbstractPTDFNetworkModel
│   │   │   ├── PTDFNetworkModel
│   │   │   └── AreaPTDFNetworkModel
│   │   ├── AbstractNFANetworkModel   → NFANetworkModel
│   │   └── AbstractDCPLLNetworkModel → DCPLLNetworkModel
│   ├── CopperPlateNetworkModel
│   └── AreaBalanceNetworkModel
├── AbstractACPModel          → ACPNetworkModel
├── AbstractACRNetworkModel   → ACRNetworkModel
├── AbstractLPACCNetworkModel → LPACCNetworkModel
└── AbstractIVRNetworkModel   → IVRNetworkModel
```

Note that `AbstractPTDFNetworkModel <: AbstractDCPNetworkModel`, so any method bound to
`<:AbstractDCPNetworkModel` also matches the PTDF models. `CopperPlateNetworkModel` and
`AreaBalanceNetworkModel` are *not* DCP subtypes.

### What each network model adds

The balance expression containers themselves are allocated up front by
`initialize_system_expressions!`, before any `construct_*!` runs. A network model does not
create them; it wires the system slacks into them (argument stage) and closes them with a
balance constraint (model stage).

| Network model             | Argument stage: variables                                             | Model stage: constraints                                                                                                     |
|:------------------------- |:--------------------------------------------------------------------- |:---------------------------------------------------------------------------------------------------------------------------- |
| `DCPNetworkModel`         | `VoltageAngle`, system slacks (active only)                           | `ReferenceBusConstraint`, `NodalBalanceActiveConstraint`                                                                     |
| `DCPLLNetworkModel`       | `VoltageAngle`, system slacks (active only)                           | `ReferenceBusConstraint`, `NodalBalanceActiveConstraint`                                                                     |
| `NFANetworkModel`         | system slacks (active only); no voltage variables                     | `NodalBalanceActiveConstraint` **only** — no `ReferenceBusConstraint`                                                        |
| `PTDFNetworkModel`        | system slacks (active only); no voltage variables                     | `CopperPlateBalanceConstraint`                                                                                               |
| `AreaPTDFNetworkModel`    | system slacks (active only); no voltage variables                     | `CopperPlateBalanceConstraint` (keyed on `PSY.Area`)                                                                         |
| `CopperPlateNetworkModel` | system slacks (active only); no voltage variables                     | `CopperPlateBalanceConstraint`                                                                                               |
| `AreaBalanceNetworkModel` | system slacks (active only); no voltage variables                     | `CopperPlateBalanceConstraint` (keyed on `PSY.Area`)                                                                         |
| `ACPNetworkModel`         | `VoltageAngle`, `VoltageMagnitude`, system slacks (active + reactive) | `ReferenceBusConstraint`, `NodalBalanceActiveConstraint`, `NodalBalanceReactiveConstraint`                                   |
| `ACRNetworkModel`         | `VoltageReal`, `VoltageImaginary`, system slacks (active + reactive)  | `ReferenceBusConstraint`, `VoltageMagnitudeConstraint`, `NodalBalanceActiveConstraint`, `NodalBalanceReactiveConstraint`     |
| `IVRNetworkModel`         | `VoltageReal`, `VoltageImaginary`, system slacks (active + reactive)  | `ReferenceBusConstraint`, `VoltageMagnitudeConstraint`, `NodalBalanceActiveConstraint`, `NodalBalanceReactiveConstraint`     |
| `LPACCNetworkModel`       | `VoltageAngle`, `VoltageDeviation`, system slacks (active + reactive) | `ReferenceBusConstraint`, `NodalBalanceActiveConstraint`, `NodalBalanceReactiveConstraint` — no `VoltageMagnitudeConstraint` |

All network variables, **including the slacks**, are created in the argument stage. System slacks
are only added when `use_slacks = true` on the `NetworkModel`, and they are penalized in the
objective at `BALANCE_SLACK_COST` during the model stage.

### System slack containers

The slack container's key and axis depend on the network model, and the AC models are the only
ones that use a `meta`:

| Network models                                                               | Slack container key | Axis            | meta         |
|:---------------------------------------------------------------------------- |:------------------- |:--------------- |:------------ |
| `CopperPlateNetworkModel`, `PTDFNetworkModel`                                | `PSY.System`        | reference buses | —            |
| `AreaBalanceNetworkModel`, `AreaPTDFNetworkModel`                            | `PSY.Area`          | area names      | —            |
| `DCPNetworkModel`, `NFANetworkModel`, `DCPLLNetworkModel`                    | `PSY.ACBus`         | bus numbers     | —            |
| `ACPNetworkModel`, `ACRNetworkModel`, `IVRNetworkModel`, `LPACCNetworkModel` | `PSY.ACBus`         | bus numbers     | `"P"`, `"Q"` |

The AC models split `SystemBalanceSlackUp` / `SystemBalanceSlackDown` into two containers — one
for active power (`"P"`) and one for reactive (`"Q"`) — because a single bus axis has to carry
both. These metas are passed positionally, not as a `meta =` keyword.

### Reference bus constraint

`ReferenceBusConstraint` pins the slack bus of each subnetwork, and what it pins depends on the
voltage coordinates:

| Network models                                              | meta           | Pins                                           |
|:----------------------------------------------------------- |:-------------- |:---------------------------------------------- |
| `DCPNetworkModel`, `DCPLLNetworkModel`, `LPACCNetworkModel` | —              | ``\theta_{ref} = 0``                           |
| `ACPNetworkModel`                                           | `"va"`, `"vm"` | ``\theta_{ref} = 0`` and ``v_{ref} = v_{set}`` |
| `ACRNetworkModel`, `IVRNetworkModel`                        | `"vi"`, `"vr"` | ``v_{i,ref} = 0`` and ``v_{r,ref} = v_{set}``  |

The AC models additionally error if the reference-bus setpoint falls outside the bus voltage
limits.

## [Branch Formulations](@id PowerSystems.Branch-Formulations)

### AC branch formulations

The branch constructors delegate to shared helpers, so a constructor body that looks short still
emits several containers. The helpers expand as follows:

| Helper                                  | Emits                                                                                                                                          |
|:--------------------------------------- |:---------------------------------------------------------------------------------------------------------------------------------------------- |
| `_add_static_branch_flow_variables!`    | `FlowActivePowerFromToVariable`, `FlowActivePowerToFromVariable`, `FlowReactivePowerFromToVariable`, `FlowReactivePowerToFromVariable`         |
| `_wire_static_branch_flow_to_balance!`  | `ActivePowerBalance ← FlowActivePower{FromTo,ToFrom}Variable` and `ReactivePowerBalance ← FlowReactivePower{FromTo,ToFrom}Variable`            |
| `_add_flow_slacks!`                     | `FlowActivePowerSlackUpperBound` **and** `FlowActivePowerSlackLowerBound`                                                                      |
| `_add_static_branch_balance_arguments!` | `FlowActivePowerSlackUpperBound` only (when `use_slacks`), then the four balance wirings, then `BranchRatingTimeSeriesParameter` if configured |
| `_add_hvdc_active_flow_arguments!`      | `FlowActivePowerVariable` and `ActivePowerBalance ← FlowActivePowerVariable`                                                                   |

Note the asymmetry: `_add_flow_slacks!` adds an upper **and** lower slack, while
`_add_static_branch_balance_arguments!` — the path taken by `StaticBranch` on the AC network
models — adds only the upper slack.

#### `StaticBranch` support matrix

| Network model             | Argument stage                                                                                                                                                                                       | Model stage                                                                                                                                           |
|:------------------------- |:---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |:----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DCPNetworkModel`         | `FlowActivePowerVariable`; slacks (upper + lower); `ActivePowerBalance ← FlowActivePowerVariable`; `BranchRatingTimeSeriesParameter` if configured                                                   | `FlowRateConstraint` (`"lb"`/`"ub"`), `NetworkFlowConstraint`, `AngleDifferenceConstraint`                                                            |
| `NFANetworkModel`         | same as DCP                                                                                                                                                                                          | `FlowRateConstraint` (`"lb"`/`"ub"`) only — no `NetworkFlowConstraint`, no `AngleDifferenceConstraint` (transportation model)                         |
| `DCPLLNetworkModel`       | `FlowActivePowerFromToVariable`, `FlowActivePowerToFromVariable`; slacks **or** hard flow bounds (mutually exclusive); `ActivePowerBalance ←` each directional flow. No rating time-series parameter | `FlowRateConstraint` (`"ft_ub"`, `"ft_lb"`, `"tf_ub"`, `"tf_lb"`), `NetworkFlowConstraint`, `NetworkLossConstraint`, `AngleDifferenceConstraint`      |
| `PTDFNetworkModel`        | **no flow variables**; slacks (upper + lower); rating parameters if configured                                                                                                                       | `PTDFBranchFlow` expression, then `FlowRateConstraint` (`"lb"`/`"ub"`) on that expression. No `NetworkFlowConstraint`                                 |
| `CopperPlateNetworkModel` | no-op                                                                                                                                                                                                | no-op                                                                                                                                                 |
| `AreaBalanceNetworkModel` | no-op                                                                                                                                                                                                | no-op                                                                                                                                                 |
| `ACPNetworkModel`         | four directional flow variables; upper slack only; four balance wirings; `BranchRatingTimeSeriesParameter` if configured                                                                             | `FlowRateConstraintFromTo`, `FlowRateConstraintToFrom`, `NetworkFlowConstraint` (`"p_ft"`, `"q_ft"`, `"p_tf"`, `"q_tf"`), `AngleDifferenceConstraint` |
| `ACRNetworkModel`         | same as ACP                                                                                                                                                                                          | same as ACP                                                                                                                                           |
| `LPACCNetworkModel`       | same as ACP, **plus** `CosineApproximation`                                                                                                                                                          | same as ACP, **plus** `CosineRelaxationConstraint`                                                                                                    |
| `IVRNetworkModel`         | same as ACP, **plus** the six branch current variables (`BranchCurrent{FromTo,ToFrom}{Real,Imaginary}`, `BranchSeriesCurrent{Real,Imaginary}`)                                                       | same as ACP, **plus** `CurrentLimitConstraint` (`"from"`/`"to"`). `NetworkFlowConstraint` carries ten metas here                                      |

`DCPLLNetworkModel` enforces the rating either with slacks *or* with hard JuMP bounds on the
directional flow variables, never both: when `use_slacks = false` the `FlowRateConstraint` builder
returns without emitting anything and the rating lives entirely in the variable bounds.

#### `StaticBranchBounds`

| Network model                                           | Behaviour                                                                                                                                                                                                                                                                                                                                                             |
|:------------------------------------------------------- |:--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DCPNetworkModel`                                       | Supported, and permits `use_slacks`. Rating is enforced with `"lb"`/`"ub"` **constraints**, not variable bounds                                                                                                                                                                                                                                                       |
| `PTDFNetworkModel`, `AreaPTDFNetworkModel`              | Supported (both share the `AbstractPTDFNetworkModel` methods), and permit `use_slacks`. Rating really is enforced with JuMP variable bounds; adds `NetworkFlowConstraint` tying `PTDFBranchFlow` to `FlowActivePowerVariable`                                                                                                                                         |
| `ACPNetworkModel`, `ACRNetworkModel`, `IVRNetworkModel` | Supported, but **reject `use_slacks`** with an `ArgumentError`. ACR is served by the same method as ACP, widened to a `Union{ACPNetworkModel, ACRNetworkModel}` network bound                                                                                                                                                                                         |
| `LPACCNetworkModel`                                     | Supported, but **rejects `use_slacks`** with an `ArgumentError`. Adds the four directional flow variables plus `CosineApproximation` in the argument stage, and `CosineRelaxationConstraint` in the model stage, on top of the shared rate and Ohm's-law constraints                                                                                                  |
| `NFANetworkModel`                                       | Supported, but **rejects `use_slacks`** with an `ArgumentError`: the rating is a hard bound on `FlowActivePowerVariable` and the model stage never reads slacks, so a requested slack would be unused and unpriced                                                                                                                                                    |
| `DCPLLNetworkModel`                                     | Supported, on `FlowActivePowerFromToVariable`/`FlowActivePowerToFromVariable` (not `FlowActivePowerVariable`), and **permits `use_slacks`**: with slacks the argument stage adds slack pairs; without them it calls `_set_dcpll_flow_bounds!` to set hard variable bounds directly, because DCPLL's `FlowRateConstraint` builder is a no-op when `use_slacks = false` |
| `CopperPlateNetworkModel`, `AreaBalanceNetworkModel`    | no-op                                                                                                                                                                                                                                                                                                                                                                 |

`StaticBranchBounds` rejects `use_slacks` on `ACPNetworkModel`, `ACRNetworkModel`,
`IVRNetworkModel`, `LPACCNetworkModel` and `NFANetworkModel`; only `DCPNetworkModel`,
`DCPLLNetworkModel` and the PTDF models accept it.

#### `StaticBranchUnbounded`

A no-op on every network model except PTDF, where the model stage still builds the
`PTDFBranchFlow` expression (so flows are reportable, but unconstrained).

#### `SecurityConstrainedStaticBranch`

N-1 security constraints are built with Modified Outage Distribution Factors (PNM `VirtualMODF`).

| Network model                                                                                     | Behaviour                                                                                                                                                                                                                                                                                                                               |
|:------------------------------------------------------------------------------------------------- |:--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PTDFNetworkModel`, `AreaPTDFNetworkModel`                                                        | Full support: `PTDFBranchFlow` and `PostContingencyBranchFlow` expressions, `FlowRateConstraint` and `PostContingencyFlowRateConstraint` (`"lb"`/`"ub"`), optional post-contingency slacks. The post-contingency flow is the MODF-redistributed expression `MODF ⋅ nodal balance` (on these networks the balance holds only injections) |
| `DCPNetworkModel`                                                                                 | Full support: replicates the DCP `StaticBranch` construction (`FlowActivePowerVariable`, DC Ohm's law, angle-difference and rate limits) and builds the genuine MODF post-contingency flow `MODF ⋅ nodal injections`, with the injections recovered exactly (by KCL) from the branch-flow terms of the zero-constrained nodal balance   |
| `ACPNetworkModel`, `ACRNetworkModel`, `IVRNetworkModel`, `LPACCNetworkModel`, `DCPLLNetworkModel` | **Blocked** at template validation with an `IS.ConflictingInputsError`: the MODF post-contingency formulation is a lossless linear DC construct and is not available on AC or lossy network models                                                                                                                                      |
| `NFANetworkModel`, `CopperPlateNetworkModel`, `AreaBalanceNetworkModel`                           | Deliberate no-op — a `@warn` states the security constraints are inert                                                                                                                                                                                                                                                                  |

#### Tap and phase-angle control

| Formulation         | Supported on                                                                                                                                          |
|:------------------- |:----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `VoltageControlTap` | `ACPNetworkModel`, `ACRNetworkModel`, `IVRNetworkModel`, `LPACCNetworkModel`. Dropped from active-power templates by the `models_reactive_power` gate |
| `TapControl`        | `DCPNetworkModel` only                                                                                                                                |
| `PhaseAngleControl` | `DCPNetworkModel` and the PTDF models only                                                                                                            |

Under `ACRNetworkModel` and `IVRNetworkModel`, `VoltageControlTap` additionally creates a
`RegulatedVoltageMagnitude` variable and a `RegulatedVoltageMagnitudeConstraint` (both with
`meta = "1"`), because those formulations have no scalar voltage-magnitude primitive to fix. Under
`ACPNetworkModel` the network's own `VoltageMagnitude` variable is fixed directly instead.

### HVDC formulations

#### Two-terminal HVDC

| Formulation                    | Supported networks                                                                                                       | Key variables                                                                                                     | Key constraints                                                                                                        |
|:------------------------------ |:------------------------------------------------------------------------------------------------------------------------ |:----------------------------------------------------------------------------------------------------------------- |:---------------------------------------------------------------------------------------------------------------------- |
| `HVDCTwoTerminalUnbounded`     | all except `AreaBalanceNetworkModel`                                                                                     | `FlowActivePowerVariable` (+ reactive from/to on AC networks, all unbounded)                                      | none — active and reactive flows are unconstrained                                                                     |
| `HVDCTwoTerminalLossless`      | all except `AreaBalanceNetworkModel`                                                                                     | `FlowActivePowerVariable` (+ reactive from/to on ACP/ACR/IVR/LPACC, bounded by `reactive_power_limits_from`/`to`) | `FlowRateConstraint` (`"ub"`/`"lb"`)                                                                                   |
| `HVDCTwoTerminalDispatch`      | PTDF, and all active-power + AC-native models                                                                            | `FlowActivePower{FromTo,ToFrom}Variable`, `HVDCLosses`, `HVDCFlowDirectionVariable`                               | `FlowRateConstraint{FromTo,ToFrom}`, `HVDCPowerBalance` (nine metas)                                                   |
| `HVDCTwoTerminalPiecewiseLoss` | all                                                                                                                      | `HVDCActivePowerReceived{From,To}Variable`, `HVDCPiecewiseLossVariable`, `HVDCPiecewiseBinaryLossVariable`        | `FlowRateConstraint{FromTo,ToFrom}`, `HVDCFlowCalculationConstraint` (`"ft"`, `"tf"`, `"bin"`)                         |
| `HVDCTwoTerminalLCC`           | `ACPNetworkModel`, `ACRNetworkModel`, `IVRNetworkModel`, `LPACCNetworkModel` (rejected at template validation elsewhere) | 17 variables (rectifier/inverter angles, DC voltages, AC currents, taps)                                          | 11 constraints (DC line voltage, overlap angle, power-factor angle, AC current, power calculation)                     |
| `HVDCTwoTerminalVSC`           | all except `AreaBalanceNetworkModel`                                                                                     | `FlowActivePower{FromTo,ToFrom}Variable`, `DCLineCurrentFlowVariable`, `HVDC{From,To}DCVoltage`                   | `HVDCCableOhmsLawConstraint`, `HVDCVSCConverterPowerConstraint` (`"ft"`/`"tf"`), `HVDCVSCApparentPowerLimitConstraint` |
| `VoltageControlVSC`            | `ACPNetworkModel`, `ACRNetworkModel`, `IVRNetworkModel`, `LPACCNetworkModel` (auto-dropped from active-power templates)  | as `HVDCTwoTerminalVSC`, plus `RegulatedVoltageMagnitude` (`"from"`/`"to"`) on ACR/IVR                            | as above, plus `HVDCDCControlConstraint` (`"from"`/`"to"`)                                                             |

!!! warning "HVDCTwoTerminalDispatch loses its losses on CopperPlate"
    
    On `CopperPlateNetworkModel` the constructor warns, then skips `HVDCPowerBalance` entirely:
    `HVDCLosses` and `HVDCFlowDirectionVariable` are created but left unconstrained and unwired,
    so the line's losses vanish from the single system balance. Use
    `HVDCTwoTerminalPiecewiseLoss` on CopperPlate when the losses matter. On every other
    supported network the losses are accounted for: the nodal models
    (NFA/DCP/DCPLL/ACP/ACR/IVR/LPACC) carry them implicitly through the `HVDCPowerBalance`
    coupling `ft + tf == losses` with both directional flows entering their terminal balances,
    while the PTDF/AreaPTDF paths add `HVDCLosses` to the aggregated system/area row explicitly.
    On `AreaBalanceNetworkModel` the Dispatch formulation is not built at all (warn no-op).

!!! warning "HVDCTwoTerminalLossless pins reactive flow to zero on default VSC/LCC data"
    
    `PSY.TwoTerminalVSCLine` and `PSY.TwoTerminalLCCLine` default both
    `reactive_power_limits_from` and `reactive_power_limits_to` to `(min = 0.0, max = 0.0)`.
    Because `HVDCTwoTerminalLossless` bounds the reactive flow variables by those limits, such a
    device can neither inject nor absorb reactive power at the affected terminal, which can make
    an AC network model infeasible. This is valid data, so the build warns (naming the device)
    rather than erroring.

The apparent-power limit on the VSC formulations depends on the `"bilinear_approximation"` device
attribute. With the default `"none"` it is an exact quadratic disk (`"from"`/`"to"`); with a
linearizing scheme it becomes a box of eight half-planes, plus eight more octagon cuts when
`"use_octagon"` is true (the default).

#### Multi-terminal HVDC (`PSY.InterconnectingConverter`, `PSY.TModelHVDCLine`)

| Formulation               | Supported networks                                                           | Key variables                                                                                                                                                             | Key constraints                                                                                                                                                             |
|:------------------------- |:---------------------------------------------------------------------------- |:------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |:--------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LosslessConverter`       | all                                                                          | `ActivePowerVariable` (+ `ReactivePowerVariable` on AC networks)                                                                                                          | `ConverterPowerCapabilityConstraint` on AC networks                                                                                                                         |
| `LinearLossConverter`     | all                                                                          | `ActivePowerVariable`, `CurrentAbsoluteValueVariable` (+ `ReactivePowerVariable` on AC networks)                                                                          | `CurrentAbsoluteValueConstraint` (`"ge_pos"`/`"ge_neg"`); `ConverterPowerCapabilityConstraint` on AC networks                                                               |
| `QuadraticLossConverter`  | all                                                                          | `ActivePowerVariable`, `ConverterCurrent`, `CurrentAbsoluteValueVariable` (`ConverterACCurrentVariable` instead on ACP/ACR/IVR; + `ReactivePowerVariable` on AC networks) | `ConverterLossConstraint`, `CurrentAbsoluteValueConstraint` (`"ge_pos"`/`"ge_neg"`); `ConverterACCurrentConstraint` and `ConverterPowerCapabilityConstraint` on AC networks |
| `VoltageControlConverter` | `ACPNetworkModel`, `ACRNetworkModel`, `IVRNetworkModel`, `LPACCNetworkModel` | `ActivePowerVariable`, `ReactivePowerVariable`, `ConverterCurrent`, `ConverterACCurrentVariable` (ACP/ACR/IVR) or `CurrentAbsoluteValueVariable` (LPACC)                  | `ConverterLossConstraint`, `ConverterPowerCapabilityConstraint`, `HVDCDCControlConstraint`; `ConverterACCurrentConstraint` on ACP/ACR/IVR                                   |
| `LosslessLine`            | all                                                                          | `FlowActivePowerVariable`                                                                                                                                                 | none                                                                                                                                                                        |
| `DCLossyLine`             | all                                                                          | `DCLineCurrent`                                                                                                                                                           | `DCLineCurrentConstraint`                                                                                                                                                   |

`LinearLossConverter` models the loss `b·|I| + c` from the converter `loss_function`
proportional/constant terms, approximating `|I|` by `|P|` at nominal DC voltage; a
non-zero quadratic term is rejected at build.

The HVDC network model is a separate template slot from the AC network model:

| HVDC network model                | Adds                                                             | Required by                                                        |
|:--------------------------------- |:---------------------------------------------------------------- |:------------------------------------------------------------------ |
| `TransportHVDCNetworkModel`       | `NodalBalanceActiveConstraint` on each DC bus                    | `LosslessConverter`, `LinearLossConverter`, `LosslessLine`         |
| `VoltageDispatchHVDCNetworkModel` | `DCVoltage` variable per DC bus; `NodalBalanceCurrentConstraint` | `QuadraticLossConverter`, `VoltageControlConverter`, `DCLossyLine` |

## [ThermalGen Formulations](@id ThermalGen-Formulations)

Nine concrete thermal formulations, under three abstract branches:

| Abstract                             | Concrete                                                                                               |
|:------------------------------------ |:------------------------------------------------------------------------------------------------------ |
| `AbstractStandardUnitCommitment`     | `ThermalBasicUnitCommitment`, `ThermalStandardUnitCommitment`                                          |
| `AbstractCompactUnitCommitment`      | `ThermalBasicCompactUnitCommitment`, `ThermalCompactUnitCommitment`, `ThermalMultiStartUnitCommitment` |
| `AbstractThermalDispatchFormulation` | `ThermalBasicDispatch`, `ThermalStandardDispatch`, `ThermalDispatchNoMin`, `ThermalCompactDispatch`    |

The *standard* family dispatches `ActivePowerVariable` directly. The *compact* family instead
dispatches `PowerAboveMinimumVariable` and reconstructs total power as ``p = P_{min} u + \hat{p}``,
wiring **both** the above-minimum variable and the commitment status into `ActivePowerBalance`.

| Formulation                                                      | Variables                                                                                                                   | Constraints                                                                                                                                                      |
|:---------------------------------------------------------------- |:--------------------------------------------------------------------------------------------------------------------------- |:---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ThermalBasicDispatch`                                           | `ActivePowerVariable`, `ReactivePowerVariable`                                                                              | `ActivePowerVariableLimitsConstraint`, `ReactivePowerVariableLimitsConstraint`                                                                                   |
| `ThermalDispatchNoMin`                                           | as above, with lower bound relaxed to 0                                                                                     | as above                                                                                                                                                         |
| `ThermalStandardDispatch`                                        | as above                                                                                                                    | as above **+ `RampConstraint`**                                                                                                                                  |
| `ThermalCompactDispatch`                                         | `PowerAboveMinimumVariable`, `ReactivePowerVariable`, `PowerOutput` (aux)                                                   | range limits **+ `RampConstraint`**. Adds `OnStatusParameter` and wires it into `ActivePowerBalance`                                                             |
| `ThermalBasicUnitCommitment`                                     | `ActivePowerVariable`, `ReactivePowerVariable`, `OnVariable`, `StartVariable`, `StopVariable`, `TimeDurationOn`/`Off` (aux) | range limits **+ `CommitmentConstraint`**. No ramp, no duration                                                                                                  |
| `ThermalStandardUnitCommitment`                                  | as above                                                                                                                    | as above **+ `RampConstraint` + `DurationConstraint`**                                                                                                           |
| `ThermalBasicCompactUnitCommitment`                              | compact variable set + commitment variables                                                                                 | range limits + `CommitmentConstraint`. No ramp, no duration                                                                                                      |
| `ThermalCompactUnitCommitment`                                   | as above                                                                                                                    | as above **+ `RampConstraint` + `DurationConstraint`**                                                                                                           |
| `ThermalMultiStartUnitCommitment` (`PSY.ThermalMultiStart` only) | compact set **+ `ColdStartVariable`, `WarmStartVariable`, `HotStartVariable`**                                              | as above **+ `StartupTimeLimitTemperatureConstraint` (`"hot"`/`"warm"`), `StartTypeConstraint`, `StartupInitialConditionConstraint`, `ActiveRangeICConstraint`** |

All nine implement both a `<:AbstractNetworkModel` and a `<:AbstractActivePowerModel` method, so all
eleven network models are supported. The active-power method simply omits `ReactivePowerVariable`,
the `ReactivePowerBalance` wiring, and `ReactivePowerVariableLimitsConstraint`.

Metas on thermal keys: `"lb"`/`"ub"` (range limits), `"up"`/`"dn"` (ramp and duration), `"aux"`
(the `CommitmentConstraint` start+stop ≤ 1 container), `"hot"`/`"warm"` (startup temperature), and
`"ubon"`/`"uboff"` on the MultiStart range limits.

`FixedOutput` on thermal devices builds on every network model: the device contributes its
`max_active_power` time series straight into the balance with no dispatch decision.

## [RenewableGen Formulations](@id PowerSystems.RenewableGen-Formulations)

| Formulation                    | Variables                                      | Constraints                                                                                                                                                                                                 |
|:------------------------------ |:---------------------------------------------- |:----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `RenewableFullDispatch`        | `ActivePowerVariable`, `ReactivePowerVariable` | `ActivePowerVariableTimeSeriesLimitsConstraint` (`"ub"`, against `ActivePowerTimeSeriesParameter`), `ActivePowerVariableLimitsConstraint` (`"lb"`), `ReactivePowerVariableLimitsConstraint` (`"lb"`/`"ub"`) |
| `RenewableConstantPowerFactor` | as above                                       | as above, except the reactive limits are replaced by an **`EqualityConstraint`** pinning ``q = p \tan(\arccos(pf))``                                                                                        |
| `FixedOutput`                  | none                                           | none — the time-series parameter is wired straight into the balance                                                                                                                                         |

Both dispatch formulations support all eleven network models. Renewable injection carries a
**negative** objective multiplier, and the renewable cost expressions include a
`CurtailmentCostExpression` (populated only for a `CostCurve{LinearCurve}`).

Note that `RenewableConstantPowerFactor` emits **no** `ReactivePowerVariableLimitsConstraint` at
all — the power-factor equality replaces it.

## [Hydro Formulations](@id HydroPowerSimulations-Formulations)

Hydro is the largest family. It splits by *which PSY device* the formulation attaches to.

### On `PSY.HydroGen`

| Formulation                     | Variables                                                                 | Constraints                                                                    |
|:------------------------------- |:------------------------------------------------------------------------- |:------------------------------------------------------------------------------ |
| `HydroDispatchRunOfRiver`       | `ActivePowerVariable`, `ReactivePowerVariable`, `HydroEnergyOutput` (aux) | range limits + `ActivePowerVariableTimeSeriesLimitsConstraint`                 |
| `HydroDispatchRunOfRiverBudget` | as above, **+ `HydroEnergyShortageVariable`** when `use_slacks`           | as above **+ `EnergyBudgetConstraint`** (optional `"interval"` meta container) |
| `HydroCommitmentRunOfRiver`     | as above **+ `OnVariable`**                                               | semicontinuous range limits + TS limits                                        |

### On `PSY.HydroReservoir`

| Formulation                 | Variables                                                                                                     | Constraints                                                                                                                                                                   |
|:--------------------------- |:------------------------------------------------------------------------------------------------------------- |:----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `HydroEnergyModelReservoir` | `EnergyVariable`, `WaterSpillageVariable`, `HydroEnergyShortage`/`SurplusVariable`                            | `EnergyBalanceConstraint`; optional `EnergyTargetConstraint`, `EnergyBudgetConstraint`                                                                                        |
| `HydroWaterModelReservoir`  | `HydroReservoirHeadVariable`, `HydroReservoirVolumeVariable`, `WaterSpillageVariable`, water shortage/surplus | `ReservoirInventoryConstraint`, `ReservoirLevelLimitConstraint` (`"ub"`/`"lb"`), `ReservoirHeadToVolumeConstraint`; optional `WaterTargetConstraint`, `WaterBudgetConstraint` |
| `HydroWaterFactorModel`     | `WaterSpillageVariable`, `HydroReservoirVolumeVariable`                                                       | `ReservoirInventoryConstraint`, `ReservoirLevelTargetConstraint`. Contributes nothing to the objective                                                                        |

### On `PSY.HydroTurbine` / `PSY.HydroPumpTurbine`

| Formulation                                       | Variables                                                                        | Constraints                                                                                                                              |
|:------------------------------------------------- |:-------------------------------------------------------------------------------- |:---------------------------------------------------------------------------------------------------------------------------------------- |
| `HydroTurbineEnergyDispatch` / `…Commitment`      | `ActivePowerVariable` (+ `OnVariable` for commitment)                            | range limits (semicontinuous for commitment)                                                                                             |
| `HydroTurbineWaterLinearDispatch` / `…Commitment` | `HydroTurbineFlowRateVariable` (turbine × reservoir × t), `ActivePowerVariable`  | range limits + `TurbinePowerOutputConstraint` (linear, shallow-reservoir head model)                                                     |
| `HydroTurbineBilinearDispatch`                    | as above                                                                         | as above, with the flow × head product handled by the bilinear approximation API — exact NLP by default, MILP under a linearizing scheme |
| `HydroWaterFactorModel` (turbine side)            | `HydroTurbineFlowRateVariable` (turbine × t), `ActivePowerVariable`              | range limits + `HydroPowerConstraint`                                                                                                    |
| `HydroPumpEnergyDispatch` / `…Commitment`         | `ActivePowerVariable`, `ActivePowerPumpVariable`, optional `ReservationVariable` | range limits; commitment adds `InputActivePowerVariableLimitsConstraint`; `ActivePowerPumpReservationConstraint` when reserving          |

`ActivePowerPumpVariable` enters `ActivePowerBalance` with multiplier `-1.0` — pumping is a
withdrawal. The three water-flow turbine formulations are collected by the union alias
`HydroTurbineWaterFormulation`.

Every hydro formulation supports all eleven network models. The AC methods add
`ReactivePowerVariable`, wire it into `ReactivePowerBalance`, and keep the water and energy
constraints unchanged; the active-power methods omit the reactive pieces.

## Storage and Hybrid Formulations

There is exactly one concrete storage formulation and one concrete hybrid formulation.

### [`StorageDispatchWithReserves`](@id storage_math_model)

Attributes: `"reservation"` (default `true`), `"cycling_limits"`, `"energy_target"`,
`"complete_coverage"`, `"regularization"` (all default `false`).

| Stage    | Emits                                                                                                                                                                                                                                                                                                                                               |
|:-------- |:--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Argument | `ActivePowerInVariable`, `ActivePowerOutVariable`, `EnergyVariable`, `StorageEnergyOutput` (aux), `ReactivePowerVariable` (AC only); `ReservationVariable` if reserving; energy-target and cycling slacks if enabled; `InitialEnergyLevel` initial condition; `ActivePowerBalance ← ActivePowerOutVariable` (+1) and `← ActivePowerInVariable` (−1) |
| Model    | `Output`/`InputActivePowerVariableLimitsConstraint`, `StateofChargeLimitsConstraint`, `EnergyBalanceConstraint`; optional `StateofChargeTargetConstraint`, `StorageCyclingCharge`/`Discharge`, regularization constraints; with services, the reserve coverage / charge / discharge constraints                                                     |

### `HybridDispatchWithReserves`

A single PCC with optional thermal, renewable, storage and load subcomponents. Attributes:
`"reservation"`, `"storage_reservation"` (both default `true`), `"energy_target"`,
`"regularization"` (default `false`). One constructor pair covers all eleven network models; the
reactive-power pieces are added conditionally.

### The reserve trait axes

Storage and hybrid reserve *expressions* are parametrized on three axes rather than duplicated as
sibling singletons:

  - **Direction** — `PSY.ReserveUp` / `PSY.ReserveDown`
  - **Scale** — [`UnscaledReserve`](@ref) (raw multiplier) / [`DeployedReserve`](@ref) (scaled by `deployed_fraction`)
  - **Side** — [`DischargeSide`](@ref) / [`ChargeSide`](@ref)

giving eight instantiations each of `StorageReserveBalanceExpression{D,S,Sd}` and
`HybridPCCReserveExpression{D,S,Sd}`. `Unscaled` is used for *assignment* constraints (what may be
offered); `Deployed` for *energy-affecting* constraints (state-of-charge balance, cycling,
regularization).

The load-bearing rule is that **the sides swap**: on the discharge side an up-reserve raises
effective power, but on the charge side the roles reverse, because a charging battery's net
consumption is *increased* by downward reserve.

## Load, Source and Shunt Formulations

| Formulation                         | Device                                     | Variables                                                                              | Constraints                                                                                                                                                    |
|:----------------------------------- |:------------------------------------------ |:-------------------------------------------------------------------------------------- |:-------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `StaticPowerLoad`                   | `PSY.ElectricLoad`                         | none                                                                                   | none — the time-series parameter goes straight into the balance (multiplier −1)                                                                                |
| `PowerLoadDispatch`                 | controllable load                          | `ActivePowerVariable`, `ReactivePowerVariable`                                         | `ActivePowerVariableTimeSeriesLimitsConstraint`; reactive limits are a constant-power-factor equality                                                          |
| `PowerLoadInterruption`             | controllable load                          | as above **+ binary `OnVariable`**                                                     | as above **+ the binary linking constraint** (`meta = "binary"`)                                                                                               |
| `PowerLoadShift`                    | `PSY.ShiftablePowerLoad`                   | `ShiftUp`/`ShiftDownActivePowerVariable`                                               | `ShiftedActivePowerBalanceConstraint` (optional `"additional"` meta), `RealizedShiftedLoadMinimumBoundConstraint`, shift limits, `NonAnticipativityConstraint` |
| `ImportExportSourceModel`           | `PSY.Source`                               | `ActivePowerIn`/`OutVariable`, `ReactivePowerVariable`, optional `ReservationVariable` | range limits + `ImportExportBudgetConstraint` (`"export"`/`"import"`)                                                                                          |
| `SynchronousCondenserBasicDispatch` | `PSY.SynchronousCondenser`                 | `ReactivePowerVariable`                                                                | none                                                                                                                                                           |
| `ShuntSusceptanceDispatch`          | `SwitchedAdmittance`, `FACTSControlDevice` | `ShuntSusceptanceVariable`, `ReactivePowerVariable`                                    | `ShuntReactivePowerConstraint` (``q = b V^2``)                                                                                                                 |

`ShuntSusceptanceDispatch` is supported on `ACPNetworkModel`, `ACRNetworkModel`,
`IVRNetworkModel` and `LPACCNetworkModel` (where ``V^2`` is linearized consistently with the
voltage approximation); it is dropped from active-power templates by the
`models_reactive_power` gate. All four load dispatch formulations, including `PowerLoadShift`,
support all eleven network models.

`SynchronousCondenserBasicDispatch` is likewise gated by `models_reactive_power`: a condenser
supplies only reactive power, so on a network without a reactive power balance the device model
is dropped from the template with a message.

## [Service Formulations](@id service_formulations)

| Formulation                  | Service type                | Argument stage                                                                                 | Model stage                                                |
|:---------------------------- |:--------------------------- |:---------------------------------------------------------------------------------------------- |:---------------------------------------------------------- |
| `RangeReserve`               | `PSY.Reserve`               | `RequirementTimeSeriesParameter` (omitted for `ConstantReserve`), `ActivePowerReserveVariable` | `RequirementConstraint`, `ParticipationFractionConstraint` |
| `RampReserve`                | `PSY.Reserve`               | as above                                                                                       | as above **+ `RampConstraint`**                            |
| `NonSpinningReserve`         | `PSY.ReserveNonSpinning`    | as above, but **no** device-range expression wiring                                            | as above **+ `ReservePowerConstraint`**                    |
| `StepwiseCostReserve` (ORDC) | `PSY.Reserve`               | `ServiceRequirementVariable` + ORDC slope/breakpoint parameters                                | `RequirementConstraint` only — no participation constraint |
| `GroupReserve`               | `PSY.ConstantReserveGroup`  | no variables                                                                                   | `RequirementConstraint` across contributing services       |
| `ConstantMaxInterfaceFlow`   | `PSY.TransmissionInterface` | optional slacks, `InterfaceTotalFlow` expression                                               | `InterfaceFlowLimit` (`"ub"`/`"lb"`)                       |
| `VariableMaxInterfaceFlow`   | `PSY.TransmissionInterface` | as above **+ min/max flow-limit parameters**                                                   | as above, with parameterized limits                        |

`GroupReserve` is deliberately constructed **last** in both stages, because it aggregates the other
services' variables.

!!! warning "GroupReserve does not support slacks"
    
    `GroupReserve`'s requirement-constraint builder reads a `slack_vars` binding that is never
    created, so a `ServiceModel` with `use_slacks = true` raises `UndefVarError`. A group reserve
    also cannot currently be built end to end: a `ConstantReserveGroup` aggregates services rather
    than devices, so its contributing-device list is empty and construction errors out before the
    requirement constraint is reached.

Reserve contributions reach a device through `get_expression_type_for_reserve`: for thermal,
renewable and hydro an up-reserve enters `ActivePowerRangeExpressionUB` (+1) and a down-reserve
`ActivePowerRangeExpressionLB` (−1); storage and hybrid instead route everything into
`TotalReserveOffering`. Any other device type hits an error — loads, sources, condensers and shunts
cannot contribute to a reserve.

Service `meta` strings are **per-instance**, not a fixed vocabulary: every reserve container is
keyed by the service's own name (`meta = get_service_name(model)`). The only fixed metas here are
`"ub"`/`"lb"` on `InterfaceFlowLimit`.

!!! note "AGC is not available"
    
    `services_models/agc.jl` is not included in the module and its `construct_service!` methods are
    commented out. `AbstractAGCFormulation` and `PIDSmoothACE` are still *defined* but have no
    constructor and cannot be used.

## [Feedforward Formulations](@id ff_formulations)

!!! warning "Feedforwards are not implemented in PowerOperationsModels"
    
    POM defines **no concrete feedforward types**. `AbstractAffectFeedforward` is an IOM abstract
    used as the type of the `DeviceModel.feedforwards` field, and the concrete feedforwards
    (`UpperBoundFeedforward`, `SemiContinuousFeedforward`, `FixValueFeedforward`, and so on) live in
    PowerSimulations.jl and have not yet been migrated.
    
    Every `add_feedforward_arguments!` / `add_feedforward_constraints!` call site in POM's
    constructors resolves to a **stub that returns without emitting anything**, and
    `has_semicontinuous_feedforward` always returns `false`. The `UpperBoundFeedForwardSlack` /
    `LowerBoundFeedForwardSlack` variable types and the `FixValueParameter` plumbing exist, but
    nothing in POM constructs them — the plumbing is present, the driver is absent.

## [Piecewise-linear cost](@id pwl_cost)

There are **two** piecewise-linear cost formulations, and which one you get is decided by the
*shape of the cost data*, not by a flag:

|                    | Lambda (convex combination)                                             | Delta (incremental block offer)                                                               |
|:------------------ |:----------------------------------------------------------------------- |:--------------------------------------------------------------------------------------------- |
| Triggered by       | `PiecewisePointCurve` — absolute (power, cost) breakpoints              | `PiecewiseIncrementalCurve` / `PiecewiseAverageCurve` — per-segment slopes                    |
| Variable           | `PiecewiseLinearCostVariable` (``\lambda \in [0,1]``)                   | `PiecewiseLinearBlockIncrementalOffer` / `…DecrementalOffer` (``\delta \ge 0``)               |
| Linking constraint | `PiecewiseLinearCostConstraint`: ``p = \sum_i \lambda_i P_i``           | block-offer constraint: ``p = \sum_k \delta_k + P_{min}``                                     |
| Normalization      | `PiecewiseLinearCostNormalizationConstraint`: ``\sum_i \lambda_i = u``  | none                                                                                          |
| Segment bounds     | none                                                                    | ``\delta_k \le P_{k+1} - P_k``                                                                |
| SOS2               | **only when the curve is non-convex** — then the problem becomes a MILP | **never** — the segment-width bounds enforce ordering, so even a non-convex curve stays an LP |

The lambda normalization couples to the commitment status: its right-hand side is `1.0` with no
commitment, the `OnStatusParameter` for a compact dispatch, or the `OnVariable` for a unit
commitment.

Offer *direction* selects the delta family: generation is an `IncrementalOffer`; the charging side
of storage, the import side of a `Source`, and controllable loads are `DecrementalOffer` (negative
objective sign). ORDC reserve demand curves are also decremental, because a willingness-to-pay
curve is concave.

## [When to use `meta` versus a new key type](@id meta_vs_key_type)

Every container key (`VariableKey`, `ConstraintKey`, `ExpressionKey`, `ParameterKey`) carries a
`meta::String` field, defaulting to `IOM.CONTAINER_KEY_EMPTY_META` (`""`). The choice between
adding a `meta` and defining a new key type is a modelling decision, not a naming one:

  - Use **`meta`** when you are slicing *one conceptual object* along an orthogonal axis. The
    slices share a name because they are the same constraint viewed from different sides — for
    example a single `FlowRateConstraint` sliced into `"lb"` and `"ub"`, or a single
    `NetworkFlowConstraint` sliced into `"p_ft"`, `"q_ft"`, `"p_tf"`, `"q_tf"`. Reserving a new
    type for each slice would multiply near-identical types and make it impossible to ask for
    "the flow-rate constraints" as a group.

  - Use **a distinct key type** when the constraint is *semantically different* — it expresses a
    different physical or economic relationship. `NetworkFlowConstraint` (Ohm's law) and
    `FlowRateConstraint` (a thermal rating) both act on branch flows, but they are different
    statements about the system and so are different types.

A useful test: if you would ever want to enable, disable, dualize, or report the two things
independently *as concepts*, they are different types. If you would always want them together and
are only separating them because a single container cannot hold both, that is a `meta`.

Two mechanical consequences worth knowing:

  - `add_variable_container!` has an extra method taking `meta::String` **positionally** as its
    fourth argument; `add_constraints_container!` accepts `meta` as a keyword only. The AC network
    slacks (`"P"` / `"Q"`) use the positional form, so a grep for `meta =` will not find them.
  - `meta` must not contain the component-name delimiter; `check_meta_chars` enforces this.

### Meta vocabulary

Most metas fall into a small number of families:

| Family                      | Values                                                                                                                | Used by                                                                                                                                                                             |
|:--------------------------- |:--------------------------------------------------------------------------------------------------------------------- |:----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Bound direction             | `"lb"`, `"ub"`                                                                                                        | `FlowRateConstraint`, `AngleDifferenceConstraint`, `PostContingencyFlowRateConstraint`, `InterfaceFlowLimit`, and the generic device range constraints (from `IOM.constraint_meta`) |
| Flow direction × bound      | `"ft_ub"`, `"ft_lb"`, `"tf_ub"`, `"tf_lb"`                                                                            | `FlowRateConstraint` under `DCPLLNetworkModel`; `HVDCPowerBalance`                                                                                                                  |
| Power component × direction | `"p_ft"`, `"q_ft"`, `"p_tf"`, `"q_tf"` (+ `"cr_fr"`, `"ci_fr"`, `"cr_to"`, `"ci_to"`, `"vr_to"`, `"vi_to"` under IVR) | `NetworkFlowConstraint` on the AC models                                                                                                                                            |
| Terminal                    | `"from"`, `"to"`                                                                                                      | `HVDCDCControlConstraint`, `CurrentLimitConstraint`, `HVDCVSCApparentPowerLimitConstraint`, `RegulatedVoltageMagnitude` on VSC/LCC                                                  |
| Voltage coordinate          | `"va"`, `"vm"` (ACP); `"vi"`, `"vr"` (ACR/IVR)                                                                        | `ReferenceBusConstraint`                                                                                                                                                            |
| Active vs reactive          | `"P"`, `"Q"`                                                                                                          | `SystemBalanceSlackUp` / `SystemBalanceSlackDown` on the AC models (positional)                                                                                                     |
| Per-instance                | `meta = get_service_name(model)`, `"$(typeof(service))_$(name)"`                                                      | Services, and the storage/hybrid reserve families — these are **not** a fixed vocabulary                                                                                            |

!!! note "`HVDCPowerBalance` is two different types"
    
    POM defines `HVDCPowerBalance <: ConstraintType`, while IOM defines an unrelated
    `HVDCPowerBalance <: ExpressionType`. They share a name but are different types in different
    modules.
