# Ported from PowerSimulations.jl PR #1579 (MODF SCUC migration), adapted to
# POM / PS6 APIs. Exercises the `_build_device_model_outages!` unplanned
# outage-axis selection and the
# `_pin_outage_buses!` bus-pinning (N3) logic.
#
# Adaptation notes:
#   * internal symbols are namespaced `POM.` / `IOM.` / `PNM.`; expression and
#     constraint accessors take the *type* (no instance `()`), matching POM's
#     `IOM.get_expression(container, POM.X, T)` convention.
#   * a `PSY.PlannedOutage` is a scheduled topology change, not a contingency, so it never
#     appears on post-contingency axes.
#   * the upstream "outages kwarg selects a subset" sub-testset is DEFERRED: the
#     IOM `DeviceModel(...; outages)` kwarg is typed
#     `AbstractVector{<:IS.InfrastructureSystemsComponent}`, but outage objects
#     (`GeometricDistributionForcedOutage` / `FixedForcedOutage`) are
#     `IS.SupplementalAttribute`s, a sibling branch of
#     `InfrastructureSystemsType`, so they are rejected at construction
#     (TypeError). The explicit-subset selection path is therefore not
#     representable through the public constructor; the auto-discovery
#     path is the portable one and is exercised in full below.
#   * for the bus-pinning unit tests we populate `IOM.get_outages(dm)` directly
#     (the same dict `_assign_outage_to_sc_models!` writes), since the kwarg
#     cannot accept the supplemental attribute.

@testset "Post-contingency outage axes — unplanned outages only" begin
    scb_formulation = POM.SecurityConstrainedStaticBranch

    # `PSY.GeometricDistributionForcedOutage` and `PSY.FixedForcedOutage` are the unplanned
    # outages; `PSY.PlannedOutage` is not a contingency. The unplanned outages monitor
    # different-sized sets so the testset can
    # assert that sparse containers carry per-outage axes, not a shared global
    # axis.
    function _build_mixed_outage_system()
        sys = PSB.build_system(PSITestSystems, "c_sys5")
        lines = sort!(collect(PSY.get_components(PSY.Line, sys)); by = PSY.get_name)
        @assert length(lines) >= 3
        all_branches = collect(PSY.get_components(PSY.ACTransmission, sys))
        unplanned = PSY.GeometricDistributionForcedOutage(;
            mean_time_to_recovery = 10,
            outage_transition_probability = 0.9999,
            monitored_components = all_branches,
        )
        unplanned_narrow = PSY.FixedForcedOutage(;
            outage_status = 0.0,
            monitored_components = [lines[3]],
        )
        planned = PSY.PlannedOutage(; outage_schedule = "planned_outage_ts")
        planned_schedule = zeros(24)
        planned_schedule[[3, 4]] .= 1.0
        PSY.add_supplemental_attribute!(sys, lines[1], unplanned)
        PSY.add_supplemental_attribute!(sys, lines[4], unplanned_narrow)
        PSY.add_supplemental_attribute!(sys, lines[2], planned)
        PSY.add_time_series!(
            sys,
            planned,
            PSY.Deterministic(;
                name = "planned_outage_ts",
                data = SortedDict(
                    Dates.DateTime(2024, 1, 1) => planned_schedule,
                    Dates.DateTime(2024, 1, 2) => planned_schedule,
                ),
                resolution = Dates.Hour(1),
            ),
        )
        return sys, unplanned, unplanned_narrow, planned
    end

    function _build_model(sys; attributes = Dict{String, Any}())
        template = get_thermal_dispatch_template_network(
            NetworkModel(
                PTDFNetworkModel;
                use_slacks = false,
            ),
        )
        @test_logs (:warn, r"Overwriting Line existing model") set_device_model!(
            template,
            DeviceModel(
                PSY.Line, scb_formulation;
                attributes = attributes,
            ),
        )
        model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        return model
    end

    function _axes(model)
        container = IOM.get_optimization_container(model)
        expr = IOM.get_expression(container, POM.PostContingencyBranchFlow, PSY.Line)
        cons_ub = IOM.get_constraint(
            container,
            IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "ub"),
        )
        # SparseAxisArray stores tuple keys; project axis 1 (outage_id).
        expr_outages = Set(k[1] for k in keys(expr.data))
        cons_outages = Set(k[1] for k in keys(cons_ub.data))
        return expr_outages, cons_outages
    end

    @testset "planned outages never appear; per-outage axes differ in size" begin
        sys, unplanned, unplanned_narrow, planned = _build_mixed_outage_system()
        model = _build_model(sys)

        expr_ax, cons_ax = _axes(model)
        @test expr_ax == cons_ax
        @test expr_ax == Set([
            string(IS.get_id(unplanned)),
            string(IS.get_id(unplanned_narrow)),
        ])
        @test !(string(IS.get_id(planned)) in expr_ax)

        container = IOM.get_optimization_container(model)
        expr = IOM.get_expression(container, POM.PostContingencyBranchFlow, PSY.Line)
        wide_id = string(IS.get_id(unplanned))
        narrow_id = string(IS.get_id(unplanned_narrow))
        wide_branches = Set(k[2] for k in keys(expr.data) if k[1] == wide_id)
        narrow_branches = Set(k[2] for k in keys(expr.data) if k[1] == narrow_id)
        @test length(wide_branches) == 6
        @test length(narrow_branches) == 1
    end

    # DEFERRED: "outages kwarg selects a subset" — passing outage objects to the
    # `DeviceModel(...; outages = [...])` kwarg is rejected by IOM's
    # `AbstractVector{<:IS.InfrastructureSystemsComponent}` signature (outages
    # are SupplementalAttributes). See module-level note.
end

@testset "Outage pinning includes outaged-component buses (N3)" begin
    # Regression: `_pin_outage_buses!` must pin both the
    # MONITORED components' buses AND the OUTAGED (associated) components'
    # buses. If only the monitored set is pinned, a degree-two reduction
    # between the outaged arc's endpoints can collapse the contingency arc out
    # of the reduced topology and PNM's MODF column for that contingency would
    # have no matching arc to apply.
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    lines = collect(PSY.get_components(PSY.Line, sys))
    @assert length(lines) >= 3
    outaged_line = lines[1]   # the contingency arc itself
    monitored_only_line = lines[2]   # in the monitored set but not the outaged component
    transition = PSY.GeometricDistributionForcedOutage(;
        mean_time_to_recovery = 10,
        outage_transition_probability = 0.9999,
        monitored_components = [monitored_only_line],
    )
    PSY.add_supplemental_attribute!(sys, outaged_line, transition)
    outage_uuid = IS.get_id(transition)

    # The outage only pins buses when it is registered on an SC-formulated
    # branch DeviceModel. The constructor `outages` kwarg cannot accept the
    # supplemental attribute, so populate the DeviceModel's outage dict directly
    # (the same dict `_assign_outage_to_sc_models!` writes during validation).
    branch_models = IOM.BranchModelContainer()
    dm = DeviceModel(PSY.Line, POM.SecurityConstrainedStaticBranch)
    IOM.get_outages(dm)[outage_uuid] =
        Dict{DataType, Set{String}}(
            PSY.Line => Set([PSY.get_name(monitored_only_line)]),
        )
    branch_models[nameof(PSY.Line)] = dm

    irreducible_buses = Set{Int}()
    for m in values(branch_models)
        POM._pin_outage_buses!(irreducible_buses, m, sys)
    end

    monitored_arc = PSY.get_arc(monitored_only_line)
    outaged_arc = PSY.get_arc(outaged_line)

    # Monitored component endpoints must be present (existing behavior).
    @test PSY.get_number(PSY.get_from(monitored_arc)) in irreducible_buses
    @test PSY.get_number(PSY.get_to(monitored_arc)) in irreducible_buses

    # Outaged component endpoints must also be present (N3 fix).
    @test PSY.get_number(PSY.get_from(outaged_arc)) in irreducible_buses
    @test PSY.get_number(PSY.get_to(outaged_arc)) in irreducible_buses
end

@testset "Outage on a non-SC device pins nothing" begin
    # Scoping regression: a system Outage attribute whose branch is modeled
    # with a non-SC formulation must NOT pin buses. Otherwise a stray Outage
    # would force a provided PTDF to be discarded and recomputed on every
    # non-SC build. `StaticBranch` does not `supports_outages`, so even a
    # populated outage dict is ignored.
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    lines = collect(PSY.get_components(PSY.Line, sys))
    @assert length(lines) >= 2
    outaged_line = lines[1]
    transition = PSY.GeometricDistributionForcedOutage(;
        mean_time_to_recovery = 10,
        outage_transition_probability = 0.9999,
        monitored_components = [lines[2]],
    )
    PSY.add_supplemental_attribute!(sys, outaged_line, transition)
    outage_uuid = IS.get_id(transition)

    branch_models = IOM.BranchModelContainer()
    dm = DeviceModel(PSY.Line, POM.StaticBranch)
    # Even if an outage dict were present, StaticBranch is not outage-aware so
    # `_pin_outage_buses!` skips it.
    branch_models[nameof(PSY.Line)] = dm

    irreducible_buses = Set{Int}()
    for m in values(branch_models)
        POM._pin_outage_buses!(irreducible_buses, m, sys)
    end

    @test isempty(irreducible_buses)
end

@testset "include_planned_outages is rejected" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel; use_slacks = false),
    )
    @test_logs (:warn, r"Overwriting Line existing model") set_device_model!(
        template,
        DeviceModel(
            PSY.Line,
            POM.SecurityConstrainedStaticBranch;
            attributes = Dict{String, Any}("include_planned_outages" => true),
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    status = build!(model; output_dir = output_dir, console_level = Logging.AboveMaxLevel)
    @test status == IOM.ModelBuildStatus.FAILED
    log_text = read(
        joinpath(IOM.get_output_dir(model), IOM.PROBLEM_LOG_FILENAME),
        String,
    )
    @test occursin(r"removed attribute .*include_planned_outages", log_text)
    @test occursin("include_planned_outages", log_text)
    @test occursin("removed", log_text)
    @test_throws IS.ConflictingInputsError POM.validate_template(model)
end

@testset "include_planned_outages is rejected on an EmulationModel" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5"; add_single_time_series = true)
    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel; use_slacks = false),
    )
    @test_logs (:warn, r"Overwriting Line existing model") set_device_model!(
        template,
        DeviceModel(
            PSY.Line,
            POM.SecurityConstrainedStaticBranch;
            attributes = Dict{String, Any}("include_planned_outages" => true),
        ),
    )
    model = EmulationModel(template, sys; optimizer = HiGHS_optimizer)
    status = build!(
        model;
        output_dir = mktempdir(; cleanup = true),
        console_level = Logging.AboveMaxLevel,
    )
    @test status == IOM.ModelBuildStatus.FAILED
    log_text = read(
        joinpath(IOM.get_output_dir(model), IOM.PROBLEM_LOG_FILENAME),
        String,
    )
    @test occursin("include_planned_outages", log_text)
    @test occursin("removed", log_text)
end

@testset "include_planned_outages is rejected on a model dropped for having no devices" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    @test isempty(PSY.get_components(PSY.TwoWindingTransformer, sys))
    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel; use_slacks = false),
    )
    @test_logs (:warn, r"Overwriting TwoWindingTransformer existing model") set_device_model!(
        template,
        DeviceModel(
            PSY.TwoWindingTransformer,
            POM.StaticBranch;
            attributes = Dict{String, Any}("include_planned_outages" => true),
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test_throws r"removed attribute .*include_planned_outages" POM.validate_template(model)
end
