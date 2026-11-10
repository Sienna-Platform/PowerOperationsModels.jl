#=
`SharedHRSGHeatBalance` for `PSY.CombinedCycleBlock`.

Per block, heat recovery steam generator (HRSG) `h` with efficiency `η` and time step `t`,
with CTs `G_h`, CAs `S_h`, affine heat curves `a p + b u` in fuel units per hour, and `κ` the
heat equivalent of the electrical output:

    Q_h,t = η Σ_{g ∈ G_h} ((a_g − κ) p_g,t + b_g u_g,t)      recovered heat, inlined
    Σ_{s ∈ S_h} q_s,t ≤ Q_h,t                               HRSGHeatAllocationConstraint
    q_s,t = a_s p_s,t + b_s u_s,t                            HRSGHeatDrawConstraint
    u_s,t ≤ Σ_{g ∈ G_h} u_g,t                                CombinedCycleCommitmentConstraint

The commitment status `u` is the device's `OnVariable`, its `OnStatusParameter` under a
feedforward, or the constant 1 under a dispatch formulation; the commitment link is only
built for a CA whose status is not that constant.

The rows couple devices of possibly different concrete thermal types, so the constraint
containers are keyed on `PSY.ThermalGen`. The heat allocation `q` is keyed per concrete CA
type.
=#

const SUBTRACT_ELECTRICAL_OUTPUT_ATTRIBUTE = "subtract_electrical_output"

get_default_attributes(
    ::Type{PSY.CombinedCycleBlock},
    ::Type{SharedHRSGHeatBalance},
) = Dict{String, Any}(SUBTRACT_ELECTRICAL_OUTPUT_ATTRIBUTE => true)

# Build-time view of one CT or CA: its heat curve in the block's fuel units per hour against
# system-base power.
struct HeatUnit{D <: PSY.ThermalGen}
    device::D
    slope::Float64
    intercept::Float64
end

unit_name(unit::HeatUnit) = PSY.get_name(unit.device)

# One HRSG of a block, resolved from member ids to devices. `kappa` is the heat equivalent of
# one unit of system-base power per hour, in the block's fuel units.
struct HRSGData
    name::String
    efficiency::Float64
    kappa::Float64
    cts::Vector{HeatUnit}
    cas::Vector{HeatUnit}
end

hrsg_name(block::PSY.CombinedCycleBlock, hrsg_number::Int) =
    "$(PSY.get_name(block))__hrsg$(hrsg_number)"
heat_allocation_name(unit::HeatUnit, hrsg_number::Int) =
    "$(unit_name(unit))__hrsg$(hrsg_number)"
hrsg_unit_name(hrsg::HRSGData, unit::HeatUnit) = "$(hrsg.name)__$(unit_name(unit))"

hrsg_numbers(block::PSY.CombinedCycleBlock) = sort!(
    collect(union(keys(PSY.get_hrsg_ct_map(block)), keys(PSY.get_hrsg_ca_map(block)))),
)

# The block's members by id. PSY stores membership as ids; only `ThermalGen` can be a member.
function combined_cycle_members(sys::PSY.System, block::PSY.CombinedCycleBlock)
    members = PSY.get_associated_components(sys, block; component_type = PSY.ThermalGen)
    return Dict{Int, PSY.ThermalGen}(IS.get_id(d) => d for d in members)
end

# The affine heat-input curve of a member. Validation rejects every other cost shape before
# the build, so the fallbacks here are the loud backstop.
heat_curve(d::PSY.ThermalGen) = heat_curve(PSY.get_operation_cost(d), d)
heat_curve(cost::PSY.ThermalGenerationCost, d::PSY.ThermalGen) =
    heat_curve(PSY.get_variable_operation_cost(cost), d)
heat_curve(curve::PSY.FuelCurve{PSY.LinearCurve}, ::PSY.ThermalGen) = curve
heat_curve(cost, d::PSY.ThermalGen) = throw(
    IS.ConflictingInputsError(
        "$(PSY.get_name(d)) is a CombinedCycleBlock member but its variable cost is a " *
        "$(typeof(cost)); SharedHRSGHeatBalance needs a FuelCurve{LinearCurve}.",
    ),
)

function HeatUnit(d::PSY.ThermalGen, base_power::Float64)
    curve = heat_curve(d)
    value_curve = PSY.get_value_curve(curve)
    slope = get_proportional_cost_per_system_unit(
        PSY.get_proportional_term(value_curve),
        PSY.get_power_units(curve),
        base_power,
        PSY.get_base_power(d, u"NU"),
    )
    return HeatUnit(d, slope, PSY.get_constant_term(value_curve))
end

# Heat equivalent of one unit of system-base power per hour, or zero when the block's
# efficiency already nets the electrical output out of the exhaust.
function electrical_heat_per_system_unit(
    block::PSY.CombinedCycleBlock,
    by_id::Dict{Int, PSY.ThermalGen},
    base_power::Float64,
    subtract_electrical_output::Bool,
)
    subtract_electrical_output || return 0.0
    # Validation requires one fuel unit across the block, so any member's curve carries it.
    first_member = by_id[first(first(values(PSY.get_hrsg_ct_map(block))))]
    fuel_units = IS.get_fuel_units(heat_curve(first_member))
    return electrical_heat_equivalent(fuel_units) * base_power
end

function resolve_hrsgs(
    sys::PSY.System,
    block::PSY.CombinedCycleBlock,
    base_power::Float64,
    subtract_electrical_output::Bool,
)
    by_id = combined_cycle_members(sys, block)
    kappa = electrical_heat_per_system_unit(
        block, by_id, base_power, subtract_electrical_output,
    )
    efficiency = PSY.get_heat_recovery_to_steam_factor(block)
    ct_map = PSY.get_hrsg_ct_map(block)
    ca_map = PSY.get_hrsg_ca_map(block)
    return [
        HRSGData(
            hrsg_name(block, n),
            efficiency,
            kappa,
            [HeatUnit(by_id[id], base_power) for id in ct_map[n]],
            [HeatUnit(by_id[id], base_power) for id in ca_map[n]],
        ) for n in hrsg_numbers(block)
    ]
end

# Every HRSG of every block the plant model covers, with its HRSG number, in a deterministic
# (block name, HRSG number) order.
function resolve_hrsgs(
    container::OptimizationContainer,
    sys::PSY.System,
    model::PlantModel{PSY.CombinedCycleBlock, SharedHRSGHeatBalance},
)
    base_power = get_model_base_power(container)
    subtract = get_attribute(model, SUBTRACT_ELECTRICAL_OUTPUT_ATTRIBUTE)::Bool
    blocks = sort!(
        collect(PSY.get_supplemental_attributes(PSY.CombinedCycleBlock, sys));
        by = PSY.get_name,
    )
    hrsgs = Tuple{Int, HRSGData}[]
    for block in blocks
        for (n, hrsg) in zip(
            hrsg_numbers(block), resolve_hrsgs(sys, block, base_power, subtract))
            push!(hrsgs, (n, hrsg))
        end
    end
    return hrsgs
end

##################################### Variables ############################################

function add_heat_allocation_variables!(
    container::OptimizationContainer,
    hrsgs::Vector{Tuple{Int, HRSGData}},
)
    names_by_type = Dict{DataType, Vector{String}}()
    for (n, hrsg) in hrsgs, ca in hrsg.cas
        push!(get!(Vector{String}, names_by_type, typeof(ca.device)),
            heat_allocation_name(ca, n))
    end
    for (D, names) in names_by_type
        _add_heat_allocation_container!(container, D, names)
    end
    return
end

# Function barrier: `D` is concrete here, so the container key and the base names are typed.
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

##################################### Commitment ###########################################

# Whether a unit's commitment is a variable, a feedforward parameter, or the constant 1.
function commitment_status(
    container::OptimizationContainer,
    devices_template::DevicesModelContainer,
    unit::HeatUnit{D},
) where {D <: PSY.ThermalGen}
    W = get_formulation(devices_template[nameof(D)])
    return IOM._get_sos_value(container, W, unit.device)
end

commitment_is_constant(status::IOM.SOSStatusVariable.Value) =
    status == IOM.SOSStatusVariable.NO_VARIABLE

# The unit's commitment at `t`: `OnVariable`, `OnStatusParameter` entry, or `1.0`.
function unit_commitment(
    container::OptimizationContainer,
    status::IOM.SOSStatusVariable.Value,
    unit::HeatUnit{D},
    t::Int,
) where {D <: PSY.ThermalGen}
    return IOM._determine_bin_lhs(
        container, status, D, unit_name(unit), t;
        on_var_type = typeof(get_default_on_variable(unit.device)),
    )
end

unit_power(container::OptimizationContainer, unit::HeatUnit{D}, t::Int) where {D} =
    get_variable(container, ActivePowerVariable, D)[unit_name(unit), t]

heat_allocation(
    container::OptimizationContainer,
    unit::HeatUnit{D},
    hrsg_number::Int,
    t::Int,
) where {D} =
    get_variable(container, HRSGHeatAllocationVariable, D)[
        heat_allocation_name(unit, hrsg_number), t]

##################################### Constraints ##########################################

# `Q_h,t`, inlined into the rows that use it rather than stored as an expression.
function recovered_heat(
    container::OptimizationContainer,
    devices_template::DevicesModelContainer,
    hrsg::HRSGData,
    t::Int,
)
    expr = JuMP.AffExpr(0.0)
    for ct in hrsg.cts
        status = commitment_status(container, devices_template, ct)
        JuMP.add_to_expression!(
            expr, hrsg.efficiency * (ct.slope - hrsg.kappa), unit_power(container, ct, t))
        JuMP.add_to_expression!(
            expr, hrsg.efficiency * ct.intercept, unit_commitment(container, status, ct, t),
        )
    end
    return expr
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HRSGHeatAllocationConstraint},
    hrsgs::Vector{Tuple{Int, HRSGData}},
    devices_template::DevicesModelContainer,
)
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)
    constraint = add_constraints_container!(
        container, HRSGHeatAllocationConstraint, PSY.ThermalGen,
        [hrsg.name for (_, hrsg) in hrsgs], time_steps,
    )
    for (n, hrsg) in hrsgs, t in time_steps
        lhs = -recovered_heat(container, devices_template, hrsg, t)
        for ca in hrsg.cas
            JuMP.add_to_expression!(lhs, heat_allocation(container, ca, n, t))
        end
        constraint[hrsg.name, t] = JuMP.@constraint(jump_model, lhs <= 0.0)
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HRSGHeatDrawConstraint},
    hrsgs::Vector{Tuple{Int, HRSGData}},
    devices_template::DevicesModelContainer,
)
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)
    names = [hrsg_unit_name(hrsg, ca) for (_, hrsg) in hrsgs for ca in hrsg.cas]
    constraint = add_constraints_container!(
        container, HRSGHeatDrawConstraint, PSY.ThermalGen, names, time_steps)
    for (n, hrsg) in hrsgs, ca in hrsg.cas
        status = commitment_status(container, devices_template, ca)
        name = hrsg_unit_name(hrsg, ca)
        for t in time_steps
            lhs = JuMP.AffExpr(0.0)
            JuMP.add_to_expression!(lhs, heat_allocation(container, ca, n, t))
            JuMP.add_to_expression!(lhs, -ca.slope, unit_power(container, ca, t))
            JuMP.add_to_expression!(
                lhs,
                -ca.intercept,
                unit_commitment(container, status, ca, t),
            )
            constraint[name, t] = JuMP.@constraint(jump_model, lhs == 0.0)
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{CombinedCycleCommitmentConstraint},
    hrsgs::Vector{Tuple{Int, HRSGData}},
    devices_template::DevicesModelContainer,
)
    # A CA with a constant status has nothing to link; under a dispatch formulation this
    # drops the whole container.
    linked = Tuple{HRSGData, HeatUnit, IOM.SOSStatusVariable.Value}[]
    for (_, hrsg) in hrsgs, ca in hrsg.cas
        status = commitment_status(container, devices_template, ca)
        commitment_is_constant(status) || push!(linked, (hrsg, ca, status))
    end
    isempty(linked) && return
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)
    constraint = add_constraints_container!(
        container, CombinedCycleCommitmentConstraint, PSY.ThermalGen,
        [hrsg_unit_name(hrsg, ca) for (hrsg, ca, _) in linked], time_steps,
    )
    for (hrsg, ca, status) in linked
        name = hrsg_unit_name(hrsg, ca)
        ct_statuses =
            [commitment_status(container, devices_template, ct) for ct in hrsg.cts]
        for t in time_steps
            lhs = JuMP.AffExpr(0.0)
            JuMP.add_to_expression!(lhs, 1.0, unit_commitment(container, status, ca, t))
            for (ct, ct_status) in zip(hrsg.cts, ct_statuses)
                JuMP.add_to_expression!(
                    lhs,
                    -1.0,
                    unit_commitment(container, ct_status, ct, t),
                )
            end
            constraint[name, t] = JuMP.@constraint(jump_model, lhs <= 0.0)
        end
    end
    return
end

##################################### Duals ################################################

# Plant rows are keyed on the device family they couple, not on a concrete device type, so the
# dual mirrors every existing container of the requested constraint type.
function add_constraint_dual!(
    container::OptimizationContainer,
    ::PSY.System,
    model::PlantModel,
)
    isempty(get_duals(model)) && return
    time_steps = get_time_steps(container)
    for constraint_type in get_duals(model)
        keys_of_type = [
            key for key in IOM.get_constraint_keys(container) if
            get_entry_type(key) === constraint_type
        ]
        isempty(keys_of_type) && throw(
            IS.InvalidValue(
                "No constraint of type $(nameof(constraint_type)) is stored for " *
                "$(nameof(get_component_type(model))); cannot assign a dual variable.",
            ),
        )
        for key in keys_of_type
            existing = get_constraint(container, key)
            add_dual_container!(
                container, constraint_type, get_component_type(key),
                axes(existing)[1], time_steps; meta = key.meta,
            )
        end
    end
    return
end
