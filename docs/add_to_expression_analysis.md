# `add_to_expression!` Call Analysis

## Three distinct signature families:

### 1. Device form with network model (6-arg)
`(container, ExpressionType, VariableType, devices, model, network_model)`

- **~50 definitions** in `add_to_expression.jl`
- **Called from**: POM's `construct_device!` implementations
- **NOT called internally by IOM**

### 2. Device form without network model (5-arg)
`(container, ExpressionType, VariableType/ParameterType, devices, model)`

- **~18 definitions** in `add_to_expression.jl`
- **Called from**: POM's `construct_device!` implementations
- **NOT called internally by IOM**

### 3. Cost form (5-arg) - renamed to `add_cost_to_expression!`
`(container, ExpressionType, cost_expr, component, time_period)`

- **2 definitions** in `add_to_expression.jl` lines 2388 & 2406
  - Line 2388: `S <: Union{CostExpressions, FuelConsumptionExpression}`, `T <: PSY.Component`
  - Line 2406: `S <: CostExpressions`, `T <: PSY.ReserveDemandCurve`
- **Called from IOM's objective_function code** (~15 call sites)
- **Renamed** from `add_to_expression!` to `add_cost_to_expression!` to distinguish from device forms

## The Problem (FIXED)

The objective_function code calls:
```julia
add_to_expression!(container, ProductionCostExpression, exp, d, t)
```

Previously, `ProductionCostExpression <: ExpressionType` was **NOT** a subtype of `CostExpressions`, so it wouldn't match the existing definitions.

### Fix Applied

In IOM's `standard_variables_expressions.jl`, the type hierarchy was corrected:
- `CostExpressions` changed from `struct` to `abstract type`
- `ProductionCostExpression <: CostExpressions` (was `<: ExpressionType`)

Now `ProductionCostExpression` correctly matches the 5-arg cost form method signature.

## Summary Table

| Signature | IOM Defs | IOM Calls | POM Calls | Status |
|-----------|----------|-----------|-----------|--------|
| 6-arg (device + network) | ~50 | 0 | many | Device-specific, candidates to move to POM |
| 5-arg (device, no network) | ~18 | 0 | many | Device-specific, candidates to move to POM |
| 5-arg (cost) `add_cost_to_expression!` | 2 | ~15 | 0 | Renamed, internal to IOM, stays in IOM |

## Conclusion

- The **cost form** (`add_cost_to_expression!`) is called from IOM's objective_function code and belongs in IOM. It has been renamed to distinguish it from the device forms.
- The **device forms** (`add_to_expression!` with 5-arg and 6-arg signatures taking `devices, model`) are called only from POM's `construct_device!` implementations and are candidates to move to POM.
