function add_dummy_time_series_data!(sys)
    # Attach dummy data so the problem builds:
    dummy_data = Dict(
        DateTime("2020-01-01T08:00:00") => [5.0, 6, 7, 7, 7],
        DateTime("2020-01-01T08:30:00") => [9.0, 9, 9, 9, 8],
        DateTime("2020-01-01T09:00:00") => [6.0, 6, 5, 5, 4],
    )
    resolution = Dates.Minute(5)
    dummy_forecast = Deterministic("max_active_power", dummy_data, resolution)
    load = collect(get_components(StandardLoad, sys))[1]
    add_time_series!(sys, load, dummy_forecast)
    return sys
end

# Regression test for https://github.com/Sienna-Platform/PowerSimulations.jl/issues/1594
# Combines a NetworkModel with radial + degree-two reductions, a Line DeviceModel
# with a filter_function, and a request for FlowRateConstraint duals. Before the
# fix in src/devices_models/devices/common/add_constraint_dual.jl, the dual
# container was sized along PSY.get_name.(devices) — every device passing the
# filter — while the FlowRateConstraint container was sized along the
# post-reduction axis from get_branch_argument_constraint_axis. The resulting
# axis mismatch raised DimensionMismatch in process_duals during dual
# extraction. Building a model is enough to detect the regression: after the
# fix, axes(dual)[1] must equal axes(constraint)[1] for every meta.
@testset "FlowRateConstraint duals with branch filter and network reductions" begin
    sys = build_system(PSITestSystems, "case11_network_reductions")
    add_dummy_time_series_data!(sys)
    nr = NetworkReduction[RadialReduction(), DegreeTwoReduction()]
    ptdf = PTDF(sys; network_reductions = nr)

    template = PowerOperationsProblemTemplate(
        NetworkModel(PTDFNetworkModel;
            network_matrix = ptdf,
            duals = [CopperPlateBalanceConstraint],
            reduce_radial_branches = PNM.has_radial_reduction(ptdf.network_reduction_data),
            reduce_degree_two_branches = PNM.has_degree_two_reduction(
                ptdf.network_reduction_data,
            ),
            use_slacks = false),
    )
    # Mirror the filter shape from issue #1594: a voltage threshold that selects
    # all lines in this all-230 kV system. The filter is registered (so the
    # filter_function code path runs) but does not exclude any branch from a
    # series chain, so reductions still drop lines from the constraint axis.
    set_device_model!(
        template,
        DeviceModel(
            Line,
            StaticBranch;
            duals = [FlowRateConstraint],
            attributes = Dict(
                "filter_function" =>
                    x -> PSY.get_base_voltage(PSY.get_from(PSY.get_arc(x))) >= 230.0,
            ),
        ),
    )
    set_device_model!(template, Transformer2W, StaticBranch)
    ps_model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = get_optimization_container(ps_model)
    # The unfiltered Line set has 12 entries; full reduction leaves 6 entries
    # in the constraint axis. The dual container must use the same 6 entries.
    for meta in ("lb", "ub")
        cons_key = ConstraintKey(FlowRateConstraint, Line, meta)
        cons = get_constraint(container, cons_key)
        dual = get_duals(container)[cons_key]
        @test axes(dual)[1] == axes(cons)[1]
        @test length(axes(cons)[1]) <
              length(collect(get_components(Line, sys)))
        @test "4-5-i_1" in axes(cons)[1]
    end
end

# --- Network-constructor coverage ported from PSI test_network_constructors.jl ---
# Adapted to POM: brittle exact `moi_tests` counts are dropped in favor of
# build/solve/objective/constraint-presence assertions (model structure shifted in the
# IOM/POM refactor); native DCPNetworkModel/ACPNetworkModel and the PowerModels nonlinear
# formulations (ACR/ACT/NFA/DCPLL/LPACC) are covered elsewhere / not wired for build and
# are intentionally not duplicated here.

@testset "Network Copper Plate" begin
    template = get_thermal_dispatch_template_network(CopperPlateNetworkModel)
    for (sys_name, objval) in
        (("c_sys5", 240000.0), ("c_sys14", 142000.0), ("c_sys14_dc", 142000.0))
        sys = PSB.build_system(PSITestSystems, sys_name)
        ps_model = DecisionModel(
            template,
            sys;
            optimizer = HiGHS_optimizer,
            store_variable_names = true,
        )
        @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        psi_constraint_test(
            ps_model,
            [ConstraintKey(CopperPlateBalanceConstraint, PSY.System)],
        )
        psi_checksolve_test(ps_model, [MOI.OPTIMAL], objval, 10000)
    end
    # use_slacks path
    template_s = get_thermal_dispatch_template_network(
        NetworkModel(CopperPlateNetworkModel; use_slacks = true),
    )
    ps_model_re = DecisionModel(
        template_s,
        PSB.build_system(PSITestSystems, "c_sys5_re");
        optimizer = HiGHS_optimizer,
    )
    @test build!(ps_model_re; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    psi_checksolve_test(ps_model_re, [MOI.OPTIMAL], 240000.0, 10000)
end

@testset "Network DC-PF with PTDF Model" begin
    constraint_keys = [
        ConstraintKey(FlowRateConstraint, PSY.Line, "lb"),
        ConstraintKey(FlowRateConstraint, PSY.Line, "ub"),
        ConstraintKey(CopperPlateBalanceConstraint, PSY.System),
    ]
    for (sys_name, objval) in
        (("c_sys5", 240000.0), ("c_sys14", 142000.0), ("c_sys14_dc", 142000.0))
        sys = PSB.build_system(PSITestSystems, sys_name)
        template = get_thermal_dispatch_template_network(
            NetworkModel(PTDFNetworkModel; network_matrix = PTDF(sys)),
        )
        ps_model = DecisionModel(
            template,
            sys;
            optimizer = HiGHS_optimizer,
            store_variable_names = true,
        )
        @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        psi_constraint_test(ps_model, constraint_keys)
        psi_checksolve_test(
            ps_model,
            [MOI.OPTIMAL, MOI.ALMOST_OPTIMAL],
            objval,
            10000,
        )
    end
end

@testset "Network DC-PF with VirtualPTDF Model" begin
    constraint_keys = [
        ConstraintKey(FlowRateConstraint, PSY.Line, "lb"),
        ConstraintKey(FlowRateConstraint, PSY.Line, "ub"),
        ConstraintKey(CopperPlateBalanceConstraint, PSY.System),
    ]
    for (sys_name, objval) in (("c_sys5", 240000.0), ("c_sys14", 142000.0))
        sys = PSB.build_system(PSITestSystems, sys_name)
        template = get_thermal_dispatch_template_network(
            NetworkModel(PTDFNetworkModel; network_matrix = VirtualPTDF(sys)),
        )
        ps_model = DecisionModel(
            template,
            sys;
            optimizer = HiGHS_optimizer,
            store_variable_names = true,
        )
        @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        psi_constraint_test(ps_model, constraint_keys)
        psi_checksolve_test(
            ps_model,
            [MOI.OPTIMAL, MOI.ALMOST_OPTIMAL],
            objval,
            10000,
        )
    end
end

@testset "2 Subnetworks HVDC DC-PF with CopperPlateNetworkModel" begin
    c_sys5 = PSB.build_system(PSB.PSISystems, "2Area 5 Bus System")
    template = get_thermal_dispatch_template_network(NetworkModel(CopperPlateNetworkModel))
    ps_model = DecisionModel(
        template,
        c_sys5;
        optimizer = HiGHS_optimizer,
        store_variable_names = true,
    )
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(ps_model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = IOM.get_optimization_container(ps_model)
    cpc = get_constraint(
        container,
        ConstraintKey(CopperPlateBalanceConstraint, PSY.System),
    )
    # One CopperPlate balance per subnetwork × 24 time steps confirms the two
    # subnetworks are modeled separately. (CopperPlate doesn't model branch flows,
    # so the inter-subnetwork HVDC flow variable isn't created under this formulation.)
    @test size(cpc) == (2, 24)
end

@testset "2 Subnetworks DC-PF with PTDF Model" begin
    c_sys5 = PSB.build_system(PSB.PSISystems, "2Area 5 Bus System")
    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel; network_matrix = VirtualPTDF(c_sys5)),
    )
    ps_model = DecisionModel(
        template,
        c_sys5;
        optimizer = HiGHS_optimizer,
        store_variable_names = true,
    )
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(ps_model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = IOM.get_optimization_container(ps_model)
    cpc = get_constraint(
        container,
        ConstraintKey(CopperPlateBalanceConstraint, PSY.System),
    )
    @test size(cpc) == (2, 24)

    results = OptimizationProblemOutputs(ps_model)
    hvdc_flow = read_variable(
        results,
        "FlowActivePowerVariable__TwoTerminalGenericHVDCLine";
        table_format = TableFormat.WIDE,
    )
    @test all(hvdc_flow[!, "nodeC-nodeC2"] .<= 200 + POM.ABSOLUTE_TOLERANCE)
    @test all(hvdc_flow[!, "nodeC-nodeC2"] .>= -200 - POM.ABSOLUTE_TOLERANCE)
end

@testset "2 Areas AreaBalance PowerModel - with slacks" begin
    c_sys = build_system(PSITestSystems, "c_sys5_uc")
    areas = [PSY.Area("Area_1", 0, 0, 0), PSY.Area("Area_2", 0, 0, 0)]
    add_components!(c_sys, areas)
    for (i, comp) in enumerate(get_components(ACBus, c_sys))
        (i < 3) ? set_area!(comp, areas[1]) : set_area!(comp, areas[2])
    end
    # Deactivate Area-1 generators so the area balance needs slacks for feasibility.
    for gen in
        get_components(x -> (get_area(get_bus(x)) == areas[1]), PSY.Generator, c_sys)
        set_available!(gen, false)
    end

    template = get_thermal_dispatch_template_network(
        NetworkModel(AreaBalanceNetworkModel; use_slacks = true),
    )
    ps_model = DecisionModel(
        template,
        c_sys;
        optimizer = HiGHS_optimizer,
        store_variable_names = true,
    )
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(ps_model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = IOM.get_optimization_container(ps_model)
    cpc = get_constraint(
        container,
        ConstraintKey(CopperPlateBalanceConstraint, PSY.Area),
    )
    @test size(cpc) == (2, 24)

    results = OptimizationProblemOutputs(ps_model)
    slacks_up = read_variable(
        results,
        "SystemBalanceSlackUp__Area";
        table_format = TableFormat.WIDE,
    )
    @test all(slacks_up[!, "Area_1"] .> 0.0)
    @test all(isapprox.(slacks_up[!, "Area_2"], 0.0; atol = POM.ABSOLUTE_TOLERANCE))
end

@testset "2 Areas AreaBalance PowerModel" begin
    c_sys = PSB.build_system(PSB.PSISystems, "two_area_pjm_DA")
    transform_single_time_series!(c_sys, Hour(24), Hour(1))
    template = get_thermal_dispatch_template_network(NetworkModel(AreaBalanceNetworkModel))
    set_device_model!(template, AreaInterchange, StaticBranch)
    ps_model =
        DecisionModel(
            template,
            c_sys;
            resolution = Hour(1),
            optimizer = HiGHS_optimizer,
            store_variable_names = true,
        )
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(ps_model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = IOM.get_optimization_container(ps_model)
    cpc = get_constraint(
        container,
        ConstraintKey(CopperPlateBalanceConstraint, PSY.Area),
    )
    @test size(cpc) == (2, 24)

    results = OptimizationProblemOutputs(ps_model)
    interarea_flow = read_variable(
        results,
        "FlowActivePowerVariable__AreaInterchange";
        table_format = TableFormat.WIDE,
    )
    @test all(interarea_flow[!, "1_2"] .<= 150 + POM.ABSOLUTE_TOLERANCE)
    @test all(interarea_flow[!, "1_2"] .>= -150 - POM.ABSOLUTE_TOLERANCE)
end

@testset "2 Areas AreaPTDFNetworkModel" begin
    c_sys = PSB.build_system(PSB.PSISystems, "two_area_pjm_DA")
    transform_single_time_series!(c_sys, Hour(24), Hour(1))
    template = get_thermal_dispatch_template_network(NetworkModel(AreaPTDFNetworkModel))
    set_device_model!(template, AreaInterchange, StaticBranch)
    set_device_model!(template, MonitoredLine, StaticBranchUnbounded)
    ps_model =
        DecisionModel(
            template,
            c_sys;
            resolution = Hour(1),
            optimizer = HiGHS_optimizer,
            store_variable_names = true,
        )
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(ps_model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    container = IOM.get_optimization_container(ps_model)
    cpc = get_constraint(
        container,
        ConstraintKey(CopperPlateBalanceConstraint, PSY.Area),
    )
    @test size(cpc) == (2, 24)

    results = OptimizationProblemOutputs(ps_model)
    interarea_flow = read_variable(
        results,
        "FlowActivePowerVariable__AreaInterchange";
        table_format = TableFormat.WIDE,
    )
    # AreaPTDF routes inter-area flow through the network; the interchange stays within
    # the system's declared flow limits (data-derived ±150 in two_area_pjm_DA).
    @test all(interarea_flow[!, "1_2"] .<= 150.0 + POM.ABSOLUTE_TOLERANCE)
    @test all(interarea_flow[!, "1_2"] .>= -150.0 - POM.ABSOLUTE_TOLERANCE)
end

@testset "PTDFNetworkModel radial-branch reduction matches unreduced flows" begin
    new_sys = PSB.build_system(PSITestSystems, "c_sys5_radial")
    flows = Dict{Bool, Any}()
    for reduce in (true, false)
        template = PowerOperationsProblemTemplate(
            NetworkModel(
                PTDFNetworkModel;
                reduce_radial_branches = reduce,
                use_slacks = false,
            ),
        )
        set_device_model!(template, ThermalStandard, ThermalStandardUnitCommitment)
        set_device_model!(template, PowerLoad, StaticPowerLoad)
        set_device_model!(template, Line, StaticBranch)
        set_device_model!(template, Transformer2W, StaticBranch)
        model = DecisionModel(
            template,
            new_sys;
            optimizer = HiGHS_optimizer,
            store_variable_names = true,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        res = OptimizationProblemOutputs(model)
        flows[reduce] = read_expression(
            res,
            "PTDFBranchFlow__Line";
            table_format = TableFormat.WIDE,
        )
    end
    # Every line retained under reduction must carry the same flow as the full model.
    for line in DataFrames.names(flows[true])[2:end]
        @test isapprox(flows[true][!, line], flows[false][!, line]; atol = 1e-4)
    end
end
