
# Note: Any future concrete formulation requires the definition of

# construct_device!(
#     ::OptimizationContainer,
#     ::PSY.System,
#     ::DeviceModel{<:PSY.ACTransmission, MyNewFormulation},
#     ::Union{Type{CopperPlatePowerModel}, Type{AreaBalancePowerModel}},
# ) = nothing

#

# Not implemented yet
# struct TapControl <: AbstractBranchFormulation end

#################################### Branch Variables ##################################################
# Because of the way we integrate with PowerModels, most of the time InfrastructureOptimizationModels will create variables
# for the branch flows either in AC or DC.

#! format: off
get_variable_binary(::Type{FlowActivePowerVariable}, ::Type{<:PSY.ACTransmission}, ::Type{<:AbstractBranchFormulation}) = false
get_variable_binary(::Type{FlowActivePowerFromToVariable}, ::Type{<:PSY.ACTransmission}, ::Type{<:AbstractBranchFormulation}) = false
get_variable_binary(::Type{FlowActivePowerToFromVariable}, ::Type{<:PSY.ACTransmission}, ::Type{<:AbstractBranchFormulation}) = false
get_variable_binary(::Type{FlowReactivePowerFromToVariable}, ::Type{<:PSY.ACTransmission}, ::Type{<:AbstractBranchFormulation}) = false
get_variable_binary(::Type{FlowReactivePowerToFromVariable}, ::Type{<:PSY.ACTransmission}, ::Type{<:AbstractBranchFormulation}) = false
get_variable_binary(::Type{PhaseShifterAngle}, ::Type{PSY.PhaseShiftingTransformer}, ::Type{<:AbstractBranchFormulation}) = false

get_parameter_multiplier(::Type{FixValueParameter}, ::PSY.ACTransmission, ::Type{<:AbstractBranchFormulation}) = 1.0
get_parameter_multiplier(::Type{LowerBoundValueParameter}, ::PSY.ACTransmission, ::Type{<:AbstractBranchFormulation}) = 1.0
get_parameter_multiplier(::Type{UpperBoundValueParameter}, ::PSY.ACTransmission, ::Type{<:AbstractBranchFormulation}) = 1.0

# Per-device reactance multiplier (1/get_x(d)) computed inline at add_to_expression! call sites.
get_variable_multiplier(::Type{PhaseShifterAngle}, ::Type{<:PSY.PhaseShiftingTransformer}, ::Type{PhaseAngleControl}) = 1.0

get_multiplier_value(::Type{<:AbstractDynamicBranchRatingTimeSeriesParameter}, d::PSY.ACTransmission, ::Type{StaticBranch}) = PSY.get_rating(d)
get_multiplier_value(::Type{<:AbstractDynamicBranchRatingTimeSeriesParameter}, d::PNM.BranchesParallel, ::Type{StaticBranch}) = PNM.get_equivalent_rating(d)


get_initial_conditions_device_model(::OperationModel, ::DeviceModel{T, U}) where {T <: PSY.ACTransmission, U <: AbstractBranchFormulation} = DeviceModel(T, U)

#### Properties of slack variables
get_variable_binary(::Type{FlowActivePowerSlackUpperBound}, ::Type{<:PSY.ACTransmission}, ::Type{<:AbstractBranchFormulation}) = false
get_variable_binary(::Type{FlowActivePowerSlackLowerBound}, ::Type{<:PSY.ACTransmission}, ::Type{<:AbstractBranchFormulation}) = false
# These two methods are defined to avoid ambiguities
get_variable_upper_bound(::Type{FlowActivePowerSlackUpperBound}, ::PSY.ACTransmission, ::Type{<:AbstractBranchFormulation}) = nothing
get_variable_lower_bound(::Type{FlowActivePowerSlackUpperBound}, ::PSY.ACTransmission, ::Type{<:AbstractBranchFormulation}) = 0.0
get_variable_upper_bound(::Type{FlowActivePowerSlackLowerBound}, ::PSY.ACTransmission, ::Type{<:AbstractBranchFormulation}) = nothing
get_variable_lower_bound(::Type{FlowActivePowerSlackLowerBound}, ::PSY.ACTransmission, ::Type{<:AbstractBranchFormulation}) = 0.0
get_variable_upper_bound(::Type{FlowActivePowerVariable}, ::PNM.BranchesSeries, ::Type{<:AbstractBranchFormulation}) = nothing
get_variable_lower_bound(::Type{FlowActivePowerVariable}, ::PNM.BranchesSeries, ::Type{<:AbstractBranchFormulation}) = nothing
get_variable_upper_bound(::Type{FlowActivePowerVariable}, ::PNM.BranchesParallel, ::Type{<:AbstractBranchFormulation}) = nothing
get_variable_lower_bound(::Type{FlowActivePowerVariable}, ::PNM.BranchesParallel, ::Type{<:AbstractBranchFormulation}) = nothing
get_variable_upper_bound(::Type{FlowActivePowerVariable}, ::PNM.ThreeWindingTransformerWinding, ::Type{<:AbstractBranchFormulation}) = nothing
get_variable_lower_bound(::Type{FlowActivePowerVariable}, ::PNM.ThreeWindingTransformerWinding, ::Type{<:AbstractBranchFormulation}) = nothing

# Active-flow variable bounds for native ACPPowerModel: matches the bridge convention so
# `check_variable_bounded(...)` in test_device_branch_constructors.jl finds box bounds on
# directional flow variables. Reactive-flow variables stay unbounded (default `nothing`).
get_variable_upper_bound(::Type{FlowActivePowerFromToVariable}, d::PSY.MonitoredLine, ::Type{<:AbstractBranchFormulation}) = PSY.get_flow_limits(d).from_to
get_variable_lower_bound(::Type{FlowActivePowerFromToVariable}, d::PSY.MonitoredLine, ::Type{<:AbstractBranchFormulation}) = -1 * PSY.get_flow_limits(d).from_to
get_variable_upper_bound(::Type{FlowActivePowerToFromVariable}, d::PSY.MonitoredLine, ::Type{<:AbstractBranchFormulation}) = PSY.get_flow_limits(d).to_from
get_variable_lower_bound(::Type{FlowActivePowerToFromVariable}, d::PSY.MonitoredLine, ::Type{<:AbstractBranchFormulation}) = -1 * PSY.get_flow_limits(d).to_from
get_variable_upper_bound(::Type{FlowActivePowerFromToVariable}, d::Union{PSY.TapTransformer, PSY.Transformer2W}, ::Type{<:AbstractBranchFormulation}) = PSY.get_rating(d)
get_variable_lower_bound(::Type{FlowActivePowerFromToVariable}, d::Union{PSY.TapTransformer, PSY.Transformer2W}, ::Type{<:AbstractBranchFormulation}) = -1 * PSY.get_rating(d)
get_variable_upper_bound(::Type{FlowActivePowerToFromVariable}, d::Union{PSY.TapTransformer, PSY.Transformer2W}, ::Type{<:AbstractBranchFormulation}) = PSY.get_rating(d)
get_variable_lower_bound(::Type{FlowActivePowerToFromVariable}, d::Union{PSY.TapTransformer, PSY.Transformer2W}, ::Type{<:AbstractBranchFormulation}) = -1 * PSY.get_rating(d)

#! format: on
function get_default_time_series_names(
    ::Type{U},
    ::Type{V},
) where {U <: PSY.ACTransmission, V <: AbstractBranchFormulation}
    return Dict{Type{<:TimeSeriesParameter}, String}(
        DynamicBranchRatingTimeSeriesParameter => "dynamic_line_ratings",
    )
end

function get_default_attributes(
    ::Type{U},
    ::Type{V},
) where {U <: PSY.ACTransmission, V <: AbstractBranchFormulation}
    return Dict{String, Any}()
end
#################################### Flow Variable Bounds ##################################################

function add_variables!(
    container::OptimizationContainer,
    ::Type{T},
    network_model::NetworkModel{<:AbstractPTDFModel},
    devices::IS.FlattenIteratorWrapper{U},
    ::Type{F},
) where {
    T <: AbstractACActivePowerFlow,
    U <: PSY.ACTransmission,
    F <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    net_reduction_data = network_model.network_reduction
    branch_names = get_branch_argument_variable_axis(net_reduction_data, devices)
    reduced_branch_tracker = get_reduced_branch_tracker(network_model)
    all_branch_maps_by_type = PNM.get_all_branch_maps_by_type(net_reduction_data)

    variable_container = add_variable_container!(
        container,
        T,
        U,
        branch_names,
        time_steps,
    )

    for (name, (arc, reduction)) in PNM.get_name_to_arc_map(net_reduction_data, U)
        # TODO: entry is not type stable here, it can return any type ACTransmission.
        # It might have performance implications. Possibly separate this into other functions
        reduction_entry = all_branch_maps_by_type[reduction][U][arc]
        has_entry, tracker_container = search_for_reduced_branch_argument!(
            reduced_branch_tracker,
            arc,
            T,
        )
        if has_entry
            @assert !isempty(tracker_container) name arc reduction
        end
        ub = get_variable_upper_bound(T, reduction_entry, F)
        lb = get_variable_lower_bound(T, reduction_entry, F)
        for t in time_steps
            if !has_entry
                tracker_container[t] = JuMP.@variable(
                    get_jump_model(container),
                    base_name = "$(T)_$(U)_$(reduction)_{$(name), $(t)}",
                )
                ub !== nothing && JuMP.set_upper_bound(tracker_container[t], ub)
                lb !== nothing && JuMP.set_lower_bound(tracker_container[t], lb)
            end
            variable_container[name, t] = tracker_container[t]
        end
    end
    return
end

function add_variables!(
    ::OptimizationContainer,
    ::Type{T},
    network_model::NetworkModel{<:AbstractPTDFModel},
    devices::IS.FlattenIteratorWrapper{U},
    ::Type{StaticBranchUnbounded},
) where {
    T <: AbstractACActivePowerFlow,
    U <: PSY.ACTransmission}
    @debug "PTDF Branch Flows with StaticBranchUnbounded do not require flow variables $T. Flow values are given by PTDFBranchFlow expression."
    return
end

function _add_variable_to_container!(
    variable_container::JuMPVariableArray,
    variable::JuMP.VariableRef,
    entry::T,
    ::Type{U},
    t,
) where {T <: PSY.ACTransmission, U <: PSY.ACTransmission}
    if isa(entry, U)
        name = PSY.get_name(entry)
        variable_container[name, t] = variable
    end
end

function _add_variable_to_container!(
    variable_container::JuMPVariableArray,
    variable::JuMP.VariableRef,
    double_circuit::Set{T},
    ::Type{T},
    t,
) where {T <: PSY.ACTransmission}
    for circuit in double_circuit
        if isa(circuit, T)
            name = PSY.get_name(circuit) * "_double_circuit"
            variable_container[name, t] = variable
        end
    end
    return
end

function _add_variable_to_container!(
    variable_container::JuMPVariableArray,
    variable::JuMP.VariableRef,
    series_chain::Vector{Any},
    type::Type{T},
    t,
) where {T <: PSY.ACTransmission}
    for segment in series_chain
        _add_variable_to_container!(variable_container, variable, segment, type, t)
    end
end

function add_variables!(
    container::OptimizationContainer,
    ::Type{S},
    network_model::NetworkModel{CopperPlatePowerModel},
    devices::IS.FlattenIteratorWrapper{T},
    ::Type{U},
) where {
    S <: AbstractACActivePowerFlow,
    T <: PSY.ACTransmission,
    U <: AbstractBranchFormulation,
}
    @debug "AC Branches of type $(T) do not require flow variables $S in CopperPlatePowerModel."
    return
end

function _get_flow_variable_vector(
    container::OptimizationContainer,
    ::NetworkModel{<:AbstractDCPModel},
    ::Type{B},
) where {B <: PSY.ACTransmission}
    return [get_variable(container, FlowActivePowerVariable, B)]
end

function _get_flow_variable_vector(
    container::OptimizationContainer,
    ::NetworkModel{<:AbstractPowerModel},
    ::Type{B},
) where {B <: PSY.ACTransmission}
    return [
        get_variable(container, FlowActivePowerFromToVariable, B),
        get_variable(container, FlowActivePowerToFromVariable, B),
    ]
end

function branch_rate_bounds!(
    container::OptimizationContainer,
    ::DeviceModel{B, T},
    network_model::NetworkModel{<:AbstractPowerModel},
) where {B <: PSY.ACTransmission, T <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    net_reduction_data = get_network_reduction(network_model)
    all_branch_maps_by_type = net_reduction_data.all_branch_maps_by_type
    for var in _get_flow_variable_vector(container, network_model, B)
        for (name, (arc, reduction)) in PNM.get_name_to_arc_map(net_reduction_data, B)
            # TODO: entry is not type stable here, it can return any type ACTransmission.
            # It might have performance implications. Possibly separate this into other functions
            reduction_entry = all_branch_maps_by_type[reduction][B][arc]
            # Use the same limit values as FlowRateConstraint for consistency.
            limits = get_min_max_limits(reduction_entry, FlowRateConstraint, T)
            for t in time_steps
                @assert limits.min <= limits.max "Infeasible rate limits for branch $(name)"
                JuMP.set_upper_bound(var[name, t], limits.max)
                JuMP.set_lower_bound(var[name, t], limits.min)
            end
        end
    end
    return
end

################################## PWL Loss Variables ##################################

function _check_pwl_loss_model(devices)
    first_loss = PSY.get_loss(first(devices))
    first_loss_type = typeof(first_loss)
    for d in devices
        loss = PSY.get_loss(d)
        if !isa(loss, first_loss_type)
            error(
                "Not all TwoTerminal HVDC lines have the same loss model data. Check that all loss models are LinearCurve or PiecewiseIncrementalCurve",
            )
        end
        if isa(first_loss, PSY.PiecewiseIncrementalCurve)
            len_first_loss = length(PSY.get_slopes(first_loss))
            len_loss = length(PSY.get_slopes(loss))
            if len_first_loss != len_loss
                error(
                    "Different length of PWL segments for TwoTerminal HVDC losses are not supported. Check that all HVDC data have the same amount of PWL segments.",
                )
            end
        end
    end
    return
end

################################## Rate Limits constraint_infos ############################

function get_rating(double_circuit::PNM.BranchesParallel)
    return sum([PSY.get_rating(circuit) for circuit in double_circuit])
end
function get_rating(series_chain::PNM.BranchesSeries)
    return minimum([get_rating(segment) for segment in series_chain])
end
function get_rating(device::T) where {T <: PSY.ACTransmission}
    return PSY.get_rating(device)
end
function get_rating(
    device::PNM.ThreeWindingTransformerWinding{T},
) where {T <: PSY.ThreeWindingTransformer}
    return PNM.get_equivalent_rating(device)
end

"""
Min and max limits for Abstract Branch Formulation
"""
function get_min_max_limits(
    double_circuit::PNM.BranchesParallel{<:PSY.ACTransmission},
    constraint_type::Type{<:ConstraintType},
    branch_formulation::Type{<:AbstractBranchFormulation},
) #  -> Union{Nothing, NamedTuple{(:min, :max), Tuple{Float64, Float64}}}
    min_max_by_circuit = [
        get_min_max_limits(device, constraint_type, branch_formulation) for
        device in double_circuit
    ]
    min_by_circuit = [x.min for x in min_max_by_circuit]
    max_by_circuit = [x.max for x in min_max_by_circuit]
    # Limit by most restictive circuit:
    return (min = maximum(min_by_circuit), max = minimum(max_by_circuit))
end

"""
Min and max limits for Abstract Branch Formulation
"""
function get_min_max_limits(
    transformer_entry::PNM.ThreeWindingTransformerWinding,
    constraint_type::Type{<:ConstraintType},
    branch_formulation::Type{<:AbstractBranchFormulation},
) #  -> Union{Nothing, NamedTuple{(:min, :max), Tuple{Float64, Float64}}}
    transformer = PNM.get_transformer(transformer_entry)
    winding_number = PNM.get_winding_number(transformer_entry)
    if winding_number == 1
        limits = (
            min = -1 * PSY.get_rating_primary(transformer),
            max = PSY.get_rating_primary(transformer),
        )
    elseif winding_number == 2
        limits = (
            min = -1 * PSY.get_rating_secondary(transformer),
            max = PSY.get_rating_secondary(transformer),
        )
    elseif winding_number == 3
        limits = (
            min = -1 * PSY.get_rating_tertiary(transformer),
            max = PSY.get_rating_tertiary(transformer),
        )
    end
    return limits
end

"""
Min and max limits for Abstract Branch Formulation
"""
function get_min_max_limits(
    series_chain::PNM.BranchesSeries,
    constraint_type::Type{<:ConstraintType},
    branch_formulation::Type{<:AbstractBranchFormulation},
) #  -> Union{Nothing, NamedTuple{(:min, :max), Tuple{Float64, Float64}}}
    min_max_by_segment = [
        get_min_max_limits(segment, constraint_type, branch_formulation) for
        segment in series_chain
    ]
    min_by_segment = [x.min for x in min_max_by_segment]
    max_by_segment = [x.max for x in min_max_by_segment]
    # Limit by most restictive segment:
    return (min = maximum(min_by_segment), max = minimum(max_by_segment))
end

"""
Min and max limits for Abstract Branch Formulation
"""
function get_min_max_limits(
    device::PSY.ACTransmission,
    ::Type{<:ConstraintType},
    ::Type{<:AbstractBranchFormulation},
) #  -> Union{Nothing, NamedTuple{(:min, :max), Tuple{Float64, Float64}}}
    return (min = -1 * PSY.get_rating(device), max = PSY.get_rating(device))
end

"""
Min and max limits for Abstract Branch Formulation
"""
function get_min_max_limits(
    ::PSY.PhaseShiftingTransformer,
    ::Type{PhaseAngleControlLimit},
    ::Type{PhaseAngleControl},
) #  -> Union{Nothing, NamedTuple{(:min, :max), Tuple{Float64, Float64}}}
    return (min = -π / 2, max = π / 2)
end

function _add_flow_rate_constraint!(
    container::OptimizationContainer,
    ::Type{T},
    arc::Tuple{Int, Int},
    use_slacks::Bool,
    con_lb::DenseAxisArray,
    con_ub::DenseAxisArray,
    var::DenseAxisArray,
    branch_maps_by_type::Dict,
    name::String,
) where {T <: PSY.ACTransmission}
    reduction_entry = branch_maps_by_type[arc]
    time_steps = get_time_steps(container)
    if use_slacks
        slack_ub = get_variable(container, FlowActivePowerSlackUpperBound, T)[name, :]
        slack_lb = get_variable(container, FlowActivePowerSlackLowerBound, T)[name, :]
    end
    limits = get_min_max_limits(reduction_entry, FlowRateConstraint, StaticBranch)
    for t in time_steps
        con_ub[name, t] =
            JuMP.@constraint(
                get_jump_model(container),
                var[name, t] - (use_slacks ? slack_ub[t] : 0.0) <= limits.max
            )
        con_lb[name, t] =
            JuMP.@constraint(
                get_jump_model(container),
                var[name, t] + (use_slacks ? slack_lb[t] : 0.0) >= limits.min
            )
    end
    return
end

"""
Add branch rate limit constraints for ACBranch with AbstractActivePowerModel
"""
function add_constraints!(
    container::OptimizationContainer,
    cons_type::Type{FlowRateConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    device_model::DeviceModel{T, U},
    network_model::NetworkModel{V},
) where {
    T <: PSY.ACTransmission,
    U <: AbstractBranchFormulation,
    V <: AbstractActivePowerModel,
}
    time_steps = get_time_steps(container)
    net_reduction_data = network_model.network_reduction
    reduced_branch_tracker = get_reduced_branch_tracker(network_model)
    branch_names = get_branch_argument_constraint_axis(
        net_reduction_data,
        reduced_branch_tracker,
        devices,
        cons_type,
    )
    all_branch_maps_by_type = PNM.get_all_branch_maps_by_type(net_reduction_data)

    con_lb =
        add_constraints_container!(
            container,
            cons_type,
            T,
            branch_names,
            time_steps;
            meta = "lb",
        )
    con_ub =
        add_constraints_container!(
            container,
            cons_type,
            T,
            branch_names,
            time_steps;
            meta = "ub",
        )

    array = get_variable(container, FlowActivePowerVariable, T)

    use_slacks = get_use_slacks(device_model)
    if use_slacks
        slack_ub = get_variable(container, FlowActivePowerSlackUpperBound, T)
        slack_lb = get_variable(container, FlowActivePowerSlackLowerBound, T)
    end
    for (name, (arc, reduction)) in
        get_constraint_map_by_type(reduced_branch_tracker)[FlowRateConstraint][T]
        _add_flow_rate_constraint!(
            container,
            T,
            arc,
            use_slacks,
            con_lb,
            con_ub,
            array,
            all_branch_maps_by_type[reduction][T],
            name,
        )
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    cons_type::Type{FlowRateConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    device_model::DeviceModel{T, U},
    network_model::NetworkModel{V},
) where {
    T <: PSY.ACTransmission,
    U <: AbstractBranchFormulation,
    V <: AbstractPTDFModel,
}
    time_steps = get_time_steps(container)
    net_reduction_data = network_model.network_reduction
    reduced_branch_tracker = get_reduced_branch_tracker(network_model)
    branch_names = get_branch_argument_constraint_axis(
        net_reduction_data,
        reduced_branch_tracker,
        devices,
        cons_type,
    )
    all_branch_maps_by_type = PNM.get_all_branch_maps_by_type(net_reduction_data)

    con_lb =
        add_constraints_container!(
            container,
            cons_type,
            T,
            branch_names,
            time_steps;
            meta = "lb",
        )
    con_ub =
        add_constraints_container!(
            container,
            cons_type,
            T,
            branch_names,
            time_steps;
            meta = "ub",
        )

    array = get_expression(container, PTDFBranchFlow, T)

    use_slacks = get_use_slacks(device_model)
    if use_slacks
        slack_ub = get_variable(container, FlowActivePowerSlackUpperBound, T)
        slack_lb = get_variable(container, FlowActivePowerSlackLowerBound, T)
    end
    for (name, (arc, reduction)) in
        get_constraint_map_by_type(reduced_branch_tracker)[FlowRateConstraint][T]
        _add_flow_rate_constraint!(
            container,
            T,
            arc,
            use_slacks,
            con_lb,
            con_ub,
            array,
            all_branch_maps_by_type[reduction][T],
            name,
        )
    end
    return
end

function _add_flow_rate_constraint_with_parameters!(
    container::OptimizationContainer,
    ::Type{T},
    arc::Tuple{Int, Int},
    use_slacks::Bool,
    con_lb::DenseAxisArray,
    con_ub::DenseAxisArray,
    var::DenseAxisArray,
    branch_maps_by_type::Dict,
    name::String,
    ts_name::String,
) where {T <: PSY.ACTransmission}
    time_steps = get_time_steps(container)
    if use_slacks
        slack_ub = get_variable(container, FlowActivePowerSlackUpperBound, T)[name, :]
        slack_lb = get_variable(container, FlowActivePowerSlackLowerBound, T)[name, :]
    end
    param_container =
        get_parameter(container, DynamicBranchRatingTimeSeriesParameter, T)
    param = get_parameter_column_refs(param_container, name)
    mult = get_multiplier_array(param_container)[name, :]

    for t in time_steps
        @debug "Dynamic Branch Rating applied for branch $(name) at time step $(t)"
        con_ub[name, t] =
            JuMP.@constraint(
                get_jump_model(container),
                var[name, t] - (use_slacks ? slack_ub[t] : 0.0) <= param[t] * mult[t]
            )
        con_lb[name, t] =
            JuMP.@constraint(
                get_jump_model(container),
                var[name, t] + (use_slacks ? slack_lb[t] : 0.0) >=
                -1.0 * param[t] * mult[t]
            )
    end
    return
end

function add_flow_rate_constraint_with_parameters!(
    container::OptimizationContainer,
    cons_type::Type{FlowRateConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    device_model::DeviceModel{T, U},
    network_model::NetworkModel{V},
) where {
    T <: PSY.ACTransmission,
    U <: StaticBranch,
    V <: AbstractPTDFModel,
}
    time_steps = get_time_steps(container)
    net_reduction_data = network_model.network_reduction
    reduced_branch_tracker = get_reduced_branch_tracker(network_model)

    branch_names = get_branch_argument_constraint_axis(
        net_reduction_data,
        reduced_branch_tracker,
        devices,
        cons_type,
    )

    all_branch_maps_by_type = PNM.get_all_branch_maps_by_type(net_reduction_data)

    con_lb =
        add_constraints_container!(
            container,
            cons_type,
            T,
            branch_names,
            time_steps;
            meta = "lb",
        )
    con_ub =
        add_constraints_container!(
            container,
            cons_type,
            T,
            branch_names,
            time_steps;
            meta = "ub",
        )

    var_array = get_expression(container, PTDFBranchFlow, T)

    ts_name = get_time_series_names(device_model)[DynamicBranchRatingTimeSeriesParameter]
    ts_type = get_default_time_series_type(container)
    use_slacks = get_use_slacks(device_model)
    for (name, (arc, reduction)) in
        get_constraint_map_by_type(reduced_branch_tracker)[FlowRateConstraint][T]
        if PNM.has_time_series(
            all_branch_maps_by_type[reduction][T][arc],
            ts_type,
            ts_name,
        )
            _add_flow_rate_constraint_with_parameters!(
                container,
                T,
                arc,
                use_slacks,
                con_lb,
                con_ub,
                var_array,
                all_branch_maps_by_type[reduction][T],
                name,
                ts_name,
            )
        else
            _add_flow_rate_constraint!(
                container,
                T,
                arc,
                use_slacks,
                con_lb,
                con_ub,
                var_array,
                all_branch_maps_by_type[reduction][T],
                name,
            )
        end
    end
    return
end

"""
Add rate limit from to constraints for ACBranch with AbstractPowerModel
"""
function add_constraints!(
    container::OptimizationContainer,
    cons_type::Type{FlowRateConstraintFromTo},
    devices::IS.FlattenIteratorWrapper{B},
    device_model::DeviceModel{B, <:AbstractBranchFormulation},
    network_model::NetworkModel{T},
) where {B <: PSY.ACTransmission, T <: AbstractPowerModel}
    reduced_branch_tracker = get_reduced_branch_tracker(network_model)
    net_reduction_data = get_network_reduction(network_model)
    all_branch_maps_by_type = net_reduction_data.all_branch_maps_by_type
    device_names = get_branch_argument_constraint_axis(
        net_reduction_data,
        reduced_branch_tracker,
        devices,
        cons_type,
    )
    time_steps = get_time_steps(container)
    var1 = get_variable(container, FlowActivePowerFromToVariable, B)
    var2 = get_variable(container, FlowReactivePowerFromToVariable, B)
    add_constraints_container!(
        container,
        cons_type,
        B,
        device_names,
        time_steps,
    )
    constraint = get_constraint(container, cons_type, B)

    use_slacks = get_use_slacks(device_model)
    if use_slacks
        slack_ub = get_variable(container, FlowActivePowerSlackUpperBound, B)
    end
    for (name, (arc, reduction)) in
        get_constraint_map_by_type(reduced_branch_tracker)[FlowRateConstraintFromTo][B]
        # TODO: entry is not type stable here, it can return any type ACTransmission.
        # It might have performance implications. Possibly separate this into other functions
        reduction_entry = all_branch_maps_by_type[reduction][B][arc]
        branch_rate = get_rating(reduction_entry)
        for t in time_steps
            constraint[name, t] = JuMP.@constraint(
                get_jump_model(container),
                var1[name, t]^2 + var2[name, t]^2 -
                (use_slacks ? slack_ub[name, t] : 0.0) <= branch_rate^2
            )
        end
    end
    return
end

"""
Add rate limit to from constraints for ACBranch with AbstractPowerModel
"""
function add_constraints!(
    container::OptimizationContainer,
    cons_type::Type{FlowRateConstraintToFrom},
    devices::IS.FlattenIteratorWrapper{B},
    device_model::DeviceModel{B, <:AbstractBranchFormulation},
    network_model::NetworkModel{T},
) where {B <: PSY.ACTransmission, T <: AbstractPowerModel}
    reduced_branch_tracker = get_reduced_branch_tracker(network_model)
    net_reduction_data = get_network_reduction(network_model)
    all_branch_maps_by_type = net_reduction_data.all_branch_maps_by_type
    time_steps = get_time_steps(container)
    device_names = get_branch_argument_constraint_axis(
        net_reduction_data,
        reduced_branch_tracker,
        devices,
        cons_type,
    )
    var1 = get_variable(container, FlowActivePowerToFromVariable, B)
    var2 = get_variable(container, FlowReactivePowerToFromVariable, B)
    add_constraints_container!(
        container,
        cons_type,
        B,
        device_names,
        time_steps,
    )
    constraint = get_constraint(container, cons_type, B)
    use_slacks = get_use_slacks(device_model)
    if use_slacks
        slack_ub = get_variable(container, FlowActivePowerSlackUpperBound, B)
    end
    for (name, (arc, reduction)) in
        get_constraint_map_by_type(reduced_branch_tracker)[FlowRateConstraintToFrom][B]
        # TODO: entry is not type stable here, it can return any type ACTransmission.
        # It might have performance implications. Possibly separate this into other functions
        reduction_entry = all_branch_maps_by_type[reduction][B][arc]
        branch_rate = get_rating(reduction_entry)
        for t in time_steps
            constraint[name, t] = JuMP.@constraint(
                get_jump_model(container),
                var1[name, t]^2 + var2[name, t]^2 -
                (use_slacks ? slack_ub[name, t] : 0.0) <= branch_rate^2
            )
        end
    end
    return
end

function _make_flow_expressions!(
    name::String,
    time_steps::UnitRange{Int},
    ptdf_col::Vector{Float64},
    nodal_balance_expressions::Matrix{JuMP.AffExpr},
)
    @debug "Making Flow Expression on thread $(Threads.threadid()) for branch $name"
    nz_idx = [i for i in eachindex(ptdf_col) if abs(ptdf_col[i]) > PTDF_ZERO_TOL]
    hint = length(nz_idx)
    expressions = Vector{JuMP.AffExpr}(undef, length(time_steps))
    for t in time_steps
        acc = IOM.get_hinted_aff_expr(hint)
        @inbounds for i in nz_idx
            JuMP.add_to_expression!(acc, ptdf_col[i], nodal_balance_expressions[i, t])
        end
        expressions[t] = acc
    end
    return name, expressions
end

function _make_flow_expressions!(
    name::String,
    time_steps::UnitRange{Int},
    ptdf_col::SparseArrays.SparseVector{Float64, Int},
    nodal_balance_expressions::Matrix{JuMP.AffExpr},
)
    @debug "Making Flow Expression on thread $(Threads.threadid()) for branch $name"
    nz_idx = SparseArrays.nonzeroinds(ptdf_col)
    nz_val = SparseArrays.nonzeros(ptdf_col)
    hint = length(nz_idx)
    expressions = Vector{JuMP.AffExpr}(undef, length(time_steps))
    for t in time_steps
        acc = IOM.get_hinted_aff_expr(hint)
        @inbounds for k in eachindex(nz_idx)
            JuMP.add_to_expression!(
                acc,
                nz_val[k],
                nodal_balance_expressions[nz_idx[k], t],
            )
        end
        expressions[t] = acc
    end
    return name, expressions
end

function _add_expression_to_container!(
    branch_flow_expr::JuMPAffineExpressionDArrayStringInt,
    jump_model::JuMP.Model,
    time_steps::UnitRange{Int},
    ptdf_col::AbstractVector{Float64},
    nodal_balance_expressions::JuMPAffineExpressionDArrayIntInt,
    reduction_entry::T,
    branches::Vector{String},
) where {T <: PSY.ACTransmission}
    name = PSY.get_name(reduction_entry)
    if name in branches
        branch_flow_expr[name, :] .= _make_flow_expressions!(
            name,
            time_steps,
            ptdf_col,
            nodal_balance_expressions.data,
        )
    end
    return
end

function _add_expression_to_container!(
    branch_flow_expr::JuMPAffineExpressionDArrayStringInt,
    jump_model::JuMP.Model,
    time_steps::UnitRange{Int},
    ptdf_col::AbstractVector{Float64},
    nodal_balance_expressions::JuMPAffineExpressionDArrayIntInt,
    reduction_entry::Vector{Any},
    branches::Vector{String},
)
    names = _get_branch_names(reduction_entry)
    for name in names
        if name in branches
            branch_flow_expr[name, :] .= _make_flow_expressions!(
                name,
                time_steps,
                ptdf_col,
                nodal_balance_expressions.data,
            )
            #Only one constraint added per arc; once it is found can return
            return
        end
    end
end

function _add_expression_to_container!(
    branch_flow_expr::JuMPAffineExpressionDArrayStringInt,
    jump_model::JuMP.Model,
    time_steps::UnitRange{Int},
    ptdf_col::AbstractVector{Float64},
    nodal_balance_expressions::JuMPAffineExpressionDArrayIntInt,
    reduction_entry::Set{PSY.ACTransmission},
    branches::Vector{String},
)
    names = _get_branch_names(reduction_entry)
    for name in names
        if name in branches
            branch_flow_expr[name, :] .= _make_flow_expressions!(
                name,
                time_steps,
                ptdf_col,
                nodal_balance_expressions.data,
            )
            #Only one constraint added per arc; once it is found can return
            return
        end
    end
end

function add_expressions!(
    container::OptimizationContainer,
    ::Type{PTDFBranchFlow},
    devices::IS.FlattenIteratorWrapper{B},
    model::DeviceModel{B, <:AbstractBranchFormulation},
    network_model::NetworkModel{<:AbstractPTDFModel},
) where {B <: PSY.ACTransmission}
    time_steps = get_time_steps(container)
    ptdf = get_PTDF_matrix(network_model)
    net_reduction_data = network_model.network_reduction
    # This might need to be changed to something else
    branch_names = get_branch_argument_variable_axis(net_reduction_data, devices)
    # Needs to be a vector to use multi-threading
    name_to_arc_map = collect(PNM.get_name_to_arc_map(net_reduction_data, B))
    nodal_balance_expressions = get_expression(container, ActivePowerBalance,
        PSY.ACBus,
    )

    branch_flow_expr = add_expression_container!(container, PTDFBranchFlow,
        B,
        branch_names,
        time_steps,
    )

    tasks = map(name_to_arc_map) do pair
        (name, (arc, _)) = pair
        ptdf_col = ptdf[arc, :]
        Threads.@spawn _make_flow_expressions!(
            name,
            time_steps,
            ptdf_col,
            nodal_balance_expressions.data,
        )
    end
    for task in tasks
        name, expressions = fetch(task)
        branch_flow_expr[name, :] .= expressions
    end
    #= Leaving serial code commented out for debugging purposes in the future
    for (name, (arc, reduction)) in name_to_arc_map
        reduction_entry = all_branch_maps_by_type[reduction][B][arc]
        network_reduction_map = all_branch_maps_by_type[map]
        !haskey(network_reduction_map, branch_Type) && continue
        for (arc_tuple, reduction_entry) in network_reduction_map[branch_Type]
            ptdf_col = ptdf[arc_tuple, :]
            _add_expression_to_container!(
                branch_flow_expr,
                jump_model,
                time_steps,
                ptdf_col,
                nodal_balance_expressions,
                reduction_entry,
                name,
            )
        end
    end
    =#
    return
end

"""
Add network flow constraints for ACBranch and NetworkModel with <: AbstractPTDFModel
"""
function add_constraints!(
    container::OptimizationContainer,
    cons_type::Type{NetworkFlowConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    device_model::DeviceModel{T, StaticBranchBounds},
    network_model::NetworkModel{<:AbstractPTDFModel},
) where {T <: PSY.ACTransmission}
    time_steps = get_time_steps(container)
    branch_flow_expr = get_expression(container, PTDFBranchFlow, T)
    flow_variables = get_variable(container, FlowActivePowerVariable, T)
    net_reduction_data = network_model.network_reduction
    reduced_branch_tracker = get_reduced_branch_tracker(network_model)
    branches = get_branch_argument_constraint_axis(
        net_reduction_data,
        reduced_branch_tracker,
        devices,
        cons_type,
    )
    branch_flow = add_constraints_container!(container, NetworkFlowConstraint,
        T,
        branches,
        time_steps,
    )
    jump_model = get_jump_model(container)

    use_slacks = get_use_slacks(device_model)
    if use_slacks
        slack_ub = get_variable(container, FlowActivePowerSlackUpperBound, T)
        slack_lb = get_variable(container, FlowActivePowerSlackLowerBound, T)
    end

    for name in branches
        for t in time_steps
            branch_flow[name, t] = JuMP.@constraint(
                jump_model,
                branch_flow_expr[name, t] -
                flow_variables[name, t]
                ==
                (use_slacks ? slack_ub[name, t] - slack_lb[name, t] : 0.0)
            )
        end
    end
    return
end

function add_constraints!(
    ::OptimizationContainer,
    cons_type::Type{NetworkFlowConstraint},
    ::IS.FlattenIteratorWrapper{B},
    ::DeviceModel{B, T},
    ::NetworkModel{<:AbstractPTDFModel},
) where {B <: PSY.ACTransmission, T <: Union{StaticBranchUnbounded, StaticBranch}}
    @debug "PTDF Branch Flows with $T do not require network flow constraints $cons_type. Flow values are given by PTDFBranchFlow."
    return
end

"""
Add network flow constraints for PhaseShiftingTransformer and NetworkModel with <: AbstractPTDFModel
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{NetworkFlowConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    model::DeviceModel{T, PhaseAngleControl},
    network_model::NetworkModel{<:AbstractPTDFModel},
) where {T <: PSY.PhaseShiftingTransformer}
    ptdf = get_PTDF_matrix(network_model)
    branches = PSY.get_name.(devices)
    time_steps = get_time_steps(container)
    branch_flow = add_constraints_container!(container, NetworkFlowConstraint,
        T,
        branches,
        time_steps,
    )
    nodal_balance_expressions = get_expression(container, ActivePowerBalance, PSY.ACBus)
    flow_variables = get_variable(container, FlowActivePowerVariable, T)
    angle_variables = get_variable(container, PhaseShifterAngle, T)
    jump_model = get_jump_model(container)
    for br in devices
        arc = PNM.get_arc_tuple(br)
        name = PSY.get_name(br)
        ptdf_col = ptdf[arc, :]
        inv_x = 1 / PSY.get_x(br)
        for t in time_steps
            branch_flow[name, t] = JuMP.@constraint(
                jump_model,
                sum(
                    ptdf_col[i] * nodal_balance_expressions.data[i, t] for
                    i in 1:length(ptdf_col)
                ) + inv_x * angle_variables[name, t] - flow_variables[name, t] == 0.0
            )
        end
    end
    return
end

"""
Min and max limits for monitored line
"""
function get_min_max_limits(
    device::PSY.MonitoredLine,
    ::Type{<:ConstraintType},
    ::Type{<:AbstractBranchFormulation},
)
    if PSY.get_flow_limits(device).to_from != PSY.get_flow_limits(device).from_to
        @warn(
            "Flow limits in Line $(PSY.get_name(device)) aren't equal. The minimum will be used in formulation $(T)"
        )
    end
    limit = min(
        PSY.get_rating(device),
        PSY.get_flow_limits(device).to_from,
        PSY.get_flow_limits(device).from_to,
    )
    minmax = (min = -1 * limit, max = limit)
    return minmax
end

############################## Flow Limits Constraints #####################################
"""
Add branch flow constraints for monitored lines with DC Power Model
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{FlowLimitConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    model::DeviceModel{T, U},
    ::NetworkModel{V},
) where {
    T <: Union{PSY.PhaseShiftingTransformer, PSY.MonitoredLine},
    U <: AbstractBranchFormulation,
    V <: AbstractDCPModel,
}
    add_range_constraints!(
        container,
        FlowLimitConstraint,
        FlowActivePowerVariable,
        devices,
        model,
        V,
    )
    return
end

"""
Don't add branch flow constraints for monitored lines if formulation is StaticBranchUnbounded
"""
function add_constraints!(
    ::OptimizationContainer,
    ::Type{FlowRateConstraintFromTo},
    devices::IS.FlattenIteratorWrapper{T},
    model::DeviceModel{T, U},
    ::NetworkModel{V},
) where {
    T <: PSY.MonitoredLine,
    U <: StaticBranchUnbounded,
    V <: AbstractActivePowerModel,
}
    return
end

"""
Min and max limits for flow limit from-to constraint
"""
function get_min_max_limits(
    device::PSY.MonitoredLine,
    ::Type{FlowLimitFromToConstraint},
    ::Type{<:AbstractBranchFormulation},
)
    if PSY.get_flow_limits(device).to_from != PSY.get_flow_limits(device).from_to
        @warn(
            "Flow limits in Line $(PSY.get_name(device)) aren't equal. The minimum will be used in formulation $(T)"
        )
    end
    return (
        min = -1 * PSY.get_flow_limits(device).from_to,
        max = PSY.get_flow_limits(device).from_to,
    )
end

"""
Min and max limits for flow limit to-from constraint
"""
function get_min_max_limits(
    device::PSY.MonitoredLine,
    ::Type{FlowLimitToFromConstraint},
    ::Type{<:AbstractBranchFormulation},
)
    if PSY.get_flow_limits(device).to_from != PSY.get_flow_limits(device).from_to
        @warn(
            "Flow limits in Line $(PSY.get_name(device)) aren't equal. The minimum will be used in formulation $(T)"
        )
    end
    return (
        min = -1 * PSY.get_flow_limits(device).to_from,
        max = PSY.get_flow_limits(device).to_from,
    )
end

"""
Don't add branch flow constraints for monitored lines if formulation is StaticBranchUnbounded
"""
function add_constraints!(
    ::OptimizationContainer,
    ::Type{FlowLimitToFromConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    model::DeviceModel{T, U},
    ::NetworkModel{V},
) where {
    T <: PSY.MonitoredLine,
    U <: StaticBranchUnbounded,
    V <: AbstractActivePowerModel,
}
    return
end

"""
Add phase angle limits for phase shifters
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{PhaseAngleControlLimit},
    devices::IS.FlattenIteratorWrapper{T},
    model::DeviceModel{T, PhaseAngleControl},
    ::NetworkModel{U},
) where {T <: PSY.PhaseShiftingTransformer, U <: AbstractActivePowerModel}
    add_range_constraints!(
        container,
        PhaseAngleControlLimit,
        PhaseShifterAngle,
        devices,
        model,
        U,
    )
    return
end

"""
Add network flow constraints for PhaseShiftingTransformer and NetworkModel with DCPPowerModel
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{NetworkFlowConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    model::DeviceModel{T, PhaseAngleControl},
    ::NetworkModel{DCPPowerModel},
) where {T <: PSY.PhaseShiftingTransformer}
    time_steps = get_time_steps(container)
    flow_variables = get_variable(container, FlowActivePowerVariable, T)
    ps_angle_variables = get_variable(container, PhaseShifterAngle, T)
    bus_angle_variables = get_variable(container, VoltageAngle, PSY.ACBus)
    jump_model = get_jump_model(container)
    branch_flow = add_constraints_container!(container, NetworkFlowConstraint,
        T,
        axes(flow_variables)[1],
        time_steps,
    )

    for br in devices
        name = PSY.get_name(br)
        inv_x = 1.0 / PSY.get_x(br)
        flow_variables_ = flow_variables[name, :]
        from_bus = PSY.get_number(PSY.get_from(PSY.get_arc(br)))
        to_bus = PSY.get_number(PSY.get_to(PSY.get_arc(br)))
        angle_variables_ = ps_angle_variables[name, :]
        bus_angle_from = bus_angle_variables[from_bus, :]
        bus_angle_to = bus_angle_variables[to_bus, :]
        @assert inv_x > 0.0
        for t in time_steps
            branch_flow[name, t] = JuMP.@constraint(
                jump_model,
                flow_variables_[t] ==
                inv_x * (bus_angle_from[t] - bus_angle_to[t] + angle_variables_[t])
            )
        end
    end
    return
end

function add_to_objective_function!(
    container::OptimizationContainer,
    ::IS.FlattenIteratorWrapper{T},
    device_model::DeviceModel{T, <:AbstractBranchFormulation},
    ::Type{<:AbstractPowerModel},
) where {T <: PSY.ACTransmission}
    if get_use_slacks(device_model)
        variable_up = get_variable(container, FlowActivePowerSlackUpperBound, T)
        # Use device names because there might be a network reduction
        for name in axes(variable_up, 1)
            for t in get_time_steps(container)
                add_to_objective_invariant_expression!(
                    container,
                    variable_up[name, t] * CONSTRAINT_VIOLATION_SLACK_COST,
                )
            end
        end
    end
    return
end

function add_to_objective_function!(
    container::OptimizationContainer,
    ::IS.FlattenIteratorWrapper{T},
    device_model::DeviceModel{T, <:AbstractBranchFormulation},
    ::Type{<:AbstractActivePowerModel},
) where {T <: PSY.ACTransmission}
    if get_use_slacks(device_model)
        variable_up = get_variable(container, FlowActivePowerSlackUpperBound, T)
        variable_dn = get_variable(container, FlowActivePowerSlackLowerBound, T)
        # Use device names because there might be a network reduction
        for name in axes(variable_up, 1)
            for t in get_time_steps(container)
                add_to_objective_invariant_expression!(
                    container,
                    (variable_dn[name, t] + variable_up[name, t]) *
                    CONSTRAINT_VIOLATION_SLACK_COST,
                )
            end
        end
    end
    return
end

"""
    branch_admittance(branch) -> NamedTuple

Returns the π-equivalent admittance parameters of an AC branch in per-unit:
- `g, b`: series conductance and susceptance computed from `(r, x)`
- `g_fr, b_fr`: from-side shunt
- `g_to, b_to`: to-side shunt
- `tap`: voltage-ratio magnitude (1.0 if not a tap-changing transformer)
- `shift`: nominal phase-shift angle in radians (0.0 if not a PST; the value of α for fixed PSTs)
"""
function branch_admittance end

# Plain AC line and MonitoredLine: full series admittance via PSY.
# get_series_admittance(::ACTransmission) returns 1/(R + jX).
function branch_admittance(branch::Union{PSY.Line, PSY.MonitoredLine})
    y = PSY.get_series_admittance(branch)
    b_split = PSY.get_b(branch)
    return (
        g = real(y),
        b = imag(y),
        g_fr = 0.0,
        b_fr = b_split.from,
        g_to = 0.0,
        b_to = b_split.to,
        tap = 1.0,
        shift = 0.0,
    )
end

# Plain transformer: same series admittance helper as line; shunt is on primary
# (from) side only. PSY.get_primary_shunt returns a ComplexF64 admittance.
function branch_admittance(branch::PSY.Transformer2W)
    y = PSY.get_series_admittance(branch)
    yt = PSY.get_primary_shunt(branch)
    return (
        g = real(y),
        b = imag(y),
        g_fr = real(yt),
        b_fr = imag(yt),
        g_to = 0.0,
        b_to = 0.0,
        tap = 1.0,
        shift = 0.0,
    )
end

# TapTransformer / PhaseShiftingTransformer: PSY.get_series_admittance for
# these types folds the tap into the admittance (Y = 1/(tap·Z)). The π-model
# below already applies the tap separately as `tm`, so we compute the bare
# series admittance from (r, x) directly to avoid double-counting.
function branch_admittance(branch::PSY.TapTransformer)
    y = inv(complex(PSY.get_r(branch), PSY.get_x(branch)))
    yt = PSY.get_primary_shunt(branch)
    return (
        g = real(y),
        b = imag(y),
        g_fr = real(yt),
        b_fr = imag(yt),
        g_to = 0.0,
        b_to = 0.0,
        tap = PSY.get_tap(branch),
        shift = 0.0,
    )
end

# PhaseShiftingTransformer: same series treatment as TapTransformer plus a
# nominal phase shift α. Constraint generation may swap the constant α for a
# PhaseShifterAngle variable in free-control mode.
function branch_admittance(branch::PSY.PhaseShiftingTransformer)
    y = inv(complex(PSY.get_r(branch), PSY.get_x(branch)))
    yt = PSY.get_primary_shunt(branch)
    return (
        g = real(y),
        b = imag(y),
        g_fr = real(yt),
        b_fr = imag(yt),
        g_to = 0.0,
        b_to = 0.0,
        tap = PSY.get_tap(branch),
        shift = PSY.get_α(branch),
    )
end

# BranchesParallel: equivalent π parameters supplied by PNM via EquivalentBranch.
function branch_admittance(branch::PNM.BranchesParallel)
    eb = PNM.get_equivalent_physical_branch_parameters(branch)
    r = PNM.get_equivalent_r(eb)
    x = PNM.get_equivalent_x(eb)
    y = inv(complex(r, x))
    return (
        g = real(y),
        b = imag(y),
        g_fr = PNM.get_equivalent_g_from(eb),
        b_fr = PNM.get_equivalent_b_from(eb),
        g_to = PNM.get_equivalent_g_to(eb),
        b_to = PNM.get_equivalent_b_to(eb),
        tap = PNM.get_equivalent_tap(eb),
        shift = PNM.get_equivalent_shift(eb),
    )
end

# BranchesSeries: same accessors as parallel; PNM aggregates per its rules.
function branch_admittance(branch::PNM.BranchesSeries)
    eb = PNM.get_equivalent_physical_branch_parameters(branch)
    r = PNM.get_equivalent_r(eb)
    x = PNM.get_equivalent_x(eb)
    y = inv(complex(r, x))
    return (
        g = real(y),
        b = imag(y),
        g_fr = PNM.get_equivalent_g_from(eb),
        b_fr = PNM.get_equivalent_b_from(eb),
        g_to = PNM.get_equivalent_g_to(eb),
        b_to = PNM.get_equivalent_b_to(eb),
        tap = PNM.get_equivalent_tap(eb),
        shift = PNM.get_equivalent_shift(eb),
    )
end

# Single 3W winding (post-decomposition by PNM). PSY.Transformer3W itself never
# reaches this function — the network-reduction layer expands each 3W into three
# ThreeWindingTransformerWinding entries that flow through the device set as
# their own type. If PSY.Transformer3W ever does reach a caller, MethodError is
# the correct signal — do not add a placeholder method.
function branch_admittance(winding::PNM.ThreeWindingTransformerWinding)
    r = PNM.get_equivalent_r(winding)
    x = PNM.get_equivalent_x(winding)
    y = inv(complex(r, x))
    b_split = PNM.get_equivalent_b(winding)
    return (
        g = real(y),
        b = imag(y),
        g_fr = 0.0,
        b_fr = b_split.from,
        g_to = 0.0,
        b_to = b_split.to,
        tap = 1.0,
        shift = 0.0,
    )
end

"""
    branch_flow_limits(branch) -> NamedTuple

Returns directional flow limits in per-unit MVA: `(from_to::Float64, to_from::Float64)`.
For symmetric branches both fields equal `PSY.get_rating(branch)`.
"""
function branch_flow_limits end

function branch_flow_limits(b::PSY.MonitoredLine)
    fl = PSY.get_flow_limits(b)
    return (from_to = fl.from_to, to_from = fl.to_from)
end

function branch_flow_limits(
    b::Union{
        PSY.Line,
        PSY.Transformer2W,
        PSY.TapTransformer,
        PSY.PhaseShiftingTransformer,
    },
)
    r = PSY.get_rating(b)
    return (from_to = r, to_from = r)
end

function branch_flow_limits(b::PNM.BranchesParallel)
    r = PNM.get_equivalent_rating(b)
    return (from_to = r, to_from = r)
end

function branch_flow_limits(b::PNM.BranchesSeries)
    r = PNM.get_equivalent_rating(b)
    return (from_to = r, to_from = r)
end

function branch_flow_limits(w::PNM.ThreeWindingTransformerWinding)
    r = PNM.get_equivalent_rating(w)
    return (from_to = r, to_from = r)
end

################################## Native ACP apparent-power rate constraints ###############

"""
Add from-to apparent-power rate limit constraint for ACBranch under the native ACPPowerModel.

Constrains pft^2 + qft^2 ≤ rating^2.  Does not depend on PTDF / network-reduction
infrastructure; iterates directly over devices.
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{FlowRateConstraintFromTo},
    devices::IS.FlattenIteratorWrapper{T},
    device_model::DeviceModel{T, U},
    ::NetworkModel{ACPPowerModel},
) where {T <: PSY.ACTransmission, U <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    pft = get_variable(container, FlowActivePowerFromToVariable, T)
    qft = get_variable(container, FlowReactivePowerFromToVariable, T)
    use_slacks = get_use_slacks(device_model)
    if use_slacks
        slack_ub = get_variable(container, FlowActivePowerSlackUpperBound, T)
    end
    branch_names = [PSY.get_name(d) for d in devices]
    cons = add_constraints_container!(
        container, FlowRateConstraintFromTo, T, branch_names, time_steps,
    )
    jump_model = get_jump_model(container)
    for d in devices
        name = PSY.get_name(d)
        rating = PSY.get_rating(d)
        for t in time_steps
            cons[name, t] = JuMP.@constraint(
                jump_model,
                pft[name, t]^2 + qft[name, t]^2 -
                (use_slacks ? slack_ub[name, t] : 0.0) <= rating^2,
            )
        end
    end
    return
end

"""
Add to-from apparent-power rate limit constraint for ACBranch under the native ACPPowerModel.

Constrains ptf^2 + qtf^2 ≤ rating^2.  Does not depend on PTDF / network-reduction
infrastructure; iterates directly over devices.
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{FlowRateConstraintToFrom},
    devices::IS.FlattenIteratorWrapper{T},
    device_model::DeviceModel{T, U},
    ::NetworkModel{ACPPowerModel},
) where {T <: PSY.ACTransmission, U <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    ptf = get_variable(container, FlowActivePowerToFromVariable, T)
    qtf = get_variable(container, FlowReactivePowerToFromVariable, T)
    use_slacks = get_use_slacks(device_model)
    if use_slacks
        slack_ub = get_variable(container, FlowActivePowerSlackUpperBound, T)
    end
    branch_names = [PSY.get_name(d) for d in devices]
    cons = add_constraints_container!(
        container, FlowRateConstraintToFrom, T, branch_names, time_steps,
    )
    jump_model = get_jump_model(container)
    for d in devices
        name = PSY.get_name(d)
        rating = PSY.get_rating(d)
        for t in time_steps
            cons[name, t] = JuMP.@constraint(
                jump_model,
                ptf[name, t]^2 + qtf[name, t]^2 -
                (use_slacks ? slack_ub[name, t] : 0.0) <= rating^2,
            )
        end
    end
    return
end

################################## Native DCP branch constraints ############################

"""
Add branch flow rate (rating) constraints for ACBranch under the native DCPPowerModel.

This is a simple lb/ub pair on the FlowActivePowerVariable that does not depend on the
PTDF / network-reduction infrastructure used by the AbstractActivePowerModel dispatch.
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{FlowRateConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    device_model::DeviceModel{T, U},
    ::NetworkModel{DCPPowerModel},
) where {T <: PSY.ACTransmission, U <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    flow_vars = get_variable(container, FlowActivePowerVariable, T)
    use_slacks = get_use_slacks(device_model)
    if use_slacks
        slack_ub = get_variable(container, FlowActivePowerSlackUpperBound, T)
        slack_lb = get_variable(container, FlowActivePowerSlackLowerBound, T)
    end
    jump_model = get_jump_model(container)
    branch_names = [PSY.get_name(d) for d in devices]
    con_lb = add_constraints_container!(
        container, FlowRateConstraint, T, branch_names, time_steps; meta = "lb",
    )
    con_ub = add_constraints_container!(
        container, FlowRateConstraint, T, branch_names, time_steps; meta = "ub",
    )
    for d in devices
        name = PSY.get_name(d)
        limits = get_min_max_limits(d, FlowRateConstraint, U)
        for t in time_steps
            con_ub[name, t] = JuMP.@constraint(
                jump_model,
                flow_vars[name, t] - (use_slacks ? slack_ub[name, t] : 0.0) <=
                limits.max,
            )
            con_lb[name, t] = JuMP.@constraint(
                jump_model,
                flow_vars[name, t] + (use_slacks ? slack_lb[name, t] : 0.0) >=
                limits.min,
            )
        end
    end
    return
end

"""
Add branch Ohm's law (DC power flow) constraint for ACBranch under the native DCPPowerModel:

    p_fr == -b * (va_fr - va_to - shift)

where `b` is the series susceptance from `branch_admittance` and `shift` is the nominal
phase-shift angle (0 for non-PST branches).
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{NetworkFlowConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    device_model::DeviceModel{T, U},
    network_model::NetworkModel{DCPPowerModel},
) where {T <: PSY.ACTransmission, U <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    network_reduction = get_network_reduction(network_model)
    va = get_variable(container, VoltageAngle, PSY.ACBus)
    p = get_variable(container, FlowActivePowerVariable, T)

    branch_names = [PSY.get_name(d) for d in devices]
    cons = add_constraints_container!(
        container, NetworkFlowConstraint, T, branch_names, time_steps,
    )

    for d in devices
        name = PSY.get_name(d)
        adm = branch_admittance(d)
        from_bus_obj = PSY.get_from(PSY.get_arc(d))
        to_bus_obj = PSY.get_to(PSY.get_arc(d))
        from_bus = PSY.get_name(from_bus_obj)
        to_bus = PSY.get_name(to_bus_obj)
        shift = adm.shift
        for t in time_steps
            cons[name, t] = JuMP.@constraint(
                get_jump_model(container),
                p[name, t] == -adm.b * (va[from_bus, t] - va[to_bus, t] - shift),
            )
        end
    end
    return
end

"""
Add branch angle-difference limit constraints for ACBranch under the native DCPPowerModel.

Only branches for which `PSY.get_angle_limits` is defined (currently `PSY.Line` and
`PSY.MonitoredLine`) and that carry non-trivial limits (i.e. not the ±π defaults) receive
a constraint.  Branches where the method is not defined are silently skipped.
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{AngleDifferenceConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, U},
    network_model::NetworkModel{DCPPowerModel},
) where {T <: PSY.ACTransmission, U <: AbstractBranchFormulation}
    # Filter to devices that (a) have the angle-limits API and
    # (b) carry non-trivial limits (skip the PSY default ±π).
    branches_with_limits = [
        d for d in devices if
        hasmethod(PSY.get_angle_limits, Tuple{typeof(d)}) && begin
            lims = PSY.get_angle_limits(d)
            !(lims.min ≈ -π && lims.max ≈ π)
        end
    ]
    isempty(branches_with_limits) && return

    time_steps = get_time_steps(container)
    network_reduction = get_network_reduction(network_model)
    va = get_variable(container, VoltageAngle, PSY.ACBus)

    branch_names = [PSY.get_name(d) for d in branches_with_limits]
    cons = add_constraints_container!(
        container, AngleDifferenceConstraint, T, branch_names, time_steps,
    )

    for d in branches_with_limits
        name = PSY.get_name(d)
        lims = PSY.get_angle_limits(d)
        from_bus_obj = PSY.get_from(PSY.get_arc(d))
        to_bus_obj = PSY.get_to(PSY.get_arc(d))
        from_bus = PSY.get_name(from_bus_obj)
        to_bus = PSY.get_name(to_bus_obj)
        for t in time_steps
            cons[name, t] = JuMP.@constraint(
                get_jump_model(container),
                lims.min <= va[from_bus, t] - va[to_bus, t] <= lims.max,
            )
        end
    end
    return
end

"""
Add full π-model AC Ohm's law constraints for ACBranch under the native ACPPowerModel.

Four constraints per branch per time step (p_ft, q_ft, p_tf, q_tf) relate the four
directional flow variables to voltage magnitudes and angles via the π-equivalent circuit.
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{NetworkFlowConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    device_model::DeviceModel{T, U},
    network_model::NetworkModel{ACPPowerModel},
) where {T <: PSY.ACTransmission, U <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    network_reduction = get_network_reduction(network_model)

    va = get_variable(container, VoltageAngle, PSY.ACBus)
    vm = get_variable(container, VoltageMagnitude, PSY.ACBus)
    pft = get_variable(container, FlowActivePowerFromToVariable, T)
    ptf = get_variable(container, FlowActivePowerToFromVariable, T)
    qft = get_variable(container, FlowReactivePowerFromToVariable, T)
    qtf = get_variable(container, FlowReactivePowerToFromVariable, T)

    branch_names = [PSY.get_name(d) for d in devices]
    cons_pft = add_constraints_container!(
        container, NetworkFlowConstraint, T, branch_names, time_steps; meta = "p_ft",
    )
    cons_qft = add_constraints_container!(
        container, NetworkFlowConstraint, T, branch_names, time_steps; meta = "q_ft",
    )
    cons_ptf = add_constraints_container!(
        container, NetworkFlowConstraint, T, branch_names, time_steps; meta = "p_tf",
    )
    cons_qtf = add_constraints_container!(
        container, NetworkFlowConstraint, T, branch_names, time_steps; meta = "q_tf",
    )

    for d in devices
        name = PSY.get_name(d)
        adm = branch_admittance(d)
        g = adm.g
        b = adm.b
        g_fr = adm.g_fr
        b_fr = adm.b_fr
        g_to = adm.g_to
        b_to = adm.b_to
        tm = adm.tap
        nominal_shift = adm.shift
        from_bus_obj = PSY.get_from(PSY.get_arc(d))
        to_bus_obj = PSY.get_to(PSY.get_arc(d))
        from_bus = PSY.get_name(from_bus_obj)
        to_bus = PSY.get_name(to_bus_obj)
        # Pre-compute constant coefficients from tap + shift.
        # Convention (same as PowerModels.jl ACP):
        #   tr = tm * cos(shift),  ti = tm * sin(shift)
        #   angle variable θ = va_fr - va_to  (shift already folded into tr/ti)
        tr = tm * cos(nominal_shift)
        ti = tm * sin(nominal_shift)
        # Diagonal (self) admittance terms
        g_sh_fr = (g + g_fr) / tm^2
        b_sh_fr = (b + b_fr) / tm^2
        # Off-diagonal coupling coefficients — from→to direction
        #   p_ft cos-term: (-g*tr + b*ti)/tm^2
        #   p_ft sin-term: (-b*tr - g*ti)/tm^2
        #   q_ft cos-term: -p_ft_sin = (b*tr + g*ti)/tm^2
        #   q_ft sin-term:  p_ft cos = (-g*tr + b*ti)/tm^2
        c_pft_cos = (-g * tr + b * ti) / tm^2
        c_pft_sin = (-b * tr - g * ti) / tm^2
        # Off-diagonal coupling coefficients — to→from direction
        # Use θ_tf = va_to - va_fr = -θ; cos(-θ)=cos(θ), sin(-θ)=-sin(θ)
        #   p_tf cos-term: (-g*tr - b*ti)/tm^2
        #   p_tf sin-term: (b*tr - g*ti)/tm^2   [negative because sin flips]
        #   q_tf cos-term: (b*tr - g*ti)/tm^2
        #   q_tf sin-term: (-g*tr - b*ti)/tm^2  [negative]
        c_ptf_cos = (-g * tr - b * ti) / tm^2
        c_ptf_sin = (b * tr - g * ti) / tm^2

        for t in time_steps
            θ = va[from_bus, t] - va[to_bus, t]
            vmf = vm[from_bus, t]
            vmt = vm[to_bus, t]
            jump_model = get_jump_model(container)

            # p_ft = (g + g_fr)/tm^2 * vmf^2
            #      + [(-g*tr + b*ti)/tm^2] * vmf*vmt*cos(θ)
            #      + [(-b*tr - g*ti)/tm^2] * vmf*vmt*sin(θ)
            cons_pft[name, t] = JuMP.@constraint(
                jump_model,
                pft[name, t] ==
                g_sh_fr * vmf^2 +
                c_pft_cos * vmf * vmt * cos(θ) +
                c_pft_sin * vmf * vmt * sin(θ),
            )

            # q_ft = -(b + b_fr)/tm^2 * vmf^2
            #      + [(b*tr + g*ti)/tm^2] * vmf*vmt*cos(θ)
            #      + [(-g*tr + b*ti)/tm^2] * vmf*vmt*sin(θ)
            cons_qft[name, t] = JuMP.@constraint(
                jump_model,
                qft[name, t] ==
                -b_sh_fr * vmf^2 +
                (-c_pft_sin) * vmf * vmt * cos(θ) +
                c_pft_cos * vmf * vmt * sin(θ),
            )

            # p_tf = (g + g_to) * vmt^2
            #      + [(-g*tr - b*ti)/tm^2] * vmt*vmf*cos(θ)  [cos(-θ)=cos(θ)]
            #      + [(b*tr - g*ti)/tm^2]  * vmt*vmf*sin(θ)  [sin(-θ)=-sin(θ), so +sin(θ)]
            cons_ptf[name, t] = JuMP.@constraint(
                jump_model,
                ptf[name, t] ==
                (g + g_to) * vmt^2 +
                c_ptf_cos * vmt * vmf * cos(θ) +
                c_ptf_sin * vmt * vmf * sin(θ),
            )

            # q_tf = -(b + b_to) * vmt^2
            #      + [(b*tr - g*ti)/tm^2]  * vmt*vmf*cos(θ)  [= c_ptf_sin]
            #      + [(g*tr + b*ti)/tm^2]  * vmt*vmf*sin(θ)  [= -c_ptf_cos]
            cons_qtf[name, t] = JuMP.@constraint(
                jump_model,
                qtf[name, t] ==
                -(b + b_to) * vmt^2 +
                c_ptf_sin * vmt * vmf * cos(θ) +
                (-c_ptf_cos) * vmt * vmf * sin(θ),
            )
        end
    end
    return
end

"""
Add branch angle-difference limit constraints for ACBranch under the native ACPPowerModel.

Only branches for which `PSY.get_angle_limits` is defined and that carry non-trivial limits
(i.e. not the ±π defaults) receive a constraint.  Branches where the method is not defined
are silently skipped.
"""
function add_constraints!(
    container::OptimizationContainer,
    ::Type{AngleDifferenceConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, U},
    network_model::NetworkModel{ACPPowerModel},
) where {T <: PSY.ACTransmission, U <: AbstractBranchFormulation}
    # Filter to devices that (a) have the angle-limits API and
    # (b) carry non-trivial limits (skip the PSY default ±π).
    branches_with_limits = [
        d for d in devices if
        hasmethod(PSY.get_angle_limits, Tuple{typeof(d)}) && begin
            lims = PSY.get_angle_limits(d)
            !(lims.min ≈ -π && lims.max ≈ π)
        end
    ]
    isempty(branches_with_limits) && return

    time_steps = get_time_steps(container)
    network_reduction = get_network_reduction(network_model)
    va = get_variable(container, VoltageAngle, PSY.ACBus)

    branch_names = [PSY.get_name(d) for d in branches_with_limits]
    cons = add_constraints_container!(
        container, AngleDifferenceConstraint, T, branch_names, time_steps,
    )

    for d in branches_with_limits
        name = PSY.get_name(d)
        lims = PSY.get_angle_limits(d)
        from_bus_obj = PSY.get_from(PSY.get_arc(d))
        to_bus_obj = PSY.get_to(PSY.get_arc(d))
        from_bus = PSY.get_name(from_bus_obj)
        to_bus = PSY.get_name(to_bus_obj)
        for t in time_steps
            cons[name, t] = JuMP.@constraint(
                get_jump_model(container),
                lims.min <= va[from_bus, t] - va[to_bus, t] <= lims.max,
            )
        end
    end
    return
end

################################################################################
# Transformer3W explicit star-arc decomposition for native DCP / ACP
#
# A PSY.Transformer3W is the Y-equivalent of three two-winding transformers
# meeting at an internal star bus (modeled in PSY as a real ACBus). The PNM
# reduction layer expands this into ThreeWindingTransformerWinding entries that
# native code consumes through the generic branch path. Without reduction (the
# bare DCP/ACP path) the Transformer3W reaches the loops directly, and the
# generic single-arc helpers (branch_admittance, branch_flow_limits, get_arc)
# do not apply. The methods below decompose the device on the fly: one virtual
# per-winding flow per direction, one set of ohms per winding, per-winding rate
# limits.
#
# Per-winding flow variable naming follows PNM's convention:
#   "<device_name>_winding_<i>" for i in 1, 2, 3
#
# Indexing the flow containers by these unique strings keeps the variable
# storage 2D (name × time) without inventing a new container shape.
################################################################################

"""
Returns a tuple of 3 NamedTuples, one per winding of a Transformer3W:
  (suffix, arc, r, x, rating, tap, base_power)
"""
function _three_winding_arcs(t::PSY.Transformer3W)
    return (
        (
            suffix = "winding_1",
            arc = PSY.get_primary_star_arc(t),
            r = PSY.get_r_primary(t),
            x = PSY.get_x_primary(t),
            rating = PSY.get_rating_primary(t),
            tap = PSY.get_primary_turns_ratio(t),
        ),
        (
            suffix = "winding_2",
            arc = PSY.get_secondary_star_arc(t),
            r = PSY.get_r_secondary(t),
            x = PSY.get_x_secondary(t),
            rating = PSY.get_rating_secondary(t),
            tap = PSY.get_secondary_turns_ratio(t),
        ),
        (
            suffix = "winding_3",
            arc = PSY.get_tertiary_star_arc(t),
            r = PSY.get_r_tertiary(t),
            x = PSY.get_x_tertiary(t),
            rating = PSY.get_rating_tertiary(t),
            tap = PSY.get_tertiary_turns_ratio(t),
        ),
    )
end

"Per-winding π-equivalent admittance (no shunts, no phase shift)."
function _winding_admittance(w::NamedTuple)
    y = inv(complex(w.r, w.x))
    return (
        g = real(y),
        b = imag(y),
        g_fr = 0.0,
        b_fr = 0.0,
        g_to = 0.0,
        b_to = 0.0,
        tap = w.tap,
        shift = 0.0,
    )
end

"Build the list of per-winding variable names for a set of Transformer3W devices."
function _three_winding_var_names(devices)
    names = String[]
    for d in devices
        dname = PSY.get_name(d)
        for w in _three_winding_arcs(d)
            push!(names, dname * "_" * w.suffix)
        end
    end
    return names
end

#### Variable creation: 4 directional flow vars × 3 windings per device.
function _add_three_winding_flow_variables!(
    container::OptimizationContainer,
    devices,
    network_model::NetworkModel{ACPPowerModel},
)
    time_steps = get_time_steps(container)
    names = _three_winding_var_names(devices)

    for (V, dir) in (
        (FlowActivePowerFromToVariable, "p_ft"),
        (FlowActivePowerToFromVariable, "p_tf"),
        (FlowReactivePowerFromToVariable, "q_ft"),
        (FlowReactivePowerToFromVariable, "q_tf"),
    )
        var = add_variable_container!(
            container, V, PSY.Transformer3W, names, time_steps,
        )
        for n in names, t in time_steps
            var[n, t] = JuMP.@variable(
                get_jump_model(container),
                base_name = "$(V)_Transformer3W_{$(n), $(t)}",
            )
        end
    end
    return
end

function _add_three_winding_flow_variables!(
    container::OptimizationContainer,
    devices,
    network_model::NetworkModel{DCPPowerModel},
)
    time_steps = get_time_steps(container)
    names = _three_winding_var_names(devices)
    var = add_variable_container!(
        container, FlowActivePowerVariable, PSY.Transformer3W, names, time_steps,
    )
    for n in names, t in time_steps
        var[n, t] = JuMP.@variable(
            get_jump_model(container),
            base_name = "FlowActivePowerVariable_Transformer3W_{$(n), $(t)}",
        )
    end
    return
end

#### add_to_expression: contribute per-winding flow to nodal balance.
function add_to_expression!(
    container::OptimizationContainer,
    ::Type{ActivePowerBalance},
    ::Type{FlowActivePowerVariable},
    devices::IS.FlattenIteratorWrapper{PSY.Transformer3W},
    ::DeviceModel{PSY.Transformer3W, U},
    network_model::NetworkModel{DCPPowerModel},
) where {U <: AbstractBranchFormulation}
    var = get_variable(container, FlowActivePowerVariable, PSY.Transformer3W)
    expression = get_expression(container, ActivePowerBalance, PSY.ACBus)
    network_reduction = get_network_reduction(network_model)
    time_steps = get_time_steps(container)
    for d in devices
        dname = PSY.get_name(d)
        for w in _three_winding_arcs(d)
            wname = dname * "_" * w.suffix
            from_no = PNM.get_mapped_bus_number(network_reduction, w.arc.from)
            to_no = PNM.get_mapped_bus_number(network_reduction, w.arc.to)
            for t in time_steps
                JuMP.add_to_expression!(expression[from_no, t], -1.0, var[wname, t])
                JuMP.add_to_expression!(expression[to_no, t], +1.0, var[wname, t])
            end
        end
    end
    return
end

# ACP: 4 separate methods (one per directional × {active, reactive}). Each
# specialization mirrors the generic ACTransmission methods but iterates the
# three windings and indexes by the per-winding variable name.
for (E, V, isfrom) in (
    (:ActivePowerBalance, :FlowActivePowerFromToVariable, true),
    (:ActivePowerBalance, :FlowActivePowerToFromVariable, false),
    (:ReactivePowerBalance, :FlowReactivePowerFromToVariable, true),
    (:ReactivePowerBalance, :FlowReactivePowerToFromVariable, false),
)
    @eval function add_to_expression!(
        container::OptimizationContainer,
        ::Type{$E},
        ::Type{$V},
        devices::IS.FlattenIteratorWrapper{PSY.Transformer3W},
        ::DeviceModel{PSY.Transformer3W, U},
        network_model::NetworkModel{ACPPowerModel},
    ) where {U <: AbstractBranchFormulation}
        var = get_variable(container, $V, PSY.Transformer3W)
        expression = get_expression(container, $E, PSY.ACBus)
        network_reduction = get_network_reduction(network_model)
        time_steps = get_time_steps(container)
        for d in devices
            dname = PSY.get_name(d)
            for w in _three_winding_arcs(d)
                wname = dname * "_" * w.suffix
                terminal_bus_obj = $isfrom ? w.arc.from : w.arc.to
                bus_no = PNM.get_mapped_bus_number(network_reduction, terminal_bus_obj)
                for t in time_steps
                    JuMP.add_to_expression!(expression[bus_no, t], -1.0, var[wname, t])
                end
            end
        end
        return
    end
end

#### Ohms: DCP version — one linear constraint per winding per time.
function add_constraints!(
    container::OptimizationContainer,
    ::Type{NetworkFlowConstraint},
    devices::IS.FlattenIteratorWrapper{PSY.Transformer3W},
    ::DeviceModel{PSY.Transformer3W, U},
    network_model::NetworkModel{DCPPowerModel},
) where {U <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    va = get_variable(container, VoltageAngle, PSY.ACBus)
    p = get_variable(container, FlowActivePowerVariable, PSY.Transformer3W)

    names = _three_winding_var_names(devices)
    cons = add_constraints_container!(
        container, NetworkFlowConstraint, PSY.Transformer3W, names, time_steps,
    )

    for d in devices
        dname = PSY.get_name(d)
        for w in _three_winding_arcs(d)
            wname = dname * "_" * w.suffix
            adm = _winding_admittance(w)
            from_name = PSY.get_name(w.arc.from)
            to_name = PSY.get_name(w.arc.to)
            for t in time_steps
                cons[wname, t] = JuMP.@constraint(
                    get_jump_model(container),
                    p[wname, t] == -adm.b * (va[from_name, t] - va[to_name, t]),
                )
            end
        end
    end
    return
end

#### Ohms: ACP version — full π-model, 4 NL constraints per winding per time.
function add_constraints!(
    container::OptimizationContainer,
    ::Type{NetworkFlowConstraint},
    devices::IS.FlattenIteratorWrapper{PSY.Transformer3W},
    ::DeviceModel{PSY.Transformer3W, U},
    network_model::NetworkModel{ACPPowerModel},
) where {U <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    va = get_variable(container, VoltageAngle, PSY.ACBus)
    vm = get_variable(container, VoltageMagnitude, PSY.ACBus)
    pft = get_variable(container, FlowActivePowerFromToVariable, PSY.Transformer3W)
    ptf = get_variable(container, FlowActivePowerToFromVariable, PSY.Transformer3W)
    qft = get_variable(container, FlowReactivePowerFromToVariable, PSY.Transformer3W)
    qtf = get_variable(container, FlowReactivePowerToFromVariable, PSY.Transformer3W)

    names = _three_winding_var_names(devices)
    cons_pft = add_constraints_container!(
        container, NetworkFlowConstraint, PSY.Transformer3W, names, time_steps;
        meta = "p_ft",
    )
    cons_qft = add_constraints_container!(
        container, NetworkFlowConstraint, PSY.Transformer3W, names, time_steps;
        meta = "q_ft",
    )
    cons_ptf = add_constraints_container!(
        container, NetworkFlowConstraint, PSY.Transformer3W, names, time_steps;
        meta = "p_tf",
    )
    cons_qtf = add_constraints_container!(
        container, NetworkFlowConstraint, PSY.Transformer3W, names, time_steps;
        meta = "q_tf",
    )

    for d in devices
        dname = PSY.get_name(d)
        for w in _three_winding_arcs(d)
            wname = dname * "_" * w.suffix
            adm = _winding_admittance(w)
            g, b, g_fr, b_fr, g_to, b_to, tm =
                adm.g, adm.b, adm.g_fr, adm.b_fr, adm.g_to, adm.b_to, adm.tap
            from_name = PSY.get_name(w.arc.from)
            to_name = PSY.get_name(w.arc.to)
            tr = tm * cos(0.0)  # no phase shift
            ti = tm * sin(0.0)

            for t in time_steps
                θ = va[from_name, t] - va[to_name, t]
                vmf = vm[from_name, t]
                vmt = vm[to_name, t]

                cons_pft[wname, t] = JuMP.@constraint(
                    get_jump_model(container),
                    pft[wname, t] ==
                    (g + g_fr) / tm^2 * vmf^2 +
                    ((-g * tr + b * ti) / tm^2) * vmf * vmt * cos(θ) +
                    ((-b * tr - g * ti) / tm^2) * vmf * vmt * sin(θ)
                )
                cons_qft[wname, t] = JuMP.@constraint(
                    get_jump_model(container),
                    qft[wname, t] ==
                    -(b + b_fr) / tm^2 * vmf^2 -
                    ((-b * tr - g * ti) / tm^2) * vmf * vmt * cos(θ) +
                    ((-g * tr + b * ti) / tm^2) * vmf * vmt * sin(θ)
                )
                cons_ptf[wname, t] = JuMP.@constraint(
                    get_jump_model(container),
                    ptf[wname, t] ==
                    (g + g_to) * vmt^2 +
                    ((-g * tr - b * ti) / tm^2) * vmt * vmf * cos(-θ) +
                    ((-b * tr + g * ti) / tm^2) * vmt * vmf * sin(-θ)
                )
                cons_qtf[wname, t] = JuMP.@constraint(
                    get_jump_model(container),
                    qtf[wname, t] ==
                    -(b + b_to) * vmt^2 -
                    ((-b * tr + g * ti) / tm^2) * vmt * vmf * cos(-θ) +
                    ((-g * tr - b * ti) / tm^2) * vmt * vmf * sin(-θ)
                )
            end
        end
    end
    return
end

#### Rate limits: DCP version — box bounds per winding using winding rating.
function add_constraints!(
    container::OptimizationContainer,
    ::Type{FlowRateConstraint},
    devices::IS.FlattenIteratorWrapper{PSY.Transformer3W},
    ::DeviceModel{PSY.Transformer3W, U},
    network_model::NetworkModel{DCPPowerModel},
) where {U <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    p = get_variable(container, FlowActivePowerVariable, PSY.Transformer3W)
    names = _three_winding_var_names(devices)
    cons_lb = add_constraints_container!(
        container, FlowRateConstraint, PSY.Transformer3W, names, time_steps;
        meta = "lb",
    )
    cons_ub = add_constraints_container!(
        container, FlowRateConstraint, PSY.Transformer3W, names, time_steps;
        meta = "ub",
    )
    for d in devices
        dname = PSY.get_name(d)
        for w in _three_winding_arcs(d)
            wname = dname * "_" * w.suffix
            for t in time_steps
                cons_lb[wname, t] = JuMP.@constraint(
                    get_jump_model(container), -w.rating <= p[wname, t],
                )
                cons_ub[wname, t] = JuMP.@constraint(
                    get_jump_model(container), p[wname, t] <= w.rating,
                )
            end
        end
    end
    return
end

#### Rate limits: ACP — apparent-power per winding per direction.
function add_constraints!(
    container::OptimizationContainer,
    ::Type{FlowRateConstraintFromTo},
    devices::IS.FlattenIteratorWrapper{PSY.Transformer3W},
    ::DeviceModel{PSY.Transformer3W, U},
    network_model::NetworkModel{ACPPowerModel},
) where {U <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    pft = get_variable(container, FlowActivePowerFromToVariable, PSY.Transformer3W)
    qft = get_variable(container, FlowReactivePowerFromToVariable, PSY.Transformer3W)
    names = _three_winding_var_names(devices)
    cons = add_constraints_container!(
        container, FlowRateConstraintFromTo, PSY.Transformer3W, names, time_steps,
    )
    for d in devices
        dname = PSY.get_name(d)
        for w in _three_winding_arcs(d)
            wname = dname * "_" * w.suffix
            r2 = w.rating^2
            for t in time_steps
                cons[wname, t] = JuMP.@constraint(
                    get_jump_model(container),
                    pft[wname, t]^2 + qft[wname, t]^2 <= r2,
                )
            end
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{FlowRateConstraintToFrom},
    devices::IS.FlattenIteratorWrapper{PSY.Transformer3W},
    ::DeviceModel{PSY.Transformer3W, U},
    network_model::NetworkModel{ACPPowerModel},
) where {U <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    ptf = get_variable(container, FlowActivePowerToFromVariable, PSY.Transformer3W)
    qtf = get_variable(container, FlowReactivePowerToFromVariable, PSY.Transformer3W)
    names = _three_winding_var_names(devices)
    cons = add_constraints_container!(
        container, FlowRateConstraintToFrom, PSY.Transformer3W, names, time_steps,
    )
    for d in devices
        dname = PSY.get_name(d)
        for w in _three_winding_arcs(d)
            wname = dname * "_" * w.suffix
            r2 = w.rating^2
            for t in time_steps
                cons[wname, t] = JuMP.@constraint(
                    get_jump_model(container),
                    ptf[wname, t]^2 + qtf[wname, t]^2 <= r2,
                )
            end
        end
    end
    return
end
