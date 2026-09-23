"""
Tests for time-varying deployed fractions.

A reserve's `deployed_fraction` scalar is a dimensionless share of the award assumed to be
physically deployed. Attaching a `"deployed_fraction"` profile makes it vary over the horizon,
following the same scalar-times-normalized-profile convention `requirement` uses.
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

function _build_deployed_fraction_model(sys)
    template = PowerOperationsProblemTemplate()
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, RenewableNonDispatch, FixedOutput)
    set_device_model!(template, HydroDispatch, HydroDispatchRunOfRiver)
    set_service_model!(template, OnlineReserve{ReserveUp}, RangeReserve)
    set_service_model!(template, OnlineReserve{ReserveDown}, RangeReserve)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
    return model
end

@testset "deployed_fraction_values falls back to the scalar" begin
    sys, reserve = _deployed_fraction_test_system(; deployed_fraction = 0.4)
    model = _build_deployed_fraction_model(sys)
    container = IOM.get_optimization_container(model)

    @test !PSY.has_time_series(reserve, "deployed_fraction")

    service_model = ServiceModel(typeof(reserve), RangeReserve)
    vals = POM.deployed_fraction_values(container, service_model, reserve)
    @test vals isa Vector{Float64}
    @test length(vals) == length(IOM.get_time_steps(container))
    @test all(isequal(0.4), vals)
end

@testset "deployed_fraction_values scales the profile by the scalar" begin
    profile = collect(range(0.1, 0.8; length = 48))
    sys, reserve =
        _deployed_fraction_test_system(; add_profile = profile, deployed_fraction = 0.5)
    model = _build_deployed_fraction_model(sys)
    container = IOM.get_optimization_container(model)

    @test PSY.has_time_series(reserve, "deployed_fraction")

    service_model = ServiceModel(typeof(reserve), RangeReserve)
    @test POM.get_time_series_names(service_model)[DeployedFractionTimeSeriesParameter] ==
          "deployed_fraction"

    vals = POM.deployed_fraction_values(container, service_model, reserve)
    horizon = length(IOM.get_time_steps(container))
    @test vals isa Vector{Float64}
    @test length(vals) == horizon
    @test vals ≈ 0.5 .* profile[1:horizon]
end

# The guard lives in template validation, which `mock_construct_devices!` skips, so these
# cases need a real `DecisionModel` build.
@testset "A deployed_fraction profile requires rebuild_model under recurrent solves" begin
    profile = collect(range(0.1, 0.8; length = 48))
    sys, _ = _deployed_fraction_test_system(; add_profile = profile)

    template = PowerOperationsProblemTemplate()
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, HydroDispatch, HydroDispatchRunOfRiver)
    set_service_model!(template, OnlineReserve{ReserveUp}, RangeReserve)
    set_service_model!(template, OnlineReserve{ReserveDown}, RangeReserve)

    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    IOM.get_optimization_container(model).built_for_recurrent_solves = true

    @test_throws IS.ConflictingInputsError POM.validate_template(model)
end

@testset "A deployed_fraction profile builds under recurrent solves with rebuild_model" begin
    profile = collect(range(0.1, 0.8; length = 48))
    sys, _ = _deployed_fraction_test_system(; add_profile = profile)

    template = PowerOperationsProblemTemplate()
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, HydroDispatch, HydroDispatchRunOfRiver)
    set_service_model!(template, OnlineReserve{ReserveUp}, RangeReserve)
    set_service_model!(template, OnlineReserve{ReserveDown}, RangeReserve)

    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer, rebuild_model = true)
    IOM.get_optimization_container(model).built_for_recurrent_solves = true

    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
end

@testset "No deployed_fraction profile is fine under recurrent solves" begin
    sys, _ = _deployed_fraction_test_system()

    template = PowerOperationsProblemTemplate()
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, HydroDispatch, HydroDispatchRunOfRiver)
    set_service_model!(template, OnlineReserve{ReserveUp}, RangeReserve)
    set_service_model!(template, OnlineReserve{ReserveDown}, RangeReserve)

    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    IOM.get_optimization_container(model).built_for_recurrent_solves = true

    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          ModelBuildStatus.BUILT
end

@testset "The deployed_fraction series name is overridable per ServiceModel" begin
    profile = collect(range(0.1, 0.8; length = 48))
    # The series is attached under "deployed_fraction"; a ServiceModel pointing elsewhere, or
    # declaring no name at all, must fall back to the scalar rather than pick it up.
    sys, reserve =
        _deployed_fraction_test_system(; add_profile = profile, deployed_fraction = 0.5)
    model = _build_deployed_fraction_model(sys)
    container = IOM.get_optimization_container(model)

    renamed = ServiceModel(
        typeof(reserve),
        RangeReserve;
        time_series_names = Dict{Type{<:POM.TimeSeriesParameter}, String}(
            DeployedFractionTimeSeriesParameter => "other_name",
        ),
    )
    @test POM.deployed_fraction_values(container, renamed, reserve) ==
          fill(0.5, length(IOM.get_time_steps(container)))

    declared_none = ServiceModel(
        typeof(reserve),
        RangeReserve;
        time_series_names = Dict{Type{<:POM.TimeSeriesParameter}, String}(),
    )
    @test POM.deployed_fraction_values(container, declared_none, reserve) ==
          fill(0.5, length(IOM.get_time_steps(container)))
end
