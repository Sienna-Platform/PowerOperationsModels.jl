"""
Tests for time-varying deployed fractions.

A reserve's `deployed_fraction` scalar is a dimensionless share of the award assumed to be
physically deployed. Attaching a `"deployed_fraction"` profile makes it vary over the horizon,
following the same scalar-times-normalized-profile convention `requirement` uses. The profile
is a left-hand-side parameter: a `Float64` container whose values reach the model only through
product rows that are rewritten in place between solves.
"""

# Adds a deployed-fraction profile as a `SingleTimeSeries`. Call before
# `transform_single_time_series!` so it is promoted to the forecast type the model reads.
function _add_deployed_fraction_ts!(
    sys::PSY.System,
    reserve::PSY.AbstractReserve,
    profile::Vector{Float64};
    initial_timestamp::DateTime = DateTime("2024-01-01T00:00:00"),
    resolution::Dates.Period = Hour(1),
)
    stamps = range(initial_timestamp; step = resolution, length = length(profile))
    PSY.add_time_series!(
        sys,
        reserve,
        PSY.SingleTimeSeries("deployed_fraction", TimeArray(collect(stamps), profile)),
    )
    return
end

function _deployed_fraction_test_system(;
    add_profile::Union{Nothing, Vector{Float64}} = nothing,
    deployed_fraction::Float64 = 0.4,
    horizon::Dates.Period = Hour(4),
)
    sys = PSB.build_system(
        PSITestSystems,
        "c_sys5_hy";
        add_single_time_series = true,
        add_reserves = true,
    )
    reserve = only(get_components(OnlineReserve{ReserveUp}, sys))
    set_deployed_fraction!(reserve, deployed_fraction)
    set_requirement!(reserve, 0.01 * PSY.SU)
    if add_profile !== nothing
        _add_deployed_fraction_ts!(sys, reserve, add_profile)
    end
    transform_single_time_series!(sys, horizon, horizon)
    return sys, reserve
end

function _deployed_fraction_template(;
    up_model = ServiceModel(OnlineReserve{ReserveUp}, RangeReserve),
)
    template = PowerOperationsProblemTemplate()
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, HydroDispatch, HydroDispatchRunOfRiver)
    set_service_model!(template, up_model)
    set_service_model!(template, OnlineReserve{ReserveDown}, RangeReserve)
    return template
end

function _build_deployed_fraction_model(
    sys;
    template = _deployed_fraction_template(),
    recurrent = false,
    rebuild_model = false,
)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer, rebuild_model)
    IOM.get_optimization_container(model).built_for_recurrent_solves = recurrent
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    return model
end

_hydro_award(container, reserve) = IOM.get_variable(
    container,
    ActivePowerReserveVariable,
    IOM.ComponentPairKey{HydroDispatch, typeof(reserve)},
)

_served_up_coefficient(container, reserve, hy_name, t) = JuMP.coefficient(
    IOM.get_expression(container, HydroServedReserveUpExpression, HydroDispatch)[
        hy_name,
        t,
    ],
    _hydro_award(container, reserve)[(PSY.get_name(reserve), hy_name, t)],
)

_has_deployed_fraction_container(container) = IOM.has_container_key(
    container,
    DeployedFractionParameter,
    OnlineReserve{ReserveUp},
)

@testset "DeployedFractionParameter is a time-series LHS parameter" begin
    @test DeployedFractionParameter <: IOM.TimeSeriesLHSParameter
    @test DeployedFractionParameter <: IOM.LeftHandSideParameter
    @test !(DeployedFractionParameter <: POM.TimeSeriesParameter)
    @test IOM.should_write_resulting_value(DeployedFractionParameter)
end

@testset "No profile: the scalar is a fixed coefficient and no container is built" begin
    sys, reserve = _deployed_fraction_test_system(; deployed_fraction = 0.4)
    model = _build_deployed_fraction_model(sys)
    container = IOM.get_optimization_container(model)
    hy_name = get_name(only(get_components(HydroDispatch, sys)))

    @test !_has_deployed_fraction_container(container)
    @test !has_deployed_products(
        container,
        ActivePowerReserveVariable,
        HydroDispatch,
        reserve,
    )
    for t in IOM.get_time_steps(container)
        @test _served_up_coefficient(container, reserve, hy_name, t) ≈ 0.4
    end
end

@testset "Profile: a Float64 container whose product rows carry scalar * profile" begin
    profile = collect(range(0.1, 0.8; length = 48))
    sys, reserve =
        _deployed_fraction_test_system(; add_profile = profile, deployed_fraction = 0.5)
    model = _build_deployed_fraction_model(sys)
    container = IOM.get_optimization_container(model)
    hy_name = get_name(only(get_components(HydroDispatch, sys)))
    time_steps = IOM.get_time_steps(container)

    @test _has_deployed_fraction_container(container)
    param_container =
        IOM.get_parameter(container, DeployedFractionParameter, OnlineReserve{ReserveUp})
    @test eltype(IOM.get_parameter_array(param_container)) == Float64
    @test IOM.get_parameter_array_data(param_container)[1, :] ≈ profile[time_steps]
    @test all(==(0.5), IOM.get_multiplier_array(param_container)[get_name(reserve), :])

    awards = _hydro_award(container, reserve)
    for t in time_steps
        @test deployed_fraction_in_model(
            container,
            ActivePowerReserveVariable,
            HydroDispatch,
            reserve,
            hy_name,
            awards[(get_name(reserve), hy_name, t)],
            t,
        ) ≈ 0.5 * profile[t]
    end
end

@testset "Profile under recurrent solves without rebuild builds a linear model" begin
    profile = collect(range(0.1, 0.8; length = 48))
    sys, _ = _deployed_fraction_test_system(; add_profile = profile)
    model = _build_deployed_fraction_model(sys; recurrent = true)
    jump_model = IOM.get_jump_model(IOM.get_optimization_container(model))
    for (F, _) in JuMP.list_of_constraint_types(jump_model)
        @test !(F <: JuMP.GenericQuadExpr)
    end
end

@testset "Profile under recurrent solves with rebuild_model builds" begin
    profile = collect(range(0.1, 0.8; length = 48))
    sys, _ = _deployed_fraction_test_system(; add_profile = profile)
    model = _build_deployed_fraction_model(sys; recurrent = true, rebuild_model = true)
    @test _has_deployed_fraction_container(IOM.get_optimization_container(model))
end

@testset "No profile is fine under recurrent solves" begin
    sys, _ = _deployed_fraction_test_system()
    model = _build_deployed_fraction_model(sys; recurrent = true)
    @test !_has_deployed_fraction_container(IOM.get_optimization_container(model))
end

@testset "A profile of the wrong time series type is rejected" begin
    # Attached after the transform, the series exists only as a SingleTimeSeries, not as the
    # forecast type the model reads. Silently falling back to the scalar would hide it.
    sys, reserve = _deployed_fraction_test_system()
    _add_deployed_fraction_ts!(sys, reserve, collect(range(0.1, 0.8; length = 48)))
    model = DecisionModel(_deployed_fraction_template(), sys; optimizer = HiGHS_optimizer)
    @test_throws IS.ConflictingInputsError POM.validate_template(model)
end

@testset "The deployed_fraction series name is overridable per ServiceModel" begin
    profile = collect(range(0.1, 0.8; length = 48))
    # The series is attached under "deployed_fraction"; a ServiceModel pointing elsewhere, or
    # declaring no name at all, must fall back to the scalar rather than pick it up.
    for names in (
        Dict{Type{<:IOM.ParameterType}, String}(DeployedFractionParameter => "other_name"),
        Dict{Type{<:IOM.ParameterType}, String}(),
    )
        sys, reserve =
            _deployed_fraction_test_system(; add_profile = profile, deployed_fraction = 0.5)
        up_model = ServiceModel(
            OnlineReserve{ReserveUp},
            RangeReserve;
            time_series_names = names,
        )
        model = _build_deployed_fraction_model(
            sys;
            template = _deployed_fraction_template(; up_model = up_model),
        )
        container = IOM.get_optimization_container(model)
        hy_name = get_name(only(get_components(HydroDispatch, sys)))
        @test !_has_deployed_fraction_container(container)
        for t in IOM.get_time_steps(container)
            @test _served_up_coefficient(container, reserve, hy_name, t) ≈ 0.5
        end
    end
end

@testset "Profiled and static reserves on one storage device" begin
    profile = collect(range(0.2, 0.9; length = 48))
    sys = PSB.build_system(
        PSITestSystems,
        "c_sys5_bat";
        add_single_time_series = true,
        add_reserves = true,
    )
    for r in PSY.get_components(PSY.has_demand_curve, PSY.OnlineReserve, sys)
        PSY.set_available!(r, false)
    end
    up = only([
        r for r in get_components(OnlineReserve{ReserveUp}, sys) if get_available(r)
    ])
    down = only([
        r for r in get_components(OnlineReserve{ReserveDown}, sys) if get_available(r)
    ])
    set_deployed_fraction!(up, 0.5)
    set_deployed_fraction!(down, 0.3)
    _add_deployed_fraction_ts!(sys, up, profile)
    transform_single_time_series!(sys, Hour(4), Hour(4))

    template = PowerOperationsProblemTemplate()
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(
        template,
        DeviceModel(EnergyReservoirStorage, StorageDispatchWithReserves),
    )
    set_service_model!(template, OnlineReserve{ReserveUp}, RangeReserve)
    set_service_model!(template, OnlineReserve{ReserveDown}, RangeReserve)
    model = _build_deployed_fraction_model(sys; template = template)
    container = IOM.get_optimization_container(model)

    V = EnergyReservoirStorage
    U = AncillaryServiceVariableDischarge
    name = "Bat"
    device = get_component(V, sys, name)
    up_award = IOM.get_variable(container, U, V, POM._service_container_meta(up))
    down_award = IOM.get_variable(container, U, V, POM._service_container_meta(down))
    DownExpr =
        POM.StorageReserveBalanceExpression{
            ReserveDown,
            POM.DeployedReserve,
            POM.DischargeSide,
        }
    down_expr = IOM.get_expression(container, DownExpr, V)
    down_base =
        POM.get_variable_multiplier(U, DownExpr, device, StorageDispatchWithReserves, down)

    @test has_deployed_products(container, U, V, up)
    @test !has_deployed_products(container, U, V, down)
    for t in IOM.get_time_steps(container)
        @test deployed_fraction_in_model(container, U, V, up, name, up_award[name, t], t) ≈
              0.5 * profile[t]
        @test JuMP.coefficient(down_expr[name, t], down_award[name, t]) ≈ down_base * 0.3
    end
end

@testset "A profiled reserve shared by two devices binds each award to one series row" begin
    profile = collect(range(0.1, 0.8; length = 48))
    sys = PSB.build_system(
        PSITestSystems,
        "c_sys5_hy";
        add_single_time_series = true,
        add_reserves = true,
    )
    reserve = only(get_components(OnlineReserve{ReserveUp}, sys))
    set_deployed_fraction!(reserve, 0.5)
    set_requirement!(reserve, 0.01 * PSY.SU)
    hy = only(get_components(HydroDispatch, sys))
    hy_copy = HydroDispatch(;
        name = "HydroDispatchCopy",
        available = get_available(hy),
        bus = get_bus(hy),
        active_power = get_active_power(hy, PSY.SU),
        reactive_power = get_reactive_power(hy, PSY.SU),
        rating = get_rating(hy, PSY.SU),
        prime_mover_type = get_prime_mover_type(hy),
        active_power_limits = get_active_power_limits(hy, PSY.SU),
        reactive_power_limits = get_reactive_power_limits(hy, PSY.SU),
        ramp_limits = get_ramp_limits(hy, PSY.SU / u"minute"),
        time_limits = get_time_limits(hy),
        base_power = get_base_power(hy, PSY.NU),
        input_basis = CU,
    )
    add_component!(sys, hy_copy)
    copy_time_series!(hy_copy, hy)
    add_service!(hy_copy, reserve, sys)
    _add_deployed_fraction_ts!(sys, reserve, profile)
    transform_single_time_series!(sys, Hour(4), Hour(4))

    model = _build_deployed_fraction_model(sys)
    container = IOM.get_optimization_container(model)
    param_container =
        IOM.get_parameter(container, DeployedFractionParameter, OnlineReserve{ReserveUp})
    @test size(IOM.get_parameter_array(param_container), 1) == 1

    awards = _hydro_award(container, reserve)
    for hy_name in (get_name(hy), get_name(hy_copy)), t in IOM.get_time_steps(container)
        @test deployed_fraction_in_model(
            container,
            ActivePowerReserveVariable,
            HydroDispatch,
            reserve,
            hy_name,
            awards[(get_name(reserve), hy_name, t)],
            t,
        ) ≈ 0.5 * profile[t]
    end
    key = IOM.ParameterKey(DeployedFractionParameter, OnlineReserve{ReserveUp})
    @test length(container.coefficient_bindings[key]) ==
          2 * length(IOM.get_time_steps(container))
end
