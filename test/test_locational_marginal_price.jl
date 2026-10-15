# c_sys5_uc with one demand bid at a single bus. Every bus is a NodalRedistribution
# settlement location, so each has a ClearedPositionConstraint whose dual prices an
# exogenous position there: (settlement dual - position dual) / base is the solver's own LMP.
function _add_demand_bid!(sys, bus_number)
    bus = only(
        b for b in PSY.get_components(PSY.ACBus, sys) if PSY.get_number(b) == bus_number
    )
    PSY.add_component!(
        sys,
        PSY.VirtualParticipant(;
            name = "VD", available = true, max_supply = 0.0, max_demand = 1000.0,
            settlement_point = bus,
            operation_cost = PSY.MarketBidCost(;
                decremental_offer_curves = PSY.CostCurve(
                    PSY.PiecewiseIncrementalCurve(0.0, [0.0, 1000.0], [1000.0]),
                    PSY.NU,
                ),
            ),
        ),
    )
    return sys
end

_lmp_system(; system = "c_sys5_uc", demand_bus = 4) =
    _add_demand_bid!(PSB.build_system(PSITestSystems, system), demand_bus)

function _lmp_template(;
    network_model = NetworkModel(PTDFNetworkModel),
    line_model = DeviceModel(PSY.Line, StaticBranch; use_slacks = true),
    thermal_formulation = ThermalBasicDispatch,
    locational_prices = true,
    location_filter = _ -> true,
    extra_branch_models = DeviceModel[],
)
    template = PowerOperationsProblemTemplate(network_model)
    set_device_model!(template, PSY.ThermalStandard, thermal_formulation)
    set_device_model!(template, line_model)
    for branch_model in extra_branch_models
        set_device_model!(template, branch_model)
    end
    set_market_model!(
        template,
        IOM.MarketModel(
            SettlementMarket;
            settlement_domain = PSY.System,
            locational_prices = locational_prices,
        ),
    )
    set_market_component_model!(
        template,
        DeviceModel(
            PSY.ACBus,
            NodalRedistribution;
            attributes = Dict{String, Any}("filter_function" => location_filter),
        ),
    )
    set_market_component_model!(
        template, DeviceModel(PSY.VirtualParticipant, VirtualBidDispatch),
    )
    return template
end

function _build_lmp(
    sys,
    template;
    optimizer = HiGHS_optimizer,
    output_dir = mktempdir(; cleanup = true),
)
    model = DecisionModel(template, sys; optimizer = optimizer)
    status = build!(model; output_dir = output_dir)
    return model, status
end

function _solve_lmp(sys, template; optimizer = HiGHS_optimizer)
    model, status = _build_lmp(sys, template; optimizer = optimizer)
    @test status == IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    return model
end

_build_log(output_dir) = read(joinpath(output_dir, "operation_problem.log"), String)

_available_bus_names(sys) = [
    PSY.get_name(b) for b in sort!(
        collect(PSY.get_components(PSY.get_available, PSY.ACBus, sys));
        by = PSY.get_number,
    )
]

@testset "locational_prices adds one LocationalMarginalPrice row per energized bus" begin
    sys = _lmp_system()
    model, status = _build_lmp(sys, _lmp_template())
    @test status == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    prices = IOM.get_aux_variable(container, LocationalMarginalPrice, PSY.ACBus)
    @test collect(axes(prices)[1]) == _available_bus_names(sys)
    @test collect(axes(prices)[2]) == collect(IOM.get_time_steps(container))
end

@testset "Without locational_prices there is no LocationalMarginalPrice container" begin
    sys = _lmp_system()
    model, status = _build_lmp(sys, _lmp_template(; locational_prices = false))
    @test status == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    @test !IOM.has_container_key(container, LocationalMarginalPrice, PSY.ACBus)
end

@testset "locational_prices rejects non-PTDF networks" begin
    template = _lmp_template(; network_model = NetworkModel(DCPNetworkModel))
    @test_throws ArgumentError POM._check_market_model!(template)
    @test POM._check_market_model!(_lmp_template()) === nothing
end

# A degree-1 bus "leaf" hung off bus 1 by its own line.
function _add_leaf_bus!(sys; available = true)
    anchor = only(b for b in PSY.get_components(PSY.ACBus, sys) if PSY.get_number(b) == 1)
    leaf = PSY.ACBus(;
        input_basis = u"CU",
        number = 99, name = "leaf", available = available, bustype = PSY.ACBusTypes.PQ,
        angle = 0.0, magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1),
        base_voltage = PSY.get_base_voltage(anchor), area = PSY.get_area(anchor),
    )
    PSY.add_component!(sys, leaf)
    arc = PSY.Arc(; from = anchor, to = leaf)
    PSY.add_component!(sys, arc)
    PSY.add_component!(
        sys,
        PSY.Line(;
            name = "leaf_line", available = available, active_power_flow = 0.0,
            reactive_power_flow = 0.0, arc = arc,
            r = 0.001, x = 0.01, b = (from = 0.0, to = 0.0), rating = 1.0,
            angle_limits = (min = -1.0, max = 1.0), input_basis = u"CU",
        ),
    )
    return leaf
end

# A settlement location must sit on a bus the nodal balance has a row for, so the leaf
# (reduced away or out of service) is never one.
_off_leaf(bus) = PSY.get_name(bus) != "leaf"

_radial_network() = NetworkModel(
    PTDFNetworkModel;
    network_source = SystemNetworkSource(PNM.RadialReduction()),
)

@testset "A radially reduced bus stays on the price axis" begin
    sys = _lmp_system()
    _add_leaf_bus!(sys)
    model, status = _build_lmp(
        sys,
        _lmp_template(; network_model = _radial_network(), location_filter = _off_leaf),
    )
    @test status == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    prices = IOM.get_aux_variable(container, LocationalMarginalPrice, PSY.ACBus)
    @test "leaf" in axes(prices)[1]
end

@testset "An unavailable bus is not on the price axis" begin
    sys = _lmp_system()
    _add_leaf_bus!(sys; available = false)
    model, status = _build_lmp(sys, _lmp_template(; location_filter = _off_leaf))
    @test status == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    prices = IOM.get_aux_variable(container, LocationalMarginalPrice, PSY.ACBus)
    @test !("leaf" in axes(prices)[1])
end

# The solver's own price of a 1 MW settlement withdrawal at each bus, in $/MWh (hourly
# c_sys5): the settlement dual plus 1 times the row, minus the bus's position-row dual.
function _solver_lmp(model, sys)
    container = IOM.get_optimization_container(model)
    settlement = IOM.get_constraint(container, SettlementBalanceConstraint, PSY.System)
    position = IOM.get_constraint(container, ClearedPositionConstraint, PSY.ACBus)
    row = only(axes(settlement)[1])
    scale = 1.0 / PSY.get_base_power(sys)
    out = Dict{Tuple{String, Int}, Float64}()
    for name in axes(position)[1], t in axes(position)[2]
        out[(name, t)] =
            (JuMP.dual(settlement[row, t]) - JuMP.dual(position[name, t])) * scale
    end
    return out
end

function _lmp_values(model)
    container = IOM.get_optimization_container(model)
    prices = IOM.get_aux_variable(container, LocationalMarginalPrice, PSY.ACBus)
    return Dict(
        (name, t) => prices[name, t] for name in axes(prices)[1], t in axes(prices)[2]
    )
end

# Solves once, then rates the line with the largest t = 1 flow at 90% of that flow so the
# next solve congests it.
function _congest_most_loaded_line!(sys, template)
    model = _solve_lmp(sys, template)
    container = IOM.get_optimization_container(model)
    flows = IOM.get_expression(container, PTDFBranchFlow, PSY.Line)
    names = collect(axes(flows)[1])
    loaded = argmax(l -> abs(JuMP.value(flows[l, 1])), names)
    rating = 0.9 * abs(JuMP.value(flows[loaded, 1]))
    PSY.set_rating!(PSY.get_component(PSY.Line, sys, loaded), rating * u"SU")
    return loaded
end

_any_dual_above(container, key; tol = 1e-6) =
    any(v -> abs(v) > tol, IOM.get_duals(container)[key])

@testset "The price-relevant duals are registered without being requested" begin
    sys = _lmp_system()
    model, status = _build_lmp(sys, _lmp_template())
    @test status == IOM.ModelBuildStatus.BUILT
    duals = IOM.get_duals(IOM.get_optimization_container(model))
    @test haskey(duals, IOM.ConstraintKey(SettlementBalanceConstraint, PSY.System))
    @test haskey(duals, IOM.ConstraintKey(CopperPlateBalanceConstraint, PSY.System))
    for meta in ("ub", "lb")
        @test haskey(duals, IOM.ConstraintKey(FlowRateConstraint, PSY.Line, meta))
    end
end

@testset "User-requested branch duals are kept once" begin
    sys = _lmp_system()
    line_model = DeviceModel(
        PSY.Line, StaticBranch; use_slacks = true, duals = [FlowRateConstraint],
    )
    model, status = _build_lmp(sys, _lmp_template(; line_model = line_model))
    @test status == IOM.ModelBuildStatus.BUILT
    keys_ub = filter(
        k -> IOM.get_entry_type(k) === FlowRateConstraint && k.meta == "ub",
        collect(keys(IOM.get_duals(IOM.get_optimization_container(model)))),
    )
    @test length(keys_ub) == 1
end

@testset "Congested bus prices match the solver's own" begin
    sys = _lmp_system()
    _congest_most_loaded_line!(sys, _lmp_template())
    model = _solve_lmp(sys, _lmp_template())
    container = IOM.get_optimization_container(model)
    @test _any_dual_above(
        container,
        IOM.ConstraintKey(FlowRateConstraint, PSY.Line, "ub"),
    ) ||
          _any_dual_above(container, IOM.ConstraintKey(FlowRateConstraint, PSY.Line, "lb"))
    expected = _solver_lmp(model, sys)
    actual = _lmp_values(model)
    @test keys(actual) == keys(expected)
    for k in keys(expected)
        @test isapprox(actual[k], expected[k]; atol = 1e-6)
    end
    # Congestion separates prices in at least one hour.
    @test any(
        t ->
            maximum(actual[(n, t)] for n in _available_bus_names(sys)) -
            minimum(actual[(n, t)] for n in _available_bus_names(sys)) > 1e-3,
        IOM.get_time_steps(container),
    )
end

@testset "An interior-point solve without crossover prices like the solver" begin
    sys = _lmp_system()
    _congest_most_loaded_line!(sys, _lmp_template())
    ipm = JuMP.optimizer_with_attributes(
        HiGHS.Optimizer,
        "solver" => "ipm",
        "run_crossover" => "off",
        "output_flag" => false,
    )
    model = _solve_lmp(sys, _lmp_template(); optimizer = ipm)
    expected = _solver_lmp(model, sys)
    actual = _lmp_values(model)
    for k in keys(expected)
        @test isapprox(actual[k], expected[k]; atol = 1e-4)
    end
end

@testset "A radially reduced bus prices at the bus that absorbed it" begin
    sys = _lmp_system()
    _add_leaf_bus!(sys)
    radial() =
        _lmp_template(; network_model = _radial_network(), location_filter = _off_leaf)
    _congest_most_loaded_line!(sys, radial())
    model = _solve_lmp(sys, radial())
    network_model = get_network_model(IOM.get_template(model))
    leaf = PSY.get_component(PSY.ACBus, sys, "leaf")
    host_number = PNM.get_mapped_bus_number(get_network_reduction(network_model), leaf)
    host = only(
        b for b in PSY.get_components(PSY.ACBus, sys) if PSY.get_number(b) == host_number
    )
    actual = _lmp_values(model)
    for t in IOM.get_time_steps(IOM.get_optimization_container(model))
        @test actual[("leaf", t)] == actual[(PSY.get_name(host), t)]
    end
end

@testset "A MILP model prices from its fix-and-resolve duals" begin
    sys = _lmp_system()
    template = _lmp_template(;
        line_model = DeviceModel(PSY.Line, StaticBranchUnbounded),
        thermal_formulation = ThermalBasicUnitCommitment,
    )
    model = _solve_lmp(sys, template)
    container = IOM.get_optimization_container(model)
    @test IOM.is_milp(container)
    lambda =
        IOM.get_duals(container)[IOM.ConstraintKey(SettlementBalanceConstraint, PSY.System)]
    row = only(axes(lambda)[1])
    actual = _lmp_values(model)
    for t in IOM.get_time_steps(container)
        @test abs(lambda[row, t]) > 1e-6
        for name in _available_bus_names(sys)
            @test isapprox(
                actual[(name, t)],
                lambda[row, t] / PSY.get_base_power(sys);
                atol = 1e-6,
            )
        end
    end
end

@testset "A flow-limit family the price cannot read fails the build" begin
    sys = _lmp_system()
    output_dir = mktempdir(; cleanup = true)
    template = _lmp_template(; line_model = DeviceModel(PSY.Line, StaticBranchBounds))
    _, status = _build_lmp(sys, template; output_dir = output_dir)
    @test status == IOM.ModelBuildStatus.FAILED
    @test occursin("cannot price the NetworkFlowConstraint", _build_log(output_dir))
end

@testset "Prices read back through the outputs in \$/MWh" begin
    sys = _lmp_system()
    _congest_most_loaded_line!(sys, _lmp_template())
    model = _solve_lmp(sys, _lmp_template())
    df = read_aux_variable(
        OptimizationProblemOutputs(model),
        LocationalMarginalPrice,
        PSY.ACBus;
        table_format = TableFormat.WIDE,
    )
    actual = _lmp_values(model)
    for name in _available_bus_names(sys), t in 1:size(df, 1)
        @test df[t, name] == actual[(name, t)]
    end
end

@testset "_price_scale converts a per-unit, per-step dual to \$/MWh" begin
    @test POM._price_scale(100.0, Dates.Hour(1)) == 0.01
    @test POM._price_scale(100.0, Dates.Minute(5)) ≈ 0.12
end

function _attach_line_outages!(sys)
    branches = collect(PSY.get_components(PSY.ACTransmission, sys))
    for line_name in ("1", "2", "3", "4")
        PSY.add_supplemental_attribute!(
            sys,
            PSY.get_component(PSY.ACTransmission, sys, line_name),
            PSY.GeometricDistributionForcedOutage(;
                mean_time_to_recovery = 10,
                outage_transition_probability = 0.9999,
                monitored_components = branches,
            ),
        )
    end
    return sys
end

_n1_lmp_template() = _lmp_template(;
    line_model = DeviceModel(PSY.Line, SecurityConstrainedStaticBranch; use_slacks = true),
)

@testset "Post-contingency congestion prices like the solver" begin
    sys = _attach_line_outages!(_lmp_system())
    # Rate the most loaded post-contingency flow at t = 1 at 90% of it.
    model = _solve_lmp(sys, _n1_lmp_template())
    container = IOM.get_optimization_container(model)
    pc_flow = IOM.get_expression(container, PostContingencyBranchFlow, PSY.Line)
    first_hour = filter(k -> k[3] == 1, collect(keys(pc_flow.data)))
    (_, name, _) = argmax(k -> abs(JuMP.value(pc_flow[k...])), first_hour)
    flow = maximum(abs(JuMP.value(pc_flow[k...])) for k in first_hour if k[2] == name)
    PSY.set_rating_b!(PSY.get_component(PSY.Line, sys, name), 0.9 * flow * u"SU")

    model = _solve_lmp(sys, _n1_lmp_template())
    container = IOM.get_optimization_container(model)
    duals = IOM.get_duals(container)
    @test any(
        abs(v) > 1e-6 for meta in ("ub", "lb") for
        v in values(
            duals[IOM.ConstraintKey(
                PostContingencyFlowRateConstraint,
                PSY.Line,
                meta,
            )].data,
        )
    )
    expected = _solver_lmp(model, sys)
    actual = _lmp_values(model)
    for k in keys(expected)
        @test isapprox(actual[k], expected[k]; atol = 1e-6)
    end
end

# An interface over lines "1", "2" and "6" with symmetric limits of `limit` in the
# constructor's component units.
function _add_interface!(sys, limit)
    interface = PSY.TransmissionInterface(;
        name = "west_east",
        available = true,
        active_power_flow_limits = (min = -limit, max = limit),
        input_basis = u"CU",
    )
    PSY.add_service!(
        sys, interface, [PSY.get_component(PSY.Line, sys, n) for n in ("1", "2", "6")],
    )
    return interface
end

function _interface_template()
    template = _lmp_template()
    set_service_model!(template, ServiceModel(PSY.TransmissionInterface, MaxInterfaceFlow))
    return template
end

@testset "Interface congestion prices like the solver" begin
    # Probe: a slack interface gives the t = 1 flow (per unit) and the units ratio.
    probe_sys = _lmp_system()
    probe = _add_interface!(probe_sys, 1.0e4)
    cu_per_su = 1.0e4 / PSY.get_active_power_flow_limits(probe, u"SU").max
    model = _solve_lmp(probe_sys, _interface_template())
    total = IOM.get_expression(
        IOM.get_optimization_container(model), InterfaceTotalFlow,
        PSY.TransmissionInterface,
    )
    flow = JuMP.value(total["west_east", 1])

    # A fresh system with the interface rated at 90% of that flow.
    sys = _lmp_system()
    _add_interface!(sys, 0.9 * abs(flow) * cu_per_su)
    model = _solve_lmp(sys, _interface_template())
    container = IOM.get_optimization_container(model)
    @test any(
        meta -> _any_dual_above(
            container,
            IOM.ConstraintKey(POM.InterfaceFlowLimit, PSY.TransmissionInterface, meta),
        ),
        ("ub", "lb"),
    )
    expected = _solver_lmp(model, sys)
    actual = _lmp_values(model)
    for k in keys(expected)
        @test isapprox(actual[k], expected[k]; atol = 1e-6)
    end
end

# Every bus settlement location prices a settled MW at (settlement dual - position dual) / S.
function _check_against_solver(model, sys; atol = 1e-6)
    expected = _solver_lmp(model, sys)
    actual = _lmp_values(model)
    for k in keys(expected)
        @test isapprox(actual[k], expected[k]; atol = atol)
    end
    return
end

_any_post_contingency_dual(container, T) = any(
    abs(v) > 1e-6 for meta in ("ub", "lb") for
    v in values(
        get(IOM.get_duals(container),
            IOM.ConstraintKey(PostContingencyFlowRateConstraint, T, meta), Dict(),
        ).data,
    )
)

@testset "An outage of a line and a transformer together prices each row once" begin
    function multi_type_system()
        sys = _lmp_system(; system = "c_sys14", demand_bus = 9)
        branches = collect(PSY.get_components(PSY.ACTransmission, sys))
        outage = PSY.GeometricDistributionForcedOutage(;
            mean_time_to_recovery = 10,
            outage_transition_probability = 0.9999,
            monitored_components = branches,
        )
        PSY.add_supplemental_attribute!(
            sys,
            PSY.get_component(PSY.Line, sys, "Line1"),
            outage,
        )
        PSY.add_supplemental_attribute!(
            sys, first(PSY.get_components(PSY.TwoWindingTransformer, sys)), outage,
        )
        return sys
    end
    template() = _lmp_template(;
        line_model = DeviceModel(
            PSY.Line,
            SecurityConstrainedStaticBranch;
            use_slacks = true,
        ),
        extra_branch_models = [
            DeviceModel(
                PSY.TwoWindingTransformer, SecurityConstrainedStaticBranch;
                use_slacks = true,
            ),
        ],
    )
    sys = multi_type_system()
    model = _solve_lmp(sys, template())
    container = IOM.get_optimization_container(model)
    pc_flow = IOM.get_expression(container, PostContingencyBranchFlow, PSY.Line)
    first_hour = filter(k -> k[3] == 1, collect(keys(pc_flow.data)))
    (_, name, _) = argmax(k -> abs(JuMP.value(pc_flow[k...])), first_hour)
    flow = maximum(abs(JuMP.value(pc_flow[k...])) for k in first_hour if k[2] == name)
    PSY.set_rating_b!(PSY.get_component(PSY.ACTransmission, sys, name), 0.8 * flow * u"SU")

    model = _solve_lmp(sys, template())
    container = IOM.get_optimization_container(model)
    @test _any_post_contingency_dual(container, PSY.Line)
    _check_against_solver(model, sys)
end

@testset "Area interchange limits fail the build" begin
    sys = PSB.build_system(PSISystems, "two_area_pjm_DA")
    transform_single_time_series!(sys, Hour(24), Hour(1))
    interchange = first(PSY.get_components(PSY.AreaInterchange, sys))
    to_area = PSY.get_to_area(interchange)
    bus = first(b for b in PSY.get_components(PSY.ACBus, sys) if PSY.get_area(b) == to_area)
    _add_demand_bid!(sys, PSY.get_number(bus))
    template = _lmp_template(;
        line_model = DeviceModel(PSY.Line, StaticBranchUnbounded),
        extra_branch_models = [DeviceModel(PSY.AreaInterchange, StaticBranch)],
    )
    output_dir = mktempdir(; cleanup = true)
    _, status = _build_lmp(sys, template; output_dir = output_dir)
    @test status == IOM.ModelBuildStatus.FAILED
    @test occursin("cannot price the LineFlowBoundConstraint", _build_log(output_dir))
end

@testset "Phase-shifter flow control prices like the solver" begin
    # Trans1's flow held in a band off its free value, with the angle nearly fixed, so
    # redispatch (at a cost) holds the band and its row carries a dual.
    probe = _add_demand_bid!(
        _controlled_sys14(P_FLOW_CONTROL; circuit_index = MESHED_TRANSFORMER_INDEX).sys,
        9,
    )
    controlled(enable) = _lmp_template(;
        extra_branch_models = [
            DeviceModel(
                PSY.TwoWindingTransformer,
                StaticBranch;
                attributes = Dict(POM.ENABLE_CONTROLS_KEY => enable),
            ),
        ],
    )
    model = _solve_lmp(probe, controlled(false))
    flows = IOM.get_expression(
        IOM.get_optimization_container(model), PTDFBranchFlow, PSY.TwoWindingTransformer,
    )
    free = JuMP.value(flows["Trans1", 1])
    fixture = _controlled_sys14(
        P_FLOW_CONTROL;
        circuit_index = MESHED_TRANSFORMER_INDEX,
        quantity_limits = (min = free - 0.10, max = free - 0.05),
        control_limits = (min = -1.0e-3, max = 1.0e-3),
    )
    sys = _add_demand_bid!(fixture.sys, 9)
    model = _solve_lmp(sys, controlled(true))
    container = IOM.get_optimization_container(model)
    control = IOM.get_duals(container)[IOM.ConstraintKey(
        ActivePowerFlowControlConstraint, PSY.TwoWindingTransformer,
    )]
    @test any(v -> abs(v) > 1e-6, control)
    _check_against_solver(model, sys)
end

@testset "A price that misses a row family fails against the solver's own" begin
    sys = _lmp_system()
    _congest_most_loaded_line!(sys, _lmp_template())
    model = _solve_lmp(sys, _lmp_template())
    container = IOM.get_optimization_container(model)
    duals = IOM.get_duals(container)
    for meta in ("ub", "lb")
        delete!(duals, IOM.ConstraintKey(FlowRateConstraint, PSY.Line, meta))
    end
    key = IOM.AuxVarKey(LocationalMarginalPrice, PSY.ACBus)
    context = IOM.make_solve_context(IOM.get_template(model))
    @test_throws "a constraint that moves bus injections is not read" POM.calculate_aux_variable_value!(
        container, key, sys, context,
    )
end
