# Scheduled net interchange of an Area for AreaBalanceNetworkModel and AreaPTDFNetworkModel.
# The net export of an area is the sum of the flows of the AreaInterchange devices that leave
# it minus the sum of the flows that enter it. The schedule is the `scheduled_net_interchange`
# time series of the Area (MW) if it exists, else the `scheduled_net_interchange` field.

const SCHEDULED_NET_INTERCHANGE_TS_NAME = "scheduled_net_interchange"

# ---- Argument stage: parameter ----

_add_net_interchange_parameters!(::OptimizationContainer, ::PSY.System, ::NetworkModel) =
    nothing

function _add_net_interchange_parameters!(
    container::OptimizationContainer,
    sys::PSY.System,
    network_model::NetworkModel{<:Union{AreaBalanceNetworkModel, AreaPTDFNetworkModel}},
)
    ts_type = get_default_time_series_type(container)
    areas = filter(
        a -> _has_net_interchange_series(a, ts_type),
        collect(get_available_components(network_model, PSY.Area, sys)),
    )
    isempty(areas) && return
    _add_net_interchange_series_parameter!(container, areas, ts_type)
    return
end

# A schedule series of another type would otherwise fall back to the fixed field silently.
function _has_net_interchange_series(
    area::PSY.Area,
    ts_type::Type{<:IS.TimeSeriesData},
)
    ts_name = SCHEDULED_NET_INTERCHANGE_TS_NAME
    PSY.has_time_series(area, ts_type, ts_name) && return true
    metadata = IS.list_time_series_metadata(area; name = ts_name)
    isempty(metadata) && return false
    found = join(unique(nameof.(IS.get_time_series_type.(metadata))), ", ")
    throw(
        IS.ConflictingInputsError(
            "Area $(PSY.get_name(area)) carries a $(ts_name) time series as $(found), \
            but this model reads $(nameof(ts_type)).",
        ),
    )
end

function _add_net_interchange_series_parameter!(
    container::OptimizationContainer,
    areas::Vector{PSY.Area},
    ::Type{V},
) where {V <: Union{PSY.AbstractDeterministic, PSY.StaticTimeSeries}}
    time_steps = get_time_steps(container)
    ts_name = SCHEDULED_NET_INTERCHANGE_TS_NAME
    model_interval = get_interval(get_settings(container))
    model_resolution = get_resolution(get_settings(container))
    ts_hashes_by_id = IS.get_time_series_hashes(
        areas,
        V,
        ts_name;
        resolution = _to_is_resolution(model_resolution),
        interval = _to_is_interval(model_interval),
    )
    area_names = String[]
    area_ts_hashes = Dict{String, String}()
    initial_values = Dict{String, AbstractArray}()
    for area in areas
        name = PSY.get_name(area)
        if !haskey(ts_hashes_by_id, IS.get_id(area))
            error(
                "Time series $(V):$(ts_name) for Area $name does not " *
                "match resolution=$model_resolution interval=$model_interval.",
            )
        end
        ts_hash = ts_hashes_by_id[IS.get_id(area)]
        push!(area_names, name)
        area_ts_hashes[name] = ts_hash
        if !haskey(initial_values, ts_hash)
            initial_values[ts_hash] = IOM.get_time_series_initial_values!(
                container,
                V,
                area,
                ts_name;
                interval = model_interval,
                resolution = model_resolution,
            )
        end
    end

    param_container = add_time_series_parameter_container!(
        container,
        ScheduledNetInterchangeParameter,
        PSY.Area,
        V,
        ts_name,
        collect(keys(initial_values)),
        area_names,
        (),
        time_steps,
    )
    jump_model = get_jump_model(container)
    parent_param = IOM.get_parameter_array_data(param_container)
    param_instance = ScheduledNetInterchangeParameter()
    for (i, (_, raw_ts_vals)) in enumerate(initial_values)
        ts_vals = IOM.unwrap_for_param.((param_instance,), raw_ts_vals, ((),))
        _set_parameter_series!(parent_param, jump_model, ts_vals, i, time_steps)
    end
    # The series is in MW; the multiplier converts it to system base.
    to_system_base = 1.0 / get_model_base_power(container)
    parent_mult = IOM.get_multiplier_array_data(param_container)
    for (i, name) in enumerate(area_names)
        IOM._set_multiplier_at!(parent_mult, to_system_base, i)
        IOM.add_component_name!(
            IOM.get_attributes(param_container),
            name,
            area_ts_hashes[name],
        )
    end
    return
end

# ---- Model stage: constraint ----

add_constraints!(
    ::OptimizationContainer,
    ::Type{NetInterchangeConstraint},
    ::PSY.System,
    ::NetworkModel,
) = nothing

function add_constraints!(
    container::OptimizationContainer,
    ::Type{NetInterchangeConstraint},
    sys::PSY.System,
    network_model::NetworkModel{<:Union{AreaBalanceNetworkModel, AreaPTDFNetworkModel}},
)
    areas = filter(
        a -> _has_net_interchange_schedule(container, a),
        collect(get_available_components(network_model, PSY.Area, sys)),
    )
    isempty(areas) && return
    export_terms = _net_export_terms(container, sys, areas)
    flow = get_variable(container, FlowActivePowerVariable, PSY.AreaInterchange)
    area_names = PSY.get_name.(areas)
    time_steps = get_time_steps(container)
    constraints = add_constraints_container!(
        container,
        NetInterchangeConstraint,
        PSY.Area,
        area_names,
        time_steps,
    )
    jm = get_jump_model(container)
    for area in areas
        name = PSY.get_name(area)
        for t in time_steps
            net_export = JuMP.AffExpr(0.0)
            for (interchange_name, sign) in export_terms[name]
                JuMP.add_to_expression!(net_export, sign, flow[interchange_name, t])
            end
            constraints[name, t] = _net_interchange_constraint(
                container, jm, net_export, area, t,
            )
        end
    end
    return
end

function _net_interchange_constraint(
    container::OptimizationContainer,
    jm::JuMP.Model,
    net_export::JuMP.AffExpr,
    area::PSY.Area,
    t::Int,
)
    name = PSY.get_name(area)
    if _has_net_interchange_series_parameter(container, name)
        param_container =
            get_parameter(container, ScheduledNetInterchangeParameter, PSY.Area)
        param = get_parameter_column_refs(param_container, name)
        mult = get_multiplier_array(param_container)
        return JuMP.@constraint(jm, net_export == mult[name, t] * param[t])
    end
    return JuMP.@constraint(
        jm,
        net_export == PSY.get_scheduled_net_interchange(area, u"SU")
    )
end

function _has_net_interchange_series_parameter(
    container::OptimizationContainer,
    name::String,
)
    has_container_key(container, ScheduledNetInterchangeParameter, PSY.Area) ||
        return false
    param_container = get_parameter(container, ScheduledNetInterchangeParameter, PSY.Area)
    return name in axes(get_multiplier_array(param_container), 1)
end

_has_fixed_net_interchange(area::PSY.Area) =
    !isnothing(PSY.get_scheduled_net_interchange(area, u"SU"))

function _has_net_interchange_schedule(container::OptimizationContainer, area::PSY.Area)
    return _has_net_interchange_series_parameter(container, PSY.get_name(area)) ||
           _has_fixed_net_interchange(area)
end

# Area name => [(AreaInterchange name, sign)]. The sign is +1 where the area is the
# `from_area` (the flow leaves it) and -1 where it is the `to_area`.
function _net_export_terms(
    container::OptimizationContainer,
    sys::PSY.System,
    areas::Vector{PSY.Area},
)
    if !has_container_key(container, FlowActivePowerVariable, PSY.AreaInterchange)
        error(
            "Areas $(PSY.get_name.(areas)) have a scheduled net interchange, but the \
            template has no AreaInterchange device model. Add one to model the interchange.",
        )
    end
    flow = get_variable(container, FlowActivePowerVariable, PSY.AreaInterchange)
    terms = Dict{String, Vector{Tuple{String, Float64}}}()
    for interchange_name in axes(flow, 1)
        interchange = PSY.get_component(PSY.AreaInterchange, sys, interchange_name)
        from_name = PSY.get_name(PSY.get_from_area(interchange))
        to_name = PSY.get_name(PSY.get_to_area(interchange))
        push!(
            get!(() -> Tuple{String, Float64}[], terms, from_name),
            (interchange_name, 1.0),
        )
        push!(
            get!(() -> Tuple{String, Float64}[], terms, to_name),
            (interchange_name, -1.0),
        )
    end
    for area in areas
        haskey(terms, PSY.get_name(area)) || error(
            "Area $(PSY.get_name(area)) has a scheduled net interchange, but no modeled \
            AreaInterchange connects it.",
        )
    end
    return terms
end
