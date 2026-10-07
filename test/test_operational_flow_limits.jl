_set_ofl!(d, ft_mw, tf_mw) = PSY.set_operational_flow_limit!(
    d,
    (from_to = (min = 0.0 * u"MW", max = ft_mw * u"MW"),
        to_from = (min = 0.0 * u"MW", max = tf_mw * u"MW")),
)

function _reversed_copy!(sys, line, name)
    arc = PSY.get_arc(line)
    rev_arc = PSY.Arc(; from = PSY.get_to(arc), to = PSY.get_from(arc))
    PSY.add_component!(sys, rev_arc)
    return _copy_on_arc!(sys, line, name, rev_arc)
end

function _same_copy!(sys, line, name; x_scale = 1.0)
    return _copy_on_arc!(sys, line, name, PSY.get_arc(line); x_scale = x_scale)
end

function _copy_on_arc!(sys, line, name, rev_arc; x_scale = 1.0)
    rev = PSY.Line(;
        name = name,
        available = true,
        active_power_flow = 0.0,
        reactive_power_flow = 0.0,
        arc = rev_arc,
        r = PSY.get_r(line, u"CU"),
        x = x_scale * PSY.get_x(line, u"CU"),
        b = PSY.get_b(line, u"CU"),
        rating = PSY.get_rating(line, u"CU"),
        angle_limits = PSY.get_angle_limits(line),
        input_basis = u"CU",
    )
    PSY.add_component!(sys, rev)
    return rev
end

function _rep_for(sys, name, method)
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(
        template,
        DeviceModel(
            PSY.Line,
            StaticBranchBounds;
            attributes = Dict{String, Any}(
                "parallel_branch_max_rating_method" => method,
            ),
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    nm = IOM.get_network_model(IOM.get_template(model))
    dm = IOM.get_branch_models(IOM.get_template(model))[:Line]
    rep = only(
        r for r in POM._all_branches(nm, PSY.Line) if r.name == name
    )
    return rep, dm
end

@testset "Operational limits: a Line without a limit has none" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    rep, dm = _rep_for(sys, "1", "sum_of_max")
    @test !POM._has_operational_flow_limit(rep)
    @test !POM._applies_operational_flow_limits(rep, dm)
end

@testset "Operational limits: parallel lines, per method" begin
    for (method, expected) in (
        ("sum_of_max", (ft = 0.02 + 0.01, tf = 0.04 + 0.05)),
        ("single_element_contingency", (ft = 0.01, tf = 0.04)),
        ("impedance_averaged", (ft = 0.015, tf = 0.045)),
    )
        sys = PSB.build_system(PSITestSystems, "c_sys5")
        line = PSY.get_component(PSY.Line, sys, "1")
        dup = _same_copy!(sys, line, "1_dup")
        _set_ofl!(line, 2.0, 4.0)
        _set_ofl!(dup, 1.0, 5.0)
        template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
        set_device_model!(
            template,
            DeviceModel(
                PSY.Line,
                StaticBranchBounds;
                attributes = Dict{String, Any}(
                    "parallel_branch_max_rating_method" => method,
                ),
            ),
        )
        model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        nm = IOM.get_network_model(IOM.get_template(model))
        dm = IOM.get_branch_models(IOM.get_template(model))[:Line]
        rep = only(r for r in POM._all_branches(nm, PSY.Line) if r.arc == (1, 2))
        @test POM._has_operational_flow_limit(rep)
        lims = POM._operational_flow_limits(rep, dm)
        @test lims.from_to ≈ expected.ft
        @test lims.to_from ≈ expected.tf
    end
end

@testset "Operational limits: a reversed member contributes in the group frame" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(PSY.Line, sys, "1")
    rev = _reversed_copy!(sys, line, "1_rev")
    _set_ofl!(line, 2.0, 4.0)
    _set_ofl!(rev, 1.0, 5.0)
    _, dm = _rep_for(sys, "1", "sum_of_max")
    bp = PNM.BranchesParallel([line, rev])
    lims = POM._member_operational_limits(bp, dm, "sum_of_max", PNM.NetworkReductionData())
    @test lims.from_to ≈ 0.02 + 0.05
    @test lims.to_from ≈ 0.04 + 0.01
end

@testset "Operational limits: apply_operational_flow_limits = false" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    _set_ofl!(PSY.get_component(PSY.Line, sys, "1"), 2.0, 4.0)
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(
        template,
        DeviceModel(
            PSY.Line,
            StaticBranchBounds;
            attributes = Dict{String, Any}("apply_operational_flow_limits" => false),
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    flow = IOM.get_variable(container, FlowActivePowerVariable, PSY.Line)
    rating = PSY.get_rating(PSY.get_component(PSY.Line, sys, "1"), u"SU")
    t = first(IOM.get_time_steps(container))
    @test JuMP.upper_bound(flow["1", t]) ≈ rating
end

# Unequal impedances: x2 = 2 * x1, so the weights 1/x give w2 = w1 / 2.
# from_to: (0.02 * w1 + 0.05 * w1 / 2) / (1.5 * w1) = 0.03
# to_from: (0.04 * w1 + 0.10 * w1 / 2) / (1.5 * w1) = 0.06
@testset "Operational limits: impedance_averaged weights members by series susceptance" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(PSY.Line, sys, "1")
    dup = _same_copy!(sys, line, "1_dup"; x_scale = 2.0)
    _set_ofl!(line, 2.0, 4.0)
    _set_ofl!(dup, 5.0, 10.0)
    nr = PNM.NetworkReductionData()
    @test PNM.get_effective_series_susceptance(dup, nr) ≈
          PNM.get_effective_series_susceptance(line, nr) / 2
    dm = DeviceModel(PSY.Line, StaticBranchBounds)
    bp = PNM.BranchesParallel([line, dup])
    lims = POM._member_operational_limits(bp, dm, "impedance_averaged", nr)
    @test lims.from_to ≈ 0.03
    @test lims.to_from ≈ 0.06
end

# Chain of a plain Line and a parallel block (Line + transformer on one arc, so mixed).
# Block members (pu, from_to / to_from): transformer a / b, line c / d. N-1 = sum - max.
@testset "Operational limits: a parallel block in a series chain uses N-1" begin
    sys = PSB.build_system(PSITestSystems, "case11_network_reductions")
    xfmr = first(PSY.get_components(PSY.TwoWindingTransformer, sys))
    lines = collect(PSY.get_components(PSY.Line, sys))
    plain = first(lines)
    blk_line = _copy_on_arc!(sys, plain, "blk_line", PSY.get_arc(xfmr))
    _set_ofl!(PSY.get_circuit(xfmr), 3.0, 6.0)
    _set_ofl!(blk_line, 2.0, 8.0)
    _set_ofl!(plain, 4.0, 5.0)
    ofl(d) = PSY.get_operational_flow_limit(d, u"SU")
    a, b = ofl(PSY.get_circuit(xfmr)).from_to.max, ofl(PSY.get_circuit(xfmr)).to_from.max
    c, d = ofl(blk_line).from_to.max, ofl(blk_line).to_from.max
    p, q = ofl(plain).from_to.max, ofl(plain).to_from.max
    n1_ft = a + c - max(a, c)
    n1_tf = b + d - max(b, d)
    @test !(n1_ft ≈ a + c)
    mixed = PNM.MixedBranchesParallel([xfmr, blk_line])
    dm = DeviceModel(PSY.Line, StaticBranchBounds)
    nr = PNM.NetworkReductionData()
    for (orientation, exp_ft, exp_tf) in (
        (:FromTo, min(p, n1_ft), min(q, n1_tf)),
        (:ToFrom, min(p, n1_tf), min(q, n1_ft)),
    )
        bs = PNM.BranchesSeries((1, 2))
        PNM.add_branch!(bs, plain, :FromTo)
        PNM.add_branch!(bs, mixed, orientation)
        for method in ("sum_of_max", "single_element_contingency", "impedance_averaged")
            lims = POM._member_operational_limits(bs, dm, method, nr)
            @test lims.from_to ≈ exp_ft
            @test lims.to_from ≈ exp_tf
        end
    end
end

const OFL_NETWORKS = [
    (PTDFNetworkModel, HiGHS_optimizer),
    (DCPNetworkModel, HiGHS_optimizer),
    (NFANetworkModel, HiGHS_optimizer),
    (DCPLLNetworkModel, ipopt_optimizer),
    (ACPNetworkModel, ipopt_optimizer),
]

function _build_ofl(
    network,
    optimizer;
    use_slacks = false,
    attributes = Dict{String, Any}(),
)
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    _set_ofl!(PSY.get_component(PSY.Line, sys, "1"), 2.0, 4.0)
    template = get_thermal_dispatch_template_network(NetworkModel(network))
    set_device_model!(
        template,
        DeviceModel(
            PSY.Line,
            StaticBranch;
            use_slacks = use_slacks,
            attributes = attributes,
        ),
    )
    model = DecisionModel(template, sys; optimizer = optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT
    return model, output_dir
end

# The rating stays: a row, or variable bounds under DCPLL without slacks.
_keeps_rating(container, ::Type) =
    IOM.has_container_key(container, FlowRateConstraint, PSY.Line, "ub") ||
    IOM.has_container_key(container, FlowRateConstraintFromTo, PSY.Line)

function _keeps_rating(container, ::Type{DCPLLNetworkModel})
    pft = IOM.get_variable(container, FlowActivePowerFromToVariable, PSY.Line)
    t = first(IOM.get_time_steps(container))
    return JuMP.has_upper_bound(pft["1", t]) && JuMP.has_lower_bound(pft["1", t])
end

@testset "OperationalFlowLimitConstraint rows on every network" begin
    for (network, optimizer) in OFL_NETWORKS
        model, _ = _build_ofl(network, optimizer)
        container = IOM.get_optimization_container(model)
        con_ft = IOM.get_constraint(
            container, POM.OperationalFlowLimitConstraint, PSY.Line, "ft",
        )
        con_tf = IOM.get_constraint(
            container, POM.OperationalFlowLimitConstraint, PSY.Line, "tf",
        )
        @test axes(con_ft)[1] == ["1"]
        @test axes(con_tf)[1] == ["1"]
        @test _keeps_rating(container, network)
    end
end

@testset "OperationalFlowLimitConstraint right-hand side" begin
    # NFA flow is a plain variable, so the normalized RHS is the limit.
    model, _ = _build_ofl(NFANetworkModel, HiGHS_optimizer)
    container = IOM.get_optimization_container(model)
    con_ft =
        IOM.get_constraint(container, POM.OperationalFlowLimitConstraint, PSY.Line, "ft")
    con_tf =
        IOM.get_constraint(container, POM.OperationalFlowLimitConstraint, PSY.Line, "tf")
    for t in IOM.get_time_steps(container)
        @test JuMP.normalized_rhs(con_ft["1", t]) ≈ 0.02
        @test JuMP.normalized_rhs(con_tf["1", t]) ≈ 0.04
    end
end

@testset "No operational limit and attribute false give no rows" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, DeviceModel(PSY.Line, StaticBranch))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    @test !IOM.has_container_key(
        container, POM.OperationalFlowLimitConstraint, PSY.Line, "ft",
    )

    model_off, _ = _build_ofl(
        PTDFNetworkModel, HiGHS_optimizer;
        attributes = Dict{String, Any}("apply_operational_flow_limits" => false),
    )
    container_off = IOM.get_optimization_container(model_off)
    @test !IOM.has_container_key(
        container_off, POM.OperationalFlowLimitConstraint, PSY.Line, "ft",
    )
end

@testset "Operational limit slacks are priced" begin
    model, _ = _build_ofl(PTDFNetworkModel, HiGHS_optimizer; use_slacks = true)
    container = IOM.get_optimization_container(model)
    slack = IOM.get_variable(container, FlowActivePowerSlackUpperBound, PSY.Line, "ofl_ft")
    t = first(IOM.get_time_steps(container))
    obj = IOM.get_objective_expression(IOM.get_objective_expression(container))
    @test JuMP.coefficient(obj, slack["1", t]) == POM.CONSTRAINT_VIOLATION_SLACK_COST
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "Operational limits on a TwoWindingTransformer circuit bound the flow" begin
    sys = PSB.build_system(PSITestSystems, "c_sys14")
    t2w = first(PSY.get_components(TwoWindingTransformer, sys))
    circuit = PSY.get_circuit(t2w)
    r_mw = PSY.get_rating(circuit, u"SU") * 100.0
    _set_ofl!(circuit, 0.5 * r_mw, 0.25 * r_mw)
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, DeviceModel(TwoWindingTransformer, StaticBranchBounds))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    flow = IOM.get_variable(container, FlowActivePowerVariable, TwoWindingTransformer)
    t = first(IOM.get_time_steps(container))
    rating = PSY.get_rating(circuit, u"SU")
    @test JuMP.upper_bound(flow[PSY.get_name(t2w), t]) ≈ 0.5 * rating
    @test JuMP.lower_bound(flow[PSY.get_name(t2w), t]) ≈ -0.25 * rating
end

@testset "Operational limits on one ThreeWindingTransformer winding give one row" begin
    sys = _sys5_with_3w()
    t3w = first(PSY.get_components(ThreeWindingTransformer, sys))
    primary = first(PSY.get_circuits(t3w))
    r_mw = PSY.get_rating(primary, u"SU") * 100.0
    _set_ofl!(primary, 0.5 * r_mw, 0.5 * r_mw)
    template = get_template_dispatch_with_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, DeviceModel(ThreeWindingTransformer, StaticBranch))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    con_ft = IOM.get_constraint(
        container, POM.OperationalFlowLimitConstraint, ThreeWindingTransformer, "ft",
    )
    @test axes(con_ft)[1] == ["$(PSY.get_name(t3w))_winding_1"]
end

@testset "Operational limit validation" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(PSY.Line, sys, "1")
    rating_mw = PSY.get_rating(line, u"SU") * 100.0
    _set_ofl!(line, rating_mw + 10.0, 4.0)
    PSY.set_operational_flow_limit!(
        PSY.get_component(PSY.Line, sys, "2"),
        (from_to = (min = 1.0 * u"MW", max = 5.0 * u"MW"),
            to_from = (min = 0.0 * u"MW", max = 5.0 * u"MW")),
    )
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, DeviceModel(PSY.Line, StaticBranch))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT
    log_contents = read(joinpath(output_dir, "operation_problem.log"), String)
    @test occursin("at or above the rating", log_contents)
    @test occursin("min is ignored", log_contents)
end

@testset "OperationalFlowLimitConstraint tf row negates a single flow" begin
    model, _ = _build_ofl(NFANetworkModel, HiGHS_optimizer)
    container = IOM.get_optimization_container(model)
    flow = IOM.get_variable(container, FlowActivePowerVariable, PSY.Line)
    con_ft =
        IOM.get_constraint(container, POM.OperationalFlowLimitConstraint, PSY.Line, "ft")
    con_tf =
        IOM.get_constraint(container, POM.OperationalFlowLimitConstraint, PSY.Line, "tf")
    t = first(IOM.get_time_steps(container))
    @test JuMP.normalized_coefficient(con_ft["1", t], flow["1", t]) == 1.0
    @test JuMP.normalized_coefficient(con_tf["1", t], flow["1", t]) == -1.0
end

@testset "Operational limit slacks share the row axis under a series reduction" begin
    sys = PSB.build_system(PSITestSystems, "case11_network_reductions")
    add_time_series!(
        sys,
        first(get_components(StandardLoad, sys)),
        Deterministic(
            "max_active_power",
            Dict(
                DateTime("2020-01-01T08:00:00") => [5.0, 6, 7, 7, 7],
                DateTime("2020-01-01T08:30:00") => [9.0, 9, 9, 9, 8],
                DateTime("2020-01-01T09:00:00") => [6.0, 6, 5, 5, 4],
            ),
            Dates.Minute(5),
        ),
    )
    chain = ("1-6-i_1", "6-7-i_1", "7-2-i_1")
    middle = PSY.get_component(PSY.Line, sys, "6-7-i_1")
    r_mw = PSY.get_rating(middle, u"SU") * 100.0
    _set_ofl!(middle, 0.5 * r_mw, 0.5 * r_mw)
    network = NetworkModel(
        DCPNetworkModel;
        network_source = SystemNetworkSource(
            PNM.NetworkReduction[PNM.DegreeTwoReduction()],
        ),
    )
    template = get_thermal_dispatch_template_network(network)
    set_device_model!(template, DeviceModel(PSY.Line, StaticBranch; use_slacks = true))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    for (con_meta, slack_meta) in (("ft", "ofl_ft"), ("tf", "ofl_tf"))
        rows = axes(
            IOM.get_constraint(
                container, POM.OperationalFlowLimitConstraint, PSY.Line, con_meta,
            ),
        )[1]
        slack = IOM.get_variable(
            container, FlowActivePowerSlackUpperBound, PSY.Line, slack_meta,
        )
        @test length(rows) == 1
        @test only(rows) in chain
        @test axes(slack)[1] == rows
    end
end

@testset "Operational limit validation rejects a negative or NaN max" begin
    for bad in (-1.0, NaN)
        sys = PSB.build_system(PSITestSystems, "c_sys5")
        _set_ofl!(PSY.get_component(PSY.Line, sys, "1"), bad, 4.0)
        template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
        set_device_model!(template, DeviceModel(PSY.Line, StaticBranch))
        model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        output_dir = mktempdir(; cleanup = true)
        @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.FAILED
        log_contents = read(joinpath(output_dir, "operation_problem.log"), String)
        @test occursin("InvalidValue", log_contents)
        @test occursin("Line 1 has from_to limit", log_contents)
        @test occursin("A directional limit must be finite and non-negative", log_contents)
    end
end

function _add_ofl_time_series!(sys, line, factors_ft, factors_tf)
    resolution = Dates.Hour(1)
    for (name, factors) in (
        ("operational_flow_limit_from_to", factors_ft),
        ("operational_flow_limit_to_from", factors_tf),
    )
        data = Dict(it => factors for it in PSY.get_forecast_initial_times(sys))
        PSY.add_time_series!(
            sys, line,
            PSY.Deterministic(; name = name, data = data, resolution = resolution),
        )
    end
    return
end

@testset "Operational limit time series scales the static limit" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(PSY.Line, sys, "1")
    _set_ofl!(line, 2.0, 4.0)
    steps = Int(PSY.get_forecast_horizon(sys) / Dates.Hour(1))
    _add_ofl_time_series!(sys, line, fill(0.5, steps), fill(1.0, steps))
    template = get_thermal_dispatch_template_network(NetworkModel(NFANetworkModel))
    set_device_model!(template, DeviceModel(PSY.Line, StaticBranch))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    con_ft =
        IOM.get_constraint(container, POM.OperationalFlowLimitConstraint, PSY.Line, "ft")
    con_tf =
        IOM.get_constraint(container, POM.OperationalFlowLimitConstraint, PSY.Line, "tf")
    t = first(IOM.get_time_steps(container))
    @test JuMP.normalized_rhs(con_ft["1", t]) ≈ 0.01
    @test JuMP.normalized_rhs(con_tf["1", t]) ≈ 0.04
end

@testset "Operational limit time series with StaticBranchBounds is rejected" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(PSY.Line, sys, "1")
    _set_ofl!(line, 2.0, 4.0)
    steps = Int(PSY.get_forecast_horizon(sys) / Dates.Hour(1))
    _add_ofl_time_series!(sys, line, fill(0.5, steps), fill(1.0, steps))
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, DeviceModel(PSY.Line, StaticBranchBounds))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.FAILED
    log_contents = read(joinpath(output_dir, "operation_problem.log"), String)
    @test occursin("only supported with the StaticBranch", log_contents)
end

@testset "Negative operational limit time series value is rejected" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(PSY.Line, sys, "1")
    _set_ofl!(line, 2.0, 4.0)
    steps = Int(PSY.get_forecast_horizon(sys) / Dates.Hour(1))
    factors = fill(1.0, steps)
    factors[3] = -1.0
    _add_ofl_time_series!(sys, line, factors, fill(1.0, steps))
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, DeviceModel(PSY.Line, StaticBranch))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.FAILED
    log_contents = read(joinpath(output_dir, "operation_problem.log"), String)
    @test occursin("time step 3", log_contents)
end

function _ofl_nfa_container(sys)
    template = get_thermal_dispatch_template_network(NetworkModel(NFANetworkModel))
    set_device_model!(template, DeviceModel(PSY.Line, StaticBranch))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    return IOM.get_optimization_container(model)
end

@testset "Operational limit time series scales max above the rating" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(PSY.Line, sys, "1")
    rating = PSY.get_rating(line, u"SU")
    _set_ofl!(line, 2 * rating * 100.0, 2 * rating * 100.0)
    steps = Int(PSY.get_forecast_horizon(sys) / Dates.Hour(1))
    _add_ofl_time_series!(sys, line, fill(0.4, steps), fill(0.4, steps))
    container = _ofl_nfa_container(sys)
    con_ft =
        IOM.get_constraint(container, POM.OperationalFlowLimitConstraint, PSY.Line, "ft")
    t = first(IOM.get_time_steps(container))
    @test JuMP.normalized_rhs(con_ft["1", t]) ≈ 0.8 * rating
end

@testset "Lines without the series keep their static limit" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    l1 = PSY.get_component(PSY.Line, sys, "1")
    l2 = PSY.get_component(PSY.Line, sys, "2")
    _set_ofl!(l1, 2.0, 4.0)
    _set_ofl!(l2, 3.0, 5.0)
    steps = Int(PSY.get_forecast_horizon(sys) / Dates.Hour(1))
    _add_ofl_time_series!(sys, l1, fill(0.5, steps), fill(0.5, steps))
    container = _ofl_nfa_container(sys)
    con_ft =
        IOM.get_constraint(container, POM.OperationalFlowLimitConstraint, PSY.Line, "ft")
    con_tf =
        IOM.get_constraint(container, POM.OperationalFlowLimitConstraint, PSY.Line, "tf")
    t = first(IOM.get_time_steps(container))
    @test JuMP.normalized_rhs(con_ft["1", t]) ≈ 0.01
    @test JuMP.normalized_rhs(con_ft["2", t]) ≈ 0.03
    @test JuMP.normalized_rhs(con_tf["2", t]) ≈ 0.05
end

@testset "Operational limit time series without a static limit is rejected" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(PSY.Line, sys, "1")
    steps = Int(PSY.get_forecast_horizon(sys) / Dates.Hour(1))
    _add_ofl_time_series!(sys, line, fill(0.5, steps), fill(0.5, steps))
    template = get_thermal_dispatch_template_network(NetworkModel(NFANetworkModel))
    set_device_model!(template, DeviceModel(PSY.Line, StaticBranch))
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.FAILED
    log_contents = read(joinpath(output_dir, "operation_problem.log"), String)
    @test occursin("has no operational_flow_limit", log_contents)
    @test occursin("operational_flow_limit_from_to", log_contents)
end
