_c_sys5() = PSB.build_system(PSITestSystems, "c_sys5"; add_forecasts = true)

_monitored_lines(sys) = _sorted(PSY.Line, sys)

# c_sys5 with contingencies on `ctg_names` monitoring every line, and line "3" out at
# `_OUT_STEPS`. Returns the system and each contingency's outage id by line name.
function _c_sys5_with_scheduled_contingencies(ctg_names)
    sys = _c_sys5()
    ids = Dict(
        n => _add_contingency!(
            sys,
            [PSY.get_component(PSY.Line, sys, n)],
            _monitored_lines(sys),
        ) for n in ctg_names
    )
    _schedule_outage!(sys, PSY.get_component(PSY.Line, sys, "3"), "maint", _maintenance)
    return sys, ids
end

_arc_of(model, T, name) = POM._representative_branch(_network_model(model), T, name).arc
_line_out_at(t) = t in _OUT_STEPS ? [(PSY.Line, "3")] : Tuple{DataType, String}[]

# A contingency whose line is already out limits nothing, and neither does a contingency on a
# monitored line that is out; both keep their entries at those steps with a zero flow and
# inert rating rows. A monitored line is skipped under its own contingency, whose
# post-contingency flow is zero at every step.
function _check_post_contingency_entries(model, ids)
    n = _n_steps(model)
    for (ctg, outage_id) in ids
        for line in _monitored_lines(IOM.get_system(model))
            name = PSY.get_name(line)
            name == ctg && continue
            expected = if ctg == "3" || name == "3"
                setdiff(1:n, _OUT_STEPS)
            else
                collect(1:n)
            end
            @test _limited_post_contingency_steps(model, PSY.Line, outage_id, name) ==
                  expected
        end
    end
    return
end

# Every post-contingency flow of outage `ctg` (a line) that carries a limit matches
# `reference`: the union rebuild with line "3" out at `_OUT_STEPS`, the contingency-only
# rebuild elsewhere.
function _check_post_contingency_flows(model, ids, reference)
    flows = _post_contingency_flows(model, PSY.Line)
    for (ctg, outage_id) in ids, (key_outage, name, t) in keys(flows.data)
        key_outage == outage_id || continue
        ctg == "3" && t in _OUT_STEPS && continue
        name == "3" && t in _OUT_STEPS && continue
        expected = reference(_arc_of(model, PSY.Line, name), t, ctg)
        @test _affexpr_approx_equal(flows[outage_id, name, t], expected; atol = 1e-6)
    end
    return
end

@testset "PTDF post-contingency flows follow the step topology" begin
    sys, ids = _c_sys5_with_scheduled_contingencies(("1", "2", "3"))
    model = _built_model(_sc_template(), sys)
    _check_post_contingency_entries(model, ids)
    _check_post_contingency_flows(
        model,
        ids,
        (arc, t, ctg) -> _ptdf_post_contingency_reference(
            model, _c_sys5, arc, t, _line_out_at(t), [(PSY.Line, ctg)],
        ),
    )
    # The monitored line "4" under the contingency on "1" changes at the out steps.
    flows = _post_contingency_flows(model, PSY.Line)
    @test !_affexpr_approx_equal(flows[ids["1"], "4", 1], flows[ids["1"], "4", 3])
end

@testset "DCP post-contingency flows follow the step topology" begin
    sys, ids = _c_sys5_with_scheduled_contingencies(("1", "2", "3"))
    model = _built_model(_sc_template(; network = DCPNetworkModel), sys)
    _check_post_contingency_entries(model, ids)
    _check_post_contingency_flows(
        model,
        ids,
        (arc, t, ctg) -> _dcp_post_contingency_reference(
            model, _c_sys5, arc, t, _line_out_at(t), [(PSY.Line, ctg)];
            types = (PSY.Line,),
        ),
    )
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "A schedule with everything in service matches the static security-constrained model" begin
    for network in (PTDFNetworkModel, DCPNetworkModel)
        static_sys = _c_sys5()
        scheduled_sys = _c_sys5()
        static_ids = String[]
        scheduled_ids = String[]
        for n in ("1", "2")
            push!(
                static_ids,
                _add_contingency!(
                    static_sys,
                    [PSY.get_component(PSY.Line, static_sys, n)],
                    _monitored_lines(static_sys),
                ),
            )
            push!(
                scheduled_ids,
                _add_contingency!(
                    scheduled_sys,
                    [PSY.get_component(PSY.Line, scheduled_sys, n)],
                    _monitored_lines(scheduled_sys),
                ),
            )
        end
        _schedule_outage!(
            scheduled_sys,
            PSY.get_component(PSY.Line, scheduled_sys, "3"),
            "maint",
            h -> 0.0,
        )
        static = _built_model(_sc_template(; network = network), static_sys)
        scheduled = _built_model(_sc_template(; network = network), scheduled_sys)
        @test isnothing(POM.get_topology_schedule(_network_model(static)))
        @test !isnothing(POM.get_topology_schedule(_network_model(scheduled)))
        static_id = Dict(zip(scheduled_ids, static_ids))
        rename(k) = (static_id[k[1]], k[2], k[3])
        static_flows = _post_contingency_flows(static, PSY.Line)
        scheduled_flows = _post_contingency_flows(scheduled, PSY.Line)
        @test Set(rename.(keys(scheduled_flows.data))) == Set(keys(static_flows.data))
        # Both builds add the same variables in the same order, so a variable of the static
        # model maps to the variable with the same index in the scheduled model.
        jump_model = IOM.get_jump_model(_container(scheduled))
        @test JuMP.num_variables(jump_model) ==
              JuMP.num_variables(IOM.get_jump_model(_container(static)))
        to_scheduled(e) = JuMP.AffExpr(
            JuMP.constant(e),
            Dict(JuMP.VariableRef(jump_model, JuMP.index(v)) => c for (v, c) in e.terms)...,
        )
        for k in keys(scheduled_flows.data)
            @test _affexpr_approx_equal(
                scheduled_flows.data[k],
                to_scheduled(static_flows.data[rename(k)]);
                atol = 1e-8,
            )
        end
        for meta in ("ub", "lb")
            scheduled_cons = _post_contingency_constraints(scheduled, PSY.Line, meta)
            static_cons = _post_contingency_constraints(static, PSY.Line, meta)
            @test Set(rename.(keys(scheduled_cons.data))) == Set(keys(static_cons.data))
            @test all(
                isapprox(
                    JuMP.normalized_rhs(scheduled_cons.data[k]),
                    JuMP.normalized_rhs(static_cons.data[rename(k)]);
                    atol = 1e-8,
                ) for k in keys(scheduled_cons.data)
            )
        end
    end
end

# A phase-shifting transformer as the contingency (a line scheduled out: "2" keeps the
# post-contingency network connected, "3" islands bus 5 together with the transformer), and as
# the scheduled outage under a line contingency, where the balance already holds its dropped
# shift injection.
@testset "Phase-shifting transformer contingencies and schedules on the step topology" begin
    builder = () -> _c_sys5_uc_with_transformer(; α = 0.1)
    for (ctg, scheduled) in (
        ((PSY.TwoWindingTransformer, "T"), (PSY.Line, "2")),
        ((PSY.TwoWindingTransformer, "T"), (PSY.Line, "3")),
        ((PSY.Line, "2"), (PSY.TwoWindingTransformer, "T")),
    )
        sys = builder()
        transformer = PSY.get_component(PSY.TwoWindingTransformer, sys, "T")
        monitored = vcat(_monitored_lines(sys), [transformer])
        outage_id =
            _add_contingency!(sys, [PSY.get_component(ctg[1], sys, ctg[2])], monitored)
        _schedule_outage!(
            sys,
            PSY.get_component(scheduled[1], sys, scheduled[2]),
            "maint",
            _maintenance,
        )
        model = _built_model(
            _sc_template(; sc_types = (PSY.Line, PSY.TwoWindingTransformer)),
            sys,
        )
        flows = _post_contingency_flows(model, ctg[1])
        n = _n_steps(model)
        n_checked = 0
        for component in monitored
            T = typeof(component)
            name = PSY.get_name(component)
            # The contingency's own branch carries a zero post-contingency flow throughout.
            if (T, name) != ctg
                limited = _limited_post_contingency_steps(model, ctg[1], outage_id, name)
                if (T, name) == scheduled
                    @test limited == setdiff(1:n, _OUT_STEPS)
                else
                    @test limited == collect(1:n)
                end
            end
            for t in 1:n
                step_out = t in _OUT_STEPS ? [scheduled] : Tuple{DataType, String}[]
                expected = _ptdf_post_contingency_reference(
                    model, builder, _arc_of(model, T, name), t, step_out, [ctg],
                )
                @test _affexpr_approx_equal(
                    flows[outage_id, name, t],
                    expected;
                    atol = 1e-6,
                )
                n_checked += 1
            end
        end
        @test n_checked > 0
    end
end

# Under DCP, a transformer contingency with line "3" scheduled out islands bus 5.
@testset "DCP islanding contingency on the step topology" begin
    builder = () -> _c_sys5_uc_with_transformer(; α = 0.0)
    sys = builder()
    transformer = PSY.get_component(PSY.TwoWindingTransformer, sys, "T")
    monitored = vcat(_monitored_lines(sys), [transformer])
    outage_id = _add_contingency!(sys, [transformer], monitored)
    _schedule_outage!(sys, PSY.get_component(PSY.Line, sys, "3"), "maint", _maintenance)
    model = _built_model(
        _sc_template(;
            network = DCPNetworkModel,
            sc_types = (PSY.Line, PSY.TwoWindingTransformer),
        ),
        sys,
    )
    flows = _post_contingency_flows(model, PSY.TwoWindingTransformer)
    n = _n_steps(model)
    for component in monitored
        T = typeof(component)
        name = PSY.get_name(component)
        if name == "3"
            @test _limited_post_contingency_steps(
                model, PSY.TwoWindingTransformer, outage_id, name,
            ) == setdiff(1:n, _OUT_STEPS)
        end
        for t in 1:n
            expected = _dcp_post_contingency_reference(
                model, builder, _arc_of(model, T, name), t, _line_out_at(t),
                [(PSY.TwoWindingTransformer, "T")];
                types = (PSY.Line, PSY.TwoWindingTransformer),
            )
            @test _affexpr_approx_equal(flows[outage_id, name, t], expected; atol = 1e-6)
        end
    end
end

@testset "Outputs keep one row per step when the only contingency is out at the first steps" begin
    sys = _c_sys5()
    line = PSY.get_component(PSY.Line, sys, "1")
    outage_id = _add_contingency!(sys, [line], _monitored_lines(sys))
    _schedule_outage!(sys, line, "maint", _out_at(1:2))
    template = _sc_template()
    line_model = DeviceModel(
        PSY.Line,
        SecurityConstrainedStaticBranch;
        use_slacks = true,
        duals = [POM.PostContingencyFlowRateConstraint],
    )
    Logging.with_logger(Logging.NullLogger()) do
        set_device_model!(template, line_model)
    end
    model = _built_model(template, sys)
    n = _n_steps(model)
    @test _limited_post_contingency_steps(model, PSY.Line, outage_id, "2") == 3:n
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    res = IOM.OptimizationProblemOutputs(model)
    wide = TableFormat.WIDE
    timestamps =
        read_variable(
            res,
            "ActivePowerVariable__ThermalStandard";
            table_format = wide,
        ).DateTime
    @test length(timestamps) == n
    column = "$(outage_id)__2"
    frames = (
        read_expression(res, "PostContingencyBranchFlow__Line"; table_format = wide),
        read_dual(res, "PostContingencyFlowRateConstraint__Line__ub"; table_format = wide),
        read_dual(res, "PostContingencyFlowRateConstraint__Line__lb"; table_format = wide),
        read_variable(
            res,
            "PostContingencyFlowActivePowerSlackUpperBound__Line";
            table_format = wide,
        ),
        read_variable(
            res,
            "PostContingencyFlowActivePowerSlackLowerBound__Line";
            table_format = wide,
        ),
    )
    for df in frames
        @test nrow(df) == n
        @test df.DateTime == timestamps
        @test all(isfinite, df[!, column])
        @test all(iszero, df[1:2, column])
    end
    flow = first(frames)
    @test !all(iszero, flow[3:n, column])
end

@testset "Security-constrained models sharing an outage already out at the first step" begin
    sys = _c_sys5_uc_with_transformer(; α = 0.0)
    line = PSY.get_component(PSY.Line, sys, "1")
    transformer = PSY.get_component(PSY.TwoWindingTransformer, sys, "T")
    monitored = vcat(_monitored_lines(sys), [transformer])
    outage_id = _add_contingency!(sys, [line, transformer], monitored)
    out_steps = 1:2
    _schedule_outage!(sys, line, "line_maint", _out_at(out_steps))
    _schedule_outage!(sys, transformer, "transformer_maint", _out_at(out_steps))
    model = _built_model(
        _sc_template(; sc_types = (PSY.Line, PSY.TwoWindingTransformer)),
        sys,
    )
    n = _n_steps(model)
    line_flows = _post_contingency_flows(model, PSY.Line)
    transformer_flows = _post_contingency_flows(model, PSY.TwoWindingTransformer)
    @test Set(keys(line_flows.data)) == Set(keys(transformer_flows.data))
    @test all(
        line_flows.data[k] === transformer_flows.data[k] for k in keys(line_flows.data)
    )
    # The contingency's own branches carry a zero post-contingency flow throughout.
    for component in monitored
        component in (line, transformer) && continue
        @test _limited_post_contingency_steps(
            model,
            PSY.Line,
            outage_id,
            PSY.get_name(component),
        ) == setdiff(1:n, out_steps)
    end
    for meta in ("ub", "lb")
        line_cons = _post_contingency_constraints(model, PSY.Line, meta)
        transformer_cons =
            _post_contingency_constraints(model, PSY.TwoWindingTransformer, meta)
        @test Set(keys(line_cons.data)) == Set(keys(line_flows.data))
        @test Set(keys(transformer_cons.data)) == Set(keys(line_flows.data))
        @test all(
            line_cons.data[k] == transformer_cons.data[k] for k in keys(line_cons.data)
        )
    end
end

@testset "Post-contingency ratings of a partly-out monitored parallel group" begin
    sys = _c_sys5_uc_with_parallel_line((1.0, 0.8))
    member = PSY.get_component(PSY.Line, sys, "1")
    out_member = PSY.get_component(PSY.Line, sys, "1_copy1")
    outage_id = _add_contingency!(
        sys,
        [PSY.get_component(PSY.Line, sys, "2")],
        _monitored_lines(sys),
    )
    _schedule_outage!(sys, out_member, "maint", _maintenance)
    model = _built_model(_sc_template(), sys)
    group = POM._representative_branch(_network_model(model), PSY.Line, "1")
    flows = _post_contingency_flows(model, PSY.Line)
    ub = _post_contingency_constraints(model, PSY.Line, "ub")
    lb = _post_contingency_constraints(model, PSY.Line, "lb")
    for t in 1:_n_steps(model)
        entry = t in _OUT_STEPS ? member : group.branch
        rating = PNM.get_equivalent_emergency_rating(entry)
        flow = flows[outage_id, group.name, t]
        @test isapprox(_rating_of(ub[outage_id, group.name, t], flow), rating; rtol = 1e-9)
        @test isapprox(_rating_of(lb[outage_id, group.name, t], flow), -rating; rtol = 1e-9)
    end
    @test !isapprox(
        PNM.get_equivalent_emergency_rating(member),
        PNM.get_equivalent_emergency_rating(group.branch),
    )
end

@testset "A contingency on a partly-out parallel group rates it by the members left in the union" begin
    sys = _c_sys5_uc_with_parallel_line((1.0, 0.8, 0.5))
    line, scheduled, tripped =
        [PSY.get_component(PSY.Line, sys, n) for n in ("1", "1_copy1", "1_copy2")]
    partial_id = _add_contingency!(sys, [tripped], _monitored_lines(sys))
    opening_id = _add_contingency!(sys, [line, tripped], _monitored_lines(sys))
    _schedule_outage!(sys, scheduled, "maint", _maintenance)
    model = _built_model(_sc_template(), sys)
    name = POM._representative_branch(_network_model(model), PSY.Line, "1").name
    flows = _post_contingency_flows(model, PSY.Line)
    ub = _post_contingency_constraints(model, PSY.Line, "ub")
    emergency(members...) = sum(PNM.get_equivalent_emergency_rating, members)
    for t in 1:_n_steps(model)
        out = t in _OUT_STEPS
        partial = flows[partial_id, name, t]
        expected = out ? emergency(line) : emergency(line, scheduled)
        @test isapprox(_rating_of(ub[partial_id, name, t], partial), expected; rtol = 1e-9)
        opening = flows[opening_id, name, t]
        if out
            # The union opens the arc: its post-contingency flow vanishes and the limit
            # keeps the step's intact rating.
            @test all(c -> abs(c) < 1e-9, values(opening.terms))
            @test isapprox(
                _rating_of(ub[opening_id, name, t], opening),
                emergency(line, tripped);
                rtol = 1e-9,
            )
        else
            @test isapprox(
                _rating_of(ub[opening_id, name, t], opening),
                emergency(scheduled);
                rtol = 1e-9,
            )
        end
    end
end

@testset "Post-contingency rating time series of a partly-out monitored parallel group" begin
    factor(h) = 0.9 + 0.001 * h
    sys = _c_sys5_uc_with_parallel_line((1.0, 0.8))
    members = [PSY.get_component(PSY.Line, sys, n) for n in ("1", "1_copy1")]
    for m in members
        _attach_forecast_schedule!(sys, m, "pc_rating", factor)
    end
    outage_id = _add_contingency!(
        sys,
        [PSY.get_component(PSY.Line, sys, "2")],
        _monitored_lines(sys),
    )
    _schedule_outage!(sys, last(members), "maint", _maintenance)
    template = _sc_template()
    line_model = DeviceModel(
        PSY.Line,
        SecurityConstrainedStaticBranch;
        time_series_names = Dict(
            POM.PostContingencyBranchRatingTimeSeriesParameter => "pc_rating",
        ),
    )
    Logging.with_logger(Logging.NullLogger()) do
        set_device_model!(template, line_model)
    end
    model = _built_model(template, sys)
    group = POM._representative_branch(_network_model(model), PSY.Line, "1")
    flows = _post_contingency_flows(model, PSY.Line)
    ub = _post_contingency_constraints(model, PSY.Line, "ub")
    for t in 1:_n_steps(model)
        entry = t in _OUT_STEPS ? first(members) : group.branch
        expected = factor(t) * PNM.get_equivalent_emergency_rating(entry)
        @test isapprox(
            _rating_of(ub[outage_id, group.name, t], flows[outage_id, group.name, t]),
            expected;
            rtol = 1e-9,
        )
    end
end

@testset "A post-contingency rating series stops applying while its parallel member is out" begin
    sys = _c_sys5_uc_with_parallel_line((1.0, 0.8))
    line = PSY.get_component(PSY.Line, sys, "1")
    copy = PSY.get_component(PSY.Line, sys, "1_copy1")
    _attach_forecast_schedule!(sys, line, "pc_rating", h -> 0.5)
    outage_id = _add_contingency!(
        sys,
        [PSY.get_component(PSY.Line, sys, "2")],
        _monitored_lines(sys),
    )
    _schedule_outage!(sys, line, "maint", _maintenance)
    template = _sc_template()
    line_model = DeviceModel(
        PSY.Line,
        SecurityConstrainedStaticBranch;
        time_series_names = Dict(
            POM.PostContingencyBranchRatingTimeSeriesParameter => "pc_rating",
        ),
    )
    Logging.with_logger(Logging.NullLogger()) do
        set_device_model!(template, line_model)
    end
    model = _built_model(template, sys)
    group = POM._representative_branch(_network_model(model), PSY.Line, "1")
    flows = _post_contingency_flows(model, PSY.Line)
    ub = _post_contingency_constraints(model, PSY.Line, "ub")
    lb = _post_contingency_constraints(model, PSY.Line, "lb")
    summed = PNM.get_equivalent_emergency_rating(group.branch)
    for t in 1:_n_steps(model)
        expected = if t in _OUT_STEPS
            PNM.get_equivalent_emergency_rating(copy)
        else
            0.5 * summed
        end
        flow = flows[outage_id, group.name, t]
        @test isapprox(
            _rating_of(ub[outage_id, group.name, t], flow),
            expected;
            rtol = 1e-9,
        )
        @test isapprox(
            _rating_of(lb[outage_id, group.name, t], flow),
            -expected;
            rtol = 1e-9,
        )
    end
end

# Statuses of the scheduled lines for one window: `out` is out at `steps`, every other
# scheduled line is in service throughout.
function _set_window_statuses!(model, scheduled, out, steps)
    status = IOM.get_parameter_array(_container(model), POM.BranchStatusParameter, PSY.Line)
    for name in scheduled
        status[name, :] .= 1.0
    end
    status[out, steps] .= 0.0
    return
end

_base_network() = PNM.NetworkModification("", PNM.ArcModification[])

@testset "The topology matrix keeps only the networks of the current window" begin
    sys, ids = _c_sys5_with_scheduled_contingencies(("1", "2"))
    # Neither scheduled line islands a bus together with either contingency.
    scheduled = ["3", "6"]
    for name in scheduled[2:end]
        _schedule_outage!(
            sys,
            PSY.get_component(PSY.Line, sys, name),
            "maint_$name",
            h -> 0.0,
        )
    end
    model = _built_model(_sc_template(), sys)
    network_model = _network_model(model)
    matrix = POM.get_topology_matrix(network_model)
    contingencies = Set(
        spec.modification for spec in values(PNM.get_registered_contingencies(matrix))
    )
    @test length(contingencies) == 2
    n_steps = _n_steps(model)
    # The third window has a line out at every step, so no step queries a contingency on
    # its own and the contingency-only caches are evicted; the fourth queries them again.
    windows = [("3", 2:3), ("6", 2:3), ("3", 1:n_steps), ("6", 2:3)]
    holds_contingencies = Bool[]
    for (out, steps) in windows
        _set_window_statuses!(model, scheduled, out, steps)
        _rebuild!(model, sys)
        ts = POM.get_topology_schedule(network_model)
        @test all(t -> PNM.is_arc_out(ts, _arc_of(model, PSY.Line, out), t), steps)
        in_use = POM._modifications_in_use(
            ts,
            POM.get_post_contingency_modifications(network_model),
            1:n_steps,
        )
        # One topology with the line out, and its union with each contingency.
        @test length(setdiff(in_use, contingencies)) == 3
        @test Set(keys(PNM.get_row_caches(matrix))) == union(in_use, [_base_network()])
        @test Set(keys(PNM.get_woodbury_cache(matrix))) == in_use
        push!(
            holds_contingencies,
            issubset(contingencies, keys(PNM.get_row_caches(matrix))),
        )
        # The rows the rebuilt model holds are the union rebuilds' rows.
        _check_post_contingency_flows(
            model,
            Dict(k => ids[k] for k in ("1", "2")),
            (arc, t, ctg) -> _ptdf_post_contingency_reference(
                model, _c_sys5, arc, t,
                t in steps ? [(PSY.Line, out)] : Tuple{DataType, String}[],
                [(PSY.Line, ctg)],
            ),
        )
    end
    @test holds_contingencies == [true, true, false, true]
end
