const SUBTRACT_ELECTRICAL_OUTPUT_ATTRIBUTE = "subtract_electrical_output"
const EXHAUST_LINE_ATTRIBUTE = "exhaust_line"

get_default_attributes(::Type{PSY.CombinedCycleBlock}, ::Type{SharedHRSGHeatBalance}) =
    Dict{String, Any}(
        SUBTRACT_ELECTRICAL_OUTPUT_ATTRIBUTE => true,
        EXHAUST_LINE_ATTRIBUTE => "max_load",
    )

##################################### Heat lines ###########################################

const HEAT_LINE_MODES = (:exact, :max_load, :min_load)

"""
    heat_line(curve::IS.ValueCurve, mode::Symbol)

The straight line `intercept + slope * power` that stands for a fuel curve, in the units of
the curve's data. A linear curve is its own line under every mode. For a convex piecewise
curve the line is the last segment (`:max_load`) or the first (`:min_load`) extended over
the whole range, which never sits above the curve; `:exact` accepts only a curve that is a
single line.
"""
heat_line(curve::Union{IS.IncrementalCurve, IS.AverageRateCurve}, mode::Symbol) =
    heat_line(IS.InputOutputCurve(curve), mode)

function heat_line(curve::IS.InputOutputCurve{IS.LinearFunctionData}, mode::Symbol)
    _check_heat_line_mode(mode)
    fd = IS.get_function_data(curve)
    return (intercept = IS.get_constant_term(fd), slope = IS.get_proportional_term(fd))
end

function heat_line(curve::IS.InputOutputCurve{IS.QuadraticFunctionData}, mode::Symbol)
    _check_heat_line_mode(mode)
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

function heat_line(curve::IS.InputOutputCurve{IS.PiecewiseLinearData}, mode::Symbol)
    _check_heat_line_mode(mode)
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
    if mode == :exact && !all(s -> isapprox(s, first(slopes)), slopes)
        throw(
            ArgumentError(
                "the fuel curve has more than one slope, $(slopes), so no " *
                "single line is exact",
            ),
        )
    end
    k = mode == :max_load ? length(slopes) : 1
    point = IS.get_points(fd)[k]
    return (intercept = point.y - slopes[k] * point.x, slope = slopes[k])
end

function _check_heat_line_mode(mode::Symbol)
    mode in HEAT_LINE_MODES ||
        throw(
            ArgumentError("heat line mode must be one of $(HEAT_LINE_MODES), got $(mode)"),
        )
    return
end

"The value curve that holds a unit's heat data."
heat_value_curve(cost::PSY.FuelCurve) = IS.get_value_curve(cost)
# A two-tier steam turbine draws recovered heat along its first tier.
heat_value_curve(cost::PSY.TwoTierFuelCurve) = PSY.get_first_tier_curve(cost)

const HeatCurve = Union{PSY.FuelCurve, PSY.TwoTierFuelCurve}

# ponytail: prototype data source for the HRSG heat loss, fuel units per hour while the CT
# is on; move it to a `CombinedCycleBlock` field if the idea is kept.
const HRSG_HEAT_LOSS_EXT_KEY = "hrsg_heat_loss"
hrsg_heat_loss(device::PSY.ThermalGen) =
    Float64(get(PSY.get_ext(device), HRSG_HEAT_LOSS_EXT_KEY, 0.0))

##################################### Block data ###########################################

# A CT of an HRSG with its exhaust line: fuel per hour = intercept + slope * power, with
# power in system base.
struct HeatUnit{D <: PSY.ThermalGen}
    device::D
    intercept::Float64
    slope::Float64
    "Heat the HRSG loses while the CT is on, fuel units per hour."
    loss::Float64
end

# One HRSG of a block with its available members. `kappa` is the heat equivalent of one unit
# of system-base power per hour, in the block's fuel units.
struct HRSGData
    name::String
    number::Int
    efficiency::Float64
    kappa::Float64
    cts::Vector{HeatUnit}
    cas::Vector{PSY.ThermalGen}
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
    cost::HeatCurve,
    mode::Symbol,
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

function HeatUnit(device::PSY.ThermalGen, mode::Symbol, base_power::Float64)
    line = system_heat_line(device, fuel_cost_curve(device), mode, base_power)
    return HeatUnit(device, line.intercept, line.slope, hrsg_heat_loss(device))
end

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
    mode = Symbol(get_attribute(model, EXHAUST_LINE_ATTRIBUTE)::String)
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
            cts = HeatUnit[
                HeatUnit(members[id], mode, base_power) for
                id in get(ct_map, n, Int[]) if haskey(members, id)
            ]
            push!(
                hrsgs,
                HRSGData(
                    hrsg_name(block, n),
                    n,
                    PSY.get_heat_recovery_to_steam_factor(block),
                    kappa,
                    cts,
                    cas,
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
The heat a steam turbine draws at `t`, in the block's fuel units per hour. For a `FuelCurve`
it is the unit's own heat line, `a * power + b * commitment`.
"""
function heat_draw_terms(
    container::OptimizationContainer,
    devices_template::DevicesModelContainer,
    device::PSY.ThermalGen,
    cost::HeatCurve,
    t::Int,
)
    line = system_heat_line(device, cost, :exact, get_model_base_power(container))
    expr = JuMP.AffExpr(0.0)
    JuMP.add_to_expression!(
        expr, line.slope, unit_power(container, devices_template, device, t))
    JuMP.add_to_expression!(
        expr, line.intercept, commitment_term(container, devices_template, device, t))
    add_duct_firing_offset!(expr, container, device, cost, line.slope, t)
    return expr
end

# Duct-fired output needs no recovered heat, so it leaves the draw.
add_duct_firing_offset!(
    _,
    ::OptimizationContainer,
    ::PSY.ThermalGen,
    ::PSY.FuelCurve,
    _,
    _,
) =
    nothing
function add_duct_firing_offset!(
    expr::JuMP.AffExpr,
    container::OptimizationContainer,
    device::PSY.ThermalGen,
    ::PSY.TwoTierFuelCurve,
    slope::Float64,
    t::Int,
)
    JuMP.add_to_expression!(expr, -slope, duct_firing_power(container, device, t))
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
                -hrsg.efficiency * (ct.slope - hrsg.kappa),
                unit_power(container, devices_template, ct.device, t),
            )
            JuMP.add_to_expression!(
                lhs,
                ct.loss - hrsg.efficiency * ct.intercept,
                commitment_term(container, devices_template, ct.device, t),
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

is_two_tier(device::PSY.ThermalGen) = fuel_cost_curve(device) isa PSY.TwoTierFuelCurve

# Steam turbines with a two-tier curve and the HRSGs that feed them.
two_tier_steam_units(hrsgs::Vector{HRSGData}) =
    filter(p -> is_two_tier(first(p)), steam_units(hrsgs))

function add_duct_firing_variables!(
    container::OptimizationContainer,
    hrsgs::Vector{HRSGData},
)
    names_by_type = Dict{DataType, Vector{String}}()
    for (ca, _) in two_tier_steam_units(hrsgs)
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
        add_variable_container!(container, DuctFiringPowerVariable, D, names, time_steps)
    jump_model = get_jump_model(container)
    for name in names, t in time_steps
        variable[name, t] = JuMP.@variable(
            jump_model,
            base_name = "DuctFiringPowerVariable_$(D)_{$(name), $(t)}",
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
    get_variable(container, DuctFiringPowerVariable, D)[PSY.get_name(device), t]

# The tier threshold in system base.
function system_tier_threshold(
    device::PSY.ThermalGen,
    cost::PSY.TwoTierFuelCurve,
    base_power::Float64,
)
    return PSY.get_tier_threshold(cost) / get_proportional_cost_per_system_unit(
        1.0, IS.get_power_units(cost), base_power, PSY.get_base_power(device, u"NU"))
end

"""
Rows of the steam turbines that carry a `PSY.TwoTierFuelCurve`: the duct firing limit, the
range of recovered steam, and the price of duct fuel in the objective.
"""
function add_duct_firing!(
    container::OptimizationContainer,
    hrsgs::Vector{HRSGData},
    devices_template::DevicesModelContainer,
)
    units = two_tier_steam_units(hrsgs)
    isempty(units) && return
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)
    base_power = get_model_base_power(container)
    names = [PSY.get_name(ca) for (ca, _) in units]
    limit = add_constraints_container!(
        container, DuctFiringLimitConstraint, PSY.ThermalGen, names, time_steps)
    lower = add_constraints_container!(
        container, RecoveredSteamLimitConstraint, PSY.ThermalGen, names, time_steps;
        meta = "lb")
    upper = add_constraints_container!(
        container, RecoveredSteamLimitConstraint, PSY.ThermalGen, names, time_steps;
        meta = "ub")
    for (ca, feeding) in units
        name = PSY.get_name(ca)
        cost = fuel_cost_curve(ca)
        limits = PSY.get_active_power_limits(ca, u"SU")
        threshold = system_tier_threshold(ca, cost, base_power)
        cts = unique(objectid, [ct.device for hrsg in feeding for ct in hrsg.cts])
        duct_per_ct = (limits.max - threshold) / length(cts)
        for t in time_steps
            d = duct_firing_power(container, ca, t)
            recovered = unit_power(container, devices_template, ca, t) - d
            on = commitment_term(container, devices_template, ca, t)
            burners = JuMP.AffExpr(0.0)
            for ct in cts
                JuMP.add_to_expression!(
                    burners, duct_per_ct,
                    commitment_term(container, devices_template, ct, t))
            end
            limit[name, t] = JuMP.@constraint(jump_model, d - burners <= 0.0)
            lower[name, t] =
                JuMP.@constraint(jump_model, recovered - limits.min * on >= 0.0)
            upper[name, t] = JuMP.@constraint(jump_model, recovered - threshold * on <= 0.0)
        end
        # ponytail: a linear second tier at a fixed price only; piecewise tiers and a price
        # time series need the block plumbing of the duct firing plan.
        duct_heat_rate = heat_line(PSY.get_second_tier_curve(cost), :exact).slope
        IOM.add_proportional_cost_invariant!(
            container, DuctFiringPowerVariable, ca,
            duct_heat_rate * PSY.get_second_tier_fuel_cost(cost),
            IS.get_power_units(cost), 1.0, FuelCostExpression)
    end
    return
end

##################################### Duals ################################################

# The plant rows are keyed on `PSY.ThermalGen`, the family they couple, not on a device type.
function add_constraint_dual!(
    container::OptimizationContainer,
    ::PSY.System,
    model::PlantModel{PSY.CombinedCycleBlock, SharedHRSGHeatBalance},
)
    for constraint_type in get_duals(model)
        if !has_container_key(container, constraint_type, PSY.ThermalGen)
            throw(
                IS.InvalidValue(
                    "No constraint of type $(nameof(constraint_type)) is stored for " *
                    "CombinedCycleBlock; cannot assign a dual variable.",
                ),
            )
        end
        constraint = get_constraint(container, constraint_type, PSY.ThermalGen)
        add_dual_container!(
            container, constraint_type, PSY.ThermalGen,
            axes(constraint)[1], get_time_steps(container),
        )
    end
    return
end
