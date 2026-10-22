# Operational flow limits: operator-set limits per flow direction, applied in addition to
# the rating. See `APPLY_OPERATIONAL_FLOW_LIMITS_KEY`.

const _OPERATIONAL_FLOW_LIMIT_ATTRIBUTES = (
    APPLY_OPERATIONAL_FLOW_LIMITS_KEY => true,
)

# Branches that carry their operational flow limit on the device itself.
const _DEVICE_LIMITED_BRANCHES = Union{PSY.Line, PSY.SeriesCompensator}

_operational_flow_limit_attributes(::Type{<:PSY.Device}) = ()
_operational_flow_limit_attributes(::Type{<:_DEVICE_LIMITED_BRANCHES}) =
    _OPERATIONAL_FLOW_LIMIT_ATTRIBUTES
_operational_flow_limit_attributes(::Type{<:PSY.TwoWindingTransformer}) =
    _OPERATIONAL_FLOW_LIMIT_ATTRIBUTES
_operational_flow_limit_attributes(::Type{<:PSY.ThreeWindingTransformer}) =
    _OPERATIONAL_FLOW_LIMIT_ATTRIBUTES
_operational_flow_limit_attributes(::Type{<:PSY.TwoTerminalHVDC}) =
    _OPERATIONAL_FLOW_LIMIT_ATTRIBUTES

_operational_flow_limits_enabled(model::DeviceModel) =
    get_attribute(model, APPLY_OPERATIONAL_FLOW_LIMITS_KEY) === true

# Device level. A transformer keeps its limit on its circuits.
_has_device_operational_flow_limit(::PSY.ACTransmission) = false
_has_device_operational_flow_limit(d::_DEVICE_LIMITED_BRANCHES) =
    !isnothing(PSY.get_operational_flow_limit(d, u"SU"))
_has_device_operational_flow_limit(t::PSY.TwoWindingTransformer) =
    !isnothing(PSY.get_operational_flow_limit(PSY.get_circuit(t), u"SU"))
_has_device_operational_flow_limit(t::PNM.ThreeWindingTransformerCircuit) =
    !isnothing(PSY.get_operational_flow_limit(t.circuit, u"SU"))
_has_device_operational_flow_limit(agg::PNM.AbstractReductionAggregate) =
    any(_has_device_operational_flow_limit, agg)

_device_operational_flow_limit(d::_DEVICE_LIMITED_BRANCHES) =
    PSY.get_operational_flow_limit(d, u"SU")
_device_operational_flow_limit(t::PSY.TwoWindingTransformer) =
    PSY.get_operational_flow_limit(PSY.get_circuit(t), u"SU")
_device_operational_flow_limit(t::PNM.ThreeWindingTransformerCircuit) =
    PSY.get_operational_flow_limit(t.circuit, u"SU")

function _in_frame(limits, reversed::Bool)
    if reversed
        return IOM.reverse_directions(limits)
    end
    return limits
end

# Member value per direction, in the member's own frame: the rating, tightened by the
# operational limit where the member has one.
function _member_operational_limits(
    d::PSY.ACTransmission,
    model::DeviceModel,
    ::String,
    ::PNM.NetworkReductionData,
)
    rating = _branch_rating(d, model)
    if !_has_device_operational_flow_limit(d)
        return (from_to = rating, to_from = rating)
    end
    ofl = _device_operational_flow_limit(d)
    return (
        from_to = IOM.effective_limit(ofl, rating, IOM.FromTo()),
        to_from = IOM.effective_limit(ofl, rating, IOM.ToFrom()),
    )
end

# Series chain: the weakest member per direction. A parallel block inside a chain gives
# its N-1 value, as `PNM.get_equivalent_rating(::PNM.BranchesSeries)` does.
function _member_operational_limits(
    bs::PNM.BranchesSeries,
    model::DeviceModel,
    ::String,
    nr::PNM.NetworkReductionData,
)
    from_to = Inf
    to_from = Inf
    for (member, orientation) in zip(bs, PNM.get_segment_orientations(bs))
        lims = _in_frame(
            _member_operational_limits(
                member,
                model,
                SINGLE_ELEMENT_CONTINGENCY_RATING,
                nr,
            ),
            orientation === :ToFrom,
        )
        from_to = min(from_to, lims.from_to)
        to_from = min(to_from, lims.to_from)
    end
    return (from_to = from_to, to_from = to_from)
end

# A top-level mixed group always sums; a group inside a chain keeps the chain's N-1.
_top_level_method(::PNM.MixedBranchesParallel, ::String) = SUM_OF_MAX_RATING
_top_level_method(::PNM.AbstractReductionAggregate, method::String) = method
_top_level_method(::PSY.ACTransmission, method::String) = method

# Orientation of a parallel member relative to its group arc. A bus merge can put a member
# with another original arc into the group, so compare the arcs after the bus remap.
function _is_reversed_member(
    m,
    bp::PNM.AbstractBranchesParallel,
    nr::PNM.NetworkReductionData,
)
    key = PNM.get_arc_tuple(bp, nr)
    arc = PNM.get_arc_tuple(m, nr)
    if arc == key
        return false
    elseif arc == reverse(key)
        return true
    end
    error(
        "Parallel member $(PSY.get_name(m)) has arc $(arc), which matches neither the " *
        "group arc $(key) nor its reverse.",
    )
end

function _aggregate_parallel(
    method::String,
    values::Vector{Float64},
    bp::PNM.AbstractBranchesParallel,
    nr::PNM.NetworkReductionData,
)
    if method == SINGLE_ELEMENT_CONTINGENCY_RATING
        return sum(values) - maximum(values)
    elseif method == SUM_OF_MAX_RATING
        return sum(values)
    elseif method == IMPEDANCE_AVERAGED_RATING
        weights = [PNM.get_effective_series_susceptance(m, nr) for m in bp]
        return sum(weights .* values) / sum(weights)
    end
    error("Unknown $(PARALLEL_BRANCH_MAX_RATING_KEY) value \"$(method)\".")
end

# Parallel group: each direction combined with the rating aggregator the model selects.
function _member_operational_limits(
    bp::PNM.AbstractBranchesParallel,
    model::DeviceModel,
    method::String,
    nr::PNM.NetworkReductionData,
)
    members = [
        _in_frame(
            _member_operational_limits(m, model, method, nr),
            _is_reversed_member(m, bp, nr),
        ) for m in bp
    ]
    return (
        from_to = _aggregate_parallel(method, [l.from_to for l in members], bp, nr),
        to_from = _aggregate_parallel(method, [l.to_from for l in members], bp, nr),
    )
end

_has_operational_flow_limit(rep::RepresentativeBranch) =
    _has_device_operational_flow_limit(rep.branch)

_applies_operational_flow_limits(rep::RepresentativeBranch, model::DeviceModel) =
    _operational_flow_limits_enabled(model) && _has_operational_flow_limit(rep)

"""
Operational limit of the arc of `rep` per direction, system base, in the frame of
`rep.arc`. Call only when `_has_operational_flow_limit(rep)` is `true`.
"""
function _operational_flow_limits(rep::RepresentativeBranch, model::DeviceModel)
    method = _top_level_method(
        rep.branch,
        get_attribute(model, PARALLEL_BRANCH_MAX_RATING_KEY),
    )
    lims = _member_operational_limits(rep.branch, model, method, rep.nr)
    return _in_frame(lims, PNM.get_arc_tuple(rep.branch, rep.nr) == reverse(rep.arc))
end

# The flow in each direction, as `(flow, flow_sign)`, measured at the sending end.
_single_flow(flow) = ((flow, 1.0), (flow, -1.0))

function _pair_flows(container::OptimizationContainer, ::Type{T}) where {T}
    pft = get_variable(container, FlowActivePowerFromToVariable, T)
    ptf = get_variable(container, FlowActivePowerToFromVariable, T)
    return ((pft, 1.0), (ptf, 1.0))
end

_operational_flows(
    container,
    ::Type{T},
    ::NetworkModel{<:AbstractPTDFNetworkModel},
) where {T} =
    _single_flow(get_expression(container, PTDFBranchFlow, T))
_operational_flows(container, ::Type{T}, ::NetworkModel{DCPNetworkModel}) where {T} =
    _single_flow(get_expression(container, BThetaBranchFlow, T))
_operational_flows(container, ::Type{T}, ::NetworkModel{NFANetworkModel}) where {T} =
    _single_flow(get_variable(container, FlowActivePowerVariable, T))
_operational_flows(container, ::Type{T}, ::NetworkModel{DCPLLNetworkModel}) where {T} =
    _pair_flows(container, T)
_operational_flows(
    container,
    ::Type{T},
    ::NetworkModel{<:AbstractReactivePowerNetworkModel},
) where {T} = _pair_flows(container, T)

function _operational_flows(_, ::Type{T}, ::NetworkModel{N}) where {T, N}
    throw(
        IS.ConflictingInputsError(
            "$(T) devices carry an operational_flow_limit, but $(N) does not support \
             operational flow limits. Set apply_operational_flow_limits = false or use \
             another network model.",
        ),
    )
end

_operational_slack_meta(::IOM.FromTo) = "ofl_ft"
_operational_slack_meta(::IOM.ToFrom) = "ofl_tf"

# One representative per arc with a limit. A second call for the same `T` returns the same
# axis, so the slacks and the rows share it.
function _operational_limit_reps(network_model::NetworkModel, ::Type{T}) where {T}
    return [
        rep for rep in
        _representative_branches(network_model, T, OperationalFlowLimitConstraint) if
        _has_operational_flow_limit(rep)
    ]
end

"""
Add the arguments of the operational flow limits: one upper slack per direction when the
model uses slacks.
"""
function add_operational_flow_limit_arguments!(
    container::OptimizationContainer,
    devices::Vector{T},
    device_model::DeviceModel{T},
    network_model::NetworkModel,
) where {T <: PSY.ACTransmission}
    _operational_flow_limits_enabled(device_model) || return
    ts_names = get_time_series_names(device_model)
    ts_type = get_default_time_series_type(container)
    for dir in (IOM.FromTo(), IOM.ToFrom())
        P = _operational_parameter(dir)
        haskey(ts_names, P) || continue
        ts_name = ts_names[P]
        carriers = [d for d in devices if PSY.has_time_series(d, ts_type, ts_name)]
        isempty(carriers) && continue
        _check_series_has_static_limit(T, carriers, ts_name)
        add_branch_parameters!(container, P, devices, device_model, network_model)
    end
    get_use_slacks(device_model) || return
    names = _branch_names(_operational_limit_reps(network_model, T))
    isempty(names) && return
    time_steps = get_time_steps(container)
    jump_model = get_jump_model(container)
    for dir in (IOM.FromTo(), IOM.ToFrom())
        _add_meta_flow_slack!(
            container, FlowActivePowerSlackUpperBound, T, _operational_slack_meta(dir),
            names, time_steps, jump_model,
        )
    end
    return
end

function _check_series_has_static_limit(::Type{T}, carriers, ts_name::String) where {T}
    for d in carriers
        if !_has_device_operational_flow_limit(d)
            throw(
                IS.ConflictingInputsError(
                    "$(nameof(T)) $(PSY.get_name(d)) carries the operational limit time \
                     series $(ts_name) but has no operational_flow_limit. The time series \
                     scales the static limit. Set the operational_flow_limit or remove \
                     the time series.",
                ),
            )
        end
    end
    return
end

# The time series scales the `max` of its direction in the frame of the arc.
function _series_limit(rep::RepresentativeBranch, dir)
    lims = _in_frame(
        _device_operational_flow_limit(rep.branch),
        PNM.get_arc_tuple(rep.branch, rep.nr) == reverse(rep.arc),
    )
    return IOM.get_directional_value(lims, dir).max
end

# A time series on a reduction aggregate has no well-defined direction frame.
_check_operational_time_series_entry(::PSY.ACTransmission, ::String) = nothing
function _check_operational_time_series_entry(
    ::PNM.AbstractReductionAggregate,
    name::String,
)
    throw(
        IS.ConflictingInputsError(
            "Branch $(name) carries an operational_flow_limit time series and is merged \
             into a parallel or series group. An operational limit time series is not \
             supported on a merged branch. `irreducible_buses` on the NetworkModel only \
             prevents series and radial merging, not parallel grouping.",
        ),
    )
end

# The static limit of direction `dir` per name and time step.
function _static_rhs(
    ::Type{E},
    container::OptimizationContainer,
    static::Dict{String, <:NamedTuple},
    names::Vector{String},
    dir,
) where {E}
    rhs = DenseAxisArray{E}(undef, names, get_time_steps(container))
    for name in names
        value = IOM.get_directional_value(static[name], dir)
        for t in axes(rhs, 2)
            rhs[name, t] = value
        end
    end
    return rhs
end

function _fill_series_rhs!(rhs, reps, param_container, dir)
    ts_names = Set(axes(get_multiplier_array(param_container), 1))
    for rep in reps
        rep.name in ts_names || continue
        _check_operational_time_series_entry(rep.branch, rep.name)
        scale = _series_limit(rep, dir)
        refs = get_parameter_column_refs(param_container, rep.name)
        for t in axes(rhs, 2)
            rhs[rep.name, t] = scale * refs[t]
        end
    end
    return
end

# The limit of direction `dir` per name and time step. A name with a time series gets
# its static `max` times the parameter; the other names get the static `max`.
function _operational_rhs(
    ::Type{T},
    container,
    dir,
    static::Dict{String, <:NamedTuple},
    reps,
    names::Vector{String},
) where {T}
    P = _operational_parameter(dir)
    if !has_container_key(container, P, T)
        return _static_rhs(Float64, container, static, names, dir)
    end
    param_container = get_parameter(container, P, T)
    E = promote_type(Float64, eltype(get_parameter_array(param_container)))
    rhs = _static_rhs(E, container, static, names, dir)
    _fill_series_rhs!(rhs, reps, param_container, dir)
    return rhs
end

"""
Add `OperationalFlowLimitConstraint` rows for the arcs whose devices carry an
`operational_flow_limit`. The rating rows do not change.
"""
function add_operational_flow_limit_constraints!(
    container::OptimizationContainer,
    ::Vector{T},
    device_model::DeviceModel{T},
    network_model::NetworkModel,
) where {T <: PSY.ACTransmission}
    _operational_flow_limits_enabled(device_model) || return
    reps = _operational_limit_reps(network_model, T)
    isempty(reps) && return
    names = _branch_names(reps)
    static = Dict{String, NamedTuple{(:from_to, :to_from), Tuple{Float64, Float64}}}(
        rep.name => _operational_flow_limits(rep, device_model) for rep in reps
    )
    limits = (
        _operational_rhs(T, container, IOM.FromTo(), static, reps, names),
        _operational_rhs(T, container, IOM.ToFrom(), static, reps, names),
    )
    _add_operational_limit_rows!(
        container, T, device_model, names,
        _operational_flows(container, T, network_model), limits,
    )
    return
end

# One `OperationalFlowLimitConstraint` row per name, time step, and direction.
function _add_operational_limit_rows!(
    container::OptimizationContainer,
    ::Type{T},
    device_model::DeviceModel{T},
    names::Vector{String},
    flows,
    limits,
) where {T <: PSY.ACBranch}
    directions = (IOM.FromTo(), IOM.ToFrom())
    for ((flow, flow_sign), limit, dir) in zip(flows, limits, directions)
        if get_use_slacks(device_model)
            slack = get_variable(
                container, FlowActivePowerSlackUpperBound, T,
                _operational_slack_meta(dir),
            )
            IOM.add_directional_limit_constraints!(
                container, OperationalFlowLimitConstraint, T, dir, names,
                flow, flow_sign, slack, limit,
            )
        else
            IOM.add_directional_limit_constraints!(
                container, OperationalFlowLimitConstraint, T, dir, names,
                flow, flow_sign, limit,
            )
        end
    end
    if get_use_slacks(device_model)
        _price_slack_upper!(container, T, _operational_slack_meta(IOM.FromTo()))
        _price_slack_upper!(container, T, _operational_slack_meta(IOM.ToFrom()))
    end
    return
end

# One validation entry per limited element: (name, limit, rating). A 3W transformer gives
# one entry per winding that has a limit.
function _operational_limit_entries(d::_DEVICE_LIMITED_BRANCHES, model::DeviceModel)
    entries = Tuple{String, IOM.DirectionalMinMax, Float64}[]
    if _has_device_operational_flow_limit(d)
        push!(
            entries,
            (PSY.get_name(d), _device_operational_flow_limit(d), _branch_rating(d, model)),
        )
    end
    return entries
end

function _operational_limit_entries(t::PSY.TwoWindingTransformer, model::DeviceModel)
    entries = Tuple{String, IOM.DirectionalMinMax, Float64}[]
    if _has_device_operational_flow_limit(t)
        push!(
            entries,
            (PSY.get_name(t), _device_operational_flow_limit(t), _branch_rating(t, model)),
        )
    end
    return entries
end

function _operational_limit_entries(t::PSY.ThreeWindingTransformer, ::DeviceModel)
    entries = Tuple{String, IOM.DirectionalMinMax, Float64}[]
    for (i, circuit) in enumerate(PSY.get_circuits(t))
        ofl = PSY.get_operational_flow_limit(circuit, u"SU")
        isnothing(ofl) && continue
        name = "$(PSY.get_name(t))_winding_$(i)"
        push!(entries, (name, ofl, PSY.get_rating(circuit, u"SU")))
    end
    return entries
end

_operational_limit_entries(::PSY.Device, ::DeviceModel) =
    Tuple{String, IOM.DirectionalMinMax, Float64}[]

"""
Validate the operational flow limits of the devices in `device_model` at build time.
"""
function _check_operational_flow_limits(device_model::DeviceModel{D}) where {D}
    _operational_flow_limits_enabled(device_model) || return
    entries = Tuple{String, IOM.DirectionalMinMax, Float64}[]
    for d in get_device_cache(device_model)
        append!(entries, _operational_limit_entries(d, device_model))
    end
    isempty(entries) && return
    IOM.validate_directional_limits(D, entries)
    return
end

_operational_flow_limit_time_series_names(::Type{<:PSY.ACTransmission}) =
    Dict{Type{<:TimeSeriesParameter}, String}()

function _ofl_names()
    return Dict{Type{<:TimeSeriesParameter}, String}(
        FromToFlowLimitParameter => "operational_flow_limit_from_to",
        ToFromFlowLimitParameter => "operational_flow_limit_to_from",
    )
end

_operational_flow_limit_time_series_names(::Type{<:_DEVICE_LIMITED_BRANCHES}) = _ofl_names()
_operational_flow_limit_time_series_names(::Type{<:PSY.TwoWindingTransformer}) =
    _ofl_names()

_operational_parameter(::IOM.FromTo) = FromToFlowLimitParameter
_operational_parameter(::IOM.ToFrom) = ToFromFlowLimitParameter
_operational_direction(::Type{FromToFlowLimitParameter}) = IOM.FromTo()
_operational_direction(::Type{ToFromFlowLimitParameter}) = IOM.ToFrom()

_validate_branch_parameter_values(::Type{<:TimeSeriesParameter}, ::Type, ::String, _) =
    nothing

function _validate_branch_parameter_values(
    ::Type{P},
    ::Type{D},
    name::String,
    values::AbstractVector{Float64},
) where {P <: Union{FromToFlowLimitParameter, ToFromFlowLimitParameter}, D}
    IOM.validate_directional_limit_values(D, name, _operational_direction(P), values)
    return
end

# The operational-limit series only act while the limits are applied.
_time_series_enforced(::Type{<:TimeSeriesParameter}, ::DeviceModel) = true
_time_series_enforced(::Type{FromToFlowLimitParameter}, m::DeviceModel) =
    _operational_flow_limits_enabled(m)
_time_series_enforced(::Type{ToFromFlowLimitParameter}, m::DeviceModel) =
    _operational_flow_limits_enabled(m)

_time_series_label(::Type{<:TimeSeriesParameter}) = "branch rating time series"
_time_series_label(::Type{FromToFlowLimitParameter}) = "operational limit time series"
_time_series_label(::Type{ToFromFlowLimitParameter}) = "operational limit time series"

function _tighten_bounds!(v, lower::Float64, upper::Float64)
    if JuMP.has_upper_bound(v)
        JuMP.set_upper_bound(v, min(JuMP.upper_bound(v), upper))
    else
        JuMP.set_upper_bound(v, upper)
    end
    _tighten_lower_bound!(v, lower)
    return
end

function _tighten_lower_bound!(v, lower::Float64)
    if JuMP.has_lower_bound(v)
        JuMP.set_lower_bound(v, max(JuMP.lower_bound(v), lower))
    else
        JuMP.set_lower_bound(v, lower)
    end
    return
end

# A pair of end variables can carry more than the limit of the opposite direction: on
# CopperPlate no loss row couples them, and a bilinear approximation of a VSC can give
# negative losses. Each end therefore also gets the opposite limit as its lower bound.
_bound_receiving_ends!(container, devices, ::DeviceModel) = nothing

function _bound_receiving_ends!(
    container::OptimizationContainer,
    devices,
    ::DeviceModel{
        T,
        <:Union{HVDCTwoTerminalDispatch, AbstractTwoTerminalVSCFormulation},
    },
) where {T <: PSY.TwoTerminalHVDC}
    pft = get_variable(container, FlowActivePowerFromToVariable, T)
    ptf = get_variable(container, FlowActivePowerToFromVariable, T)
    for d in devices
        _has_device_operational_flow_limit(d) || continue
        lims = _hvdc_operational_limits(d)
        name = PSY.get_name(d)
        for t in get_time_steps(container)
            _tighten_lower_bound!(pft[name, t], -lims.to_from)
            _tighten_lower_bound!(ptf[name, t], -lims.from_to)
        end
    end
    return
end

# The HVDC flow in each direction at its sending end, as `(flow, flow_sign)`. The loss
# rows keep the receiving end at or below the sending end, except where
# `_bound_receiving_ends!` adds bounds.
_hvdc_operational_flows(
    container,
    ::Type{T},
    ::DeviceModel{T, HVDCTwoTerminalLossless},
) where {T} = _single_flow(get_variable(container, FlowActivePowerVariable, T))
_hvdc_operational_flows(
    container,
    ::Type{T},
    ::DeviceModel{T, HVDCTwoTerminalDispatch},
) where {T} = _pair_flows(container, T)
_hvdc_operational_flows(
    container,
    ::Type{T},
    ::DeviceModel{T, <:AbstractTwoTerminalVSCFormulation},
) where {T} = _pair_flows(container, T)

# Received power is negative at the sending end.
function _hvdc_operational_flows(
    container,
    ::Type{T},
    ::DeviceModel{T, HVDCTwoTerminalPiecewiseLoss},
) where {T}
    received_from = get_variable(container, HVDCActivePowerReceivedFromVariable, T)
    received_to = get_variable(container, HVDCActivePowerReceivedToVariable, T)
    return ((received_from, -1.0), (received_to, -1.0))
end

function _hvdc_operational_flows(
    container,
    ::Type{T},
    ::DeviceModel{T, HVDCTwoTerminalLCC},
) where {T}
    rectifier = get_variable(container, HVDCRectifierActivePowerVariable, T)
    inverter = get_variable(container, HVDCInverterActivePowerVariable, T)
    return ((rectifier, 1.0), (inverter, -1.0))
end

_has_device_operational_flow_limit(d::PSY.TwoTerminalHVDC) =
    !isnothing(PSY.get_operational_flow_limit(d, u"SU"))

function _hvdc_operational_limits(d::PSY.TwoTerminalHVDC)
    ofl = PSY.get_operational_flow_limit(d, u"SU")
    return (
        from_to = IOM.get_directional_value(ofl, IOM.FromTo()).max,
        to_from = IOM.get_directional_value(ofl, IOM.ToFrom()).max,
    )
end

_hvdc_limited_names(devices) =
    [PSY.get_name(d) for d in devices if _has_device_operational_flow_limit(d)]

"""
Add `OperationalFlowLimitConstraint` rows for the HVDC devices that carry an
`operational_flow_limit`. The end caps stay as the variable bounds. The HVDC
formulations declare no slacks, so these rows are hard.
"""
function add_hvdc_operational_flow_limit_constraints!(
    container::OptimizationContainer,
    devices,
    device_model::DeviceModel{T},
) where {T <: PSY.TwoTerminalHVDC}
    _operational_flow_limits_enabled(device_model) || return
    names = _hvdc_limited_names(devices)
    isempty(names) && return
    static = Dict{String, NamedTuple{(:from_to, :to_from), Tuple{Float64, Float64}}}(
        PSY.get_name(d) => _hvdc_operational_limits(d) for
        d in devices if _has_device_operational_flow_limit(d)
    )
    limits = (
        _static_rhs(Float64, container, static, names, IOM.FromTo()),
        _static_rhs(Float64, container, static, names, IOM.ToFrom()),
    )
    _add_operational_limit_rows!(
        container, T, device_model, names,
        _hvdc_operational_flows(container, T, device_model), limits,
    )
    _bound_receiving_ends!(container, devices, device_model)
    return
end

function _operational_limit_entries(d::PSY.TwoTerminalHVDC, ::DeviceModel)
    ofl = PSY.get_operational_flow_limit(d, u"SU")
    isnothing(ofl) && return Tuple{String, IOM.DirectionalMinMax, Float64}[]
    caps = _hvdc_end_caps(d)
    return [(PSY.get_name(d), ofl, min(caps.from, caps.to))]
end

# The branch formulations hold a series compensator's reactance fixed, so they cannot model
# one whose reactance is a decision or a flow control.
_check_series_compensator_control_modes(::DeviceModel) = nothing

function _check_series_compensator_control_modes(
    device_model::DeviceModel{PSY.SeriesCompensator},
)
    fixed_modes = (
        PSY.SeriesCompensatorControlMode.FIXED,
        PSY.SeriesCompensatorControlMode.BYPASSED,
    )
    controlled = [
        "$(PSY.get_name(d)) ($(PSY.get_control_mode(d)))" for
        d in get_device_cache(device_model) if PSY.get_control_mode(d) ∉ fixed_modes
    ]
    isempty(controlled) && return
    throw(
        IS.ConflictingInputsError(
            "SeriesCompensator control modes DISPATCHABLE and ACTIVE_POWER_FLOW are not " *
            "supported by $(get_formulation(device_model)): $(join(controlled, ", ")). " *
            "Set their control_mode to FIXED or BYPASSED.",
        ),
    )
end
