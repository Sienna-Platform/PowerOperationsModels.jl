
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

get_multiplier_value(::Type{<:AbstractBranchRatingTimeSeriesParameter}, d::PSY.ACTransmission, ::Type{StaticBranch}) = PSY.get_rating(d, PSY.SU)


get_initial_conditions_device_model(::IOM.AbstractOptimizationModel, ::DeviceModel{T, U}) where {T <: PSY.ACTransmission, U <: AbstractBranchFormulation} = DeviceModel(T, U)

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
get_variable_upper_bound(::Type{FlowActivePowerFromToVariable}, d::PSY.MonitoredLine, ::Type{<:AbstractBranchFormulation}) = PSY.get_flow_limits(d, PSY.SU).from_to
get_variable_lower_bound(::Type{FlowActivePowerFromToVariable}, d::PSY.MonitoredLine, ::Type{<:AbstractBranchFormulation}) = -1 * PSY.get_flow_limits(d, PSY.SU).from_to
get_variable_upper_bound(::Type{FlowActivePowerToFromVariable}, d::PSY.MonitoredLine, ::Type{<:AbstractBranchFormulation}) = PSY.get_flow_limits(d, PSY.SU).to_from
get_variable_lower_bound(::Type{FlowActivePowerToFromVariable}, d::PSY.MonitoredLine, ::Type{<:AbstractBranchFormulation}) = -1 * PSY.get_flow_limits(d, PSY.SU).to_from
get_variable_upper_bound(::Type{FlowActivePowerFromToVariable}, d::Union{PSY.TapTransformer, PSY.Transformer2W}, ::Type{<:AbstractBranchFormulation}) = PSY.get_rating(d, PSY.SU)
get_variable_lower_bound(::Type{FlowActivePowerFromToVariable}, d::Union{PSY.TapTransformer, PSY.Transformer2W}, ::Type{<:AbstractBranchFormulation}) = -1 * PSY.get_rating(d, PSY.SU)
get_variable_upper_bound(::Type{FlowActivePowerToFromVariable}, d::Union{PSY.TapTransformer, PSY.Transformer2W}, ::Type{<:AbstractBranchFormulation}) = PSY.get_rating(d, PSY.SU)
get_variable_lower_bound(::Type{FlowActivePowerToFromVariable}, d::Union{PSY.TapTransformer, PSY.Transformer2W}, ::Type{<:AbstractBranchFormulation}) = -1 * PSY.get_rating(d, PSY.SU)

#! format: on
function get_default_time_series_names(
    ::Type{U},
    ::Type{V},
) where {U <: PSY.ACTransmission, V <: AbstractBranchFormulation}
    # Branch rating time series are opt-in: the user must explicitly set the
    # `BranchRatingTimeSeriesParameter` name on the `DeviceModel`. An empty
    # default routes every branch through the static-rating path.
    return Dict{Type{<:TimeSeriesParameter}, String}()
end

"""
DeviceModel attribute key selecting which `PowerNetworkMatrices` function aggregates
the individual circuit ratings of a `PNM.BranchesParallel` into a single maximum flow
limit. Valid values: `"single_element_contingency"` (default; N-1, post-trip surviving
capacity), `"sum_of_max"` (plain Σ Sᵢ), `"impedance_averaged"` (susceptance-weighted
average). `PNM.MixedBranchesParallel` groups always use `sum_of_max`.
"""
const PARALLEL_BRANCH_MAX_RATING_KEY = "parallel_branch_max_rating_method"

function get_default_attributes(
    ::Type{U},
    ::Type{V},
) where {U <: PSY.ACTransmission, V <: AbstractBranchFormulation}
    return Dict{String, Any}(
        PARALLEL_BRANCH_MAX_RATING_KEY => "single_element_contingency",
    )
end

function get_default_attributes(
    ::Type{U},
    ::Type{V},
) where {U <: PSY.ACTransmission, V <: AbstractSecurityConstrainedStaticBranch}
    return Dict{String, Any}(
        PARALLEL_BRANCH_MAX_RATING_KEY => "single_element_contingency",
        "include_planned_outages" => false,
    )
end

# Resolve the per-DeviceModel attribute to one of the explicit PNM rating functions.
# `MixedBranchesParallel` ignores the attribute and always uses the plain sum, since
# the constituent branches may carry different DeviceModel preferences and there is
# no defensible way to pick one. The PNM aggregators return system-base values
# (no `PSY.SU`).
function _get_parallel_branch_max_rating(model::DeviceModel, bp::PNM.BranchesParallel)
    method = get_attribute(model, PARALLEL_BRANCH_MAX_RATING_KEY)
    if method == "single_element_contingency"
        return PNM.get_single_element_contingency_rating(bp)
    elseif method == "sum_of_max"
        return PNM.get_sum_of_max_rating(bp)
    elseif method == "impedance_averaged"
        return PNM.get_impedance_averaged_rating(bp)
    else
        error(
            "Unknown $PARALLEL_BRANCH_MAX_RATING_KEY value: $(repr(method)). " *
            "Valid: \"single_element_contingency\", \"sum_of_max\", \"impedance_averaged\".",
        )
    end
end

function _get_parallel_branch_max_rating(::DeviceModel, mbp::PNM.MixedBranchesParallel)
    return PNM.get_sum_of_max_rating(mbp)
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
    device_model::DeviceModel{B, T},
    network_model::NetworkModel{<:AbstractPowerModel},
) where {B <: PSY.ACTransmission, T <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    net_reduction_data = get_network_reduction(network_model)
    all_branch_maps_by_type = PNM.get_all_branch_maps_by_type(net_reduction_data)
    for var in _get_flow_variable_vector(container, network_model, B)
        for (name, (arc, reduction)) in PNM.get_name_to_arc_map(net_reduction_data, B)
            # TODO: entry is not type stable here, it can return any type ACTransmission.
            # It might have performance implications. Possibly separate this into other functions
            reduction_entry = all_branch_maps_by_type[reduction][B][arc]
            # Use the same limit values as FlowRateConstraint for consistency.
            limits = min_max_flow_limits(reduction_entry, device_model)
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

"""
Scalar branch rating for a reduction entry — the single source of truth for
branch flow ratings. Parallel groups use the `PARALLEL_BRANCH_MAX_RATING_KEY`
attribute; every other entry uses `PNM.get_equivalent_rating`. Extend that (not
this) for new types. The PNM aggregators are system-base (no `PSY.SU`).
"""
function branch_rating(double_circuit::PNM.AbstractBranchesParallel, model::DeviceModel)
    return _get_parallel_branch_max_rating(model, double_circuit)
end

function branch_rating(entry, ::DeviceModel)
    return PNM.get_equivalent_rating(entry)
end

"""
Symmetric `(min, max)` flow limits from [`branch_rating`](@ref). Prefer this
over the formulation-only `get_min_max_limits` when the `DeviceModel` is in
scope.
"""
function min_max_flow_limits(entry, model::DeviceModel)
    rating = branch_rating(entry, model)
    return (min = -rating, max = rating)
end

# `MonitoredLine` has explicit, possibly asymmetric `flow_limits`; defer to its
# own `get_min_max_limits` instead of the symmetric `branch_rating` path.
function min_max_flow_limits(device::PSY.MonitoredLine, ::DeviceModel)
    return get_min_max_limits(device, FlowRateConstraint, AbstractBranchFormulation)
end

# Branch-rating time-series multiplier at build time. Non-parallel entries use
# the same aggregation as the static `branch_rating` path. Parallel groups are
# the exception: a series on one member can't be split across the group, so the
# summed (emergency) rating is used regardless of the attribute. Every PNM
# reduction wrapper is `<: PSY.ACTransmission`; the parallel methods are more
# specific (`<: AbstractBranchesParallel`), so they win for groups.
_resolve_branch_multiplier(p, d, f, ::DeviceModel) = get_multiplier_value(p, d, f)

function _resolve_branch_multiplier(
    ::Type{BranchRatingTimeSeriesParameter},
    d::PNM.AbstractBranchesParallel,
    ::Type{<:Union{StaticBranch, AbstractSecurityConstrainedStaticBranch}},
    ::DeviceModel,
)
    @warn "Parallel reduction $(PNM.get_name(d)) has a member with a branch rating \
           time series; using sum_of_max as the multiplier, regardless of the \
           `$PARALLEL_BRANCH_MAX_RATING_KEY` attribute."
    return PNM.get_sum_of_max_rating(d)
end

function _resolve_branch_multiplier(
    ::Type{PostContingencyBranchRatingTimeSeriesParameter},
    d::PNM.AbstractBranchesParallel,
    ::Type{<:Union{StaticBranch, AbstractSecurityConstrainedStaticBranch}},
    ::DeviceModel,
)
    @warn "Parallel reduction $(PNM.get_name(d)) has a member with a \
           post-contingency branch rating time series; using the summed emergency \
           rating as the multiplier, regardless of the \
           `$PARALLEL_BRANCH_MAX_RATING_KEY` attribute."
    return PNM.get_equivalent_emergency_rating(d)
end

function _resolve_branch_multiplier(
    ::Type{BranchRatingTimeSeriesParameter},
    entry::PSY.ACTransmission,
    ::Type{<:Union{StaticBranch, AbstractSecurityConstrainedStaticBranch}},
    ::DeviceModel,
)
    return PNM.get_equivalent_rating(entry)
end

function _resolve_branch_multiplier(
    ::Type{PostContingencyBranchRatingTimeSeriesParameter},
    entry::PSY.ACTransmission,
    ::Type{<:Union{StaticBranch, AbstractSecurityConstrainedStaticBranch}},
    ::DeviceModel,
)
    return PNM.get_equivalent_emergency_rating(entry)
end

# Formulation-typed adapter used by the range-constraint framework (e.g.
# `PhaseShiftingTransformer` under `FlowLimitConstraint`) and the native
# DCP rate-limit path. `MonitoredLine` overrides this below.
function get_min_max_limits(
    device::PSY.ACTransmission,
    ::Type{<:ConstraintType},
    ::Type{<:AbstractBranchFormulation},
) #  -> Union{Nothing, NamedTuple{(:min, :max), Tuple{Float64, Float64}}}
    rating = PNM.get_equivalent_rating(device)
    return (min = -rating, max = rating)
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
    arc::Tuple{Int, Int},
    use_slacks::Bool,
    con_lb::DenseAxisArray,
    con_ub::DenseAxisArray,
    var::DenseAxisArray,
    branch_maps_by_type::Dict,
    name::String,
    device_model::DeviceModel{T},
) where {T <: PSY.ACTransmission}
    reduction_entry = branch_maps_by_type[arc]
    time_steps = get_time_steps(container)
    if use_slacks
        slack_ub = get_variable(container, FlowActivePowerSlackUpperBound, T)[name, :]
        slack_lb = get_variable(container, FlowActivePowerSlackLowerBound, T)[name, :]
    end
    limits = min_max_flow_limits(reduction_entry, device_model)
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
            arc,
            use_slacks,
            con_lb,
            con_ub,
            array,
            all_branch_maps_by_type[reduction][T],
            name,
            device_model,
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
            arc,
            use_slacks,
            con_lb,
            con_ub,
            array,
            all_branch_maps_by_type[reduction][T],
            name,
            device_model,
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
        get_parameter(container, BranchRatingTimeSeriesParameter, T)
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

    # POM's `get_branch_argument_constraint_axis` already performs per-arc claim
    # dedup as a side effect (populating the tracker's constraint_dict), so the
    # iteration below over `get_constraint_map_by_type` walks the already-deduped
    # arc set. There is no need for the upstream PSI manual `name_to_arc_map`
    # walk + arc-claim push here.
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

    ts_name = get_time_series_names(device_model)[BranchRatingTimeSeriesParameter]
    ts_type = get_default_time_series_type(container)
    use_slacks = get_use_slacks(device_model)
    for (name, (arc, reduction)) in
        get_constraint_map_by_type(reduced_branch_tracker)[FlowRateConstraint][T]
        branch_map_T = all_branch_maps_by_type[reduction][T]
        if PNM.has_time_series(branch_map_T[arc], ts_type, ts_name)
            _add_flow_rate_constraint_with_parameters!(
                container,
                T,
                arc,
                use_slacks,
                con_lb,
                con_ub,
                var_array,
                branch_map_T,
                name,
                ts_name,
            )
        else
            _add_flow_rate_constraint!(
                container,
                arc,
                use_slacks,
                con_lb,
                con_ub,
                var_array,
                branch_map_T,
                name,
                device_model,
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
    all_branch_maps_by_type = PNM.get_all_branch_maps_by_type(net_reduction_data)
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

    # Gate on the parameter container actually existing, not merely on the
    # time-series name being configured: when the name is set but no branch of
    # this type carries the series, the parameter container is not created and
    # `get_parameter_array` would throw. An empty `ts_branch_names` routes every
    # arc through the static-rating path, which is the intended fallback.
    ts_branch_names = String[]
    local param, mult
    if has_container_key(container, BranchRatingTimeSeriesParameter, B)
        param = get_parameter_array(container, BranchRatingTimeSeriesParameter, B)
        mult =
            get_parameter_multiplier_array(container, BranchRatingTimeSeriesParameter, B)
        ts_branch_names = Set(axes(param, 1))
    end

    for (name, (arc, reduction)) in
        get_constraint_map_by_type(reduced_branch_tracker)[FlowRateConstraintFromTo][B]
        # TODO: entry is not type stable here, it can return any type ACTransmission.
        # It might have performance implications. Possibly separate this into other functions
        reduction_entry = all_branch_maps_by_type[reduction][B][arc]
        # `param * mult` = rating_factor * rating (an apparent-power value), so it
        # is squared here to match the static `rating^2` apparent-power RHS.
        if name in ts_branch_names
            for t in time_steps
                constraint[name, t] = JuMP.@constraint(
                    get_jump_model(container),
                    var1[name, t]^2 + var2[name, t]^2 -
                    (use_slacks ? slack_ub[name, t] : 0.0) <=
                    (param[name, t] * mult[name, t])^2
                )
            end
        else
            branch_rate = branch_rating(reduction_entry, device_model)
            for t in time_steps
                constraint[name, t] = JuMP.@constraint(
                    get_jump_model(container),
                    var1[name, t]^2 + var2[name, t]^2 -
                    (use_slacks ? slack_ub[name, t] : 0.0) <= branch_rate^2
                )
            end
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
    all_branch_maps_by_type = PNM.get_all_branch_maps_by_type(net_reduction_data)
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

    # Gate on the parameter container actually existing (see FromTo above).
    ts_branch_names = String[]
    local param, mult
    if has_container_key(container, BranchRatingTimeSeriesParameter, B)
        param = get_parameter_array(container, BranchRatingTimeSeriesParameter, B)
        mult =
            get_parameter_multiplier_array(container, BranchRatingTimeSeriesParameter, B)
        ts_branch_names = Set(axes(param, 1))
    end

    for (name, (arc, reduction)) in
        get_constraint_map_by_type(reduced_branch_tracker)[FlowRateConstraintToFrom][B]
        # TODO: entry is not type stable here, it can return any type ACTransmission.
        # It might have performance implications. Possibly separate this into other functions
        reduction_entry = all_branch_maps_by_type[reduction][B][arc]
        # `param * mult` = rating_factor * rating (an apparent-power value), so it
        # is squared here to match the static `rating^2` apparent-power RHS.
        if name in ts_branch_names
            for t in time_steps
                constraint[name, t] = JuMP.@constraint(
                    get_jump_model(container),
                    var1[name, t]^2 + var2[name, t]^2 -
                    (use_slacks ? slack_ub[name, t] : 0.0) <=
                    (param[name, t] * mult[name, t])^2
                )
            end
        else
            branch_rate = branch_rating(reduction_entry, device_model)
            for t in time_steps
                constraint[name, t] = JuMP.@constraint(
                    get_jump_model(container),
                    var1[name, t]^2 + var2[name, t]^2 -
                    (use_slacks ? slack_ub[name, t] : 0.0) <= branch_rate^2
                )
            end
        end
    end
    return
end

"""
Error if a PTDF/MODF column length differs from the nodal-balance bus
dimension. Prevents a downstream `@inbounds` out-of-bounds read; a mismatch
means the matrix and container used different network reductions.
"""
function _assert_flow_expression_dimensions(
    name::AbstractString,
    n_col::Int,
    nodal_balance_expressions::Matrix{JuMP.AffExpr},
)
    n_bus = size(nodal_balance_expressions, 1)
    if n_col != n_bus
        error(
            "Flow-expression dimension mismatch for branch/arc '$name': " *
            "PTDF/MODF column has $n_col entries but the nodal-balance " *
            "expression has $n_bus buses. PTDF and MODF must be built with " *
            "the same network reduction as the optimization container.",
        )
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
    _assert_flow_expression_dimensions(name, length(ptdf_col), nodal_balance_expressions)
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
    _assert_flow_expression_dimensions(name, length(ptdf_col), nodal_balance_expressions)
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
    branch_names = get_branch_argument_variable_axis(net_reduction_data, devices)
    # `collect` to a Vector so the spawn loop below can index it for multi-threading.
    name_to_arc_map = collect(PNM.get_name_to_arc_map(net_reduction_data, B))
    nodal_balance_expressions = get_expression(container, ActivePowerBalance,
        PSY.ACBus,
    )

    branch_flow_expr = add_expression_container!(container, PTDFBranchFlow,
        B,
        branch_names,
        time_steps,
    )

    # `ptdf[arc, :]` is a KLU solve; libklu is not concurrency-safe, so the
    # solves run serially on the dispatcher and only the JuMP `AffExpr` build is
    # parallelized via `Threads.@spawn`. The try/catch surfaces the inner
    # exception — the default error handler shows only the wrapping
    # `TaskFailedException`, which makes spawn-task failures undebuggable.
    tasks = map(name_to_arc_map) do pair
        (name, (arc, _)) = pair
        ptdf_col = ptdf[arc, :]
        Threads.@spawn try
            _make_flow_expressions!(
                name,
                time_steps,
                ptdf_col,
                nodal_balance_expressions.data,
            )
        catch e
            @error "PTDF flow-expression task failed" name = name arc = arc exception =
                (e, catch_backtrace())
            rethrow()
        end
    end
    for task in tasks
        name, expressions = fetch(task)
        branch_flow_expr[name, :] .= expressions
    end
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
        inv_x = 1 / PSY.get_x(br, PSY.SU)
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

# `MonitoredLine.flow_limits` may be asymmetric; the symmetric/min-based
# `get_min_max_limits` methods below collapse it to one value and warn once.
# The device, not a formulation type, is passed in (the old `$T` interpolation
# referenced an out-of-scope name — a latent bug).
function _warn_unequal_monitored_flow_limits(device::PSY.MonitoredLine)
    flow_limits = PSY.get_flow_limits(device, PSY.SU)
    if flow_limits.to_from != flow_limits.from_to
        @warn "Flow limits in Line $(PSY.get_name(device)) aren't equal; the \
               minimum will be used."
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
    _warn_unequal_monitored_flow_limits(device)
    limit = min(
        PNM.get_equivalent_rating(device),
        PSY.get_flow_limits(device, PSY.SU).to_from,
        PSY.get_flow_limits(device, PSY.SU).from_to,
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
    _warn_unequal_monitored_flow_limits(device)
    return (
        min = -1 * PSY.get_flow_limits(device, PSY.SU).from_to,
        max = PSY.get_flow_limits(device, PSY.SU).from_to,
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
    _warn_unequal_monitored_flow_limits(device)
    return (
        min = -1 * PSY.get_flow_limits(device, PSY.SU).to_from,
        max = PSY.get_flow_limits(device, PSY.SU).to_from,
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
    sys::PSY.System,
    ::Type{NetworkFlowConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    model::DeviceModel{T, PhaseAngleControl},
    network_model::NetworkModel{DCPPowerModel},
) where {T <: PSY.PhaseShiftingTransformer}
    time_steps = get_time_steps(container)
    number_to_name = _retained_number_to_name(sys, network_model)
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
        inv_x = 1.0 / PSY.get_x(br, PSY.SU)
        flow_variables_ = flow_variables[name, :]
        fr = _retained_bus(number_to_name, network_model, PSY.get_from(PSY.get_arc(br)))
        to = _retained_bus(number_to_name, network_model, PSY.get_to(PSY.get_arc(br)))
        fr.number == to.number && continue
        from_bus = fr.name
        to_bus = to.name
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

# Flip a π-admittance tuple to the opposite orientation (from<->to). Reduced equivalents
# may be keyed by an arc whose orientation is reversed vs the surviving branch's retained
# from->to; reorient so coefficients match (from_bus, to_bus). g/b are symmetric; from/to
# shunts swap; phase shift negates. Reduced line equivalents have tap == 1.
function _reverse_admittance(adm)
    @assert adm.tap == 1.0 "Cannot reorient a reduced arc with a non-unit tap ($(adm.tap))."
    return (
        g = adm.g,
        b = adm.b,
        g_fr = adm.g_to,
        b_fr = adm.b_to,
        g_to = adm.g_fr,
        b_to = adm.b_fr,
        tap = adm.tap,
        shift = -adm.shift,
    )
end

# Reduction-aware admittance for the retained arc (from_no -> to_no). Returns the PNM
# series/parallel equivalent π-tuple oriented from->to when the arc was aggregated by
# reduction, or `nothing` when the arc is direct (caller falls back to the branch's own).
function _reduced_arc_admittance(nr::PNM.NetworkReductionData, from_no::Int, to_no::Int)
    series_map = PNM.get_series_branch_map(nr)
    parallel_map = PNM.get_parallel_branch_map(nr)
    arc = (from_no, to_no)
    rev = (to_no, from_no)
    if haskey(series_map, arc)
        return PNM.branch_admittance(series_map[arc], nr)
    elseif haskey(series_map, rev)
        return _reverse_admittance(PNM.branch_admittance(series_map[rev], nr))
    elseif haskey(parallel_map, arc)
        return PNM.branch_admittance(parallel_map[arc], nr)
    elseif haskey(parallel_map, rev)
        return _reverse_admittance(PNM.branch_admittance(parallel_map[rev], nr))
    end
    return nothing
end

# Admittance for `branch`'s ohm's law given its retained endpoints: the branch's own
# π-parameters for a direct/un-reduced arc, or PNM's reduction-aware equivalent for a
# series/parallel-aggregated arc.
function _resolve_branch_admittance(network_model, branch, from_no::Int, to_no::Int)
    nr = get_network_reduction(network_model)
    isempty(nr) && return PNM.branch_admittance(branch)
    eq = _reduced_arc_admittance(nr, from_no, to_no)
    return eq === nothing ? PNM.branch_admittance(branch) : eq
end

# One-pass per-branch network geometry for the native DCP/ACP builders. Computes each
# branch's retained endpoints and reduction-aware admittance ONCE so the ohm's-law and
# angle-limit builders don't each rebuild `number_to_name` and re-map endpoints.
# Each entry is a NamedTuple value-bag (same idiom as `_retained_bus` / `branch_admittance`
# in this file); `collapsed` marks branches whose endpoints fold into one retained bus.
function _branch_geometries(sys::PSY.System, network_model, devices)
    number_to_name = _retained_number_to_name(sys, network_model)
    geoms = NamedTuple[]
    for d in devices
        fr = _retained_bus(number_to_name, network_model, PSY.get_from(PSY.get_arc(d)))
        to = _retained_bus(number_to_name, network_model, PSY.get_to(PSY.get_arc(d)))
        collapsed = fr.number == to.number
        adm =
            if collapsed
                PNM.branch_admittance(d)
            else
                _resolve_branch_admittance(network_model, d, fr.number, to.number)
            end
        push!(
            geoms,
            (
                name = PSY.get_name(d),
                from_name = fr.name,
                to_name = to.name,
                from_number = fr.number,
                to_number = to.number,
                adm = adm,
                collapsed = collapsed,
            ),
        )
    end
    return geoms
end

"""
    branch_flow_limits(branch) -> NamedTuple

Returns directional flow limits in per-unit MVA: `(from_to::Float64, to_from::Float64)`.
For symmetric branches both fields equal `PSY.get_rating(branch)`.
"""
function branch_flow_limits end

function branch_flow_limits(b::PSY.MonitoredLine)
    fl = PSY.get_flow_limits(b, PSY.SU)
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
    r = PSY.get_rating(b, PSY.SU)
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
Shared builder for directional apparent-power rate limit constraints under the native
ACPPowerModel.

Constrains `pflow^2 + qflow^2 ≤ rating^2` for the directional active/reactive flow variable
pair (`PVar`/`QVar`) and stores the result under the constraint key `ConsKey`. Does not
depend on PTDF / network-reduction infrastructure; iterates directly over devices.
"""
function _add_directional_flow_rate_limits!(
    container::OptimizationContainer,
    ::Type{ConsKey},
    ::Type{PVar},
    ::Type{QVar},
    devices::IS.FlattenIteratorWrapper{T},
    device_model::DeviceModel{T, U},
) where {
    ConsKey <: ConstraintType,
    PVar <: VariableType,
    QVar <: VariableType,
    T <: PSY.ACTransmission,
    U <: AbstractBranchFormulation,
}
    time_steps = get_time_steps(container)
    pflow = get_variable(container, PVar, T)
    qflow = get_variable(container, QVar, T)
    use_slacks = get_use_slacks(device_model)
    if use_slacks
        slack_ub = get_variable(container, FlowActivePowerSlackUpperBound, T)
    end
    branch_names = [PSY.get_name(d) for d in devices]
    cons = add_constraints_container!(
        container, ConsKey, T, branch_names, time_steps,
    )
    jump_model = get_jump_model(container)

    # Gate on the parameter container existing. The parameter array is keyed by
    # time-series UUID while the multiplier array is keyed by branch name, so the
    # per-branch parameter column is resolved via `get_parameter_column_refs`.
    # An empty `ts_branch_names` routes every branch through the static path.
    # `param * mult` = rating_factor * rating (an apparent-power value), squared
    # here to match the static `rating^2` apparent-power RHS.
    ts_branch_names = String[]
    local param_container, mult
    if has_container_key(container, BranchRatingTimeSeriesParameter, T)
        param_container =
            get_parameter(container, BranchRatingTimeSeriesParameter, T)
        mult = get_multiplier_array(param_container)
        ts_branch_names = Set(axes(mult, 1))
    end

    for d in devices
        name = PSY.get_name(d)
        if name in ts_branch_names
            param = get_parameter_column_refs(param_container, name)
            for t in time_steps
                cons[name, t] = JuMP.@constraint(
                    jump_model,
                    pflow[name, t]^2 + qflow[name, t]^2 -
                    (use_slacks ? slack_ub[name, t] : 0.0) <=
                    (param[t] * mult[name, t])^2,
                )
            end
        else
            # rating in system base (PSY.SU) so rating^2 matches the per-unit flow vars
            rating = PSY.get_rating(d, PSY.SU)
            for t in time_steps
                cons[name, t] = JuMP.@constraint(
                    jump_model,
                    pflow[name, t]^2 + qflow[name, t]^2 -
                    (use_slacks ? slack_ub[name, t] : 0.0) <= rating^2,
                )
            end
        end
    end
    return
end

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
    _add_directional_flow_rate_limits!(
        container,
        FlowRateConstraintFromTo,
        FlowActivePowerFromToVariable,
        FlowReactivePowerFromToVariable,
        devices,
        device_model,
    )
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
    _add_directional_flow_rate_limits!(
        container,
        FlowRateConstraintToFrom,
        FlowActivePowerToFromVariable,
        FlowReactivePowerToFromVariable,
        devices,
        device_model,
    )
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
    slack_ub =
        use_slacks ? get_variable(container, FlowActivePowerSlackUpperBound, T) :
        nothing
    slack_lb =
        use_slacks ? get_variable(container, FlowActivePowerSlackLowerBound, T) :
        nothing
    jump_model = get_jump_model(container)

    # Gate on the parameter container actually existing, not merely on the
    # time-series name being configured: when the name is set but no branch of
    # this type carries the series, the parameter container is not created.
    # The parameter array is keyed by time-series UUID while the multiplier
    # array is keyed by branch name, so resolve the per-branch parameter column
    # via `get_parameter_column_refs(param_container, name)` (the same mapping
    # the PTDF path uses). An empty `ts_branch_names` routes every branch through
    # the static-rating path.
    ts_branch_names = Set{String}()
    local param_container, mult
    if has_container_key(container, BranchRatingTimeSeriesParameter, T)
        param_container =
            get_parameter(container, BranchRatingTimeSeriesParameter, T)
        mult = get_multiplier_array(param_container)
        ts_branch_names = Set(axes(mult, 1))
    end

    branch_names = [PSY.get_name(d) for d in devices]
    static_devices = [d for d in devices if !(PSY.get_name(d) in ts_branch_names)]
    ts_devices = [d for d in devices if PSY.get_name(d) in ts_branch_names]

    # STATIC rating path: a plain `limits.min <= flow <= limits.max` (slack subtracted on
    # UB, added on LB). Delegated to the generic slack-aware IOM range helper since it is
    # the same lb/ub logic shared across devices. The "lb"/"ub" containers are created over
    # ALL `branch_names` (via `constraint_names`) so the TS path below can fill its share of
    # the same containers; only `static_devices` are constrained here.
    add_slacked_range_constraints!(
        container,
        FlowRateConstraint,
        flow_vars,
        static_devices,
        device_model,
        slack_ub,
        slack_lb;
        constraint_names = branch_names,
    )

    # TIME-SERIES rating path: the RHS is a parameterized rating (rating_factor * rating)
    # that varies per time step, so it is NOT covered by the generic range helper (which
    # takes a scalar `get_min_max_limits`). This stays POM-specific. The helper above
    # already created the "lb"/"ub" containers; index into them for the TS branches.
    if !isempty(ts_devices)
        con_lb = get_constraint(container, FlowRateConstraint, T, "lb")
        con_ub = get_constraint(container, FlowRateConstraint, T, "ub")
        for d in ts_devices
            name = PSY.get_name(d)
            # `param * mult` is the time-varying rating (rating_factor * rating).
            param = get_parameter_column_refs(param_container, name)
            for t in time_steps
                con_ub[name, t] = JuMP.@constraint(
                    jump_model,
                    flow_vars[name, t] - (use_slacks ? slack_ub[name, t] : 0.0) <=
                    param[t] * mult[name, t],
                )
                con_lb[name, t] = JuMP.@constraint(
                    jump_model,
                    flow_vars[name, t] + (use_slacks ? slack_lb[name, t] : 0.0) >=
                    -1.0 * param[t] * mult[name, t],
                )
            end
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
    sys::PSY.System,
    ::Type{NetworkFlowConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    device_model::DeviceModel{T, U},
    network_model::NetworkModel{DCPPowerModel},
) where {T <: PSY.ACTransmission, U <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    va = get_variable(container, VoltageAngle, PSY.ACBus)
    p = get_variable(container, FlowActivePowerVariable, T)

    geoms = _branch_geometries(sys, network_model, devices)
    branch_names = [g.name for g in geoms]
    cons = add_constraints_container!(
        container, NetworkFlowConstraint, T, branch_names, time_steps,
    )

    for g in geoms
        g.collapsed && continue
        shift = g.adm.shift
        for t in time_steps
            cons[g.name, t] = JuMP.@constraint(
                get_jump_model(container),
                p[g.name, t] == -g.adm.b * (va[g.from_name, t] - va[g.to_name, t] - shift),
            )
        end
    end
    return
end

"""
Add branch angle-difference limit constraints for ACBranch under the native DCP/ACP
PowerModels.

Only branches for which `PSY.get_angle_limits` is defined (currently `PSY.Line` and
`PSY.MonitoredLine`) and that carry non-trivial limits (i.e. not the ±π defaults) receive
a constraint.  Branches where the method is not defined are silently skipped.
"""
function add_constraints!(
    container::OptimizationContainer,
    sys::PSY.System,
    ::Type{AngleDifferenceConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, U},
    network_model::NetworkModel{<:Union{DCPPowerModel, ACPPowerModel}},
) where {T <: PSY.ACTransmission, U <: AbstractBranchFormulation}
    # Filter to devices that (a) have the angle-limits API and
    # (b) carry non-trivial limits (skip the PSY default ±π).
    limited = [
        d for d in devices if
        hasmethod(PSY.get_angle_limits, Tuple{typeof(d)}) && begin
            lims = PSY.get_angle_limits(d)
            !(lims.min ≈ -π && lims.max ≈ π)
        end
    ]
    isempty(limited) && return

    time_steps = get_time_steps(container)
    va = get_variable(container, VoltageAngle, PSY.ACBus)
    geoms = _branch_geometries(sys, network_model, limited)

    branch_names = [g.name for g in geoms]
    cons = add_constraints_container!(
        container, AngleDifferenceConstraint, T, branch_names, time_steps,
    )

    for (d, g) in zip(limited, geoms)
        g.collapsed && continue
        lims = PSY.get_angle_limits(d)
        for t in time_steps
            cons[g.name, t] = JuMP.@constraint(
                get_jump_model(container),
                lims.min <= va[g.from_name, t] - va[g.to_name, t] <= lims.max,
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
    sys::PSY.System,
    ::Type{NetworkFlowConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    device_model::DeviceModel{T, U},
    network_model::NetworkModel{ACPPowerModel},
) where {T <: PSY.ACTransmission, U <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)

    va = get_variable(container, VoltageAngle, PSY.ACBus)
    vm = get_variable(container, VoltageMagnitude, PSY.ACBus)
    pft = get_variable(container, FlowActivePowerFromToVariable, T)
    ptf = get_variable(container, FlowActivePowerToFromVariable, T)
    qft = get_variable(container, FlowReactivePowerFromToVariable, T)
    qtf = get_variable(container, FlowReactivePowerToFromVariable, T)

    geoms = _branch_geometries(sys, network_model, devices)
    branch_names = [g.name for g in geoms]
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

    for g_geom in geoms
        g_geom.collapsed && continue
        name = g_geom.name
        adm = g_geom.adm
        g = adm.g
        b = adm.b
        g_fr = adm.g_fr
        b_fr = adm.b_fr
        g_to = adm.g_to
        b_to = adm.b_to
        tm = adm.tap
        nominal_shift = adm.shift
        from_bus = g_geom.from_name
        to_bus = g_geom.to_name
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

"Build the list of per-winding variable names for a set of Transformer3W devices."
function _three_winding_var_names(devices)
    names = String[]
    for d in devices
        dname = PSY.get_name(d)
        for w in PNM.three_winding_arcs(d)
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
        for w in PNM.three_winding_arcs(d)
            wname = dname * "_" * w.suffix
            from_no = PNM.get_mapped_bus_number(network_reduction, PSY.get_from(w.arc))
            to_no = PNM.get_mapped_bus_number(network_reduction, PSY.get_to(w.arc))
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
            for w in PNM.three_winding_arcs(d)
                wname = dname * "_" * w.suffix
                terminal_bus_obj = $isfrom ? PSY.get_from(w.arc) : PSY.get_to(w.arc)
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
    sys::PSY.System,
    ::Type{NetworkFlowConstraint},
    devices::IS.FlattenIteratorWrapper{PSY.Transformer3W},
    ::DeviceModel{PSY.Transformer3W, U},
    network_model::NetworkModel{DCPPowerModel},
) where {U <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    number_to_name = _retained_number_to_name(sys, network_model)
    va = get_variable(container, VoltageAngle, PSY.ACBus)
    p = get_variable(container, FlowActivePowerVariable, PSY.Transformer3W)

    names = _three_winding_var_names(devices)
    cons = add_constraints_container!(
        container, NetworkFlowConstraint, PSY.Transformer3W, names, time_steps,
    )

    for d in devices
        dname = PSY.get_name(d)
        for w in PNM.three_winding_arcs(d)
            wname = dname * "_" * w.suffix
            adm = PNM.winding_admittance(w)
            fr = _retained_bus(number_to_name, network_model, PSY.get_from(w.arc))
            to = _retained_bus(number_to_name, network_model, PSY.get_to(w.arc))
            fr.number == to.number && continue
            from_name = fr.name
            to_name = to.name
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
    sys::PSY.System,
    ::Type{NetworkFlowConstraint},
    devices::IS.FlattenIteratorWrapper{PSY.Transformer3W},
    ::DeviceModel{PSY.Transformer3W, U},
    network_model::NetworkModel{ACPPowerModel},
) where {U <: AbstractBranchFormulation}
    time_steps = get_time_steps(container)
    number_to_name = _retained_number_to_name(sys, network_model)
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
        for w in PNM.three_winding_arcs(d)
            wname = dname * "_" * w.suffix
            adm = PNM.winding_admittance(w)
            g, b, g_fr, b_fr, g_to, b_to, tm =
                adm.g, adm.b, adm.g_fr, adm.b_fr, adm.g_to, adm.b_to, adm.tap
            fr = _retained_bus(number_to_name, network_model, PSY.get_from(w.arc))
            to = _retained_bus(number_to_name, network_model, PSY.get_to(w.arc))
            fr.number == to.number && continue
            from_name = fr.name
            to_name = to.name
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
        for w in PNM.three_winding_arcs(d)
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
        for w in PNM.three_winding_arcs(d)
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
        for w in PNM.three_winding_arcs(d)
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
