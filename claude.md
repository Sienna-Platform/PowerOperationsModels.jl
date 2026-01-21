# Claude Code Guidelines for PowerOperationsModels.jl

## Project Overview

**PowerOperationsModels.jl** is a Julia package that contains optimization models for power system components. It is part of the NLR Sienna ecosystem for power system modeling and simulation.

**Note:** NREL (National Renewable Energy Laboratory) no longer exists and has been renamed to NLR (National Laboratory of the Rockies). References to "NREL-Sienna" in the codebase refer to the organization now known as Sienna only and the official name is NLR National Laboratory of the Rockies (formerly known as NREL).

### Repository Structure

This is a **dual-structure repository**:

```
PowerOperationsModels.jl/           # Root - Wrapper package
├── src/PowerOperationsModels.jl    # Thin wrapper module
├── Project.toml                    # Depends on InfrastructureOptimizationModels
├── test/                           # Integration tests
├── docs/                           # Documentation
└── InfrastructureOptimizationModels.jl/     # Core implementation (subpackage)
    ├── src/                        # Main source code (~150+ files)
    │   ├── core/                   # Fundamental data structures
    │   ├── common_models/          # Reusable model construction methods
    │   ├── operation/              # DecisionModel, EmulationModel execution
    │   ├── objective_function/     # Cost function implementations
    │   ├── initial_conditions/     # IC handling
    │   └── utils/                  # Utilities
    ├── test/
    └── Project.toml
```

### Package Relationships

- **PowerOperationsModels.jl**: Contains device/component-specific optimization models (thermal generators, renewables, storage, HVDC, loads, etc.)
- **InfrastructureOptimizationModels.jl**: Infrastructure library for building optimization models (containers, templates, model construction patterns). Claude CAN modify this package if needed for compatibility.
- **PowerSimulations.jl**: Parent package from which code is being extracted to create simpler, modular packages. Both PowerOperationsModels.jl and InfrastructureOptimizationModels.jl are children of PowerSimulations. References to PSI should not exist anymore in this repository.

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `PowerSystems.jl` | Power system data structures (devices, services, networks) |
| `PowerModels.jl` | Power flow formulations (AC, DC, PTDF models) |
| `InfrastructureSystems.jl` | Base infrastructure, optimization key types |
| `JuMP.jl` | Mathematical optimization modeling |
| `PowerFlows.jl` | Power flow calculations |
| `PowerNetworkMatrices.jl` | PTDF, LODF matrices |

## Architecture Patterns

### Device Model Construction

Models follow a two-stage construction pattern with `construct_device!`:

```julia
# Stage 1: ArgumentConstructStage - Add variables and parameters
function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ArgumentConstructStage,
    device_model::DeviceModel{T, Formulation},
    network_model::NetworkModel{N},
) where {T <: PSY.Device, N <: PM.AbstractPowerModel}
    devices = get_available_components(device_model, sys)
    add_variables!(container, VariableType, devices, Formulation())
    add_parameters!(container, ParameterType, devices, device_model)
    add_to_expression!(container, ExpressionType, VariableType, devices, device_model, network_model)
    add_feedforward_arguments!(container, device_model, devices)
    return
end

# Stage 2: ModelConstructStage - Add constraints
function construct_device!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::ModelConstructStage,
    device_model::DeviceModel{T, Formulation},
    network_model::NetworkModel{N},
) where {T <: PSY.Device, N <: PM.AbstractPowerModel}
    devices = get_available_components(device_model, sys)
    add_constraints!(container, ConstraintType, devices, device_model, network_model)
    add_feedforward_constraints!(container, device_model, devices)
    objective_function!(container, devices, device_model, N)
    add_constraint_dual!(container, sys, device_model)
    return
end
```

### Type Aliases

```julia
const PM = PowerModels
const PSY = PowerSystems
const POM = InfrastructureOptimizationModels
const IS = InfrastructureSystems
const ISOPT = InfrastructureSystems.Optimization
const MOI = MathOptInterface
const PNM = PowerNetworkMatrices
const PFS = PowerFlows
```

### Key Types

- `OptimizationContainer`: Central container holding JuMP model, variables, constraints, parameters
- `DeviceModel{D, F}`: Specifies device type `D` and formulation `F`
- `ServiceModel{S, F}`: Specifies service type `S` and formulation `F`
- `NetworkModel{N}`: Network formulation wrapper
- `ProblemTemplate`: Defines optimization problem structure
- `DecisionModel`: Single-shot optimization model
- `EmulationModel`: Rolling-horizon simulation model

## Coding Style Requirements

This repository follows the [InfrastructureSystems.jl Style Guide](https://nrel-sienna.github.io/InfrastructureSystems.jl/stable/style/):

### Naming Conventions

- **Types**: `PascalCase` (e.g., `ActivePowerVariable`, `FlowRateConstraint`)
- **Functions**: `snake_case` (e.g., `add_variables!`, `construct_device!`)
- **Constants**: `SCREAMING_SNAKE_CASE` (e.g., `LOG_GROUP_BRANCH_CONSTRUCTIONS`)
- **Mutating functions**: End with `!` (e.g., `build!`, `solve!`, `add_constraints!`)

### Code Organization

- One type per file when the type has significant methods
- Group related functions in the same file
- Use `include()` statements in main module file to control load order
- Keep files focused and reasonably sized

### Type Annotations

- Use type annotations on function arguments for dispatch
- Use parametric types with `where` clauses for flexibility
- Prefer abstract types in signatures for extensibility

```julia
# Good: Flexible parametric signature
function add_constraints!(
    container::OptimizationContainer,
    ::Type{T},
    devices::U,
    model::DeviceModel{D, F},
    network_model::NetworkModel{N},
) where {T <: ConstraintType, U <: Union{Vector, IS.FlattenIteratorWrapper}, D <: PSY.Device, F, N}
```

### Documentation

Follow [InfrastructureSystems.jl Documentation Best Practices](https://nrel-sienna.github.io/InfrastructureSystems.jl/stable/docs_best_practices/explanation/):

- Use `DocStringExtensions.jl` with `@template` for consistent signatures
- Document all public functions and types
- Include examples in docstrings where helpful
- Use `# Arguments` and `# Returns` sections for complex functions

```julia
"""
$(TYPEDSIGNATURES)

Brief description of what the function does.

# Arguments
- `container::OptimizationContainer`: The optimization container
- `devices`: Iterable of devices to process

# Returns
Nothing, modifies `container` in place.
"""
function add_variables!(container, devices)
    # implementation
end
```

## Julia Performance Best Practices

All code must follow Julia performance best practices:

### Type Stability

- Ensure functions are type-stable (return type depends only on input types)
- Avoid containers with abstract element types
- Use `@code_warntype` to check for type instabilities

```julia
# Bad: Type unstable
function get_value(x)
    x > 0 ? 1.0 : "negative"  # Returns Float64 or String
end

# Good: Type stable
function get_value(x)::Float64
    x > 0 ? 1.0 : -1.0
end
```

### Avoid Global Variables

- Never use non-const global variables in performance-critical code
- Pass data through function arguments
- Use closures or functors if state is needed

### Preallocate Arrays

```julia
# Bad: Growing array in loop
results = []
for i in 1:n
    push!(results, compute(i))
end

# Good: Preallocated
results = Vector{Float64}(undef, n)
for i in 1:n
    results[i] = compute(i)
end
```

### Use Views for Slices

```julia
# Bad: Creates copy
subarray = array[1:100]

# Good: Creates view (no allocation)
subarray = @view array[1:100]
```

### Avoid String Interpolation in Hot Paths

```julia
# Bad in loops
for device in devices
    key = "device_$(get_name(device))_power"
end

# Good: Use Symbol or pre-compute
for device in devices
    key = Symbol(:device_, get_name(device), :_power)
end
```

### Access Struct Fields Directly

- Use direct field access in performance-critical code
- Getter functions are fine for API but add overhead

## Template Placeholders to Replace

The repository was created from a template. The following placeholders need substitution:

| Location | Placeholder | Replace With |
|----------|-------------|--------------|
| `README.md` | `SIENNA-Template` | `PowerOperationsModels.jl` |
| `README.md` | `Sienna-PACKAGE.jl` | `PowerOperationsModels.jl` |
| `README.md` | `SIENNA-PACKAGE` | `PowerOperationsModels` |
| `README.md` | GitHub URLs | `NREL-Sienna/PowerOperationsModels.jl` |
| `CONTRIBUTING.md` | CLA URL | Update to correct package name |
| `Project.toml` | `authors = ["YOUR_NAME"]` | Actual author names |
| `docs/src/index.md` | Placeholder text | Actual package description |

## Testing

### Test Structure

```
test/
├── runtests.jl              # Main entry point with Aqua checks
├── includes.jl              # Test dependencies
├── test_utils/              # Shared test utilities
│   ├── solver_definitions.jl
│   ├── operations_problem_templates.jl
│   └── ...
└── test_*.jl                # Individual test files
```

### Running Tests

```julia
using Pkg
Pkg.test("PowerOperationsModels")

# Or for InfrastructureOptimizationModels specifically
cd("InfrastructureOptimizationModels.jl")
Pkg.test()
```

### Test Utilities

- Use `HiGHS` for LP/MIP testing
- Use `Ipopt` for nonlinear testing
- Use `PowerSystemCaseBuilder` for test systems
- Set `ENV["SIENNA_RANDOM_SEED"] = 1234` for reproducibility

## Common Development Tasks

### Adding a New Device Formulation

1. Define the formulation type in the appropriate module
2. Implement `construct_device!` for both `ArgumentConstructStage` and `ModelConstructStage`
3. Add variable/constraint types if needed
4. Register exports in main module
5. Add tests

### Adding a New Variable Type

```julia
# In core/standard_variables_expressions.jl or appropriate file
struct MyNewVariable <: VariableType end

# Implement add_variables! method
function add_variables!(
    container::OptimizationContainer,
    ::Type{MyNewVariable},
    devices::U,
    formulation::F,
) where {U, F}
    # Implementation
end

# Export in main module
export MyNewVariable
```

### Adding a New Constraint Type

```julia
struct MyNewConstraint <: ConstraintType end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{MyNewConstraint},
    devices::U,
    model::DeviceModel{D, F},
    network_model::NetworkModel{N},
) where {U, D, F, N}
    # Implementation
end

export MyNewConstraint
```

## Important Notes

1. **Method Ambiguity**: The codebase uses extensive multiple dispatch. When adding new methods, check for ambiguity with existing methods using `Test.detect_ambiguities`.

2. **Network Model Compatibility**: Not all device formulations work with all network models. Check existing `construct_device!` signatures for compatible combinations.

3. **Feedforward Support**: Most device models should support feedforward patterns via `add_feedforward_arguments!` and `add_feedforward_constraints!`.

4. **Dual Variables**: Use `add_constraint_dual!` to enable dual variable extraction for constraints.

5. **Expression Order**: When building expressions, `add_expressions!` must come before `add_constraints!` that use those expressions.

## Debugging

- Enable debug logging: `ENV["SIIP_LOGGING_CONFIG"] = "debug"`
- Use `LOG_GROUP_*` constants for targeted debug output
- Check `optimization_debugging.jl` for debugging utilities
