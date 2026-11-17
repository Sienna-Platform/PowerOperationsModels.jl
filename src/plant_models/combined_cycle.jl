const SUBTRACT_ELECTRICAL_OUTPUT_ATTRIBUTE = "subtract_electrical_output"
const EXHAUST_LINE_ATTRIBUTE = "exhaust_line"

get_default_attributes(::Type{PSY.CombinedCycleBlock}, ::Type{SharedHRSGHeatBalance}) =
    Dict{String, Any}(
        SUBTRACT_ELECTRICAL_OUTPUT_ATTRIBUTE => true,
        EXHAUST_LINE_ATTRIBUTE => "max_load",
    )

##################################### Exhaust heat #########################################

"How the exhaust heat of a CT follows its fuel curve, set by the `\"exhaust_line\"` attribute."
abstract type ExhaustHeatModel end
"The last segment of the CT fuel curve, extended over the whole range."
struct MaxLoadExhaust <: ExhaustHeatModel end
"The first segment of the CT fuel curve, extended over the whole range."
struct MinLoadExhaust <: ExhaustHeatModel end
"The CT's own piecewise fuel, with an SOS2 constraint on its breakpoint weights."
struct PiecewiseExhaust <: ExhaustHeatModel end
"The CT's own piecewise fuel with no SOS2 constraint, so far breakpoints can overstate heat."
struct RelaxedPiecewiseExhaust <: ExhaustHeatModel end

const PiecewiseExhaustModel = Union{PiecewiseExhaust, RelaxedPiecewiseExhaust}

const EXHAUST_HEAT_MODELS = Dict{String, ExhaustHeatModel}(
    "max_load" => MaxLoadExhaust(),
    "min_load" => MinLoadExhaust(),
    "piecewise" => PiecewiseExhaust(),
    "piecewise_relaxed" => RelaxedPiecewiseExhaust(),
)

exhaust_heat_model(model::PlantModel{PSY.CombinedCycleBlock, SharedHRSGHeatBalance}) =
    EXHAUST_HEAT_MODELS[get_attribute(model, EXHAUST_LINE_ATTRIBUTE)::String]

##################################### Heat lines ###########################################

"A heat curve that must be one line, such as a steam turbine's."
struct SingleLine end

const HeatLineMode = Union{MaxLoadExhaust, MinLoadExhaust, SingleLine}

"""
    heat_line(curve::IS.ValueCurve, mode)

The straight line `intercept + slope * power` that stands for a fuel curve, in the units of
the curve's data. A linear curve is its own line under every mode. For a convex piecewise
curve the line is the last segment (`MaxLoadExhaust()`) or the first (`MinLoadExhaust()`)
extended over the whole range, which never sits above the curve; `SingleLine()` accepts only
a curve that is a single line.
"""
heat_line(curve::Union{IS.IncrementalCurve, IS.AverageRateCurve}, mode::HeatLineMode) =
    heat_line(IS.InputOutputCurve(curve), mode)

function heat_line(curve::IS.InputOutputCurve{IS.LinearFunctionData}, ::HeatLineMode)
    fd = IS.get_function_data(curve)
    return (intercept = IS.get_constant_term(fd), slope = IS.get_proportional_term(fd))
end

function heat_line(curve::IS.InputOutputCurve{IS.QuadraticFunctionData}, ::HeatLineMode)
    fd = IS.get_function_data(curve)
    if !iszero(IS.get_quadratic_term(fd))
        throw(
            ArgumentError(
                "a quadratic fuel curve has no heat line; use a linear or " *
                "convex piecewise linear curve",
            ),
        )
    end
    return (intercept = IS.get_constant_term(fd), slope = IS.get_proportional_term(fd))
end

function heat_line(curve::IS.InputOutputCurve{IS.PiecewiseLinearData}, mode::HeatLineMode)
    fd = IS.get_function_data(curve)
    slopes = IS.get_slopes(fd)
    for k in 2:length(slopes)
        if slopes[k] < slopes[k - 1] && !isapprox(slopes[k], slopes[k - 1])
            throw(
                ArgumentError(
                    "a piecewise fuel curve must be convex to have a heat " *
                    "line; its slopes are $(slopes)",
                ),
            )
        end
    end
    _check_single_slope(mode, slopes)
    k = segment_index(mode, slopes)
    point = IS.get_points(fd)[k]
    return (intercept = point.y - slopes[k] * point.x, slope = slopes[k])
end

heat_line(curve::IS.ValueCurve, ::HeatLineMode) = throw(
    ArgumentError(
        "a $(nameof(typeof(curve))) fuel curve has no heat line; use a linear or " *
        "convex piecewise linear curve",
    ),
)

segment_index(::MaxLoadExhaust, slopes::Vector{Float64}) = length(slopes)
segment_index(::Union{MinLoadExhaust, SingleLine}, ::Vector{Float64}) = 1

_check_single_slope(::Union{MaxLoadExhaust, MinLoadExhaust}, ::Vector{Float64}) = nothing
function _check_single_slope(::SingleLine, slopes::Vector{Float64})
    all(s -> isapprox(s, first(slopes)), slopes) || throw(
        ArgumentError(
            "the fuel curve has more than one slope, $(slopes), so no single line is exact",
        ),
    )
    return
end

# The line validation checks. A convex curve's first segment sits below all of it.
validation_heat_line_mode(mode::Union{MaxLoadExhaust, MinLoadExhaust}) = mode
validation_heat_line_mode(::PiecewiseExhaustModel) = MinLoadExhaust()

"The value curve that holds a unit's heat data."
heat_value_curve(cost::PSY.FuelCurve) = IS.get_value_curve(cost)
# A stacked steam turbine draws heat for its first fuel; the second is duct firing.
heat_value_curve(cost::PSY.DualFuelCurve) = PSY.get_first_fuel_curve(cost)

##################################### Block data ###########################################

# A CT of an HRSG with the fuel its exhaust heat follows, per hour, with power in system base.
abstract type HeatUnit end

# Exhaust fuel as the line `intercept + slope * power`.
struct LineHeatUnit{D <: PSY.ThermalGen} <: HeatUnit
    device::D
    intercept::Float64
    slope::Float64
end

# Exhaust fuel as `sum(fuel[i] * λ[i])` over the breakpoint weights of the CT's own cost.
struct PiecewiseHeatUnit{D <: PSY.ThermalGen} <: HeatUnit
    device::D
    fuel::Vector{Float64}
end

# One HRSG of a block with its available members. `kappa` is the heat equivalent of one unit
# of system-base power per hour, in the block's fuel units. `ct_ids` are the ids of every CT
# the block maps to the HRSG, modeled or not.
struct HRSGData
    name::String
    number::Int
    efficiency::Float64
    heat_loss::Float64
    kappa::Float64
    cts::Vector{HeatUnit}
    cas::Vector{PSY.ThermalGen}
    ct_ids::Vector{Int}
end

hrsg_name(block::PSY.CombinedCycleBlock, n::Int) = "$(PSY.get_name(block))__hrsg$(n)"
heat_allocation_name(ca::PSY.ThermalGen, n::Int) = "$(PSY.get_name(ca))__hrsg$(n)"

hrsg_numbers(block::PSY.CombinedCycleBlock) = sort!(
    collect(union(keys(PSY.get_hrsg_ct_map(block)), keys(PSY.get_hrsg_ca_map(block)))),
)

# The block's thermal members by id, available or not.
function combined_cycle_members(sys::PSY.System, block::PSY.CombinedCycleBlock)
    members = PSY.get_associated_components(sys, block; component_type = PSY.ThermalGen)
    return Dict{Int, PSY.ThermalGen}(IS.get_id(d) => d for d in members)
end

# The curve that carries a unit's heat data. An offer curve cost has none, so it is
# returned as is and validation rejects it.
fuel_cost_curve(device::PSY.ThermalGen) = fuel_cost_curve(PSY.get_operation_cost(device))
fuel_cost_curve(cost::PSY.ThermalGenerationCost) = PSY.get_variable_operation_cost(cost)
fuel_cost_curve(cost::PSY.OperationalCost) = cost

# A unit's heat line against system-base power. The intercept is fuel per hour, which has
# no power base.
function system_heat_line(
    device::PSY.ThermalGen,
    cost::Union{PSY.FuelCurve, PSY.DualFuelCurve},
    mode::HeatLineMode,
    base_power::Float64,
)
    line = heat_line(heat_value_curve(cost), mode)
    slope = get_proportional_cost_per_system_unit(
        line.slope,
        IS.get_power_units(cost),
        base_power,
        PSY.get_base_power(device, u"NU"),
    )
    return (intercept = line.intercept, slope = slope)
end

function heat_unit(
    device::PSY.ThermalGen,
    mode::Union{MaxLoadExhaust, MinLoadExhaust},
    base_power::Float64,
)
    line = system_heat_line(device, fuel_cost_curve(device), mode, base_power)
    return LineHeatUnit(device, line.intercept, line.slope)
end

heat_unit(device::PSY.ThermalGen, ::PiecewiseExhaustModel, base_power::Float64) =
    piecewise_heat_unit(device, heat_value_curve(fuel_cost_curve(device)), base_power)

# A linear curve has no breakpoint weights; its line is exact.
piecewise_heat_unit(device::PSY.ThermalGen, ::IS.LinearCurve, base_power::Float64) =
    heat_unit(device, MinLoadExhaust(), base_power)

# The cost builds its weights on the point form of the curve, so the fuel is read from it.
piecewise_heat_unit(
    device::PSY.ThermalGen,
    curve::Union{IS.PiecewiseIncrementalCurve, IS.PiecewiseAverageCurve},
    base_power::Float64,
) = piecewise_heat_unit(device, IS.InputOutputCurve(curve), base_power)

piecewise_heat_unit(device::PSY.ThermalGen, curve::IS.PiecewisePointCurve, ::Float64) =
    PiecewiseHeatUnit(device, IS.get_y_coords(IS.get_function_data(curve)))

# The thermal devices the template builds: available and kept by their model's filter.
function modeled_thermal_ids(devices_template::DevicesModelContainer)
    ids = Set{UInt}()
    for device_model in values(devices_template)
        get_component_type(device_model) <: PSY.ThermalGen || continue
        for d in get_device_cache(device_model)
            push!(ids, objectid(d))
        end
    end
    return ids
end

"""
Every HRSG of every `CombinedCycleBlock` in the system, ordered by block name and HRSG
number. Members the template does not build (not available, or filtered out of their device
model) are left out, and so is an HRSG with no steam turbine left.
"""
function resolve_hrsgs(
    container::OptimizationContainer,
    sys::PSY.System,
    model::PlantModel{PSY.CombinedCycleBlock, SharedHRSGHeatBalance},
    devices_template::DevicesModelContainer,
)
    modeled = modeled_thermal_ids(devices_template)
    base_power = get_model_base_power(container)
    subtract = get_attribute(model, SUBTRACT_ELECTRICAL_OUTPUT_ATTRIBUTE)::Bool
    mode = exhaust_heat_model(model)
    blocks = sort!(
        collect(PSY.get_supplemental_attributes(PSY.CombinedCycleBlock, sys));
        by = PSY.get_name,
    )
    hrsgs = HRSGData[]
    for block in blocks
        members =
            filter(p -> objectid(last(p)) in modeled, combined_cycle_members(sys, block))
        ct_map = PSY.get_hrsg_ct_map(block)
        ca_map = PSY.get_hrsg_ca_map(block)
        for n in hrsg_numbers(block)
            cas = PSY.ThermalGen[
                members[id] for id in get(ca_map, n, Int[]) if haskey(members, id)
            ]
            isempty(cas) && continue
            kappa = if subtract
                fuel_units = IS.get_fuel_units(fuel_cost_curve(first(cas)))
                electrical_heat_equivalent(fuel_units) * base_power
            else
                0.0
            end
            ct_ids = get(ct_map, n, Int[])
            cts = HeatUnit[
                heat_unit(members[id], mode, base_power) for
                id in ct_ids if haskey(members, id)
            ]
            push!(
                hrsgs,
                HRSGData(
                    hrsg_name(block, n),
                    n,
                    PSY.get_heat_recovery_to_steam_factor(block),
                    PSY.get_hrsg_heat_loss(block),
                    kappa,
                    cts,
                    cas,
                    copy(ct_ids),
                ),
            )
        end
    end
    return hrsgs
end

# Each steam turbine with the HRSGs that feed it, in first-seen order.
function steam_units(hrsgs::Vector{HRSGData})
    units = Pair{PSY.ThermalGen, Vector{HRSGData}}[]
    index = Dict{UInt, Int}()
    for hrsg in hrsgs, ca in hrsg.cas
        i = get!(index, objectid(ca)) do
            push!(units, ca => HRSGData[])
            length(units)
        end
        push!(last(units[i]), hrsg)
    end
    return units
end

# A steam turbine's heat is CT exhaust, which its CTs already count as fuel. This runs
# after the devices' model stage, so every fuel term is in the expression.
function drop_steam_fuel_consumption!(
    container::OptimizationContainer,
    hrsgs::Vector{HRSGData},
)
    for (ca, _) in steam_units(hrsgs)
        _drop_fuel_consumption!(container, ca, fuel_cost_curve(ca))
    end
    return
end

# A stacked steam turbine's expression holds only its duct fuel, which is real fuel.
_drop_fuel_consumption!(::OptimizationContainer, ::PSY.ThermalGen, ::PSY.DualFuelCurve) =
    nothing

function _drop_fuel_consumption!(
    container::OptimizationContainer,
    ca::D,
    ::PSY.FuelCurve,
) where {D <: PSY.ThermalGen}
    has_container_key(container, FuelConsumptionExpression, D) || return
    expression = get_expression(container, FuelConsumptionExpression, D)
    name = PSY.get_name(ca)
    for t in get_time_steps(container)
        expression[name, t] = zero(eltype(expression))
    end
    return
end

##################################### Variables ############################################

function add_heat_allocation_variables!(
    container::OptimizationContainer,
    hrsgs::Vector{HRSGData},
)
    names_by_type = Dict{DataType, Vector{String}}()
    for hrsg in hrsgs, ca in hrsg.cas
        push!(
            get!(Vector{String}, names_by_type, typeof(ca)),
            heat_allocation_name(ca, hrsg.number),
        )
    end
    for (D, names) in names_by_type
        _add_heat_allocation_container!(container, D, names)
    end
    return
end

# Function barrier: `D` is concrete here, so the container key is typed.
function _add_heat_allocation_container!(
    container::OptimizationContainer,
    ::Type{D},
    names::Vector{String},
) where {D <: PSY.ThermalGen}
    time_steps = get_time_steps(container)
    variable = add_variable_container!(
        container, HRSGHeatAllocationVariable, D, names, time_steps)
    jump_model = get_jump_model(container)
    for name in names, t in time_steps
        variable[name, t] = JuMP.@variable(
            jump_model,
            base_name = "HRSGHeatAllocationVariable_$(D)_{$(name), $(t)}",
            lower_bound = 0.0,
        )
    end
    return
end

heat_allocation(
    container::OptimizationContainer,
    ca::D,
    hrsg_number::Int,
    t::Int,
) where {D <: PSY.ThermalGen} =
    get_variable(container, HRSGHeatAllocationVariable, D)[
        heat_allocation_name(ca, hrsg_number), t]

##################################### Unit terms ###########################################

# A unit has an `OnVariable` entry unless its formulation has none or skips it (must run).
function has_on_variable(
    container::OptimizationContainer,
    devices_template::DevicesModelContainer,
    device::D,
) where {D <: PSY.ThermalGen}
    formulation = get_formulation(devices_template[nameof(D)])
    return has_container_key(container, OnVariable, D) &&
           !skip_variable(OnVariable, device, formulation)
end

# The `OnStatusParameter` of a feedforward has no entry for a must-run unit.
has_on_parameter(container::OptimizationContainer, device::D) where {D <: PSY.ThermalGen} =
    has_container_key(container, OnStatusParameter, D) && !_is_must_run(device)

# A unit with no commitment variable or parameter is always on.
has_constant_commitment(
    container::OptimizationContainer,
    devices_template::DevicesModelContainer,
    device::PSY.ThermalGen,
) =
    !has_on_variable(container, devices_template, device) &&
    !has_on_parameter(container, device)

# A steam turbine that is always on draws heat in every step, so it needs a CT.
function check_steam_has_ct(
    container::OptimizationContainer,
    devices_template::DevicesModelContainer,
    hrsgs::Vector{HRSGData},
)
    for (ca, feeding) in steam_units(hrsgs)
        has_constant_commitment(container, devices_template, ca) || continue
        any(hrsg -> !isempty(hrsg.cts), feeding) && continue
        throw(
            IS.ConflictingInputsError(
                "Steam turbine $(PSY.get_name(ca)) is always on under its formulation " *
                "but has no CT to draw heat from: every CT of its HRSGs is unavailable " *
                "or left out of the model. Make the steam turbine unavailable too, or " *
                "use a unit commitment formulation.",
            ),
        )
    end
    return
end

"""
The unit's commitment at `t`: its `OnVariable` entry, else its `OnStatusParameter` entry
(a feedforward), else the constant `1.0` (dispatch formulations and must-run units).
"""
function commitment_term(
    container::OptimizationContainer,
    devices_template::DevicesModelContainer,
    device::D,
    t::Int,
) where {D <: PSY.ThermalGen}
    name = PSY.get_name(device)
    if has_on_variable(container, devices_template, device)
        return get_variable(container, OnVariable, D)[name, t]
    elseif has_on_parameter(container, device)
        return get_parameter_array(container, OnStatusParameter, D)[name, t]
    end
    return 1.0
end

"""
The unit's active power at `t`, in system base: its `ActivePowerVariable`, or under a
compact formulation its minimum power times its commitment plus `PowerAboveMinimumVariable`.
"""
function unit_power(
    container::OptimizationContainer,
    devices_template::DevicesModelContainer,
    device::D,
    t::Int,
) where {D <: PSY.ThermalGen}
    formulation = get_formulation(devices_template[nameof(D)])
    return unit_power(
        power_base_kind(formulation), container, devices_template, device, t)
end

unit_power(
    ::AbsoluteBase,
    container::OptimizationContainer,
    ::DevicesModelContainer,
    device::D,
    t::Int,
) where {D <: PSY.ThermalGen} =
    get_variable(container, ActivePowerVariable, D)[PSY.get_name(device), t]

function unit_power(
    ::AboveMinimumBase,
    container::OptimizationContainer,
    devices_template::DevicesModelContainer,
    device::D,
    t::Int,
) where {D <: PSY.ThermalGen}
    expr = JuMP.AffExpr(0.0)
    JuMP.add_to_expression!(
        expr,
        get_variable(container, PowerAboveMinimumVariable, D)[PSY.get_name(device), t],
    )
    JuMP.add_to_expression!(
        expr,
        min_active_power_values(container, device)[t],
        commitment_term(container, devices_template, device, t),
    )
    return expr
end

"""
The heat a steam turbine draws at `t`, in the block's fuel units per hour: the unit's own heat
line, `a * power + b * commitment`. For a stacked `DualFuelCurve` the power is the first fuel
output `P - d`, since duct fired output needs no recovered heat.
"""
heat_draw_terms(
    container::OptimizationContainer,
    devices_template::DevicesModelContainer,
    device::PSY.ThermalGen,
    cost::PSY.FuelCurve,
    t::Int,
) = _heat_draw(container, devices_template, device, cost,
    unit_power(container, devices_template, device, t), t)

heat_draw_terms(
    container::OptimizationContainer,
    devices_template::DevicesModelContainer,
    device::PSY.ThermalGen,
    cost::PSY.DualFuelCurve,
    t::Int,
) = _heat_draw(container, devices_template, device, cost,
    unit_power(container, devices_template, device, t) -
    duct_firing_power(container, device, t), t)

function _heat_draw(
    container::OptimizationContainer,
    devices_template::DevicesModelContainer,
    device::PSY.ThermalGen,
    cost::Union{PSY.FuelCurve, PSY.DualFuelCurve},
    power::JuMP.AbstractJuMPScalar,
    t::Int,
)
    line = system_heat_line(device, cost, SingleLine(), get_model_base_power(container))
    expr = JuMP.AffExpr(0.0)
    JuMP.add_to_expression!(expr, line.slope, power)
    JuMP.add_to_expression!(
        expr, line.intercept, commitment_term(container, devices_template, device, t))
    return expr
end

"The fuel a CT burns per hour at `t`, as its exhaust heat follows it."
function exhaust_fuel(
    container::OptimizationContainer,
    devices_template::DevicesModelContainer,
    ct::LineHeatUnit,
    t::Int,
)
    expr = JuMP.AffExpr(0.0)
    JuMP.add_to_expression!(
        expr, ct.slope, unit_power(container, devices_template, ct.device, t))
    JuMP.add_to_expression!(
        expr, ct.intercept, commitment_term(container, devices_template, ct.device, t))
    return expr
end

# The weights sum to the commitment, so the no-load fuel is in the breakpoint values.
function exhaust_fuel(
    container::OptimizationContainer,
    ::DevicesModelContainer,
    ct::PiecewiseHeatUnit{D},
    t::Int,
) where {D <: PSY.ThermalGen}
    weights = get_variable(container, PiecewiseLinearCostVariable, D)
    name = PSY.get_name(ct.device)
    expr = JuMP.AffExpr(0.0)
    for (i, fuel) in enumerate(ct.fuel)
        JuMP.add_to_expression!(expr, fuel, weights[name, i, t])
    end
    return expr
end

# Under `PiecewiseExhaust`, only two neighboring breakpoint weights of a CT can be nonzero.
add_exhaust_sos2_constraints!(
    ::OptimizationContainer,
    ::Vector{HRSGData},
    ::Union{MaxLoadExhaust, MinLoadExhaust, RelaxedPiecewiseExhaust},
) = nothing

function add_exhaust_sos2_constraints!(
    container::OptimizationContainer,
    hrsgs::Vector{HRSGData},
    ::PiecewiseExhaust,
)
    for hrsg in hrsgs, ct in hrsg.cts
        _add_exhaust_sos2!(container, ct)
    end
    return
end

_add_exhaust_sos2!(::OptimizationContainer, ::LineHeatUnit) = nothing

function _add_exhaust_sos2!(
    container::OptimizationContainer,
    ct::PiecewiseHeatUnit{D},
) where {D <: PSY.ThermalGen}
    weights = get_variable(container, PiecewiseLinearCostVariable, D)
    name = PSY.get_name(ct.device)
    for t in get_time_steps(container)
        IOM.add_pwl_sos2_constraint!(
            container, D, name, t, [weights[name, i, t] for i in eachindex(ct.fuel)])
    end
    return
end

##################################### Constraints ##########################################

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HRSGHeatAllocationConstraint},
    hrsgs::Vector{HRSGData},
    devices_template::DevicesModelContainer,
)
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)
    constraint = add_constraints_container!(
        container, HRSGHeatAllocationConstraint, PSY.ThermalGen,
        [hrsg.name for hrsg in hrsgs], time_steps,
    )
    for hrsg in hrsgs, t in time_steps
        lhs = JuMP.AffExpr(0.0)
        for ca in hrsg.cas
            JuMP.add_to_expression!(lhs, heat_allocation(container, ca, hrsg.number, t))
        end
        for ct in hrsg.cts
            JuMP.add_to_expression!(
                lhs,
                hrsg.efficiency * hrsg.kappa,
                unit_power(container, devices_template, ct.device, t),
            )
            JuMP.add_to_expression!(
                lhs,
                hrsg.heat_loss,
                commitment_term(container, devices_template, ct.device, t),
            )
            JuMP.add_to_expression!(
                lhs,
                -hrsg.efficiency,
                exhaust_fuel(container, devices_template, ct, t),
            )
        end
        constraint[hrsg.name, t] = JuMP.@constraint(jump_model, lhs <= 0.0)
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HRSGHeatDrawConstraint},
    hrsgs::Vector{HRSGData},
    devices_template::DevicesModelContainer,
)
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)
    units = steam_units(hrsgs)
    constraint = add_constraints_container!(
        container, HRSGHeatDrawConstraint, PSY.ThermalGen,
        [PSY.get_name(ca) for (ca, _) in units], time_steps,
    )
    for (ca, feeding) in units
        name = PSY.get_name(ca)
        cost = fuel_cost_curve(ca)
        for t in time_steps
            lhs = JuMP.AffExpr(0.0)
            for hrsg in feeding
                JuMP.add_to_expression!(
                    lhs, heat_allocation(container, ca, hrsg.number, t))
            end
            JuMP.add_to_expression!(
                lhs, -1.0, heat_draw_terms(container, devices_template, ca, cost, t))
            constraint[name, t] = JuMP.@constraint(jump_model, lhs == 0.0)
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{CombinedCycleCommitmentConstraint},
    hrsgs::Vector{HRSGData},
    devices_template::DevicesModelContainer,
)
    # No row for a steam turbine that is always on, or that has a CT that is always on.
    linked = Pair{PSY.ThermalGen, Vector{PSY.ThermalGen}}[]
    for (ca, feeding) in steam_units(hrsgs)
        has_constant_commitment(container, devices_template, ca) && continue
        cts = unique(objectid, [ct.device for hrsg in feeding for ct in hrsg.cts])
        any(ct -> has_constant_commitment(container, devices_template, ct), cts) &&
            continue
        push!(linked, ca => cts)
    end
    isempty(linked) && return
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)
    constraint = add_constraints_container!(
        container, CombinedCycleCommitmentConstraint, PSY.ThermalGen,
        [PSY.get_name(ca) for (ca, _) in linked], time_steps,
    )
    for (ca, cts) in linked, t in time_steps
        lhs = JuMP.AffExpr(0.0)
        JuMP.add_to_expression!(
            lhs, 1.0, commitment_term(container, devices_template, ca, t))
        for ct in cts
            JuMP.add_to_expression!(
                lhs, -1.0, commitment_term(container, devices_template, ct, t))
        end
        constraint[PSY.get_name(ca), t] = JuMP.@constraint(jump_model, lhs <= 0.0)
    end
    return
end

##################################### Duct firing ##########################################

is_stacked(device::PSY.ThermalGen) = is_stacked(fuel_cost_curve(device))
is_stacked(cost::PSY.DualFuelCurve) = !PSY.is_blended(cost)
is_stacked(::Any) = false

# Steam turbines with a stacked curve and the HRSGs that feed them.
stacked_steam_units(hrsgs::Vector{HRSGData}) =
    filter(p -> is_stacked(first(p)), steam_units(hrsgs))

function add_duct_firing_variables!(
    container::OptimizationContainer,
    hrsgs::Vector{HRSGData},
)
    names_by_type = Dict{DataType, Vector{String}}()
    for (ca, _) in stacked_steam_units(hrsgs)
        push!(get!(Vector{String}, names_by_type, typeof(ca)), PSY.get_name(ca))
    end
    for (D, names) in names_by_type
        _add_duct_firing_container!(container, D, names)
    end
    return
end

function _add_duct_firing_container!(
    container::OptimizationContainer,
    ::Type{D},
    names::Vector{String},
) where {D <: PSY.ThermalGen}
    time_steps = get_time_steps(container)
    variable =
        add_variable_container!(container, SecondFuelPowerVariable, D, names, time_steps)
    jump_model = get_jump_model(container)
    for name in names, t in time_steps
        variable[name, t] = JuMP.@variable(
            jump_model,
            base_name = "SecondFuelPowerVariable_$(D)_{$(name), $(t)}",
            lower_bound = 0.0,
        )
    end
    return
end

duct_firing_power(
    container::OptimizationContainer,
    device::D,
    t::Int,
) where {D <: PSY.ThermalGen} =
    get_variable(container, SecondFuelPowerVariable, D)[PSY.get_name(device), t]

# The one segment of the second curve in system base: its threshold `x0`, its width
# `x1 - x0`, and its slope, duct fuel per unit of system-base power per hour.
function duct_firing_segment(device::PSY.ThermalGen, cost::PSY.DualFuelCurve)
    system = IS.convert_power_units(device, cost, u"SU")
    fd = IS.get_function_data(PSY.get_second_fuel_curve(system))
    x0 = PSY.get_stacking_threshold(system)
    return (threshold = x0, width = last(IS.get_x_coords(fd)) - x0,
        slope = only(IS.get_y_coords(fd)))
end

# The lowest first fuel output per step under the unit's formulation.
first_fuel_min_power(
    container::OptimizationContainer,
    device::PSY.ThermalGen,
    ::Type{<:AbstractDeviceFormulation},
) = min_active_power_values(container, device)
# ThermalDispatchNoMin runs from zero output.
first_fuel_min_power(
    container::OptimizationContainer,
    ::PSY.ThermalGen,
    ::Type{ThermalDispatchNoMin},
) = zeros(length(get_time_steps(container)))

"""
Rows of the steam turbines that carry a stacked `PSY.DualFuelCurve`: the duct firing limit,
the range of the steam recovered heat makes, and the duct fuel, priced at the second fuel
price, in `FuelConsumptionExpression`, `FuelCostExpression` and the objective.
"""
function add_duct_firing!(
    container::OptimizationContainer,
    hrsgs::Vector{HRSGData},
    devices_template::DevicesModelContainer,
)
    units = stacked_steam_units(hrsgs)
    isempty(units) && return
    time_steps = get_time_steps(container)
    names = [PSY.get_name(ca) for (ca, _) in units]
    limit = add_constraints_container!(
        container, SecondFuelPowerLimitConstraint, PSY.ThermalGen, names, time_steps)
    lower = add_constraints_container!(
        container, FirstFuelPowerLimitConstraint, PSY.ThermalGen, names, time_steps;
        meta = "lb")
    upper = add_constraints_container!(
        container, FirstFuelPowerLimitConstraint, PSY.ThermalGen, names, time_steps;
        meta = "ub")
    dt = IOM.get_resolution_in_hours(container)
    for (ca, feeding) in units
        name = PSY.get_name(ca)
        cost = fuel_cost_curve(ca)::PSY.DualFuelCurve
        segment = duct_firing_segment(ca, cost)
        # Each CT the block maps to the feeding HRSGs opens its share of the ducts, so an
        # unavailable CT keeps its share closed. Validation gives every HRSG a CT.
        n_cts = length(unique(id for hrsg in feeding for id in hrsg.ct_ids))
        cts = unique(
            objectid,
            PSY.ThermalGen[ct.device for hrsg in feeding for ct in hrsg.cts],
        )
        formulation = get_formulation(devices_template[nameof(typeof(ca))])
        duct = DuctFiring(
            segment.threshold,
            segment.width / n_cts,
            segment.slope * dt,
            first_fuel_min_power(container, ca, formulation),
            fuel_price_source(container, cost, SecondFuel(), typeof(ca), formulation, name),
        )
        _add_duct_firing!(container, devices_template, ca, cts, duct, limit, lower, upper)
    end
    return
end

# The duct firing values of one stacked steam turbine, in system base: the recovered steam
# bound, each CT's share of the ducts, duct fuel per unit of `d` per step, the first fuel
# minimum per step, and the second fuel price from `fuel_price_source`.
struct DuctFiring{P}
    threshold::Float64
    per_ct::Float64
    fuel_rate::Float64
    pmin::Vector{Float64}
    price::P
end

# Function barrier: the unit type and the price source are concrete here.
function _add_duct_firing!(
    container::OptimizationContainer,
    devices_template::DevicesModelContainer,
    ca::D,
    cts::Vector{PSY.ThermalGen},
    duct::DuctFiring,
    limit::DenseAxisArray,
    lower::DenseAxisArray,
    upper::DenseAxisArray,
) where {D <: PSY.ThermalGen}
    jump_model = get_jump_model(container)
    name = PSY.get_name(ca)
    for t in get_time_steps(container)
        d = duct_firing_power(container, ca, t)
        first_fuel = unit_power(container, devices_template, ca, t) - d
        on = commitment_term(container, devices_template, ca, t)
        burners = JuMP.AffExpr(0.0)
        for ct in cts
            JuMP.add_to_expression!(
                burners, duct.per_ct, commitment_term(container, devices_template, ct, t))
        end
        limit[name, t] = JuMP.@constraint(jump_model, d - burners <= 0.0)
        lower[name, t] =
            JuMP.@constraint(jump_model, first_fuel - duct.pmin[t] * on >= 0.0)
        upper[name, t] =
            JuMP.@constraint(jump_model, first_fuel - duct.threshold * on <= 0.0)
        _add_fuel_terms!(container, duct.fuel_rate * d, duct.price, D, name, t)
    end
    return
end

##################################### Duals ################################################

# The plant rows are keyed on `PSY.ThermalGen`, the family they couple, not on a device type.
# A row type stored under several metas (`"lb"`, `"ub"`) gets one dual per meta.
function add_constraint_dual!(
    container::OptimizationContainer,
    ::PSY.System,
    model::PlantModel{PSY.CombinedCycleBlock, SharedHRSGHeatBalance},
)
    for constraint_type in get_duals(model)
        constraint_keys = filter(
            k ->
                get_entry_type(k) === constraint_type &&
                    get_component_type(k) === PSY.ThermalGen,
            IOM.get_constraint_keys(container),
        )
        if isempty(constraint_keys)
            throw(
                IS.InvalidValue(
                    "No constraint of type $(nameof(constraint_type)) is stored for " *
                    "CombinedCycleBlock; cannot assign a dual variable.",
                ),
            )
        end
        for key in constraint_keys
            add_dual_container!(
                container, constraint_type, PSY.ThermalGen,
                axes(get_constraint(container, key))[1], get_time_steps(container);
                meta = key.meta,
            )
        end
    end
    return
end
