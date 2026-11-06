#################################### RepresentativeBranch ##################################

const _NO_BUS_NAMES = Dict{Int, String}()

"""
One branch as the reduction-aware builders see it. Build with
[`_representative_branches`](@ref) (one per arc, for constraint rows) or
[`_all_branches`](@ref) (one per reporting row, for variables), and iterate with
[`_foreach_branch`](@ref).

`B` is either a PSY.Device, a PNM.AbstractReductionAggregate, or
PNM.ThreeWindingTransformerCircuit.
"""
struct RepresentativeBranch{B}
    name::String
    arc::Tuple{Int, Int}
    branch::B
    nr::PNM.NetworkReductionData
    number_to_name::Dict{Int, String}
    monitored_type::DataType
end

"""
How the arc this branch occupies came to exist. Read off the entry rather than stored: `B` is
concrete per specialization, so this resolves statically and costs nothing.

PNM used to hand out a `Symbol` naming the internal map an entry came from, and this struct
kept it alongside the entry that symbol was used to fetch. The entry answers the question.
"""
_provenance(rep) = PNM.arc_provenance(rep.branch)

# Appears in JuMP variable names, so keep it short and stable.
_reduction_label(::PNM.DirectArc) = "direct"
_reduction_label(::PNM.ParallelArc) = "parallel"
_reduction_label(::PNM.SeriesArc) = "series"
_reduction_label(::PNM.SyntheticArc) = "synthetic"
_reduction_label(rep::RepresentativeBranch) = _reduction_label(_provenance(rep))

"""
Used for specializing the device loop per concrete RepresentativeBranch.
"""
function _foreach_branch(f::F, reps) where {F}
    for rep in reps
        f(rep)
    end
    return
end

_branch_names(reps) = String[rep.name for rep in reps]

function _make_representative_branch(
    catalog::PNM.BranchCatalog,
    arc_map,
    number_to_name::Dict{Int, String},
    ::Type{T},
    name::AbstractString,
) where {T <: PSY.ACTransmission}
    arc = arc_map[name]
    return RepresentativeBranch(
        name,
        arc,
        PNM.get_reduction_entry(catalog, arc),
        PNM.get_network_reduction_data(catalog),
        number_to_name,
        T,
    )
end

"""
One [`RepresentativeBranch`](@ref) per reduced arc of `T` not already claimed for the
constraint family `C`, in the axis order the constraint containers must be sized with.

Pass `number_to_name` (from `_retained_number_to_name`) whenever the builder reads endpoint
bus names; builders with no `sys` in scope may omit it.
"""
function _representative_branches(
    network_model::NetworkModel,
    ::Type{T},
    ::Type{C};
    number_to_name::Dict{Int, String} = _NO_BUS_NAMES,
) where {T <: PSY.ACTransmission, C <: ConstraintType}
    catalog = get_branch_catalog(network_model)
    tracker = get_reduced_branch_tracker(network_model)
    arc_map = PNM.get_name_to_arc_map(catalog, T)
    return RepresentativeBranch[
        _make_representative_branch(catalog, arc_map, number_to_name, T, name)
        for name in get_branch_argument_constraint_axis(catalog, tracker, T, C)
    ]
end

"""
One entry per reporting row, for variable container axes: every segment of a series chain
gets its own row, because a lossless chain carries the same flow in each, while a parallel
group gets one row at whatever depth it sits. A parallel member is therefore not an axis key
-- reach its row with [`_representative_branch`](@ref), which redirects.
"""
function _all_branches(
    network_model::NetworkModel,
    ::Type{T};
    number_to_name::Dict{Int, String} = _NO_BUS_NAMES,
) where {T <: PSY.ACTransmission}
    catalog = get_branch_catalog(network_model)
    arc_map = PNM.get_name_to_arc_map(catalog, T)
    return RepresentativeBranch[
        _make_representative_branch(catalog, arc_map, number_to_name, T, name)
        for name in keys(arc_map)
    ]
end

"""
The [`RepresentativeBranch`](@ref) carrying component `name` of type `T`.
A component absorbed into a reduction is redirected to the entry that
represents it.
"""
function _representative_branch(
    network_model::NetworkModel,
    ::Type{T},
    name::AbstractString;
    number_to_name::Dict{Int, String} = _NO_BUS_NAMES,
) where {T <: PSY.ACTransmission}
    catalog = get_branch_catalog(network_model)
    arc_map = PNM.get_name_to_arc_map(catalog, T)
    entry_name = if haskey(arc_map, name)
        name
    else
        redirects = get(
            PNM.get_component_to_reduction_name_map(catalog),
            T,
            Dict{String, String}(),
        )
        get(redirects, name, string())
    end
    isempty(entry_name) && error("$(T) \"$(name)\" does not exist in the reduction maps.")
    return _make_representative_branch(catalog, arc_map, number_to_name, T, entry_name)
end

################################## Topology ################################################

_from_number(rep::RepresentativeBranch) = rep.arc[1]
_to_number(rep::RepresentativeBranch) = rep.arc[2]

function _bus_name(rep::RepresentativeBranch, number::Int)
    name = get(rep.number_to_name, number, nothing)
    name === nothing && error(
        "RepresentativeBranch $(rep.name) carries no bus-name map; build it with \
         `number_to_name = _retained_number_to_name(sys, network_model)` to read \
         endpoint bus names.",
    )
    return name
end

_from_name(rep::RepresentativeBranch) = _bus_name(rep, _from_number(rep))
_to_name(rep::RepresentativeBranch) = _bus_name(rep, _to_number(rep))

################################## Electrical ##############################################

_admittance(branch::PNM.AbstractReductionAggregate, nr::PNM.NetworkReductionData) =
    PNM.branch_admittance(branch, nr)
_admittance(branch::PSY.ACTransmission, ::PNM.NetworkReductionData) =
    PNM.branch_admittance(branch)
_admittance(rep::RepresentativeBranch) = _admittance(rep.branch, rep.nr)

_dc_shift(branch::PNM.AbstractReductionAggregate, nr::PNM.NetworkReductionData) =
    PNM.get_series_phase_shift(branch, nr)
_dc_shift(branch::PSY.ACTransmission, ::PNM.NetworkReductionData) =
    PNM.get_series_phase_shift(branch)
_dc_shift(rep::RepresentativeBranch) = _dc_shift(rep.branch, rep.nr)

# DC susceptance `1/(tap*x)` — tap-divided, not the r-inclusive π-model susceptance.
_dc_susceptance(rep::RepresentativeBranch) =
    PNM.get_series_susceptance(rep.branch, u"SU")
# DC susceptance and phase shift of the entry conducting on the arc at step `t`; both are zero
# when the arc is out. A substitute entry (a lone member, a group of the members in service,
# or a Ward equivalent) is not registered in `rep.nr` and may be framed opposite to the arc,
# so its shift is recovered from the schedule's `b·α` injection, which is in the arc's frame.
_dc_parameters_at(::RepresentativeBranch, ::PNM.TopologySchedule, ::Nothing) = (0.0, 0.0)

function _dc_parameters_at(
    rep::RepresentativeBranch,
    ts::PNM.TopologySchedule,
    entry::PSY.ACTransmission,
)
    entry === rep.branch && return (_dc_susceptance(rep), _dc_shift(rep))
    b = PNM.get_series_susceptance(entry, u"SU")
    return (b, PNM.get_arc_shift_injection(ts, rep.arc, entry) / b)
end

const _DCStepParameters = @NamedTuple{b::Float64, shift::JuMP.AffExpr, own::Bool}

# The DC parameters of every time step: susceptance, fixed shift, and whether the arc's own
# entry conducts. Steps sharing a topology share one entry, so its shift expression is built
# once per topology.
_step_dc_parameters(rep::RepresentativeBranch, ::Nothing, time_steps) = fill(
    _DCStepParameters((_dc_susceptance(rep), JuMP.AffExpr(_dc_shift(rep)), true)),
    length(time_steps),
)

function _step_dc_parameters(
    rep::RepresentativeBranch,
    ts::PNM.TopologySchedule,
    time_steps,
)
    by_topology = Dict{Int, _DCStepParameters}()
    return [
        get!(by_topology, PNM.get_topology_index(ts, t)) do
            entry = PNM.get_in_service_entry(ts, rep.arc, t)
            b, shift = _dc_parameters_at(rep, ts, entry)
            return _DCStepParameters((
                b,
                JuMP.AffExpr(shift),
                _own_entry_conducts(rep, entry),
            ))
        end for t in time_steps
    ]
end

_dc_resistance(rep::RepresentativeBranch) = PNM.arc_dc_resistance(rep.nr, rep.arc)
_dc_shift_injection(rep::RepresentativeBranch) =
    PNM.arc_dc_shift_injection(rep.nr, rep.arc)

################################## Transformer control #####################################

const _VOLTAGE_CONTROL = PSY.TransformerControlObjective.VOLTAGE
const _REACTIVE_CONTROL = PSY.TransformerControlObjective.REACTIVE_POWER_FLOW
const _ACTIVE_CONTROL = PSY.TransformerControlObjective.ACTIVE_POWER_FLOW
const _UNDEFINED_CONTROL = PSY.TransformerControlObjective.UNDEFINED

const _TAP_CONTROLS = (_VOLTAGE_CONTROL, _REACTIVE_CONTROL)
const _PHASE_CONTROLS = (_ACTIVE_CONTROL,)

_supports_tap_control(::NetworkModel{<:NativeACNetworkModel}) = true
_supports_tap_control(::NetworkModel) = false

_supports_phase_control(
    ::NetworkModel{
        <:Union{DCPNetworkModel, AbstractDCPLLNetworkModel, AbstractPTDFNetworkModel},
    },
) = true
_supports_phase_control(::NetworkModel) = false

_get_circuit(t::PSY.TwoWindingTransformer) = PSY.get_circuit(t)
_get_circuit(t::PNM.ThreeWindingTransformerCircuit) = t.circuit
_get_circuit(::Union{PSY.ACTransmission, PNM.AbstractReductionAggregate}) = nothing

_control_objective(::Nothing, ::DeviceModel) = _UNDEFINED_CONTROL
_control_objective(c::PSY.TransformerCircuit, d::DeviceModel) =
    if PSY.get_available(c) && _control_enabled(d)
        PSY.get_control_objective(c)
    else
        PSY.TransformerControlObjective.UNDEFINED
    end
_control_objective(rep::RepresentativeBranch, d::DeviceModel) =
    _control_objective(_get_circuit(rep.branch), d)

function _tap_controlled(
    rep::RepresentativeBranch,
    d::DeviceModel,
    network_model::NetworkModel,
)
    return _supports_tap_control(network_model) &&
           _control_objective(rep, d) in _TAP_CONTROLS
end

function _phase_controlled(
    rep::RepresentativeBranch,
    d::DeviceModel,
    network_model::NetworkModel,
)
    return _supports_phase_control(network_model) &&
           _control_objective(rep, d) in _PHASE_CONTROLS
end

function _controlled_circuit_names(
    branch::Union{PSY.ACTransmission, PNM.ThreeWindingTransformerCircuit},
    device_model::DeviceModel,
    network_model::NetworkModel,
)
    objective = _control_objective(_get_circuit(branch), device_model)
    modeled =
        (objective in _TAP_CONTROLS && _supports_tap_control(network_model)) ||
        (objective in _PHASE_CONTROLS && _supports_phase_control(network_model))
    if modeled
        return [PNM.get_name(branch)]
    end
    return String[]
end
_controlled_circuit_names(
    entry::PNM.AbstractReductionAggregate,
    device_model::DeviceModel,
    network_model::NetworkModel,
) = reduce(
    vcat,
    (
        _controlled_circuit_names(member, device_model, network_model) for
        member in entry
    );
    init = String[],
)
_controlled_circuit_names(
    rep::RepresentativeBranch,
    device_model::DeviceModel,
    network_model::NetworkModel,
) = _controlled_circuit_names(rep.branch, device_model, network_model)

# PSY holds one band per controlled quantity; the control objective selects which
# actuator band and which target band the circuit populates.
_populated_band(band::NamedTuple, ::PSY.TransformerCircuit, ::String) = band
function _populated_band(::Nothing, c::PSY.TransformerCircuit, field::String)
    arc = PSY.get_arc(c)
    error(
        "TransformerCircuit $(PSY.get_name(PSY.get_from(arc))) -> " *
        "$(PSY.get_name(PSY.get_to(arc))) has control objective " *
        "$(PSY.get_control_objective(c)) but no $(field).",
    )
end

_control_limits(::Nothing) = (min = -Inf, max = Inf)
function _control_limits(c::PSY.TransformerCircuit)
    if PSY.get_control_objective(c) in _PHASE_CONTROLS
        return _populated_band(PSY.get_phase_angle_limits(c), c, "phase_angle_limits")
    end
    return _populated_band(PSY.get_tap_ratio_limits(c), c, "tap_ratio_limits")
end
_control_limits(rep::RepresentativeBranch) = _control_limits(_get_circuit(rep.branch))

_quantity_limits(::Nothing) = (min = -Inf, max = Inf)
function _quantity_limits(c::PSY.TransformerCircuit)
    objective = PSY.get_control_objective(c)
    if objective == _VOLTAGE_CONTROL
        return _populated_band(
            PSY.get_controlled_voltage_limits(c), c, "controlled_voltage_limits",
        )
    elseif objective == _REACTIVE_CONTROL
        return _populated_band(
            PSY.get_controlled_reactive_power_flow_limits(c, u"SU"), c,
            "controlled_reactive_power_flow_limits",
        )
    elseif objective == _ACTIVE_CONTROL
        return _populated_band(
            PSY.get_controlled_active_power_flow_limits(c, u"SU"), c,
            "controlled_active_power_flow_limits",
        )
    end
    return _populated_band(nothing, c, "target band that POM models for this objective")
end
_quantity_limits(rep::RepresentativeBranch) = _quantity_limits(_get_circuit(rep.branch))

_regulated_number(::Nothing) = -1
_regulated_number(c::PSY.TransformerCircuit) = PSY.get_regulated_bus_number(c)
_regulated_number(rep::RepresentativeBranch) = _regulated_number(_get_circuit(rep.branch))

################################## Ratings and limits ######################################

function _parallel_branches_rating(model::DeviceModel, bp::PNM.BranchesParallel)
    method = get_attribute(model, PARALLEL_BRANCH_MAX_RATING_KEY)
    if method == SINGLE_ELEMENT_CONTINGENCY_RATING
        return PNM.get_single_element_contingency_rating(bp)
    elseif method == SUM_OF_MAX_RATING
        return PNM.get_sum_of_max_rating(bp)
    elseif method == IMPEDANCE_AVERAGED_RATING
        return PNM.get_impedance_averaged_rating(bp)
    else
        error(
            "Unknown $PARALLEL_BRANCH_MAX_RATING_KEY value: $(repr(method)). " *
            "Valid: $(repr(SINGLE_ELEMENT_CONTINGENCY_RATING)), " *
            "$(repr(SUM_OF_MAX_RATING)), $(repr(IMPEDANCE_AVERAGED_RATING)).",
        )
    end
end
_parallel_branches_rating(::DeviceModel, mbp::PNM.MixedBranchesParallel) =
    PNM.get_sum_of_max_rating(mbp)

_branch_rating(d::PSY.ACTransmission, ::DeviceModel) = PSY.get_rating(d, u"SU")
_branch_rating(t::PSY.TwoWindingTransformer, ::DeviceModel) =
    PSY.get_rating(PSY.get_circuit(t), u"SU")
_branch_rating(t::PNM.ThreeWindingTransformerCircuit, ::DeviceModel) =
    PSY.get_rating(t.circuit, u"SU")
_branch_rating(entry::PNM.BranchesSeries, ::DeviceModel) = PNM.get_equivalent_rating(entry)
_branch_rating(entry::PSY.GenericArcImpedance, ::DeviceModel) =
    PNM.get_equivalent_rating(entry)
_branch_rating(entry::PNM.AbstractBranchesParallel, model::DeviceModel) =
    _parallel_branches_rating(model, entry)
_branch_rating(rep::RepresentativeBranch, model::DeviceModel) =
    _branch_rating(rep.branch, model)

"""
`_branch_rating` with a zero guard, for the flow limits that would otherwise pin
the arc to zero flow.
"""
function _directional_flow_rating(rep::RepresentativeBranch, model::DeviceModel)
    rating = _branch_rating(rep, model)
    iszero(rating) && error(
        "Branch $(rep.name) has a zero rating; the flow limit would force zero flow. \
         Assign a non-zero thermal rating to it or its member branches, or use an \
         unbounded formulation.",
    )
    return rating
end

_flow_limits(rep::RepresentativeBranch, model::DeviceModel) =
    _flow_limits(rep.branch, model)

function _flow_limits(entry, model::DeviceModel)
    rating = _branch_rating(entry, model)
    return (min = -rating, max = rating)
end

# The entry whose rating applies at step `t`. An out arc's flow is identically zero, so its
# rating row is inert and keeps the arc's own entry.
_entry_at(rep::RepresentativeBranch, ::Nothing, ::Int) = rep.branch

function _entry_at(rep::RepresentativeBranch, ts::PNM.TopologySchedule, t::Int)
    entry = PNM.get_in_service_entry(ts, rep.arc, t)
    isnothing(entry) && return rep.branch
    return entry
end

# Whether the arc's own entry carries the flow at step `t`. A branch scheduled out may leave
# its arc conducting through another entry, such as a Ward equivalent filed on the same arc.
_own_entry_conducts(::RepresentativeBranch, ::Nothing, ::Int) = true
_own_entry_conducts(rep::RepresentativeBranch, ts::PNM.TopologySchedule, t::Int) =
    _own_entry_conducts(rep, PNM.get_in_service_entry(ts, rep.arc, t))
# `entry` is the entry conducting on the arc, as `PNM.get_in_service_entry` resolves it.
_own_entry_conducts(rep::RepresentativeBranch, entry) = entry === rep.branch

# Whether the arc's own entry carries the flow at each step, resolved once per topology.
_step_own_entry_conducts(::RepresentativeBranch, ::Nothing, time_steps) =
    trues(length(time_steps))

function _step_own_entry_conducts(
    rep::RepresentativeBranch,
    ts::PNM.TopologySchedule,
    time_steps,
)
    by_topology = Dict{Int, Bool}()
    return BitVector([
        get!(by_topology, PNM.get_topology_index(ts, t)) do
            _own_entry_conducts(rep, ts, t)
        end for t in time_steps
    ])
end

# Flow limits at every time step, resolved once per topology.
_step_flow_limits(rep::RepresentativeBranch, ::Nothing, time_steps, model::DeviceModel) =
    fill(_flow_limits(rep, model), length(time_steps))

function _step_flow_limits(
    rep::RepresentativeBranch,
    ts::PNM.TopologySchedule,
    time_steps,
    model::DeviceModel,
)
    by_topology = Dict{Int, @NamedTuple{min::Float64, max::Float64}}()
    return [
        get!(by_topology, PNM.get_topology_index(ts, t)) do
            _step_entry_flow_limits(rep, _entry_at(rep, ts, t), model)
        end for t in time_steps
    ]
end

_step_entry_flow_limits(rep::RepresentativeBranch, entry, model::DeviceModel) =
    if entry === rep.branch
        _flow_limits(entry, model)
    else
        _substitute_flow_limits(rep, entry, model)
    end

# The limits of an entry that conducts on the arc in place of its own entry. A zero rating
# would pin the arc to zero flow at those steps.
function _substitute_flow_limits(rep::RepresentativeBranch, entry, model::DeviceModel)
    limits = _flow_limits(entry, model)
    iszero(limits.max) && error(
        "Branch $(PNM.get_name(entry)) carries the flow of arc $(rep.name) at the steps \
         its other branches are out, and has a zero rating; the flow limit would force \
         zero flow. Assign a non-zero thermal rating to it or use an unbounded formulation.",
    )
    return limits
end

"""
`rating` with a zero guard, for the post-contingency flow limits that would otherwise pin
the flow on `entry` after an outage to zero.
"""
function _nonzero_emergency_rating(entry, rating::Real)
    iszero(rating) && error(
        "Branch $(PNM.get_name(entry)) has a zero emergency rating; the post-contingency \
         flow limit would force zero flow. Assign a non-zero `rating_b`, or a non-zero \
         `rating` when `rating_b` is unset, to it or its member branches, or use a \
         formulation without post-contingency limits.",
    )
    return rating
end
_nonzero_emergency_rating(_, ::Nothing) = nothing

"""
Emergency rating of `entry`. `PNM.get_equivalent_emergency_rating` covers raw devices,
reduction aggregates and three-winding circuits alike — it returns `rating_b` and falls back
to `rating` where `rating_b` is undefined — and is already system-base per-unit, so it takes
no `u"SU"`.
"""
_emergency_rating(entry) =
    _nonzero_emergency_rating(entry, PNM.get_equivalent_emergency_rating(entry))

"""Post-contingency (emergency) flow limits of the arc."""
function _emergency_flow_limits(branch::PSY.ACTransmission)
    rating = _emergency_rating(branch)
    return (min = -rating, max = rating)
end
_emergency_flow_limits(rep::RepresentativeBranch) = _emergency_flow_limits(rep.branch)

"""
Post-contingency (emergency) flow limits of `entry`, the entry conducting on a monitored arc,
when the components in `tripped` are out of service. An aggregate keeps the emergency rating
of its members in service.
"""
function _emergency_flow_limits(entry::PSY.ACTransmission, tripped::Set{PSY.ACTransmission})
    rating = _post_contingency_rating(entry, tripped)
    return (min = -rating, max = rating)
end
_emergency_flow_limits(rep::RepresentativeBranch, tripped::Set{PSY.ACTransmission}) =
    _emergency_flow_limits(rep.branch, tripped)

_post_contingency_rating(branch::PSY.ACTransmission, ::Set{PSY.ACTransmission}) =
    _emergency_rating(branch)

# When the outage opens the arc, its MODF row is zero, so the intact limit stays.
function _post_contingency_rating(
    entry::PNM.AbstractReductionAggregate,
    tripped::Set{PSY.ACTransmission},
)::Float64
    if PNM.is_open_after_outage(entry, tripped)
        return _emergency_rating(entry)
    end
    return _nonzero_emergency_rating(
        entry,
        PNM.get_post_outage_emergency_rating(entry, tripped),
    )
end

# Factor on the arc's post-contingency rating series under one outage. The series
# multiplier of an aggregate is its intact emergency rating.
_post_contingency_share(::PSY.ACTransmission, ::Set{PSY.ACTransmission}) = 1.0

function _post_contingency_share(
    entry::PNM.AbstractReductionAggregate,
    tripped::Set{PSY.ACTransmission},
)::Float64
    return _post_contingency_rating(entry, tripped) / _emergency_rating(entry)
end

# The entry in service at step `t` holds only the members in service at `t`, so tripping
# the contingency on it rates the arc by the members in service once the components out at
# `t` and the contingency's components are all removed. Resolved once per topology.
_step_emergency_flow_limits(
    rep::RepresentativeBranch,
    ::Nothing,
    time_steps,
    tripped::Set{PSY.ACTransmission},
) = fill(_emergency_flow_limits(rep, tripped), length(time_steps))

function _step_emergency_flow_limits(
    rep::RepresentativeBranch,
    ts::PNM.TopologySchedule,
    time_steps,
    tripped::Set{PSY.ACTransmission},
)
    by_topology = Dict{Int, @NamedTuple{min::Float64, max::Float64}}()
    return [
        get!(by_topology, PNM.get_topology_index(ts, t)) do
            _emergency_flow_limits(_entry_at(rep, ts, t), tripped)
        end for t in time_steps
    ]
end

# `_post_contingency_share` of the entry in service at every step, resolved once per
# topology.
_step_post_contingency_shares(
    rep::RepresentativeBranch,
    ::Nothing,
    time_steps,
    tripped::Set{PSY.ACTransmission},
) = fill(_post_contingency_share(rep.branch, tripped), length(time_steps))

function _step_post_contingency_shares(
    rep::RepresentativeBranch,
    ts::PNM.TopologySchedule,
    time_steps,
    tripped::Set{PSY.ACTransmission},
)
    by_topology = Dict{Int, Float64}()
    return [
        get!(by_topology, PNM.get_topology_index(ts, t)) do
            _post_contingency_share(_entry_at(rep, ts, t), tripped)
        end for t in time_steps
    ]
end

function _min_endpoint_voltage_limit(branch::PSY.ACTransmission)
    arc = PSY.get_arc(branch)
    # bus voltage limits are already per-unit
    vmin_fr = PSY.get_voltage_limits(PSY.get_from(arc), u"CU").min
    vmin_to = PSY.get_voltage_limits(PSY.get_to(arc), u"CU").min
    return min(vmin_fr, vmin_to)
end
_min_endpoint_voltage_limit(entry::PNM.AbstractReductionAggregate) =
    minimum(_min_endpoint_voltage_limit(member) for member in entry)

"""
Current rating of the arc: apparent-power rating over the lowest endpoint voltage it can
see, so the bound holds across the whole voltage band.
"""
function _current_rating(rep::RepresentativeBranch, model::DeviceModel)
    rate_a = _directional_flow_rating(rep, model)
    vmin = _min_endpoint_voltage_limit(rep.branch)
    vmin <= 0.0 &&
        error("IVR: $(rep.name) has a non-positive endpoint voltage minimum ($vmin)")
    return rate_a / vmin
end

_angle_limits(d::PSY.Line) = PSY.get_angle_limits(d)
_angle_limits(::Union{PSY.ACTransmission, PNM.AbstractReductionAggregate}) =
    (min = -π / 2, max = π / 2)
_angle_limits(rep::RepresentativeBranch) = _angle_limits(rep.branch)

# A branch constrains the angle difference when it carries angle-limit data (only
# Line does) narrower than the PSY default ±π window.
_is_binding_angle_window(lims) = !(lims.min ≈ -π && lims.max ≈ π)
_constrains_angle_difference(::Union{PSY.ACTransmission, PNM.AbstractReductionAggregate}) =
    false
_constrains_angle_difference(d::PSY.Line) =
    _is_binding_angle_window(PSY.get_angle_limits(d))
_constrains_angle_difference(rep::RepresentativeBranch) =
    _constrains_angle_difference(rep.branch)

# Widest angle excursion the arc allows, the `vad_max` of the LPAC cosine relaxation.
function _max_angle_difference(rep::RepresentativeBranch)
    lims = _angle_limits(rep)
    return max(abs(lims.min), abs(lims.max))
end

################################## Miscellaneous ##########################################

_monitored_type(rep::RepresentativeBranch) = rep.monitored_type
