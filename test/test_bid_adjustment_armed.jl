function _bid_adjustment_template(;
    network_model = NetworkModel(PTDFNetworkModel),
    thermal_formulation = ThermalBasicDispatch,
    line_model = DeviceModel(PSY.Line, StaticBranch; use_slacks = true),
    load_formulation = StaticPowerLoadBidAdjustment,
)
    template = PowerOperationsProblemTemplate(network_model)
    set_device_model!(template, PSY.ThermalStandard, thermal_formulation)
    set_device_model!(template, PSY.PowerLoad, load_formulation)
    set_device_model!(template, line_model)
    return template
end

function _build_bid_adjustment_model(
    sys,
    template;
    output_dir = mktempdir(; cleanup = true),
)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    status = build!(model; output_dir = output_dir)
    return model, status
end

_build_log(output_dir) = read(joinpath(output_dir, "operation_problem.log"), String)

@testset "StaticPowerLoadBidAdjustment adds BidAdjustmentArmed per load" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    model, status = _build_bid_adjustment_model(sys, _bid_adjustment_template())
    @test status == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    armed = IOM.get_aux_variable(container, BidAdjustmentArmed, PSY.PowerLoad)
    load_names = sort!([PSY.get_name(l) for l in PSY.get_components(PSY.PowerLoad, sys)])
    @test sort!(collect(axes(armed)[1])) == load_names
    @test collect(axes(armed)[2]) == collect(IOM.get_time_steps(container))
end

# The formulation copies StaticPowerLoad's active-power path; this pins the copy to the
# original so a later StaticPowerLoad change cannot drift away from it unnoticed.
@testset "StaticPowerLoadBidAdjustment models load exactly as StaticPowerLoad" begin
    results = Dict{Any, Any}()
    for formulation in (StaticPowerLoad, StaticPowerLoadBidAdjustment)
        sys = PSB.build_system(PSITestSystems, "c_sys5")
        template = _bid_adjustment_template(; load_formulation = formulation)
        model, status = _build_bid_adjustment_model(sys, template)
        @test status == IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        results[formulation] = (
            values = IOM.lookup_value(
                container, ActivePowerTimeSeriesParameter, PSY.PowerLoad,
            ),
            multipliers = IOM.get_parameter_multiplier_array(
                container, ActivePowerTimeSeriesParameter, PSY.PowerLoad,
            ),
            model = model,
        )
    end
    static = results[StaticPowerLoad]
    adjusted = results[StaticPowerLoadBidAdjustment]
    @test static.values == adjusted.values
    @test static.multipliers == adjusted.multipliers
    # The aux variable is not a JuMP variable, so both problems have the same size.
    @test JuMP.num_variables(
        IOM.get_jump_model(IOM.get_optimization_container(static.model)),
    ) ==
          JuMP.num_variables(
        IOM.get_jump_model(IOM.get_optimization_container(adjusted.model)),
    )
end

@testset "StaticPowerLoadBidAdjustment rejects non-PTDF networks" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    output_dir = mktempdir(; cleanup = true)
    template = _bid_adjustment_template(; network_model = NetworkModel(DCPNetworkModel))
    _, status = _build_bid_adjustment_model(sys, template; output_dir = output_dir)
    @test status == IOM.ModelBuildStatus.FAILED
    @test occursin("supports only PTDFNetworkModel", _build_log(output_dir))
end

@testset "Counted branch-limit duals are registered without being requested" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    model, status = _build_bid_adjustment_model(sys, _bid_adjustment_template())
    @test status == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    for meta in ("ub", "lb")
        key = IOM.ConstraintKey(FlowRateConstraint, PSY.Line, meta)
        @test haskey(IOM.get_duals(container), key)
        @test axes(IOM.get_duals(container)[key]) ==
              axes(IOM.get_constraint(container, key))
    end
end

@testset "User-requested duals are kept" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line_model = DeviceModel(
        PSY.Line, StaticBranch; use_slacks = true, duals = [FlowRateConstraint],
    )
    model, status = _build_bid_adjustment_model(
        sys, _bid_adjustment_template(; line_model = line_model),
    )
    @test status == IOM.ModelBuildStatus.BUILT
    keys_ub = filter(
        k -> IOM.get_entry_type(k) === FlowRateConstraint && k.meta == "ub",
        collect(keys(IOM.get_duals(IOM.get_optimization_container(model)))),
    )
    @test length(keys_ub) == 1
end

@testset "Branch limits without slacks fail the build" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    output_dir = mktempdir(; cleanup = true)
    line_model = DeviceModel(PSY.Line, StaticBranch; use_slacks = false)
    _, status = _build_bid_adjustment_model(
        sys, _bid_adjustment_template(; line_model = line_model);
        output_dir = output_dir,
    )
    @test status == IOM.ModelBuildStatus.FAILED
    @test occursin("Set `use_slacks = true`", _build_log(output_dir))
end

@testset "Only ub and lb branch-limit rows count for bid adjustment" begin
    counts = PowerOperationsModels._counts_for_bid_adjustment
    for T in (FlowRateConstraint, PostContingencyFlowRateConstraint)
        @test counts(IOM.ConstraintKey(T, PSY.Line, "ub"))
        @test counts(IOM.ConstraintKey(T, PSY.Line, "lb"))
        @test !counts(IOM.ConstraintKey(T, PSY.Line, "ft_ub"))
    end
    @test !counts(IOM.ConstraintKey(CopperPlateBalanceConstraint, PSY.System, "ub"))
end

const _LOAD_BUMP = 1.05

_load_bus(load) = PSY.get_number(PSY.get_bus(load))

# Directed injection shift factor of `load` to `line`'s row in direction `sign`, from a
# dense PTDF built independently of the model.
_directed_sf(ptdf, line::String, load, sign::Float64) = sign * ptdf[line, _load_bus(load)]

# Rates the most loaded line whose t = 1 flow has sign `flow_sign` just below that flow,
# among lines for which some load's directed shift factor is below -0.02, so congestion
# in that direction can arm a load.
function _congest_line!(sys, flow_sign::Float64; exclude::Vector{String} = String[])
    ptdf = PNM.PTDF(sys)
    loads = collect(PSY.get_components(PSY.PowerLoad, sys))
    model, status = _build_bid_adjustment_model(sys, _bid_adjustment_template())
    @test status == IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    flows =
        IOM.get_expression(IOM.get_optimization_container(model), PTDFBranchFlow, PSY.Line)
    candidates = filter(collect(axes(flows)[1])) do line
        !(line in exclude) &&
            flow_sign * JuMP.value(flows[line, 1]) > 1e-6 &&
            any(l -> _directed_sf(ptdf, line, l, flow_sign) < -0.02, loads)
    end
    @test !isempty(candidates)
    line = argmax(l -> abs(JuMP.value(flows[l, 1])), candidates)
    rating = 0.9 * abs(JuMP.value(flows[line, 1]))
    PSY.set_rating!(PSY.get_component(PSY.Line, sys, line), rating * u"SU")
    return line
end

function _price_line_slacks!(model, line::String, price::Float64)
    container = IOM.get_optimization_container(model)
    jump_model = IOM.get_jump_model(container)
    for S in (FlowActivePowerSlackUpperBound, FlowActivePowerSlackLowerBound)
        slack = IOM.get_variable(container, S, PSY.Line)
        for t in axes(slack)[2]
            JuMP.set_objective_coefficient(jump_model, slack[line, t], price)
        end
    end
    return
end

# Independent reference: arm a load wherever a base-case row's dual reached 90% of its
# slack's objective coefficient and the dense-PTDF directed shift factor is below -0.02.
function _expected_armed(container, sys)
    ptdf = PNM.PTDF(sys)
    objective = JuMP.objective_function(IOM.get_jump_model(container))
    loads = collect(PSY.get_components(PSY.PowerLoad, sys))
    time_steps = IOM.get_time_steps(container)
    expected = Dict((PSY.get_name(l), t) => 0.0 for l in loads, t in time_steps)
    for (meta, S, sign) in (
        ("ub", FlowActivePowerSlackUpperBound, 1.0),
        ("lb", FlowActivePowerSlackLowerBound, -1.0),
    )
        dual =
            IOM.get_duals(container)[IOM.ConstraintKey(FlowRateConstraint, PSY.Line, meta)]
        slack = IOM.get_variable(container, S, PSY.Line)
        for line in axes(dual)[1], t in time_steps
            abs(dual[line, t]) >= 0.9 * JuMP.coefficient(objective, slack[line, t]) ||
                continue
            for l in loads
                if _directed_sf(ptdf, line, l, sign) < -0.02
                    expected[(PSY.get_name(l), t)] = 1.0
                end
            end
        end
    end
    return expected
end

function _armed_values(container)
    armed = IOM.get_aux_variable(container, BidAdjustmentArmed, PSY.PowerLoad)
    return Dict((n, t) => armed[n, t] for n in axes(armed)[1], t in axes(armed)[2])
end

# Natural congestion price of `line` at t = 1 under the default slack penalty.
function _natural_congestion_price(sys, line::String)
    model, _ = _build_bid_adjustment_model(sys, _bid_adjustment_template())
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    duals = IOM.get_duals(IOM.get_optimization_container(model))
    price = maximum(
        abs(duals[IOM.ConstraintKey(FlowRateConstraint, PSY.Line, meta)][line, 1]) for
        meta in ("ub", "lb")
    )
    @test price > 1e-6
    @test price < 0.9 * POM.CONSTRAINT_VIOLATION_SLACK_COST
    return price
end

# Solves with `line`'s slacks priced at `price` and returns the model.
function _solve_priced(
    sys,
    line::String,
    price::Float64;
    template = _bid_adjustment_template(),
)
    model, status = _build_bid_adjustment_model(sys, template)
    @test status == IOM.ModelBuildStatus.BUILT
    _price_line_slacks!(model, line, price)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    return model
end

function _slack_at_t1(model, line::String, S)
    container = IOM.get_optimization_container(model)
    return JuMP.value(IOM.get_variable(container, S, PSY.Line)[line, 1])
end

# Raising a load that worsens the congestion must grow the violation more than raising
# the load with the largest directed shift factor; independent of any shift-factor code.
function _check_sign_physically(sys, line::String, flow_sign::Float64, price::Float64)
    if flow_sign > 0.0
        S = FlowActivePowerSlackUpperBound
    else
        S = FlowActivePowerSlackLowerBound
    end
    ptdf = PNM.PTDF(sys)
    loads = collect(PSY.get_components(PSY.PowerLoad, sys))
    worsening = argmin(l -> _directed_sf(ptdf, line, l, flow_sign), loads)
    relieving = argmax(l -> _directed_sf(ptdf, line, l, flow_sign), loads)
    @test worsening !== relieving
    base = _slack_at_t1(_solve_priced(sys, line, price), line, S)
    @test base > 1e-6
    growth = Dict{String, Float64}()
    for load in (worsening, relieving)
        p = PSY.get_max_active_power(load, u"SU")
        PSY.set_max_active_power!(load, _LOAD_BUMP * p * u"SU")
        growth[PSY.get_name(load)] =
            _slack_at_t1(_solve_priced(sys, line, price), line, S) - base
        PSY.set_max_active_power!(load, p * u"SU")
    end
    @test growth[PSY.get_name(worsening)] > 1e-6
    @test growth[PSY.get_name(worsening)] > growth[PSY.get_name(relieving)]
end

for (label, flow_sign) in (("upper", 1.0), ("lower", -1.0))
    @testset "Base-case $(label)-bound congestion at its cap arms the worsening loads" begin
        sys = PSB.build_system(PSITestSystems, "c_sys5")
        line = _congest_line!(sys, flow_sign)
        price = 0.5 * _natural_congestion_price(sys, line)
        model = _solve_priced(sys, line, price)
        container = IOM.get_optimization_container(model)
        actual = _armed_values(container)
        @test actual == _expected_armed(container, sys)
        @test any(isone, values(actual))
        @test any(iszero, values(actual))
        _check_sign_physically(sys, line, flow_sign, price)
    end
end

@testset "No row at cap leaves every load unarmed" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = _congest_line!(sys, 1.0)
    _natural_congestion_price(sys, line)
    model, _ = _build_bid_adjustment_model(sys, _bid_adjustment_template())
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test all(iszero, values(_armed_values(IOM.get_optimization_container(model))))
end

@testset "Repricing and re-solving clears arming" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = _congest_line!(sys, 1.0)
    natural = _natural_congestion_price(sys, line)
    model, _ = _build_bid_adjustment_model(sys, _bid_adjustment_template())
    _price_line_slacks!(model, line, 0.5 * natural)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test any(isone, values(_armed_values(IOM.get_optimization_container(model))))
    _price_line_slacks!(model, line, POM.CONSTRAINT_VIOLATION_SLACK_COST)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test all(iszero, values(_armed_values(IOM.get_optimization_container(model))))
end

@testset "StaticPowerLoadBidAdjustment solves to StaticPowerLoad's objective" begin
    objectives = map((StaticPowerLoad, StaticPowerLoadBidAdjustment)) do formulation
        sys = PSB.build_system(PSITestSystems, "c_sys5")
        model, status = _build_bid_adjustment_model(
            sys, _bid_adjustment_template(; load_formulation = formulation),
        )
        @test status == IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
        JuMP.objective_value(IOM.get_jump_model(IOM.get_optimization_container(model)))
    end
    @test objectives[1] ≈ objectives[2]
end

@testset "MILP model arms like the LP reference" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_uc")
    line = _congest_line!(sys, 1.0)
    price = 0.5 * _natural_congestion_price(sys, line)
    template = _bid_adjustment_template(; thermal_formulation = ThermalBasicUnitCommitment)
    model = _solve_priced(sys, line, price; template = template)
    container = IOM.get_optimization_container(model)
    @test IOM.is_milp(container)
    @test _armed_values(container) == _expected_armed(container, sys)
end

@testset "A counted row without a positive slack penalty fails the solve" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    output_dir = mktempdir(; cleanup = true)
    model, status = _build_bid_adjustment_model(
        sys, _bid_adjustment_template(); output_dir = output_dir,
    )
    @test status == IOM.ModelBuildStatus.BUILT
    line = PSY.get_name(first(PSY.get_components(PSY.Line, sys)))
    _price_line_slacks!(model, line, 0.0)
    # `solve!` catches the post-solve error, logs it and marks the run failed.
    @test solve!(model) != IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test occursin("needs a positive slack penalty", _build_log(output_dir))
end

# Outaging line "4" (bus 2 - bus 3) gives c_sys5 post-contingency rows whose MODF arming
# differs from the base-case PTDF arming of the same monitored line.
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

_n1_template() = _bid_adjustment_template(;
    line_model = DeviceModel(PSY.Line, SecurityConstrainedStaticBranch; use_slacks = true),
)

function _solve_n1(sys)
    model, status = _build_bid_adjustment_model(sys, _n1_template())
    @test status == IOM.ModelBuildStatus.BUILT
    return model
end

# Directed MODF shift factor of `load` to monitored `name` under `outage_id`, read from the
# model's own contingency matrix (a PNM input) rather than production code.
function _directed_modf_sf(model, outage_id::String, name::String, load, sign::Float64)
    network_model = IOM.get_network_model(IOM.get_template(model))
    modf = IOM.get_contingency_matrix(network_model)
    spec = PNM.get_registered_contingencies(modf)[parse(Int, outage_id)]
    arc = PNM.get_name_to_arc_map(PNM.get_branch_catalog(modf), PSY.Line)[name]
    column = PNM.get_bus_lookup(modf)[_load_bus(load)]
    return sign * modf[arc, spec][column]
end

@testset "Security-constrained branches with no outages build and arm nothing" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    model = _solve_n1(sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    container = IOM.get_optimization_container(model)
    @test all(iszero, values(_armed_values(container)))
end

@testset "StaticPowerLoadBidAdjustment rejects motor loads" begin
    @test_throws r"does not support" POM._check_bid_adjustment_load_type(PSY.MotorLoad)
    @test POM._check_bid_adjustment_load_type(PSY.PowerLoad) === nothing
end

@testset "Post-contingency congestion at its cap arms from the MODF shift factor" begin
    sys = _attach_line_outages!(PSB.build_system(PSITestSystems, "c_sys5"))
    loads = collect(PSY.get_components(PSY.PowerLoad, sys))

    # Find the most loaded post-contingency flow at t = 1 that some load worsens, among rows
    # that arm some load differently from the monitored line's base-case PTDF row, so
    # substituting the PTDF for the MODF cannot pass this testset.
    ptdf = PNM.PTDF(sys)
    _modf_arms(model, o, n, l, s) = _directed_modf_sf(model, o, n, l, s) < -0.02
    _ptdf_arms(n, l, s) = _directed_sf(ptdf, n, l, s) < -0.02
    model = _solve_n1(sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    container = IOM.get_optimization_container(model)
    pc_flow = IOM.get_expression(container, PostContingencyBranchFlow, PSY.Line)
    candidates = filter(collect(keys(pc_flow.data))) do (outage_id, name, t)
        t == 1 || return false
        if JuMP.value(pc_flow[outage_id, name, t]) > 0.0
            flow_sign = 1.0
        else
            flow_sign = -1.0
        end
        any(l -> _modf_arms(model, outage_id, name, l, flow_sign), loads) &&
            any(
                l ->
                    _modf_arms(model, outage_id, name, l, flow_sign) !=
                    _ptdf_arms(name, l, flow_sign),
                loads,
            )
    end
    @test !isempty(candidates)
    (outage_id, name, _) = argmax(k -> abs(JuMP.value(pc_flow[k...])), candidates)
    flow = JuMP.value(pc_flow[outage_id, name, 1])
    @test any(
        l ->
            _modf_arms(model, outage_id, name, l, sign(flow)) !=
            _ptdf_arms(name, l, sign(flow)),
        loads,
    )
    line = PSY.get_component(PSY.Line, sys, name)
    PSY.set_rating_b!(line, 0.9 * abs(flow) * u"SU")
    @test PNM.get_equivalent_emergency_rating(line) ≈ 0.9 * abs(flow)

    # Natural price of that row, then reprice its slacks to half of it.
    model = _solve_n1(sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    duals = IOM.get_duals(IOM.get_optimization_container(model))
    natural = maximum(
        abs(
            duals[IOM.ConstraintKey(PostContingencyFlowRateConstraint, PSY.Line, meta)][
                outage_id, name, 1,
            ],
        ) for meta in ("ub", "lb")
    )
    @test natural > 1e-6

    model = _solve_n1(sys)
    container = IOM.get_optimization_container(model)
    jump_model = IOM.get_jump_model(container)
    for S in (
        PostContingencyFlowActivePowerSlackUpperBound,
        PostContingencyFlowActivePowerSlackLowerBound,
    )
        slack = IOM.get_variable(container, S, PSY.Line)
        for t in IOM.get_time_steps(container)
            JuMP.set_objective_coefficient(
                jump_model,
                slack[outage_id, name, t],
                0.5 * natural,
            )
        end
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    # Independent reference over base-case and post-contingency rows.
    expected = _expected_armed(container, sys)
    objective = JuMP.objective_function(jump_model)
    for (meta, S, sign) in (
        ("ub", PostContingencyFlowActivePowerSlackUpperBound, 1.0),
        ("lb", PostContingencyFlowActivePowerSlackLowerBound, -1.0),
    )
        dual = IOM.get_duals(container)[IOM.ConstraintKey(
            PostContingencyFlowRateConstraint, PSY.Line, meta,
        )]
        slack = IOM.get_variable(container, S, PSY.Line)
        for ((o, n, t), value) in dual.data
            abs(value) >= 0.9 * JuMP.coefficient(objective, slack[o, n, t]) || continue
            for l in loads
                if _directed_modf_sf(model, o, n, l, sign) < -0.02
                    expected[(PSY.get_name(l), t)] = 1.0
                end
            end
        end
    end
    actual = _armed_values(container)
    @test actual == expected
    @test any(isone, values(actual))

    resolve = PowerOperationsModels._monitored_arcs_by_name
    network_model = IOM.get_network_model(IOM.get_template(model))
    modf = IOM.get_contingency_matrix(network_model)
    @test resolve(network_model, [name]) == Dict(
        name => PNM.get_name_to_arc_map(PNM.get_branch_catalog(modf), PSY.Line)[name],
    )
    @test_throws r"maps to no arc" resolve(network_model, ["not a branch"])
end

@testset "A counted row with an unreadable dual container errors" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    model, status = _build_bid_adjustment_model(sys, _bid_adjustment_template())
    @test status == IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)
    collect_rows! = PowerOperationsModels._collect_rows_at_cap!
    counted = IOM.ConstraintKey(FlowRateConstraint, PSY.Line, "ub")
    @test_throws r"cannot read its dual container of type Matrix" collect_rows!(
        Dict(), Dict(), container, nothing, counted, zeros(1, 1),
    )
    uncounted = IOM.ConstraintKey(FlowRateConstraint, PSY.Line, "ft_ub")
    @test isnothing(
        collect_rows!(Dict(), Dict(), container, nothing, uncounted, zeros(1, 1)),
    )
end

@testset "A load on a radial bus arms through its retained bus" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    load = first(sort!(collect(PSY.get_components(PSY.PowerLoad, sys)); by = PSY.get_name))
    parent = PSY.get_bus(load)
    leaf = get_copied_bus(parent)
    PSY.add_component!(sys, leaf)
    arc = PSY.Arc(; from = parent, to = leaf)
    PSY.add_component!(sys, arc)
    template_line = first(PSY.get_components(PSY.Line, sys))
    leaf_line = get_copied_line(template_line)
    PSY.set_arc!(leaf_line, arc)
    PSY.add_component!(sys, leaf_line)
    PSY.set_bus!(load, leaf)

    line = _congest_line!(sys, 1.0; exclude = [PSY.get_name(leaf_line)])
    price = 0.5 * _natural_congestion_price(sys, line)
    template = _bid_adjustment_template(;
        network_model = NetworkModel(
            PTDFNetworkModel;
            network_source = SystemNetworkSource(PNM.RadialReduction()),
        ),
    )
    model = _solve_priced(sys, line, price; template = template)
    container = IOM.get_optimization_container(model)
    reduction = IOM.get_network_reduction(IOM.get_network_model(IOM.get_template(model)))
    @test PNM.get_mapped_bus_number(reduction, leaf) == PSY.get_number(parent)
    # A radial leaf carries its parent's shift factors, so the dense unreduced PTDF in the
    # reference gives the same answer the reduced model must.
    network_model = IOM.get_network_model(IOM.get_template(model))
    @test !haskey(
        PNM.get_bus_lookup(IOM.get_network_matrix(network_model)),
        PSY.get_number(leaf),
    )
    actual = _armed_values(container)
    @test actual == _expected_armed(container, sys)
    @test any(t -> actual[(PSY.get_name(load), t)] == 1.0, IOM.get_time_steps(container))
end
