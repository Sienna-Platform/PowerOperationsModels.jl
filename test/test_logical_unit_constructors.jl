const LOGICAL_UNIT_FORMULATIONS =
    (BasicDispatch, StandardDispatch, BasicUnitCommitment, StandardUnitCommitment)

@testset "Logical unit commitment matches thermal" begin
    for F in (BasicUnitCommitment, StandardUnitCommitment),
        network in (CopperPlateNetworkModel, PTDFNetworkModel)

        thermal = PSB.build_system(PSITestSystems, "c_sys5_uc")
        logical = replace_thermals_with_logical_units!(
            PSB.build_system(PSITestSystems, "c_sys5_uc"),
        )
        @test isempty(PSY.get_components(PSY.ThermalStandard, logical))
        @test logical_unit_objective(logical, F; network) ≈
              thermal_objective(thermal, F; network) rtol = 1e-6
    end
end

@testset "Must-run and missing ramps match thermal" begin
    # Sundance is off in every hour of the plain Standard optimum, so must-run changes the cost.
    thermal = PSB.build_system(PSITestSystems, "c_sys5_uc")
    must_run = PSY.get_component(PSY.ThermalStandard, thermal, "Sundance")
    PSY.set_commitment_mode!(must_run, PSY.CommitmentModes.MUST_RUN)
    PSY.set_ramp_limits!(must_run, nothing)
    PSY.set_time_limits!(
        PSY.get_component(PSY.ThermalStandard, thermal, "Brighton"),
        nothing,
    )
    logical = replace_thermals_with_logical_units!(deepcopy(thermal))
    model = solved_model(
        logical,
        PSY.LogicalGenerationUnit,
        StandardUnitCommitment,
        CopperPlateNetworkModel,
    )
    @test _objective(model) ≈ thermal_objective(thermal, StandardUnitCommitment) rtol =
        1e-6
    @test !isapprox(
        _objective(model),
        thermal_objective(
            PSB.build_system(PSITestSystems, "c_sys5_uc"),
            StandardUnitCommitment,
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
    set_device_model!(template, ThermalStandard, StandardUnitCommitment)
    set_device_model!(template, PSY.LogicalGenerationUnit, StandardUnitCommitment)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    for T in (PSY.ThermalStandard, PSY.LogicalGenerationUnit)
        on = IOM.get_variable(container, OnVariable, T)
        @test issetequal(axes(on)[1], PSY.get_name.(PSY.get_components(T, sys)))
    end
end

# Logical units match the thermal abstracts, so every other thermal formulation must be rejected.
@testset "Logical units under other formulations fail loudly" begin
    logical = replace_thermals_with_logical_units!(
        PSB.build_system(PSITestSystems, "c_sys5_uc"),
    )
    function logical_model(F)
        template = get_thermal_dispatch_template_network(CopperPlateNetworkModel)
        delete!(IOM.get_device_models(template), :ThermalStandard)
        set_device_model!(template, PSY.LogicalGenerationUnit, F)
        return DecisionModel(
            template,
            logical;
            optimizer = HiGHS_optimizer,
            initialize_model = false,
        )
    end
    for F in (
        ThermalDispatchNoMin,
        ThermalCompactDispatch,
        ThermalCompactUnitCommitment,
        ThermalBasicCompactUnitCommitment,
        ThermalMultiStartUnitCommitment,
        FixedOutput,
    )
        @test_throws IS.ConflictingInputsError POM.validate_template(logical_model(F))
    end
    dir = mktempdir()
    model = logical_model(ThermalCompactUnitCommitment)
    @test build!(model; output_dir = dir) == IOM.ModelBuildStatus.FAILED
    @test occursin(
        "PSY.LogicalGenerationUnit does not support formulation " *
        "$(ThermalCompactUnitCommitment)",
        read(joinpath(dir, "operation_problem.log"), String),
    )
    for F in LOGICAL_UNIT_FORMULATIONS
        @test POM.validate_template(logical_model(F)) === nothing
    end
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
        @test logical_unit_objective(logical, BasicDispatch; network) ≈
              thermal_objective(thermal, BasicDispatch; network) rtol = 1e-6
    end
end

# c_sys5, not c_sys5_uc: the thermal StandardDispatch twin is infeasible on c_sys5_uc.
@testset "Logical standard dispatch with binding ramps matches its thermal twin" begin
    for network in (CopperPlateNetworkModel, PTDFNetworkModel)
        unramped = PSB.build_system(PSITestSystems, "c_sys5")
        for d in PSY.get_components(PSY.ThermalStandard, unramped)
            PSY.set_ramp_limits!(d, nothing)
        end
        thermal = tighten_ramps!(PSB.build_system(PSITestSystems, "c_sys5"))
        logical = replace_thermals_with_logical_units!(deepcopy(thermal))
        t_obj = thermal_objective(thermal, StandardDispatch; network)
        @test logical_unit_objective(logical, StandardDispatch; network) ≈
              t_obj rtol = 1e-6
        @test !isapprox(
            t_obj,
            thermal_objective(unramped, StandardDispatch; network);
            rtol = 1e-6,
        )
    end
end

@testset "Logical standard dispatch skips ramps for units without ramp limits" begin
    thermal =
        tighten_ramps!(PSB.build_system(PSITestSystems, "c_sys5"); none = ("Park City",))
    logical = replace_thermals_with_logical_units!(deepcopy(thermal))
    model = solved_model(
        logical,
        PSY.LogicalGenerationUnit,
        StandardDispatch,
        CopperPlateNetworkModel,
    )
    @test _objective(model) ≈
          thermal_objective(thermal, StandardDispatch) rtol = 1e-6
    @test issetequal(ramp_rows(model), ["Alta", "Brighton", "Solitude", "Sundance"])
end

# `case` with `name` offering the `add_mbc!` market bid over its 10-100 MW curve range.
function market_bid_system(name; start_up = nothing, case = "c_sys5_uc")
    sys = PSB.build_system(PSITestSystems, case)
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
    model = solved_model(
        logical,
        PSY.LogicalGenerationUnit,
        StandardUnitCommitment,
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
          thermal_objective(thermal, StandardUnitCommitment) rtol = 1e-6
end

# The MBC offset by p_min must be the constant first breakpoint: dispatch has no OnVariable.
function blocks_cover_power_above_min(model, sys, ::Type{T}, name) where {T}
    container = IOM.get_optimization_container(model)
    power = IOM.get_variable(container, ActivePowerVariable, T)
    blocks = IOM.get_variable(container, IOM.PiecewiseLinearBlockIncrementalOffer, T)
    p_min = 10.0 / PSY.get_base_power(sys)
    return all(axes(power)[2]) do t
        delta = sum(JuMP.value(v) for (k, v) in blocks.data if k[1] == name && k[end] == t)
        isapprox(delta + p_min, JuMP.value(power[name, t]); atol = 1e-6)
    end
end

@testset "MarketBidCost under dispatch formulations" begin
    # c_sys5 for the standard pair: StandardDispatch is infeasible on c_sys5_uc.
    for (F, case) in ((BasicDispatch, "c_sys5_uc"), (StandardDispatch, "c_sys5"))
        thermal = market_bid_system("Park City"; case)
        logical = replace_thermals_with_logical_units!(deepcopy(thermal))
        t_model = solved_model(thermal, PSY.ThermalStandard, F, CopperPlateNetworkModel)
        l_model =
            solved_model(logical, PSY.LogicalGenerationUnit, F, CopperPlateNetworkModel)
        @test blocks_cover_power_above_min(
            t_model,
            thermal,
            PSY.ThermalStandard,
            "Park City",
        )
        @test blocks_cover_power_above_min(
            l_model,
            logical,
            PSY.LogicalGenerationUnit,
            "Park City",
        )
        @test _objective(l_model) ≈ _objective(t_model) rtol = 1e-6
    end
    # ThermalDispatchNoMin has no constant p_min offset to use, so it still fails to build.
    template = get_thermal_dispatch_template_network(CopperPlateNetworkModel)
    set_device_model!(template, PSY.ThermalStandard, ThermalDispatchNoMin)
    model =
        DecisionModel(template, market_bid_system("Park City"); optimizer = TWIN_OPTIMIZER)
    @test build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.FAILED
end

# c_sys5_uc with `name` offering a time-varying `MarketBidTimeSeriesCost`, built on the unit
# after any conversion so the thermal and logical systems share nothing. Slopes are cut to a
# third so the offer undercuts the other units and its varying tranches set the dispatch.
function ts_market_bid_system(name; logical::Bool)
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    logical && replace_thermals_with_logical_units!(sys)
    T = logical ? PSY.LogicalGenerationUnit : PSY.ThermalStandard
    unit = PSY.get_component(T, sys, name)
    PSY.set_active_power_limits!(unit, (min = 10.0 * u"MW", max = 100.0 * u"MW"))
    add_mbc!(sys, make_selector(T, name))
    extend_mbc!(
        sys,
        make_selector(T, name);
        modify_baseline_pwl = pwl -> PiecewiseStepData(
            PSY.get_x_coords(pwl),
            PSY.get_y_coords(pwl) ./ 3,
        ),
        initial_varies = true,
        slopes_vary = true,
    )
    return sys
end

@testset "Logical units with MarketBidTimeSeriesCost match thermal" begin
    thermal = ts_market_bid_system("Park City"; logical = false)
    logical = ts_market_bid_system("Park City"; logical = true)
    unit = PSY.get_component(PSY.LogicalGenerationUnit, logical, "Park City")
    @test PSY.get_operation_cost(unit) isa PSY.MarketBidTimeSeriesCost
    for F in (StandardUnitCommitment, BasicDispatch)
        model =
            solved_model(logical, PSY.LogicalGenerationUnit, F, CopperPlateNetworkModel)
        power = IOM.get_variable(
            IOM.get_optimization_container(model),
            ActivePowerVariable,
            PSY.LogicalGenerationUnit,
        )
        # The offer's tranches are in use, not just its minimum.
        @test any(JuMP.value(power["Park City", t]) > 0.1 + 1e-3 for t in axes(power)[2])
        @test _objective(model) ≈ thermal_objective(thermal, F) rtol = 1e-6
    end
end

# Skipping initialization keeps Sundance offline at t0, so it starts once in the horizon.
@testset "Startup stages on logical units do not warn" begin
    stages = (hot = 300.0, warm = 600.0, cold = 900.0)
    warning = "Multi-start costs detected"
    function run(start_up, T, F)
        sys = market_bid_system("Sundance"; start_up)
        T == PSY.LogicalGenerationUnit && replace_thermals_with_logical_units!(sys)
        dir = mktempdir()
        model = solved_model(
            sys, T, F, CopperPlateNetworkModel;
            output_dir = dir, initialize_model = false,
        )
        starts = IOM.get_variable(IOM.get_optimization_container(model), StartVariable, T)
        n_starts = sum(JuMP.value.(starts["Sundance", :]))
        log = read(joinpath(dir, "operation_problem.log"), String)
        return _objective(model), n_starts, log
    end
    lu = (PSY.LogicalGenerationUnit, StandardUnitCommitment)
    t_obj, t_starts, t_log = run(stages, PSY.ThermalStandard, StandardUnitCommitment)
    l_obj, l_starts, l_log = run(stages, lu...)
    zero_obj, zero_starts, _ = run((hot = 0.0, warm = 0.0, cold = 0.0), lu...)
    @test occursin(warning, t_log)  # the log does capture this warning
    @test !occursin(warning, l_log)
    @test l_starts ≈ t_starts ≈ zero_starts ≈ 1
    @test l_obj ≈ t_obj rtol = 1e-6
    # A single-start formulation charges the costliest (cold) stage per start.
    @test l_obj - zero_obj ≈ stages.cold * l_starts rtol = 1e-6
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
    F = StandardUnitCommitment
    model = solved_model(
        logical,
        PSY.LogicalGenerationUnit,
        F,
        CopperPlateNetworkModel;
        time_series_names = ts_names(PSY.LogicalGenerationUnit, F),
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
        F;
        time_series_names = ts_names(PSY.ThermalStandard, F),
    )
    @test _objective(model) ≈ t_obj rtol = 1e-6
    @test !isapprox(_objective(model), logical_unit_objective(logical, F); rtol = 1e-6)
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
    net = CopperPlateNetworkModel
    t_model = solved_model(
        thermal, PSY.ThermalStandard, StandardUnitCommitment, net;
        services = reserves,
    )
    l_model = solved_model(
        logical, PSY.LogicalGenerationUnit, StandardUnitCommitment, net;
        services = reserves,
    )
    t_obj = _objective(t_model)
    @test _objective(l_model) ≈ t_obj rtol = 1e-6
    container = IOM.get_optimization_container(l_model)
    R = OnlineReserve{ReserveUp}
    @test haskey(
        IOM.get_variables(container),
        IOM.VariableKey(
            ActivePowerReserveVariable,
            IOM.ComponentPairKey{PSY.LogicalGenerationUnit, R},
        ),
    )
    slack(m) =
        JuMP.value.(
            IOM.get_variable(
                IOM.get_optimization_container(m),
                ReserveRequirementSlack,
                R,
            ).data,
        )
    @test maximum(abs, slack(l_model)) < 1e-7
    @test isapprox(slack(l_model), slack(t_model); atol = 1e-7)
    @test !isapprox(
        t_obj,
        thermal_objective(thermal, StandardUnitCommitment);
        rtol = 1e-6,
    )
end

# Awards of `name` into service `S` over the horizon, from a solved model.
function reserve_awards(model, ::Type{T}, ::Type{S}, service, name) where {T, S}
    award = IOM.get_variable(
        IOM.get_optimization_container(model),
        ActivePowerReserveVariable,
        IOM.ComponentPairKey{T, S},
    )
    return [JuMP.value(award[(service, name, t)]) for t in 1:24]
end

@testset "Logical units clear reserve offers like thermal" begin
    thermal = PSB.build_system(PSITestSystems, "c_sys5_uc"; add_reserves = true)
    R = OnlineReserve{ReserveUp}
    contributors, _ =
        add_device_reserve_offers!(thermal, PSY.get_component(R, thermal, "Reserve1"))
    logical = replace_thermals_with_logical_units!(deepcopy(thermal))
    services = (ServiceModel(R, RangeReserve),)
    for F in (StandardUnitCommitment, BasicUnitCommitment)
        t_model = solved_model(
            thermal,
            PSY.ThermalStandard,
            F,
            CopperPlateNetworkModel;
            services,
        )
        l_model =
            solved_model(
                logical,
                PSY.LogicalGenerationUnit,
                F,
                CopperPlateNetworkModel;
                services,
            )
        blocks = IOM.get_variable(
            IOM.get_optimization_container(l_model),
            POM.PiecewiseLinearBlockReserveOffer,
            PSY.LogicalGenerationUnit,
        )
        @test sum(JuMP.value, blocks) > 1e-3  # the offers clear
        for g in contributors
            name = PSY.get_name(g)
            @test reserve_awards(l_model, PSY.LogicalGenerationUnit, R, "Reserve1", name) ≈
                  reserve_awards(t_model, PSY.ThermalStandard, R, "Reserve1", name) atol =
                1e-6
        end
        @test _objective(l_model) ≈ _objective(t_model) rtol = 1e-6
    end
end

@testset "An off logical unit supplies offline reserve" begin
    thermal, offunit = _offline_ordc_uc_system()
    off_name = PSY.get_name(offunit)
    logical = replace_thermals_with_logical_units!(deepcopy(thermal))
    services = (
        ServiceModel(OfflineReserve, StepwiseCostReserve),
        ServiceModel(OnlineReserve{ReserveUp}, StepwiseCostReserve),
    )
    for F in (StandardUnitCommitment, BasicUnitCommitment)
        t_model = solved_model(
            thermal,
            PSY.ThermalStandard,
            F,
            CopperPlateNetworkModel;
            services,
        )
        l_model =
            solved_model(
                logical,
                PSY.LogicalGenerationUnit,
                F,
                CopperPlateNetworkModel;
                services,
            )
        container = IOM.get_optimization_container(l_model)
        @test IOM.has_container_key(
            container, POM.OfflineReserveBandConstraint, PSY.LogicalGenerationUnit)
        on = IOM.get_variable(container, OnVariable, PSY.LogicalGenerationUnit)
        @test all(JuMP.value(on[off_name, t]) < 0.5 for t in 1:24)
        T = PSY.LogicalGenerationUnit
        @test sum(reserve_awards(l_model, T, OfflineReserve, "NSPIN", off_name)) > 1.0
        @test maximum(
            reserve_awards(l_model, T, OnlineReserve{ReserveUp}, "SPIN", off_name),
        ) <
              1e-3
        @test reserve_awards(l_model, T, OfflineReserve, "NSPIN", off_name) ≈
              reserve_awards(
            t_model,
            PSY.ThermalStandard,
            OfflineReserve,
            "NSPIN",
            off_name,
        ) atol =
            1e-6
        @test _objective(l_model) ≈ _objective(t_model) rtol = 1e-6
    end
end
