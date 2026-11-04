@testset "Logical unit formulation types" begin
    @test LogicalUnitBasicDispatch <: AbstractLogicalUnitDispatch
    @test LogicalUnitStandardDispatch <: AbstractLogicalUnitDispatch
    @test LogicalUnitBasicCommitment <: AbstractLogicalUnitCommitment
    @test LogicalUnitStandardCommitment <: AbstractLogicalUnitCommitment
    @test !(LogicalUnitStandardCommitment <: AbstractThermalFormulation)
    @test PSY.LogicalGenerationUnit <: PowerOperationsModels.ThermalOrLogicalUnit
end

@testset "Logical unit commitment matches its thermal twin" begin
    for (lf, tf) in (
            (LogicalUnitBasicCommitment, ThermalBasicUnitCommitment),
            (LogicalUnitStandardCommitment, ThermalStandardUnitCommitment),
        ),
        network in (CopperPlateNetworkModel, PTDFNetworkModel)

        thermal = PSB.build_system(PSITestSystems, "c_sys5_uc")
        logical = replace_thermals_with_logical_units!(
            PSB.build_system(PSITestSystems, "c_sys5_uc"),
        )
        @test isempty(PSY.get_components(PSY.ThermalStandard, logical))
        @test logical_unit_objective(logical, lf; network) ≈
              thermal_objective(thermal, tf; network) rtol = 1e-6
    end
end

@testset "Must-run and missing ramps match thermal" begin
    # Sundance is off in every hour of the plain Standard optimum, so must-run changes the cost.
    thermal = PSB.build_system(PSITestSystems, "c_sys5_uc")
    must_run = PSY.get_component(PSY.ThermalStandard, thermal, "Sundance")
    PSY.set_commitment_mode!(must_run, PSY.CommitmentModes.MUST_RUN)
    PSY.set_ramp_limits!(must_run, nothing)
    logical = replace_thermals_with_logical_units!(deepcopy(thermal))
    model = solved_commitment_model(
        logical,
        PSY.LogicalGenerationUnit,
        LogicalUnitStandardCommitment,
        CopperPlateNetworkModel,
    )
    @test _objective(model) ≈ thermal_objective(thermal, ThermalStandardUnitCommitment) rtol =
        1e-6
    @test !isapprox(
        _objective(model),
        thermal_objective(
            PSB.build_system(PSITestSystems, "c_sys5_uc"),
            ThermalStandardUnitCommitment,
        );
        rtol = 1e-6,
    )

    container = IOM.get_optimization_container(model)
    for V in (OnVariable, StartVariable, StopVariable)
        names = axes(IOM.get_variable(container, V, PSY.LogicalGenerationUnit))[1]
        @test "Sundance" ∉ names
        @test issetequal(names, ["Alta", "Brighton", "Park City", "Solitude"])
    end
    power = IOM.get_variable(container, ActivePowerVariable, PSY.LogicalGenerationUnit)
    unit = PSY.get_component(PSY.LogicalGenerationUnit, logical, "Sundance")
    p_min = PSY.get_active_power_limits(unit, u"SU").min
    @test all(JuMP.lower_bound(power["Sundance", t]) == p_min for t in axes(power)[2])
end

@testset "Logical units next to thermal units" begin
    sys = replace_thermals_with_logical_units!(
        PSB.build_system(PSITestSystems, "c_sys5_uc");
        names = ("Alta", "Brighton"),
    )
    @test length(PSY.get_components(PSY.LogicalGenerationUnit, sys)) == 2
    template = get_thermal_dispatch_template_network(CopperPlateNetworkModel)
    set_device_model!(template, ThermalStandard, ThermalStandardUnitCommitment)
    set_device_model!(template, PSY.LogicalGenerationUnit, LogicalUnitStandardCommitment)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    @test haskey(
        IOM.get_variables(container),
        IOM.VariableKey(OnVariable, PSY.ThermalStandard),
    )
    @test haskey(
        IOM.get_variables(container),
        IOM.VariableKey(OnVariable, PSY.LogicalGenerationUnit),
    )
end

@testset "A thermal formulation on logical units fails loudly" begin
    logical = replace_thermals_with_logical_units!(
        PSB.build_system(PSITestSystems, "c_sys5_uc"),
    )
    template = get_thermal_dispatch_template_network(CopperPlateNetworkModel)
    delete!(IOM.get_device_models(template), :ThermalStandard)
    set_device_model!(template, PSY.LogicalGenerationUnit, ThermalStandardUnitCommitment)
    model = DecisionModel(template, logical; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.FAILED
end

# Ramps of 10% of Pmax per hour, which bind on the c_sys5 load profile; `none` units get no ramps.
function tighten_ramps!(sys; none = ())
    for d in PSY.get_components(PSY.ThermalStandard, sys)
        if PSY.get_name(d) in none
            PSY.set_ramp_limits!(d, nothing)
        else
            r = PSY.get_active_power_limits(d, u"SU").max / 600
            PSY.set_ramp_limits!(d, (up = r * u"SU/minute", down = r * u"SU/minute"))
        end
    end
    return sys
end

function ramp_rows(model)
    container = IOM.get_optimization_container(model)
    rows = Set{String}()
    for (k, c) in IOM.get_constraints(container)
        IOM.get_component_type(k) == PSY.LogicalGenerationUnit &&
            IOM.get_entry_type(k) == RampConstraint &&
            union!(rows, axes(c)[1])
    end
    return rows
end

@testset "Logical unit basic dispatch matches its thermal twin" begin
    for network in (CopperPlateNetworkModel, PTDFNetworkModel)
        thermal = PSB.build_system(PSITestSystems, "c_sys5_uc")
        logical = replace_thermals_with_logical_units!(
            PSB.build_system(PSITestSystems, "c_sys5_uc"),
        )
        @test logical_unit_objective(logical, LogicalUnitBasicDispatch; network) ≈
              thermal_objective(thermal, ThermalBasicDispatch; network) rtol = 1e-6
    end
end

# c_sys5, not c_sys5_uc: the thermal ThermalStandardDispatch twin is infeasible on c_sys5_uc.
@testset "Logical standard dispatch with binding ramps matches its thermal twin" begin
    for network in (CopperPlateNetworkModel, PTDFNetworkModel)
        unramped = PSB.build_system(PSITestSystems, "c_sys5")
        for d in PSY.get_components(PSY.ThermalStandard, unramped)
            PSY.set_ramp_limits!(d, nothing)
        end
        thermal = tighten_ramps!(PSB.build_system(PSITestSystems, "c_sys5"))
        logical = replace_thermals_with_logical_units!(deepcopy(thermal))
        t_obj = thermal_objective(thermal, ThermalStandardDispatch; network)
        @test logical_unit_objective(logical, LogicalUnitStandardDispatch; network) ≈
              t_obj rtol = 1e-6
        @test !isapprox(
            t_obj,
            thermal_objective(unramped, ThermalStandardDispatch; network);
            rtol = 1e-6,
        )
    end
end

@testset "Logical standard dispatch skips ramps for units without ramp limits" begin
    thermal =
        tighten_ramps!(PSB.build_system(PSITestSystems, "c_sys5"); none = ("Park City",))
    logical = replace_thermals_with_logical_units!(deepcopy(thermal))
    model = solved_commitment_model(
        logical,
        PSY.LogicalGenerationUnit,
        LogicalUnitStandardDispatch,
        CopperPlateNetworkModel,
    )
    @test _objective(model) ≈
          thermal_objective(thermal, ThermalStandardDispatch) rtol = 1e-6
    @test isempty(
        ramp_rows(model) ∩ ["Park City"],
    )
    @test issetequal(ramp_rows(model), ["Alta", "Brighton", "Solitude", "Sundance"])
end

# c_sys5_uc with `name` offering the `add_mbc!` market bid over its 10-100 MW curve range.
function market_bid_system(name; start_up = nothing)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    add_mbc!(sys, make_selector(PSY.ThermalStandard, name))
    unit = PSY.get_component(PSY.ThermalStandard, sys, name)
    PSY.set_active_power_limits!(unit, (min = 10.0 * u"MW", max = 100.0 * u"MW"))
    isnothing(start_up) || PSY.set_start_up!(PSY.get_operation_cost(unit), start_up)
    return sys
end

@testset "Logical units with MarketBidCost match thermal" begin
    thermal = market_bid_system("Park City")
    logical = replace_thermals_with_logical_units!(deepcopy(thermal))
    unit = PSY.get_component(PSY.LogicalGenerationUnit, logical, "Park City")
    @test PSY.get_operation_cost(unit) isa PSY.MarketBidCost
    model = solved_commitment_model(
        logical,
        PSY.LogicalGenerationUnit,
        LogicalUnitStandardCommitment,
        CopperPlateNetworkModel,
    )
    @test haskey(
        IOM.get_variables(IOM.get_optimization_container(model)),
        IOM.VariableKey(
            IOM.PiecewiseLinearBlockIncrementalOffer,
            PSY.LogicalGenerationUnit,
        ),
    )
    @test _objective(model) ≈
          thermal_objective(thermal, ThermalStandardUnitCommitment) rtol = 1e-6
end

@testset "Startup stages on logical units do not warn" begin
    stages = (hot = 300.0, warm = 600.0, cold = 900.0)
    thermal = market_bid_system("Park City"; start_up = stages)
    logical = replace_thermals_with_logical_units!(deepcopy(thermal))
    warning = "Multi-start costs detected"
    function build_log(sys, T, F)
        dir = mktempdir()
        model =
            solved_commitment_model(sys, T, F, CopperPlateNetworkModel; output_dir = dir)
        return _objective(model), read(joinpath(dir, "operation_problem.log"), String)
    end
    t_obj, t_log = build_log(thermal, PSY.ThermalStandard, ThermalStandardUnitCommitment)
    l_obj, l_log = build_log(
        logical,
        PSY.LogicalGenerationUnit,
        LogicalUnitStandardCommitment,
    )
    @test occursin(warning, t_log)  # the log does capture this warning
    @test !occursin(warning, l_log)
    @test l_obj ≈ t_obj rtol = 1e-6
end

# Per-hour `max_active_power` on every thermal, 100% of Pmax for 12 hours, then 80%.
function add_max_power_series!(sys)
    load = first(PSY.get_components(PSY.PowerLoad, sys))
    load_ts = PSY.get_time_series(PSY.Deterministic, load, "max_active_power")
    data = OrderedDict(
        k => [t <= 12 ? 1.0 : 0.8 for t in eachindex(v)] for
        (k, v) in PSY.get_data(load_ts)
    )
    for d in PSY.get_components(PSY.ThermalStandard, sys)
        ts = PSY.Deterministic(;
            name = "max_active_power",
            data,
            resolution = IS.get_resolution(load_ts),
            interval = IS.get_interval(load_ts),
        )
        PSY.add_time_series!(sys, d, ts)
    end
    return sys
end

@testset "Per-hour max power on logical units" begin
    thermal = add_max_power_series!(PSB.build_system(PSITestSystems, "c_sys5_uc"))
    logical = replace_thermals_with_logical_units!(deepcopy(thermal))
    @test all(
        PSY.has_time_series(d, PSY.Deterministic, "max_active_power") for
        d in PSY.get_components(PSY.LogicalGenerationUnit, logical)
    )
    ts_names(T, F) = merge(
        POM.get_default_time_series_names(T, F),
        Dict(ActivePowerTimeSeriesParameter => "max_active_power"),
    )
    lf, tf = LogicalUnitStandardCommitment, ThermalStandardUnitCommitment
    model = solved_commitment_model(
        logical,
        PSY.LogicalGenerationUnit,
        lf,
        CopperPlateNetworkModel;
        time_series_names = ts_names(PSY.LogicalGenerationUnit, lf),
    )
    @test haskey(
        IOM.get_constraints(IOM.get_optimization_container(model)),
        IOM.ConstraintKey(
            ActivePowerVariableTimeSeriesLimitsConstraint,
            PSY.LogicalGenerationUnit,
            "ub",
        ),
    )
    t_obj = thermal_objective(
        thermal,
        tf;
        time_series_names = ts_names(PSY.ThermalStandard, tf),
    )
    @test _objective(model) ≈ t_obj rtol = 1e-6
    @test !isapprox(_objective(model), logical_unit_objective(logical, lf); rtol = 1e-6)
end

@testset "Logical units provide reserves" begin
    reserves = (ServiceModel(OnlineReserve{ReserveUp}, RangeReserve; use_slacks = true),)
    thermal = PSB.build_system(PSITestSystems, "c_sys5_uc"; add_reserves = true)
    logical = replace_thermals_with_logical_units!(deepcopy(thermal))
    for d in PSY.get_components(PSY.LogicalGenerationUnit, logical)
        twin = PSY.get_component(PSY.ThermalStandard, thermal, PSY.get_name(d))
        @test issetequal(
            PSY.get_name.(PSY.get_services(d)),
            PSY.get_name.(PSY.get_services(twin)),
        )
    end
    t_obj = thermal_objective(thermal, ThermalStandardUnitCommitment; services = reserves)
    @test logical_unit_objective(
        logical,
        LogicalUnitStandardCommitment;
        services = reserves,
    ) ≈
          t_obj rtol = 1e-6
    @test !isapprox(
        t_obj,
        thermal_objective(thermal, ThermalStandardUnitCommitment);
        rtol = 1e-6,
    )
end
