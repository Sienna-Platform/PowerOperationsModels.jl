# Regression test for https://github.com/NREL-Sienna/PowerSimulations.jl/issues/1594
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

    template = ProblemTemplate(
        NetworkModel(PTDFPowerModel;
            PTDF_matrix = ptdf,
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
          PSI.ModelBuildStatus.BUILT

    container = PSI.get_optimization_container(ps_model)
    # The unfiltered Line set has 12 entries; full reduction leaves 6 entries
    # in the constraint axis. The dual container must use the same 6 entries.
    for meta in ("lb", "ub")
        cons_key = PSI.ConstraintKey(FlowRateConstraint, Line, meta)
        cons = PSI.get_constraint(container, cons_key)
        dual = PSI.get_duals(container)[cons_key]
        @test axes(dual)[1] == axes(cons)[1]
        @test length(axes(cons)[1]) <
              length(collect(get_components(Line, sys)))
        @test "4-5-i_1" in axes(cons)[1]
    end
end