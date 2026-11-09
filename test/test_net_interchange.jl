const NET_INTERCHANGE_MODELS = (AreaBalanceNetworkModel, AreaPTDFNetworkModel)

# `schedules` maps an area name to a fixed MW value, a vector of MW values (time series),
# or `nothing`. Areas that are not in `schedules` get `nothing`.
function _net_interchange_container(
    network_type;
    schedules::Dict{String, Any},
    with_interchange = true,
)
    sys = PSB.build_system(PSISystems, "two_area_pjm_DA"; force_build = true)
    load_ts = first(get_time_series_multiple(first(get_components(PowerLoad, sys))))
    stamps = TimeSeries.timestamp(get_data(load_ts))
    for area in get_components(Area, sys)
        schedule = get(schedules, get_name(area), nothing)
        _set_net_interchange_schedule!(sys, area, schedule, stamps)
    end
    transform_single_time_series!(sys, Hour(24), Hour(1))
    template = get_thermal_dispatch_template_network(NetworkModel(network_type))
    set_device_model!(template, Line, StaticBranch)
    if with_interchange
        set_device_model!(template, AreaInterchange, StaticBranch)
    end
    model = DecisionModel(template, sys; resolution = Hour(1), optimizer = HiGHS_optimizer)
    return model
end

_set_net_interchange_schedule!(::PSY.System, area::Area, ::Nothing, ::Any) =
    set_scheduled_net_interchange!(area, nothing)

_set_net_interchange_schedule!(::PSY.System, area::Area, mw::Float64, ::Any) =
    set_scheduled_net_interchange!(area, mw * u"MW")

function _set_net_interchange_schedule!(
    sys::PSY.System,
    area::Area,
    mw::Vector{Float64},
    stamps,
)
    set_scheduled_net_interchange!(area, nothing)
    add_time_series!(
        sys,
        area,
        SingleTimeSeries(
            "scheduled_net_interchange",
            TimeArray(
                stamps,
                repeat(mw; outer = cld(length(stamps), length(mw)))[1:length(stamps)],
            ),
        ),
    )
    return
end

# Net export of Area1 in MW per time step. Area1 is the from-area of AreaInterchange "1_2".
function _area1_net_export_mw(model)
    container = IOM.get_optimization_container(model)
    flow = IOM.get_variable(container, FlowActivePowerVariable, AreaInterchange)
    base = IOM.get_model_base_power(container)
    return [JuMP.value(flow["1_2", t]) * base for t in axes(flow, 2)]
end

@testset "NetInterchangeConstraint with a fixed schedule: $network_type" for network_type in
                                                                             NET_INTERCHANGE_MODELS
    model = _net_interchange_container(
        network_type;
        schedules = Dict{String, Any}("Area1" => 40.0),
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    constraints = IOM.get_constraint(container, NetInterchangeConstraint, Area)
    @test axes(constraints, 1) == ["Area1"]
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    export_mw = _area1_net_export_mw(model)
    @test length(export_mw) == 24
    @test all(isapprox.(export_mw, 40.0; atol = 1e-6))
end

@testset "NetInterchangeConstraint sign: import on the to-area: $network_type" for network_type in
                                                                                   NET_INTERCHANGE_MODELS
    model = _net_interchange_container(
        network_type;
        schedules = Dict{String, Any}("Area2" => -30.0),
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test all(isapprox.(_area1_net_export_mw(model), 30.0; atol = 1e-6))
end

@testset "NetInterchangeConstraint with a time series schedule: $network_type" for network_type in
                                                                                   NET_INTERCHANGE_MODELS
    series = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0]
    model = _net_interchange_container(
        network_type;
        schedules = Dict{String, Any}("Area1" => series),
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    @test IOM.has_container_key(container, ScheduledNetInterchangeParameter, Area)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    expected = repeat(series; outer = 3)[1:24]
    @test all(isapprox.(_area1_net_export_mw(model), expected; atol = 1e-6))
end

@testset "NetInterchangeConstraint is absent without a schedule: $network_type" for network_type in
                                                                                    NET_INTERCHANGE_MODELS
    model = _net_interchange_container(network_type; schedules = Dict{String, Any}())
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    @test !IOM.has_container_key(container, NetInterchangeConstraint, Area)
    @test !IOM.has_container_key(container, ScheduledNetInterchangeParameter, Area)
end

@testset "A schedule without an AreaInterchange model fails the build: $network_type" for network_type in
                                                                                          NET_INTERCHANGE_MODELS
    model = _net_interchange_container(
        network_type;
        schedules = Dict{String, Any}("Area1" => 40.0),
        with_interchange = false,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.FAILED
end
