"""
    construct_topology_schedule!(container, template, network_model, sys)

Build the `PNM.TopologySchedule` of the model's time steps from the branch status
parameters, and store it in the network model together with the post-contingency network of
each registered contingency at every step. Every AC branch with a status of 0 at a step is
removed at that step. Does nothing when the network model has no topology matrix.

The topology matrix keeps its caches only for the base network and the networks this
schedule uses, so a model rebuilt for every window of a simulation holds one window's rows.
At each step the model queries the network of the components out at the step and, for each
contingency, the union of those components with the contingency's remaining components. At a
step with nothing out that union equals the contingency's own network, which is then in use;
when every step has something out, the contingency's own network is never queried, so its
caches are evicted while its registration is kept.

Islands are not modeled: throws an `IS.ConflictingInputsError` listing every available
injector of a modeled device type that is in service at a step where its bus lies outside
the islands holding a reference bus.
"""
function construct_topology_schedule!(
    container::OptimizationContainer,
    template::PowerOperationsProblemTemplate,
    network_model::NetworkModel,
    sys::PSY.System,
)
    matrix = get_topology_matrix(network_model)
    isnothing(matrix) && return
    time_steps = get_time_steps(container)
    _check_steps_start_at_one(time_steps)
    removed = [Set{PSY.Component}() for _ in time_steps]
    for (key, param) in IOM.get_parameters(container)
        IOM.get_entry_type(key) === BranchStatusParameter || continue
        _collect_removed!(removed, IOM.get_component_type(key), param, sys)
    end
    ts = PNM.TopologySchedule(matrix, sys, removed)
    post_contingency = _PostContingencyModifications(
        uuid => _post_contingency_modifications(ts, sys, uuid, time_steps) for
        uuid in keys(PNM.get_registered_contingencies(matrix))
    )
    PNM.retain_modifications!(
        matrix,
        _modifications_in_use(ts, post_contingency, time_steps),
    )
    set_topology_schedule!(network_model, ts, post_contingency)
    _check_island_consistency(container, template, network_model, sys)
    return
end

# Statuses, per-step limits and topology indices are stored in vectors indexed by the step
# itself, so the steps must be the positions 1, 2, ….
function _check_steps_start_at_one(time_steps)
    first(time_steps) == 1 && return
    throw(
        ArgumentError(
            "Component statuses and topology schedules need time steps starting at 1; \
             got $time_steps.",
        ),
    )
end

"""
The post-contingency network of the registered contingency `uuid` at every step of a
topology schedule: the components already out at the step together with the contingency's
remaining available components, or `nothing` when every one of them is already out. Steps
on the same topology share one modification.
"""
function _post_contingency_modifications(
    ts::PNM.TopologySchedule,
    sys::PSY.System,
    uuid::Int,
    time_steps::UnitRange{Int},
)
    outage = PSY.get_supplemental_attribute(sys, uuid)
    components = [
        c for c in PSY.get_associated_components(sys, outage) if PSY.get_available(c)
    ]
    by_topology = Dict{Int, Union{Nothing, PNM.NetworkModification}}()
    return Union{Nothing, PNM.NetworkModification}[
        get!(by_topology, PNM.get_topology_index(ts, t)) do
            PNM.get_post_contingency_modification(ts, t, components)
        end for t in time_steps
    ]
end

# Every network the schedule and its post-contingency networks resolve rows on.
function _modifications_in_use(
    ts::PNM.TopologySchedule,
    post_contingency::_PostContingencyModifications,
    time_steps::UnitRange{Int},
)
    in_use = Set{PNM.NetworkModification}()
    for t in time_steps
        mod = PNM.get_network_modification(ts, t)
        isnothing(mod) || push!(in_use, mod)
    end
    for mods in values(post_contingency), mod in mods
        isnothing(mod) || push!(in_use, mod)
    end
    return in_use
end

function _collect_removed!(
    removed::Vector{Set{PSY.Component}},
    ::Type{D},
    param::IOM.ParameterContainer,
    sys::PSY.System,
) where {D <: PSY.ACTransmission}
    status = IOM.get_parameter_array(param)
    for name in axes(status, 1)
        component = PSY.get_component(D, sys, name)
        for t in axes(status, 2)
            status[name, t] == 0.0 && push!(removed[t], component)
        end
    end
    return
end

# HVDC statuses act on the device's own variables, not on the AC network.
_collect_removed!(
    ::Vector{Set{PSY.Component}},
    ::Type,
    ::IOM.ParameterContainer,
    ::PSY.System,
) = nothing

_injects(::PSY.Component) = false
_injects(::PSY.StaticInjection) = true
_injects(::PSY.FixedAdmittance) = false
_injects(::PSY.SwitchedAdmittance) = false

function _check_island_consistency(
    container::OptimizationContainer,
    template::PowerOperationsProblemTemplate,
    network_model::NetworkModel,
    sys::PSY.System,
)
    isolated = _isolated_buses_by_step(
        get_topology_schedule(network_model),
        get_time_steps(container),
    )
    all(isempty, isolated) && return
    reduction = get_network_reduction(network_model)
    violations = _IslandViolations()
    for device_model in values(get_device_models(template))
        _collect_island_violations!(
            violations, container, device_model, isolated, reduction, sys,
        )
    end
    isempty(violations) && return
    throw(IS.ConflictingInputsError(_island_violation_message(violations, reduction)))
end

# An injector found in service on an isolated island: its type name, its name, and whether
# it can carry a `PlannedOutage` that would take it out.
const _IsolatedInjector = @NamedTuple{type_name::String, name::String, schedulable::Bool}

# The steps at which each injector is isolated, by island (its sorted retained buses).
const _IslandViolations = Dict{Vector{Int}, Dict{_IsolatedInjector, Vector{Int}}}

# For each step, the sorted island of every retained bus outside the reference islands.
# Steps sharing a topology share the result.
function _isolated_buses_by_step(ts::PNM.TopologySchedule, time_steps)
    by_topology = Dict{Int, Dict{Int, Vector{Int}}}()
    return [
        get!(() -> _isolated_buses(ts, t), by_topology, PNM.get_topology_index(ts, t))
        for t in time_steps
    ]
end

function _isolated_buses(ts::PNM.TopologySchedule, t::Int)
    islands, reference_islands = PNM.get_islands(ts, t)
    isolated = Dict{Int, Vector{Int}}()
    for (k, island) in enumerate(islands)
        k in reference_islands && continue
        sorted = sort(island)
        for bus in island
            isolated[bus] = sorted
        end
    end
    return isolated
end

# Injector statuses do not reach the subcomponents of a hybrid system, so it cannot be
# scheduled out.
_can_carry_planned_outage(::PSY.Component) = true
_can_carry_planned_outage(::PSY.HybridSystem) = false

function _collect_island_violations!(
    violations::_IslandViolations,
    container::OptimizationContainer,
    device_model::DeviceModel{D},
    isolated::Vector{Dict{Int, Vector{Int}}},
    reduction::PNM.NetworkReductionData,
    sys::PSY.System,
) where {D <: PSY.Component}
    status = get_component_statuses(container, D)
    for device in get_available_components(device_model, sys)
        _injects(device) || continue
        bus = PNM.get_mapped_bus_number(reduction, PSY.get_bus(device))
        name = PSY.get_name(device)
        injector = _IsolatedInjector((
            string(nameof(D)), name, _can_carry_planned_outage(device),
        ))
        for (t, isolated_at_t) in enumerate(isolated)
            haskey(isolated_at_t, bus) || continue
            get_component_status(status, name, t) == 0.0 && continue
            by_injector = get!(
                Dict{_IsolatedInjector, Vector{Int}},
                violations,
                isolated_at_t[bus],
            )
            push!(get!(Vector{Int}, by_injector, injector), t)
        end
    end
    return
end

function _island_violation_message(
    violations::_IslandViolations,
    reduction::PNM.NetworkReductionData,
)
    lines = [
        "Planned outages isolate buses that still have injectors in service. " *
        "Islands are not modeled:",
        "take each listed injector out with a PlannedOutage over the same steps. An " *
        "injector that cannot carry a PlannedOutage must be made unavailable, or the " *
        "branch outages changed so that its bus stays connected.",
    ]
    for island in sort!(collect(keys(violations)))
        by_injector = violations[island]
        entries = [
            _isolated_injector_entry(injector, by_injector[injector]) for
            injector in sort!(collect(keys(by_injector)))
        ]
        push!(
            lines,
            "  Island $(island)$(_reduced_buses_note(island, reduction)): " *
            join(entries, "; "),
        )
    end
    return join(lines, "\n")
end

function _isolated_injector_entry(injector::_IsolatedInjector, steps::Vector{Int})
    entry = "$(injector.type_name) \"$(injector.name)\" at steps $(_format_steps(steps))"
    injector.schedulable && return entry
    return entry * " (cannot carry a PlannedOutage)"
end

# The buses a network reduction merged into the island's retained buses, which the island
# also isolates.
function _reduced_buses_note(island::Vector{Int}, reduction::PNM.NetworkReductionData)
    reduction_map = PNM.get_bus_reduction_map(reduction)
    merged = Int[]
    for bus in island
        for original in get(reduction_map, bus, Set{Int}())
            original in island || push!(merged, original)
        end
    end
    isempty(merged) && return ""
    return " (with the buses reduced into it: $(sort!(merged)))"
end

# Consecutive steps collapse to ranges: [3, 4, 5, 8] becomes "3-5, 8".
function _format_steps(steps::Vector{Int})
    sorted = sort(steps)
    parts = String[]
    start = sorted[1]
    for (previous, next) in zip(sorted, Iterators.drop(sorted, 1))
        next == previous + 1 && continue
        push!(parts, _format_step_range(start, previous))
        start = next
    end
    push!(parts, _format_step_range(start, sorted[end]))
    return join(parts, ", ")
end

function _format_step_range(first_step::Int, last_step::Int)
    first_step == last_step && return string(first_step)
    return "$first_step-$last_step"
end
