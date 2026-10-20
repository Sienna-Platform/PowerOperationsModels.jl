# Ground-truth regression test for the MODF security-constrained branch
# formulation (`SecurityConstrainedStaticBranch`). Validates that every
# JuMP.AffExpr stored in the post-contingency expression container equals
# `dot(modf_matrix[arc, ctg], nodal_balance[:, t])`, and that the
# `PostContingencyFlowRateConstraint` RHS is the emergency rating expressed in
# PER-UNIT on the system base (the MODF-derived flow expression is per-unit, so
# the RHS must be too).
#
# The system's outage supplemental attributes (added below) are legitimate
# data setup. The MODF matrix is auto-constructed during
# `instantiate_network_model!` and each SC `DeviceModel.outages` field is
# auto-populated by `_build_device_model_outages!` during template validation —
# no manual stand-ins.

# The ground-truth columns below are read from a freshly-built VirtualMODF/
# VirtualPTDF (intentionally independent of the production matrix). On macOS the
# default sparse backend is Apple Accelerate, whose factorization is internally
# multithreaded and NOT bit-reproducible across builds, so two independent
# factorizations of the identical ABA matrix differ by ~1e-15. That noise is
# benign (a single production matrix is built once and reused, so it is
# self-consistent), but it breaks exact `isequal_canonical` on the re-derived
# coefficients. Compare the affine expressions up to that round-off instead: the
# tolerance is ~1e7× the observed noise yet far below any real coefficient bug.
function _affexpr_approx_equal(actual, expected; atol = 1e-8)
    d = actual - expected            # matching terms cancel to ~1e-15
    coeff_resid = maximum((abs(c) for (c, _) in JuMP.linear_terms(d)); init = 0.0)
    return coeff_resid ≤ atol && abs(JuMP.constant(d)) ≤ atol
end

# The Line container also holds rows for monitored transformers.
function _monitored_arc(name_to_arc_maps, name)
    line_arcs = name_to_arc_maps[PSY.Line]
    if haskey(line_arcs, name)
        return line_arcs[name]
    end
    return name_to_arc_maps[PSY.TwoWindingTransformer][name]
end

# The flow of one transformer as the model holds it, by formulation.
_dcp_transformer_flow(container, ::Type{StaticBranch}, name, t) =
    IOM.get_expression(container, POM.BThetaBranchFlow, PSY.TwoWindingTransformer)[name, t]
_dcp_transformer_flow(container, ::Type{POM.SecurityConstrainedStaticBranch}, name, t) =
    IOM.get_variable(container, POM.FlowActivePowerVariable, PSY.TwoWindingTransformer)[
        name,
        t,
    ]

@testset "Post-contingency expressions and constraints match MODF ground truth" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    all_branches = collect(get_components(PSY.ACTransmission, c_sys5))
    for line_name in ["1", "2", "3"]
        line = get_component(PSY.ACTransmission, c_sys5, line_name)
        transition = PSY.GeometricDistributionForcedOutage(;
            mean_time_to_recovery = 10,
            outage_transition_probability = 0.9999,
            monitored_components = all_branches,
        )
        PSY.add_supplemental_attribute!(c_sys5, line, transition)
    end

    template = get_thermal_dispatch_template_network(
        NetworkModel(
            PTDFNetworkModel;
            network_source = PrebuiltMatrixSource(PNM.VirtualPTDF(c_sys5)),
        ),
    )
    set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
    set_device_model!(
        template,
        PSY.TwoWindingTransformer,
        POM.SecurityConstrainedStaticBranch,
    )
    set_device_model!(
        template,
        PSY.TwoWindingTransformer,
        POM.SecurityConstrainedStaticBranch,
    )

    ps_model = DecisionModel(template, c_sys5; optimizer = HiGHS_optimizer)
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(ps_model)
    network_model = IOM.get_network_model(IOM.get_template(ps_model))
    @test IOM.get_contingency_matrix(network_model) isa PNM.VirtualMODF

    # Fresh VirtualMODF for the ground-truth column (independent solver pool so
    # a build-time race cannot pass the test by being read identically). The
    # fresh MODF re-registers the same outages from the supplemental
    # attributes, so its ContingencySpec UUIDs match the production matrix's.
    ground_truth_modf = PNM.VirtualMODF(c_sys5)
    ground_truth_registered = PNM.get_registered_contingencies(ground_truth_modf)
    @test !isempty(ground_truth_registered)

    nodal_balance =
        IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus).data
    time_steps = IOM.get_time_steps(container)

    net_reduction_data = POM.get_branch_catalog(network_model)
    name_to_arc_maps = PNM.get_name_to_arc_maps(net_reduction_data)

    n_checked = 0
    n_constraints_checked = 0
    for V in (PSY.Line, PSY.TwoWindingTransformer, PSY.TwoWindingTransformer)
        IOM.has_container_key(container, POM.PostContingencyBranchFlow, V) || continue
        pcbf = IOM.get_expression(container, POM.PostContingencyBranchFlow, V)
        n_checked += 1

        con_ub = IOM.get_constraints(container)[IOM.ConstraintKey(
            POM.PostContingencyFlowRateConstraint, V, "ub",
        )]
        con_lb = IOM.get_constraints(container)[IOM.ConstraintKey(
            POM.PostContingencyFlowRateConstraint, V, "lb",
        )]

        for (outage_id_str, name, t) in keys(pcbf.data)
            outage_id = parse(Int, outage_id_str)
            ctg = ground_truth_registered[outage_id]

            # Resolve the monitored name to its arc.
            arc = nothing
            for (T, n2a) in name_to_arc_maps
                if haskey(n2a, name)
                    arc = n2a[name]
                    break
                end
            end
            @assert !isnothing(arc) "monitored name $name not found in any \
                                     reduction map"

            # --- Expression equality: coeffs == VirtualMODF column entries. ---
            modf_col = ground_truth_modf[arc, ctg]
            nz_idx = [
                i for i in eachindex(modf_col) if
                abs(modf_col[i]) > POM.PTDF_ZERO_TOL
            ]
            expected = IOM.get_hinted_aff_expr(length(nz_idx))
            for i in nz_idx
                JuMP.add_to_expression!(expected, modf_col[i], nodal_balance[i, t])
            end
            actual = pcbf[outage_id_str, name, t]
            @test _affexpr_approx_equal(actual, expected)

            # --- Constraint RHS equality: emergency rating in PER-UNIT. ---
            # The post-contingency flow expression carries an affine constant
            # (load injections folded into the nodal balance); JuMP migrates it
            # to the RHS, so `normalized_rhs == limit - constant(expr)`. Adding
            # the constant back recovers the raw emergency-rating limit and
            # makes this a pure per-unit (system-base) units check.
            reduction_entry = PNM.get_reduction_entry(net_reduction_data, arc)
            limits = POM._emergency_flow_limits(reduction_entry)
            expr_const = JuMP.constant(actual)
            @test JuMP.normalized_rhs(con_ub[outage_id_str, name, t]) + expr_const ≈
                  limits.max
            @test JuMP.normalized_rhs(con_lb[outage_id_str, name, t]) + expr_const ≈
                  limits.min
            n_constraints_checked += 1
        end
    end
    @test n_checked >= 1
    @test n_constraints_checked >= 1
end

# Testsets below are ported from PSI PR #1579. They assert physics (containers
# present, build/solve succeed, structural relationships) rather than PSI's exact
# MOI-count / objective-value magic numbers, which differ under POM/PS6.

@testset "Security Constrained branch formulation Network DC-PF with VirtualPTDF + auto-MODF" begin
    # Exercises the prebuilt-VirtualPTDF code path with a derived MODF: the contingency
    # matrix is always derived from the source's factorization core during instantiate.
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    all_branches = collect(get_components(PSY.ACTransmission, c_sys5))
    for line_name in ["1", "2", "3"]
        transition_data = PSY.GeometricDistributionForcedOutage(;
            mean_time_to_recovery = 10,
            outage_transition_probability = 0.9999,
            monitored_components = all_branches,
        )
        component = get_component(PSY.ACTransmission, c_sys5, line_name)
        PSY.add_supplemental_attribute!(c_sys5, component, transition_data)
    end
    template = get_thermal_dispatch_template_network(
        NetworkModel(
            PTDFNetworkModel;
            network_source = PrebuiltMatrixSource(PNM.VirtualPTDF(c_sys5)),
        ),
    )
    set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
    set_device_model!(
        template,
        PSY.TwoWindingTransformer,
        POM.SecurityConstrainedStaticBranch,
    )
    set_device_model!(
        template,
        PSY.TwoWindingTransformer,
        POM.SecurityConstrainedStaticBranch,
    )

    ps_model = DecisionModel(template, c_sys5; optimizer = HiGHS_optimizer)
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    # MODF should have been derived during build
    nm = IOM.get_network_model(IOM.get_template(ps_model))
    @test !isnothing(IOM.get_contingency_matrix(nm))

    constraint_keys = [
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "lb"),
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "ub"),
    ]
    psi_constraint_test(ps_model, constraint_keys)
end

@testset "PTDFBranchFlow expressions match ptdf-derived ground truth" begin
    # Validates that every JuMP.AffExpr in the PTDFBranchFlow expression
    # container equals dot(ptdf_matrix[arc, :], nodal_balance[:, t]).
    c_sys14 = PSB.build_system(PSB.PSITestSystems, "c_sys14")

    template = get_thermal_dispatch_template_network(
        NetworkModel(
            PTDFNetworkModel;
            network_source = PrebuiltMatrixSource(PNM.VirtualPTDF(c_sys14)),
        ),
    )
    set_device_model!(template, PSY.Line, POM.StaticBranch)
    set_device_model!(template, PSY.TwoWindingTransformer, POM.StaticBranch)
    set_device_model!(template, PSY.TwoWindingTransformer, POM.StaticBranch)

    ps_model = DecisionModel(template, c_sys14; optimizer = HiGHS_optimizer)
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(ps_model)
    network_model = IOM.get_network_model(IOM.get_template(ps_model))
    @test IOM.get_network_matrix(network_model) isa PNM.VirtualPTDF

    ground_truth_ptdf = PNM.VirtualPTDF(c_sys14)

    nodal_balance =
        IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus).data
    time_steps = IOM.get_time_steps(container)

    net_reduction_data = POM.get_branch_catalog(network_model)
    modeled_branch_types = network_model.modeled_branch_types

    n_checked = 0
    for V in modeled_branch_types
        IOM.has_container_key(container, POM.PTDFBranchFlow, V) || continue
        pbf = IOM.get_expression(container, POM.PTDFBranchFlow, V)
        name_to_arc_map = collect(PNM.get_name_to_arc_map(net_reduction_data, V))
        isempty(name_to_arc_map) && continue
        n_checked += 1
        for (name, arc) in name_to_arc_map
            ptdf_col = ground_truth_ptdf[arc, :]
            nz_idx = [
                i for i in eachindex(ptdf_col) if abs(ptdf_col[i]) > POM.PTDF_ZERO_TOL
            ]
            for t in time_steps
                expected = IOM.get_hinted_aff_expr(length(nz_idx))
                for i in nz_idx
                    JuMP.add_to_expression!(expected, ptdf_col[i], nodal_balance[i, t])
                end
                actual =
                    pbf[name, t] +
                    PNM.arc_dc_shift_injection(
                        PNM.get_network_reduction_data(net_reduction_data), arc)
                @test _affexpr_approx_equal(actual, expected)
            end
        end
    end
    @test n_checked >= 1
end

@testset "Security-constrained formulation rejected for ThreeWindingTransformer" begin
    # SC branch formulations are not implemented for ThreeWindingTransformer.
    # Configuring one must raise at template validation.
    branch_models = IOM.BranchModelContainer()
    branch_models[nameof(PSY.ThreeWindingTransformer)] =
        DeviceModel(PSY.ThreeWindingTransformer, POM.SecurityConstrainedStaticBranch)
    @test_throws IS.ConflictingInputsError POM._check_security_constrained_three_winding_transformer(
        branch_models,
    )

    # Allowed combinations must pass.
    ok_models = IOM.BranchModelContainer()
    ok_models[nameof(PSY.ThreeWindingTransformer)] =
        DeviceModel(PSY.ThreeWindingTransformer, POM.StaticBranch)
    ok_models[nameof(PSY.Line)] =
        DeviceModel(PSY.Line, POM.SecurityConstrainedStaticBranch)
    @test isnothing(
        POM._check_security_constrained_three_winding_transformer(ok_models),
    )
end

@testset "Post-contingency expressions match modf-derived ground truth (c_sys14)" begin
    # Same structural ground-truth check as the c_sys5 testset at the top of
    # this file, but on c_sys14 with a subset of outaged lines — guards the
    # parallel `add_post_contingency_flow_expressions!` path on a larger grid.
    c_sys14 = PSB.build_system(PSB.PSITestSystems, "c_sys14")
    outage_line_names = ["Line1", "Line2", "Line9", "Line10"]
    all_branches = collect(get_components(PSY.ACTransmission, c_sys14))
    for line_name in outage_line_names
        line = get_component(PSY.ACTransmission, c_sys14, line_name)
        transition = PSY.GeometricDistributionForcedOutage(;
            mean_time_to_recovery = 10,
            outage_transition_probability = 0.9999,
            monitored_components = all_branches,
        )
        PSY.add_supplemental_attribute!(c_sys14, line, transition)
    end

    template = get_thermal_dispatch_template_network(
        NetworkModel(
            PTDFNetworkModel;
            network_source = PrebuiltMatrixSource(PNM.VirtualPTDF(c_sys14)),
        ),
    )
    set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
    set_device_model!(
        template,
        PSY.TwoWindingTransformer,
        POM.SecurityConstrainedStaticBranch,
    )
    set_device_model!(
        template,
        PSY.TwoWindingTransformer,
        POM.SecurityConstrainedStaticBranch,
    )

    ps_model = DecisionModel(template, c_sys14; optimizer = HiGHS_optimizer)
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(ps_model)
    network_model = IOM.get_network_model(IOM.get_template(ps_model))
    @test IOM.get_contingency_matrix(network_model) isa PNM.VirtualMODF

    ground_truth_modf = PNM.VirtualMODF(c_sys14)
    ground_truth_registered = PNM.get_registered_contingencies(ground_truth_modf)
    @test !isempty(ground_truth_registered)

    nodal_balance =
        IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus).data

    net_reduction_data = POM.get_branch_catalog(network_model)
    modeled_branch_types = network_model.modeled_branch_types
    name_to_arc_maps = PNM.get_name_to_arc_maps(net_reduction_data)
    n_checked = 0
    for V in modeled_branch_types
        IOM.has_container_key(container, POM.PostContingencyBranchFlow, V) || continue
        pcbf = IOM.get_expression(container, POM.PostContingencyBranchFlow, V)
        n_checked += 1
        for (outage_id_str, name, t) in keys(pcbf.data)
            outage_id = parse(Int, outage_id_str)
            ctg = ground_truth_registered[outage_id]
            arc = nothing
            for n2a in values(name_to_arc_maps)
                if haskey(n2a, name)
                    arc = n2a[name]
                    break
                end
            end
            @assert !isnothing(arc) "monitored name $name not found in any \
                                     reduction map"
            modf_col = ground_truth_modf[arc, ctg]
            nz_idx = [
                i for i in eachindex(modf_col) if abs(modf_col[i]) > POM.PTDF_ZERO_TOL
            ]
            expected = IOM.get_hinted_aff_expr(length(nz_idx))
            for i in nz_idx
                JuMP.add_to_expression!(expected, modf_col[i], nodal_balance[i, t])
            end
            actual = pcbf[outage_id_str, name, t]
            @test _affexpr_approx_equal(actual, expected)
        end
    end
    @test n_checked >= 1
end

function _add_line_outage!(sys::PSY.System, line_name::String)
    outage = PSY.GeometricDistributionForcedOutage(;
        mean_time_to_recovery = 10,
        outage_transition_probability = 0.9999,
        monitored_components = collect(get_components(PSY.ACTransmission, sys)),
    )
    line = get_component(PSY.ACTransmission, sys, line_name)
    PSY.add_supplemental_attribute!(sys, line, outage)
    return outage
end

function _sc_branch_template(line_model::DeviceModel)
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, line_model)
    set_device_model!(
        template,
        PSY.TwoWindingTransformer,
        POM.SecurityConstrainedStaticBranch,
    )
    return template
end

function _build_sc_model(template, sys::PSY.System)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    return model
end

_resolved_line_outages(model) =
    Set(keys(IOM.get_outages(IOM.get_model(IOM.get_template(model), PSY.Line))))

function _post_contingency_outage_axis(model)
    container = IOM.get_optimization_container(model)
    con_ub = IOM.get_constraint(
        container,
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "ub"),
    )
    return Set(k[1] for k in keys(con_ub.data))
end

_registered_outages(model) = Set(
    keys(
        PNM.get_registered_contingencies(
            IOM.get_contingency_matrix(IOM.get_network_model(IOM.get_template(model))),
        ),
    ),
)

@testset "SecurityConstrainedStaticBranch auto-discovers all supplemental-attribute outages" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    outage_ids = Set(IS.get_id(_add_line_outage!(c_sys5, name)) for name in ["1", "2", "3"])
    model = _build_sc_model(
        _sc_branch_template(DeviceModel(PSY.Line, POM.SecurityConstrainedStaticBranch)),
        c_sys5,
    )
    @test _resolved_line_outages(model) == outage_ids
    @test _post_contingency_outage_axis(model) == Set(string.(outage_ids))
end

@testset "SecurityConstrainedStaticBranch models only the selected outages" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    outages = [_add_line_outage!(c_sys5, name) for name in ["1", "2", "3"]]
    selected = [outages[1], outages[3]]
    selected_ids = Set(IS.get_id.(selected))
    model = _build_sc_model(
        _sc_branch_template(
            DeviceModel(PSY.Line, POM.SecurityConstrainedStaticBranch; outages = selected),
        ),
        c_sys5,
    )
    @test _resolved_line_outages(model) == selected_ids
    @test _post_contingency_outage_axis(model) == Set(string.(selected_ids))
    @test _registered_outages(model) == selected_ids
end

@testset "SecurityConstrainedStaticBranch with an empty outage selection models no outages" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    for name in ["1", "2", "3"]
        _add_line_outage!(c_sys5, name)
    end
    model = _build_sc_model(
        _sc_branch_template(
            DeviceModel(
                PSY.Line,
                POM.SecurityConstrainedStaticBranch;
                outages = PSY.Outage[],
            ),
        ),
        c_sys5,
    )
    @test isempty(_resolved_line_outages(model))
    @test isempty(_post_contingency_outage_axis(model))
    @test isempty(_registered_outages(model))
end

@testset "Rebuilding a model includes outages added to the system between builds" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    first_ids = Set(IS.get_id(_add_line_outage!(c_sys5, name)) for name in ["1", "2"])
    model = _build_sc_model(
        _sc_branch_template(DeviceModel(PSY.Line, POM.SecurityConstrainedStaticBranch)),
        c_sys5,
    )
    @test _resolved_line_outages(model) == first_ids

    added_id = IS.get_id(_add_line_outage!(c_sys5, "3"))
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test _resolved_line_outages(model) == union(first_ids, added_id)
    @test _post_contingency_outage_axis(model) ==
          Set(string.(union(first_ids, added_id)))
end

@testset "SecurityConstrainedStaticBranch rejects a selected attribute that is not an outage" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    _add_line_outage!(c_sys5, "1")
    geo = PSY.GeographicInfo(;
        geo_json = Dict("type" => "Point", "coordinates" => [0.0, 0.0]),
    )
    PSY.add_supplemental_attribute!(
        c_sys5,
        get_component(PSY.ACTransmission, c_sys5, "1"),
        geo,
    )
    template = _sc_branch_template(
        DeviceModel(PSY.Line, POM.SecurityConstrainedStaticBranch; outages = [geo]),
    )
    model = DecisionModel(template, c_sys5; optimizer = HiGHS_optimizer)
    @test_throws IS.ConflictingInputsError POM.validate_template(model)
end

@testset "DeviceModel outage selection is dropped with a warning for non-SC formulations" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    outage = _add_line_outage!(c_sys5, "1")
    @test_logs (:warn, r"does not support") match_mode = :any begin
        dm = DeviceModel(PSY.Line, POM.StaticBranch; outages = [outage])
        @test IOM.get_outage_selection(dm) === nothing
    end
end

@testset "Multi-component outage: dual-claim + dedup at build" begin
    # An outage attached to BOTH a Line and a TwoWindingTransformer is owned by both
    # SC DeviceModels. The build dedups: the second DeviceModel's expression and
    # constraint containers reference the first claimer's objects.
    sys = PSB.build_system(PSITestSystems, "c_sys14")
    line = first(get_components(PSY.Line, sys))
    transformer = first(get_components(PSY.TwoWindingTransformer, sys))
    @test !isnothing(line)
    @test !isnothing(transformer)

    outage = PSY.GeometricDistributionForcedOutage(;
        mean_time_to_recovery = 10,
        outage_transition_probability = 0.9999,
        monitored_components = [line, transformer],
    )
    PSY.add_supplemental_attribute!(sys, line, outage)
    PSY.add_supplemental_attribute!(sys, transformer, outage)
    outage_uuid = IS.get_id(outage)
    outage_uuid_str = string(outage_uuid)

    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel),
    )
    set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
    set_device_model!(
        template,
        PSY.TwoWindingTransformer,
        POM.SecurityConstrainedStaticBranch,
    )
    ps_model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    template_under_test = IOM.get_template(ps_model)
    line_dm = IOM.get_model(template_under_test, PSY.Line)
    transformer_dm = IOM.get_model(template_under_test, PSY.TwoWindingTransformer)

    @test haskey(IOM.get_outages(line_dm), outage_uuid)
    @test haskey(IOM.get_outages(transformer_dm), outage_uuid)

    container = IOM.get_optimization_container(ps_model)
    line_pcbf = IOM.get_expression(container, POM.PostContingencyBranchFlow, PSY.Line)
    transformer_pcbf =
        IOM.get_expression(
            container,
            POM.PostContingencyBranchFlow,
            PSY.TwoWindingTransformer,
        )

    line_name = PSY.get_name(line)
    transformer_name = PSY.get_name(transformer)
    time_steps = IOM.get_time_steps(container)

    # Expression-level dedup: same `AffExpr` object (===) in both containers.
    for t in time_steps
        @test line_pcbf[outage_uuid_str, line_name, t] ===
              transformer_pcbf[outage_uuid_str, line_name, t]
        @test line_pcbf[outage_uuid_str, transformer_name, t] ===
              transformer_pcbf[outage_uuid_str, transformer_name, t]
    end

    # Constraint-level dedup: same `ConstraintRef` in both per-V containers.
    for meta in ("lb", "ub")
        line_cons = IOM.get_constraint(
            container,
            IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, meta),
        )
        transformer_cons = IOM.get_constraint(
            container,
            IOM.ConstraintKey(
                POM.PostContingencyFlowRateConstraint,
                PSY.TwoWindingTransformer,
                meta,
            ),
        )
        for t in time_steps
            @test line_cons[outage_uuid_str, line_name, t] ===
                  transformer_cons[outage_uuid_str, line_name, t]
            @test line_cons[outage_uuid_str, transformer_name, t] ===
                  transformer_cons[outage_uuid_str, transformer_name, t]
        end
    end
end

@testset "SCUC constraint tracking: parallel circuits collapse to representative" begin
    # After two parallel members collapse to a single reduction representative,
    # the pre-contingency `FlowRateConstraint` tracker must record the arc once
    # (representative-keyed), and the post-contingency container's name axis must
    # use the representative — never the individual branch names.
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    parallel_line_name = "1"
    parallel_line = first(
        get_components(b -> get_name(b) == parallel_line_name, PSY.ACTransmission, sys),
    )
    add_equivalent_ac_transmission_with_parallel_circuits!(
        sys,
        parallel_line,
        typeof(parallel_line),
    )

    outage = PSY.GeometricDistributionForcedOutage(;
        mean_time_to_recovery = 10,
        outage_transition_probability = 0.9999,
        monitored_components = [parallel_line],
    )
    PSY.add_supplemental_attribute!(sys, parallel_line, outage)
    outage_uuid = string(IS.get_id(outage))

    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel),
    )
    set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
    ps_model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(ps_model)
    network_model = IOM.get_network_model(IOM.get_template(ps_model))
    tracker = IOM.get_reduced_branch_tracker(network_model)
    net_reduction_data = POM.get_branch_catalog(network_model)

    # Derive the representative name from the reduction map (PNM names it after the arc,
    # e.g. "<from>_<to>_double_circuit"; not hard-coded so the test tracks PNM naming).
    c2r = PNM.get_component_to_reduction_name_map(net_reduction_data)
    @test haskey(c2r, PSY.Line)
    representative_name = c2r[PSY.Line][parallel_line_name]
    @test representative_name != parallel_line_name
    @test get(c2r[PSY.Line], parallel_line_name * "_copy", nothing) == representative_name

    # FlowRateConstraint tracker: representative-name key, no individual names.
    flow_cmap =
        POM.get_constraint_map_by_type(tracker)[POM.FlowRateConstraint][PSY.Line]
    @test haskey(flow_cmap, representative_name)
    @test !haskey(flow_cmap, parallel_line_name)
    @test !haskey(flow_cmap, parallel_line_name * "_copy")

    # Post-contingency container: name axis uses the representative.
    con_ub = IOM.get_constraint(
        container,
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "ub"),
    )
    name_axis = Set(k[2] for k in keys(con_ub.data))
    @test representative_name in name_axis
    @test !(parallel_line_name in name_axis)
    @test !(parallel_line_name * "_copy" in name_axis)
    @test outage_uuid in Set(k[1] for k in keys(con_ub.data))
end

@testset "Security Constrained branch formulation builds for supported network formulations" begin
    # Every NetworkModel formulation with a construct_device! dispatch for
    # SecurityConstrainedStaticBranch must build and emit the post-contingency
    # emergency-rate constraint container.
    sys = PSB.build_system(PSB.PSISystems, "two_area_pjm_DA")
    transform_single_time_series!(sys, Hour(24), Hour(1))
    all_branches = collect(get_components(PSY.ACTransmission, sys))
    for line in Iterators.take(get_components(PSY.Line, sys), 3)
        PSY.add_supplemental_attribute!(
            sys,
            line,
            PSY.GeometricDistributionForcedOutage(;
                mean_time_to_recovery = 10,
                outage_transition_probability = 0.9999,
                monitored_components = all_branches,
            ),
        )
    end

    constraint_keys = [
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "lb"),
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "ub"),
    ]
    # Every NetworkModel formulation with a construct_device! dispatch for
    # SecurityConstrainedStaticBranch must build to completion. These are the
    # lossless linear networks: PTDF, AreaPTDF, and DCP. AC and lossy networks
    # (ACP/ACR/IVR/LPACC/DCPLL) are rejected at template validation — see the
    # "blocked on AC and lossy network models" testset.
    for (label, NetFormulation, optimizer) in [
        ("PTDFNetworkModel", PTDFNetworkModel, HiGHS_optimizer),
        ("AreaPTDFNetworkModel", POM.AreaPTDFNetworkModel, HiGHS_optimizer),
        ("DCPNetworkModel", POM.DCPNetworkModel, HiGHS_optimizer),
    ]
        @testset "$label" begin
            template = get_thermal_dispatch_template_network(
                NetworkModel(NetFormulation),
            )
            set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
            set_device_model!(
                template,
                PSY.TwoWindingTransformer,
                POM.SecurityConstrainedStaticBranch,
            )
            set_device_model!(
                template,
                PSY.TwoWindingTransformer,
                POM.SecurityConstrainedStaticBranch,
            )

            ps_model = DecisionModel(template, sys; optimizer = optimizer)
            @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
                  IOM.ModelBuildStatus.BUILT
            psi_constraint_test(ps_model, constraint_keys)
        end
    end
end

@testset "DCP post-contingency expressions differ per outage" begin
    # The single highest-value N-1 check: for one monitored branch, the
    # post-contingency flow expression must depend on WHICH branch is out (the
    # MODF row differs per outage). A formulation that reuses the branch's own
    # base-case flow for every outage produces byte-identical expressions and
    # models zero contingency response — this testset exists to reject that.
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    monitored = get_component(PSY.ACTransmission, c_sys5, "3")
    for line_name in ["1", "2"]
        outaged = get_component(PSY.ACTransmission, c_sys5, line_name)
        PSY.add_supplemental_attribute!(
            c_sys5,
            outaged,
            PSY.GeometricDistributionForcedOutage(;
                mean_time_to_recovery = 10,
                outage_transition_probability = 0.9999,
                monitored_components = [monitored],
            ),
        )
    end

    template = get_thermal_dispatch_template_network(NetworkModel(POM.DCPNetworkModel))
    set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)

    ps_model = DecisionModel(template, c_sys5; optimizer = HiGHS_optimizer)
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(ps_model)
    pcbf = IOM.get_expression(container, POM.PostContingencyBranchFlow, PSY.Line)
    outage_ids = sort!(unique(k[1] for k in keys(pcbf.data)))
    @test length(outage_ids) == 2

    for t in IOM.get_time_steps(container)
        expr_outage_1 = pcbf[outage_ids[1], "3", t]
        expr_outage_2 = pcbf[outage_ids[2], "3", t]
        # A genuine MODF-weighted expression spans the network's flow variables,
        # not just the monitored branch's own flow.
        @test length(expr_outage_1.terms) > 1
        @test length(expr_outage_2.terms) > 1
        # Different outage => different MODF row => different coefficients.
        @test !_affexpr_approx_equal(expr_outage_1, expr_outage_2)
    end
end

@testset "DCP post-contingency expressions match MODF x injection ground truth" begin
    # Coefficient-level check against an independent oracle. The oracle derives
    # the nodal injection expressions straight from the SYSTEM TOPOLOGY (KCL at
    # each bus: injection = sum of flows leaving - sum of flows arriving, from
    # the PSY arcs) and a freshly-built VirtualMODF — it does NOT go through the
    # production balance-filtering path, so a sign or ordering error there
    # cannot cancel out here.
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    all_branches = collect(get_components(PSY.ACTransmission, c_sys5))
    for line_name in ["1", "2", "3"]
        line = get_component(PSY.ACTransmission, c_sys5, line_name)
        PSY.add_supplemental_attribute!(
            c_sys5,
            line,
            PSY.GeometricDistributionForcedOutage(;
                mean_time_to_recovery = 10,
                outage_transition_probability = 0.9999,
                monitored_components = all_branches,
            ),
        )
    end

    template = get_thermal_dispatch_template_network(NetworkModel(POM.DCPNetworkModel))
    set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)

    ps_model = DecisionModel(template, c_sys5; optimizer = HiGHS_optimizer)
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(ps_model)
    network_model = IOM.get_network_model(IOM.get_template(ps_model))
    @test !isnothing(IOM.get_contingency_matrix(network_model))
    time_steps = IOM.get_time_steps(container)

    # Base-case DCP structure is intact: flow limits and the DC Ohm's law exist
    # for the security-constrained branches.
    @test !isempty(
        IOM.get_constraints(container)[IOM.ConstraintKey(
            FlowRateConstraint, PSY.Line, "ub",
        )],
    )
    @test !isempty(
        IOM.get_constraint(
            container, IOM.ConstraintKey(POM.NetworkFlowConstraint, PSY.Line),
        ),
    )

    # Independent oracle, part 1: nodal injection expressions from KCL over the
    # raw PSY arcs. Flow f_b (from -> to) leaves the from-bus and arrives at the
    # to-bus, so injection[from] += f_b and injection[to] -= f_b.
    ground_truth_modf = PNM.VirtualMODF(c_sys5)
    ground_truth_registered = PNM.get_registered_contingencies(ground_truth_modf)
    @test !isempty(ground_truth_registered)
    bus_axis = PNM.get_bus_axis(ground_truth_modf)
    flow_vars = IOM.get_variable(container, POM.FlowActivePowerVariable, PSY.Line)
    injection_oracle = Dict{Tuple{Int, Int}, JuMP.AffExpr}(
        (bus_no, t) => zero(JuMP.AffExpr) for bus_no in bus_axis, t in time_steps
    )
    for line in get_components(PSY.Line, c_sys5)
        arc = PSY.get_arc(line)
        from_no = PSY.get_number(PSY.get_from(arc))
        to_no = PSY.get_number(PSY.get_to(arc))
        for t in time_steps
            flow = flow_vars[PSY.get_name(line), t]
            JuMP.add_to_expression!(injection_oracle[(from_no, t)], 1.0, flow)
            JuMP.add_to_expression!(injection_oracle[(to_no, t)], -1.0, flow)
        end
    end

    # Independent oracle, part 2: expected expression = MODF row . injections.
    pcbf = IOM.get_expression(container, POM.PostContingencyBranchFlow, PSY.Line)
    @test !isempty(pcbf.data)
    con_ub = IOM.get_constraints(container)[IOM.ConstraintKey(
        POM.PostContingencyFlowRateConstraint, PSY.Line, "ub",
    )]
    con_lb = IOM.get_constraints(container)[IOM.ConstraintKey(
        POM.PostContingencyFlowRateConstraint, PSY.Line, "lb",
    )]
    @test !isempty(con_ub.data)
    @test !isempty(con_lb.data)

    net_reduction_data = POM.get_branch_catalog(network_model)
    name_to_arc_map = PNM.get_name_to_arc_maps(net_reduction_data)[PSY.Line]

    n_checked = 0
    for (outage_id_str, name, t) in keys(pcbf.data)
        outage_id = parse(Int, outage_id_str)
        ctg = ground_truth_registered[outage_id]
        arc = name_to_arc_map[name]

        modf_col = ground_truth_modf[arc, ctg]
        expected = zero(JuMP.AffExpr)
        for i in eachindex(modf_col)
            abs(modf_col[i]) > POM.PTDF_ZERO_TOL || continue
            JuMP.add_to_expression!(
                expected,
                modf_col[i],
                injection_oracle[(bus_axis[i], t)],
            )
        end
        actual = pcbf[outage_id_str, name, t]
        @test _affexpr_approx_equal(actual, expected)

        # RHS = +/- emergency rating in system per-unit.
        reduction_entry = PNM.get_reduction_entry(net_reduction_data, arc)
        limits = POM._emergency_flow_limits(reduction_entry)
        expr_const = JuMP.constant(actual)
        @test JuMP.normalized_rhs(con_ub[outage_id_str, name, t]) + expr_const ≈
              limits.max
        @test JuMP.normalized_rhs(con_lb[outage_id_str, name, t]) + expr_const ≈
              limits.min
        n_checked += 1
    end
    @test n_checked >= 1

    psi_checksolve_test(ps_model, [MOI.OPTIMAL, MOI.ALMOST_OPTIMAL])
end

@testset "DCP post-contingency flows include StaticBranch transformer flows" begin
    for transformer_formulation in (StaticBranch, POM.SecurityConstrainedStaticBranch)
        c_sys14 = PSB.build_system(PSITestSystems, "c_sys14")
        all_branches = collect(get_components(PSY.ACTransmission, c_sys14))
        for line_name in ["Line1", "Line9"]
            line = get_component(PSY.ACTransmission, c_sys14, line_name)
            PSY.add_supplemental_attribute!(
                c_sys14,
                line,
                PSY.FixedForcedOutage(;
                    outage_status = 1.0,
                    monitored_components = all_branches,
                ),
            )
        end
        template =
            get_thermal_dispatch_template_network(NetworkModel(POM.DCPNetworkModel))
        set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
        set_device_model!(template, PSY.TwoWindingTransformer, transformer_formulation)
        ps_model = DecisionModel(template, c_sys14; optimizer = HiGHS_optimizer)
        @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT

        container = IOM.get_optimization_container(ps_model)
        time_steps = IOM.get_time_steps(container)
        ground_truth_modf = PNM.VirtualMODF(c_sys14)
        registered = PNM.get_registered_contingencies(ground_truth_modf)
        bus_axis = PNM.get_bus_axis(ground_truth_modf)

        # KCL oracle over the raw PSY arcs: flow f leaves `from` and arrives at `to`.
        injection = Dict{Tuple{Int, Int}, JuMP.AffExpr}(
            (bus_no, t) => zero(JuMP.AffExpr) for bus_no in bus_axis, t in time_steps
        )
        line_flows = IOM.get_variable(container, POM.FlowActivePowerVariable, PSY.Line)
        for line in get_components(PSY.Line, c_sys14), t in time_steps
            arc = PSY.get_arc(line)
            flow = line_flows[PSY.get_name(line), t]
            JuMP.add_to_expression!(
                injection[(PSY.get_number(PSY.get_from(arc)), t)],
                1.0,
                flow,
            )
            JuMP.add_to_expression!(
                injection[(PSY.get_number(PSY.get_to(arc)), t)],
                -1.0,
                flow,
            )
        end
        for tr in get_components(PSY.TwoWindingTransformer, c_sys14), t in time_steps
            arc = PSY.get_arc(tr)
            flow = _dcp_transformer_flow(
                container,
                transformer_formulation,
                PSY.get_name(tr),
                t,
            )
            JuMP.add_to_expression!(
                injection[(PSY.get_number(PSY.get_from(arc)), t)],
                1.0,
                flow,
            )
            JuMP.add_to_expression!(
                injection[(PSY.get_number(PSY.get_to(arc)), t)],
                -1.0,
                flow,
            )
        end

        pcbf = IOM.get_expression(container, POM.PostContingencyBranchFlow, PSY.Line)
        name_to_arc_maps =
            PNM.get_name_to_arc_maps(
                POM.get_branch_catalog(
                    IOM.get_network_model(IOM.get_template(ps_model)),
                ),
            )
        n_checked = 0
        for (outage_id_str, name, t) in keys(pcbf.data)
            modf_col = ground_truth_modf[
                _monitored_arc(name_to_arc_maps, name),
                registered[parse(Int, outage_id_str)],
            ]
            expected = zero(JuMP.AffExpr)
            for i in eachindex(modf_col)
                abs(modf_col[i]) > POM.PTDF_ZERO_TOL || continue
                JuMP.add_to_expression!(expected, modf_col[i], injection[(bus_axis[i], t)])
            end
            @test _affexpr_approx_equal(pcbf[outage_id_str, name, t], expected)
            n_checked += 1
        end
        @test n_checked >= 1
    end
end

@testset "DCP N-1 rejects a StaticBranch transformer with a phase shift" begin
    # `_dcp_nodal_injection_expressions` would carry the shift, but validation blocks the case.
    c_sys14 = PSB.build_system(PSITestSystems, "c_sys14")
    transformer = get_component(PSY.TwoWindingTransformer, c_sys14, "Trans1")
    PSY.set_α!(PSY.get_circuit(transformer), 0.1)
    template = get_thermal_dispatch_template_network(NetworkModel(POM.DCPNetworkModel))
    set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
    set_device_model!(template, PSY.TwoWindingTransformer, StaticBranch)
    model = DecisionModel(template, c_sys14; optimizer = HiGHS_optimizer)
    @test_throws IS.ConflictingInputsError POM.validate_template(model)
end

@testset "Security-constrained branches are blocked on AC and lossy network models" begin
    # The MODF post-contingency formulation is a lossless linear DC construct;
    # the AC and lossy networks are rejected at template validation. `build!`
    # swallows the throw into a FAILED status, so assert against
    # `validate_template` directly.
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    all_branches = collect(get_components(PSY.ACTransmission, c_sys5))
    line = get_component(PSY.ACTransmission, c_sys5, "1")
    PSY.add_supplemental_attribute!(
        c_sys5,
        line,
        PSY.GeometricDistributionForcedOutage(;
            mean_time_to_recovery = 10,
            outage_transition_probability = 0.9999,
            monitored_components = all_branches,
        ),
    )

    for NetFormulation in (
        POM.ACPNetworkModel,
        POM.ACRNetworkModel,
        POM.IVRNetworkModel,
        POM.LPACCNetworkModel,
        POM.DCPLLNetworkModel,
    )
        template = get_thermal_dispatch_template_network(NetworkModel(NetFormulation))
        set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
        model = DecisionModel(template, c_sys5; optimizer = ipopt_optimizer)
        @test_throws IS.ConflictingInputsError POM.validate_template(model)
    end
end

@testset "Security-constrained branches are inert no-ops on NFA/CopperPlate/AreaBalance" begin
    # These networks carry no branch-flow representation for the MODF machinery:
    # the model builds, no post-contingency containers are created, and a @warn
    # tells the user that the security limits are inert (the warning lands in
    # the build's operation_problem.log, not the console).
    two_area = PSB.build_system(PSB.PSISystems, "two_area_pjm_DA")
    transform_single_time_series!(two_area, Hour(24), Hour(1))
    c_sys5_nfa = PSB.build_system(PSITestSystems, "c_sys5")
    c_sys5_cp = PSB.build_system(PSITestSystems, "c_sys5")
    for sys in (c_sys5_nfa, c_sys5_cp, two_area)
        all_branches = collect(get_components(PSY.ACTransmission, sys))
        line = first(get_components(PSY.Line, sys))
        PSY.add_supplemental_attribute!(
            sys,
            line,
            PSY.GeometricDistributionForcedOutage(;
                mean_time_to_recovery = 10,
                outage_transition_probability = 0.9999,
                monitored_components = all_branches,
            ),
        )
    end

    for (NetFormulation, sys) in (
        (POM.NFANetworkModel, c_sys5_nfa),
        (POM.CopperPlateNetworkModel, c_sys5_cp),
        (POM.AreaBalanceNetworkModel, two_area),
    )
        template = get_thermal_dispatch_template_network(NetworkModel(NetFormulation))
        set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
        ps_model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        output_dir = mktempdir(; cleanup = true)
        @test build!(ps_model; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT

        container = IOM.get_optimization_container(ps_model)
        @test !any(
            k -> IOM.get_entry_type(k) === POM.PostContingencyFlowRateConstraint,
            keys(IOM.get_constraints(container)),
        )
        @test !any(
            k -> IOM.get_entry_type(k) === POM.PostContingencyBranchFlow,
            keys(IOM.get_expressions(container)),
        )

        log_contents = read(joinpath(output_dir, "operation_problem.log"), String)
        @test occursin("security-constrained branch limits are inert", log_contents)
    end
end

# ---------------------------------------------------------------------------
# Additional testsets ported from PowerSimulations.jl PR #1579 (Task 6.1).
# The parallel-line / reduction testsets upstream assert exact PSI-internal MOI
# counts (`moi_tests`) and PSI objective magic numbers. Those constants depend
# on PSI's container layout and are NOT reproduced here; instead we assert the
# portable physics: build succeeds, the pre- and post-contingency constraint
# containers are present and well-formed, and (on the small systems) the LP
# solves to optimality. c_sys14_dc solve is skipped exactly as upstream does
# (HiGHS is slow to reach optimality on it).
# ---------------------------------------------------------------------------

@testset "Security Constrained branch formulation DC-PF with PTDF/MODF and parallel lines" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    c_sys14 = PSB.build_system(PSITestSystems, "c_sys14")
    c_sys14_dc = PSB.build_system(PSITestSystems, "c_sys14_dc")
    parallel_branches_to_add = IdDict{System, Vector{String}}(
        c_sys5 => ["3", "4"],
        c_sys14 => ["Line1", "Line14"],
        c_sys14_dc => ["Line1", "Line14"],
    )
    systems = [c_sys5, c_sys14, c_sys14_dc]
    for sys in systems
        for branch_name in parallel_branches_to_add[sys]
            branch = first(
                get_components(b -> get_name(b) == branch_name, PSY.ACTransmission, sys),
            )
            add_equivalent_ac_transmission_with_parallel_circuits!(
                sys,
                branch,
                typeof(branch),
            )
        end
    end

    constraint_keys = [
        IOM.ConstraintKey(FlowRateConstraint, PSY.Line, "lb"),
        IOM.ConstraintKey(FlowRateConstraint, PSY.Line, "ub"),
        IOM.ConstraintKey(CopperPlateBalanceConstraint, PSY.System),
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "lb"),
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "ub"),
    ]
    lines_outages = IdDict{System, Vector{String}}(
        c_sys5 => ["1", "2", "3"],
        c_sys14 => ["Line1", "Line2", "Line9", "Line10", "Line12", "Trans2"],
        c_sys14_dc => ["Line9"],
    )
    for (ix, sys) in enumerate(systems)
        # outages must be added before MODF matrix computation
        all_branches = collect(get_components(PSY.ACTransmission, sys))
        for line_name in lines_outages[sys]
            transition_data = PSY.GeometricDistributionForcedOutage(;
                mean_time_to_recovery = 10,
                outage_transition_probability = 0.9999,
                monitored_components = all_branches,
            )
            component = get_component(PSY.ACTransmission, sys, line_name)
            PSY.add_supplemental_attribute!(sys, component, transition_data)
        end
        template = get_thermal_dispatch_template_network(
            NetworkModel(PTDFNetworkModel),
        )
        set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
        set_device_model!(
            template,
            PSY.TwoWindingTransformer,
            POM.SecurityConstrainedStaticBranch,
        )
        set_device_model!(
            template,
            PSY.TwoWindingTransformer,
            POM.SecurityConstrainedStaticBranch,
        )

        ps_model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        psi_constraint_test(ps_model, constraint_keys)

        ix > 2 && continue # skip c_sys14_dc solve (HiGHS slow to optimality)
        psi_checksolve_test(ps_model, [MOI.OPTIMAL, MOI.ALMOST_OPTIMAL])
    end
end

@testset "Security Constrained branch formulation DC-PF with PTDF/MODF and parallel lines removing complete arc" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    c_sys14 = PSB.build_system(PSITestSystems, "c_sys14")
    c_sys14_dc = PSB.build_system(PSITestSystems, "c_sys14_dc")
    parallel_branches_to_add = IdDict{System, Vector{String}}(
        c_sys5 => ["3", "4"],
        c_sys14 => ["Line1", "Line14"],
        c_sys14_dc => ["Line1", "Line14"],
    )
    systems = [c_sys5, c_sys14, c_sys14_dc]
    for sys in systems
        for branch_name in parallel_branches_to_add[sys]
            branch = first(
                get_components(b -> get_name(b) == branch_name, PSY.ACTransmission, sys),
            )
            add_equivalent_ac_transmission_with_parallel_circuits!(
                sys,
                branch,
                typeof(branch),
            )
        end
    end

    constraint_keys = [
        IOM.ConstraintKey(FlowRateConstraint, PSY.Line, "lb"),
        IOM.ConstraintKey(FlowRateConstraint, PSY.Line, "ub"),
        IOM.ConstraintKey(CopperPlateBalanceConstraint, PSY.System),
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "lb"),
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "ub"),
    ]
    # Outage BOTH members of each parallel pair so the whole arc goes out.
    lines_outages = IdDict{System, Vector{String}}(
        c_sys5 => ["3", "4"],
        c_sys14 => ["Line1", "Line14"],
        c_sys14_dc => ["Line1", "Line14"],
    )
    for (ix, sys) in enumerate(systems)
        all_branches = collect(get_components(PSY.ACTransmission, sys))
        for line_name in lines_outages[sys]
            transition_data = PSY.GeometricDistributionForcedOutage(;
                mean_time_to_recovery = 10,
                outage_transition_probability = 0.9999,
                monitored_components = all_branches,
            )
            component = get_component(PSY.ACTransmission, sys, line_name)
            PSY.add_supplemental_attribute!(sys, component, transition_data)
            component_parallel =
                get_component(PSY.ACTransmission, sys, line_name * "_copy")
            PSY.add_supplemental_attribute!(sys, component_parallel, transition_data)
        end
        template = get_thermal_dispatch_template_network(
            NetworkModel(PTDFNetworkModel),
        )
        set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
        set_device_model!(
            template,
            PSY.TwoWindingTransformer,
            POM.SecurityConstrainedStaticBranch,
        )
        set_device_model!(
            template,
            PSY.TwoWindingTransformer,
            POM.SecurityConstrainedStaticBranch,
        )

        ps_model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        psi_constraint_test(ps_model, constraint_keys)

        ix > 2 && continue
        psi_checksolve_test(ps_model, [MOI.OPTIMAL, MOI.ALMOST_OPTIMAL])
    end
end

@testset "Security Constrained branch formulation DC-PF with PTDF/MODF and degree-two reductions" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    c_sys14 = PSB.build_system(PSITestSystems, "c_sys14")
    c_sys14_dc = PSB.build_system(PSITestSystems, "c_sys14_dc")
    parallel_branches_to_add = IdDict{System, Vector{String}}(
        c_sys5 => ["4"],
        c_sys14 => ["Line14"],
        c_sys14_dc => ["Line14"],
    )
    systems = [c_sys5, c_sys14, c_sys14_dc]
    for sys in systems
        for branch_name in parallel_branches_to_add[sys]
            branch = first(
                get_components(b -> get_name(b) == branch_name, PSY.ACTransmission, sys),
            )
            add_equivalent_ac_transmission_with_series_parallel_circuits!(
                sys,
                branch,
                typeof(branch),
            )
        end
    end

    constraint_keys = [
        IOM.ConstraintKey(FlowRateConstraint, PSY.Line, "lb"),
        IOM.ConstraintKey(FlowRateConstraint, PSY.Line, "ub"),
        IOM.ConstraintKey(CopperPlateBalanceConstraint, PSY.System),
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "lb"),
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "ub"),
    ]
    lines_outages = IdDict{System, Vector{String}}(
        c_sys5 => ["1", "2", "3"],
        c_sys14 => ["Line1", "Line2", "Line9", "Line10", "Line12", "Trans2"],
        c_sys14_dc => ["Line9"],
    )
    for (ix, sys) in enumerate(systems)
        # In the reduction path each outage monitors only its own outaged line.
        # Monitoring `all_branches` would pin every bus as irreducible and cancel
        # the degree-two reduction the test exists to exercise.
        for line_name in lines_outages[sys]
            component = get_component(PSY.ACTransmission, sys, line_name)
            transition_data = PSY.GeometricDistributionForcedOutage(;
                mean_time_to_recovery = 10,
                outage_transition_probability = 0.9999,
                monitored_components = [component],
            )
            PSY.add_supplemental_attribute!(sys, component, transition_data)
        end
        nr = NetworkReduction[DegreeTwoReduction()]
        template = get_thermal_dispatch_template_network(
            NetworkModel(
                PTDFNetworkModel;
                network_source = SystemNetworkSource(nr),
            ),
        )
        set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
        set_device_model!(
            template,
            PSY.TwoWindingTransformer,
            POM.SecurityConstrainedStaticBranch,
        )
        set_device_model!(
            template,
            PSY.TwoWindingTransformer,
            POM.SecurityConstrainedStaticBranch,
        )

        ps_model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        psi_constraint_test(ps_model, constraint_keys)

        # Sparse-container structural check on c_sys5: each monitoring outage
        # produces a PostContingencyFlowRateConstraint SparseAxisArray whose
        # axis-1 (outage_id) covers exactly the Line-monitoring outages, and
        # whose (outage_id, t) coverage is full-rank in time.
        if ix == 1
            template_under_test = IOM.get_template(ps_model)
            line_dm = IOM.get_model(template_under_test, PSY.Line)
            line_outages = IOM.get_outages(line_dm)
            @test !isempty(line_outages)
            container = IOM.get_optimization_container(ps_model)
            time_steps = IOM.get_time_steps(container)
            con_ub = IOM.get_constraint(
                container,
                IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "ub"),
            )
            ub_keys = collect(keys(con_ub.data))
            ub_outages = Set(k[1] for k in ub_keys)
            ub_names = Set(k[2] for k in ub_keys)
            @test !isempty(ub_outages)
            @test !isempty(ub_names)
            line_monitoring_outages = Set(
                string(uuid) for (uuid, per_type) in line_outages if
                haskey(per_type, PSY.Line) && !isempty(per_type[PSY.Line])
            )
            @test ub_outages == line_monitoring_outages
            for outage_id in ub_outages
                for t in time_steps
                    @test any(k -> k[1] == outage_id && k[3] == t, ub_keys)
                end
            end
        end

        ix > 2 && continue
        psi_checksolve_test(ps_model, [MOI.OPTIMAL, MOI.ALMOST_OPTIMAL])
    end
end

@testset "Security Constrained branch formulation DC-PF with reductions and separate monitored lines" begin
    c_sys5 = PSB.build_system(PSITestSystems, "c_sys5")
    c_sys14 = PSB.build_system(PSITestSystems, "c_sys14")
    c_sys14_dc = PSB.build_system(PSITestSystems, "c_sys14_dc")
    parallel_branches_to_add = IdDict{System, Vector{String}}(
        c_sys5 => ["4"],
        c_sys14 => ["Line14"],
        c_sys14_dc => ["Line14"],
    )
    systems = [c_sys5, c_sys14, c_sys14_dc]
    for sys in systems
        for branch_name in parallel_branches_to_add[sys]
            branch = first(
                get_components(b -> get_name(b) == branch_name, PSY.ACTransmission, sys),
            )
            add_equivalent_ac_transmission_with_series_parallel_circuits!(
                sys,
                branch,
                typeof(branch),
            )
        end
    end

    constraint_keys = [
        IOM.ConstraintKey(FlowRateConstraint, PSY.Line, "lb"),
        IOM.ConstraintKey(FlowRateConstraint, PSY.Line, "ub"),
        IOM.ConstraintKey(CopperPlateBalanceConstraint, PSY.System),
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "lb"),
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "ub"),
    ]
    # Outaged lines (taken out of service)
    lines_outages = IdDict{System, Vector{String}}(
        c_sys5 => ["1", "2", "3"],
        c_sys14 => ["Line1", "Line2", "Line9", "Line10", "Line12", "Trans2"],
        c_sys14_dc => ["Line9"],
    )
    # Monitored lines — different from the outaged lines (non-trivial test)
    monitored_lines = IdDict{System, Vector{String}}(
        c_sys5 => ["4", "5", "6"],
        c_sys14 => ["Line3", "Line4", "Line5", "Line6", "Line7", "Line8"],
        c_sys14_dc => ["Line1"],
    )
    for (ix, sys) in enumerate(systems)
        for (idx, line_name) in enumerate(lines_outages[sys])
            outaged_component = get_component(PSY.ACTransmission, sys, line_name)
            monitored_component =
                get_component(PSY.ACTransmission, sys, monitored_lines[sys][idx])
            transition_data = PSY.GeometricDistributionForcedOutage(;
                mean_time_to_recovery = 10,
                outage_transition_probability = 0.9999,
                monitored_components = [monitored_component],
            )
            PSY.add_supplemental_attribute!(sys, outaged_component, transition_data)
        end
        nr = NetworkReduction[DegreeTwoReduction()]
        template = get_thermal_dispatch_template_network(
            NetworkModel(
                PTDFNetworkModel;
                network_source = SystemNetworkSource(nr),
            ),
        )
        set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
        set_device_model!(
            template,
            PSY.TwoWindingTransformer,
            POM.SecurityConstrainedStaticBranch,
        )
        set_device_model!(
            template,
            PSY.TwoWindingTransformer,
            POM.SecurityConstrainedStaticBranch,
        )

        ps_model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
        @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        psi_constraint_test(ps_model, constraint_keys)

        if ix == 1
            template_under_test = IOM.get_template(ps_model)
            line_dm = IOM.get_model(template_under_test, PSY.Line)
            line_outages = IOM.get_outages(line_dm)
            @test !isempty(line_outages)
            container = IOM.get_optimization_container(ps_model)
            time_steps = IOM.get_time_steps(container)
            con_ub = IOM.get_constraint(
                container,
                IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "ub"),
            )
            ub_keys = collect(keys(con_ub.data))
            ub_outages = Set(k[1] for k in ub_keys)
            ub_names = Set(k[2] for k in ub_keys)
            @test !isempty(ub_outages)
            @test !isempty(ub_names)
            line_monitoring_outages = Set(
                string(uuid) for (uuid, per_type) in line_outages if
                haskey(per_type, PSY.Line) && !isempty(per_type[PSY.Line])
            )
            @test ub_outages == line_monitoring_outages
            for outage_id in ub_outages
                for t in time_steps
                    @test any(k -> k[1] == outage_id && k[3] == t, ub_keys)
                end
            end
        end

        ix > 2 && continue
        psi_checksolve_test(ps_model, [MOI.OPTIMAL, MOI.ALMOST_OPTIMAL])
    end
end

# Duals of the post-contingency flow constraints (ported from upstream PSI).
# These exercise the IOM dual-assignment path for SparseAxisArray-keyed, meta'd
# post-contingency constraints. They were previously blocked because the
# `SparseAxisArray` method of `_assign_dual_from_existing!` in
# `InfrastructureOptimizationModels/src/common_models/add_constraint_dual.jl` did
# not forward `meta = key.meta`, collapsing the "lb"/"ub" keys onto one empty-meta
# dual key. That IOM fix is now in place, so both paths can register and read back
# their duals.

# Attach N-1 outages on three named branches, each monitoring every branch, so the
# post-contingency flow constraints are dense enough that at least one binds.
function _attach_some_branch_outages!(sys)
    branches = collect(get_components(PSY.ACTransmission, sys))
    for line_name in ("1", "2", "3")
        PSY.add_supplemental_attribute!(
            sys,
            get_component(PSY.ACTransmission, sys, line_name),
            PSY.GeometricDistributionForcedOutage(;
                mean_time_to_recovery = 10,
                outage_transition_probability = 0.9999,
                monitored_components = branches,
            ),
        )
    end
    return sys
end

# Shared assertions: the post-contingency duals must mirror their constraint's
# sparse keys exactly, be finite, not be uniformly zero (something binds), and
# round-trip through `read_duals`.
function _test_post_contingency_line_duals(container)
    duals = IOM.get_duals(container)
    collected = Float64[]
    for meta in ("lb", "ub")
        cons_key =
            IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, meta)
        cons = IOM.get_constraint(container, cons_key)
        @test haskey(duals, cons_key)
        dual = duals[cons_key]
        # Dual container must mirror the sparse constraint's keys exactly.
        @test Set(keys(dual.data)) == Set(keys(cons.data))
        @test !isempty(dual.data)
        @test all(isfinite, values(dual.data))
        append!(collected, values(dual.data))
    end
    # Some post-contingency constraint binds in this congested system, so the duals
    # are not all the zero-initialized default — proves the sparse path actually
    # computed them rather than leaving the container untouched.
    @test any(!iszero, collected)

    # SparseAxisArray duals must also round-trip through `read_duals`.
    dual_frames = IOM.read_duals(container)
    for meta in ("lb", "ub")
        df = dual_frames[IOM.ConstraintKey(
            POM.PostContingencyFlowRateConstraint,
            PSY.Line,
            meta,
        )]
        @test nrow(df) > 0
        @test ncol(df) > 0
        @test all(isfinite, Matrix(df))
    end
end

@testset "Duals of post-contingency flow constraints (sparse dual path)" begin
    # Exercises the sparse dual-assignment path on an LP (thermal dispatch) so
    # HiGHS returns the dual values directly.
    c_sys5 = _attach_some_branch_outages!(PSB.build_system(PSITestSystems, "c_sys5"))
    template = get_thermal_dispatch_template_network(
        NetworkModel(PTDFNetworkModel),
    )
    set_device_model!(
        template,
        DeviceModel(
            PSY.Line,
            POM.SecurityConstrainedStaticBranch;
            duals = [POM.PostContingencyFlowRateConstraint],
        ),
    )
    set_device_model!(
        template,
        PSY.TwoWindingTransformer,
        POM.SecurityConstrainedStaticBranch,
    )
    set_device_model!(
        template,
        PSY.TwoWindingTransformer,
        POM.SecurityConstrainedStaticBranch,
    )

    ps_model = DecisionModel(template, c_sys5; optimizer = HiGHS_optimizer)
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(ps_model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    _test_post_contingency_line_duals(IOM.get_optimization_container(ps_model))
end

@testset "Duals of post-contingency flow constraints (MILP / unit commitment path)" begin
    # Unit-commitment binaries make this a MILP, so duals go through the
    # relax-integers / re-solve-LP / copy-duals path rather than the direct LP
    # path of the testset above.
    c_sys5 = _attach_some_branch_outages!(PSB.build_system(PSITestSystems, "c_sys5"))
    template =
        PowerOperationsProblemTemplate(
            NetworkModel(PTDFNetworkModel),
        )
    set_device_model!(template, PSY.PowerLoad, StaticPowerLoad)
    set_device_model!(template, PSY.ThermalStandard, ThermalStandardUnitCommitment)
    set_device_model!(
        template,
        DeviceModel(
            PSY.Line,
            POM.SecurityConstrainedStaticBranch;
            duals = [POM.PostContingencyFlowRateConstraint],
        ),
    )
    set_device_model!(
        template,
        PSY.TwoWindingTransformer,
        POM.SecurityConstrainedStaticBranch,
    )
    set_device_model!(
        template,
        PSY.TwoWindingTransformer,
        POM.SecurityConstrainedStaticBranch,
    )

    ps_model = DecisionModel(template, c_sys5; optimizer = HiGHS_optimizer)
    @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test IOM.is_milp(IOM.get_optimization_container(ps_model))
    @test solve!(ps_model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    _test_post_contingency_line_duals(IOM.get_optimization_container(ps_model))
end

# The buses a reduction retained: the representatives, i.e. the keys of its bus
# reduction map.
_sc_retained_buses(nrd) = Set(keys(PNM.get_bus_reduction_map(nrd)))

@testset "SC PTDF and MODF reduce to one bus set" begin
    # Regression: a [Radial, DegreeTwo] reduction plus many monitored components used
    # to be able to reduce the PTDF and the MODF onto different bus sets. Both now wrap
    # one factorization core built from one Ybus, so they cannot diverge and the caller
    # never replicates the irreducible-bus computation.
    sys = PSB.build_system(PSB.PSITestSystems, "test_RTS_GMLC_sys")
    all_lines = collect(get_components(PSY.Line, sys))
    @test length(all_lines) > 1
    monitored = all_lines                       # force many irreducible buses
    for l in first(all_lines, 5)                # several N-1 contingencies
        PSY.add_supplemental_attribute!(
            sys,
            l,
            PSY.GeometricDistributionForcedOutage(;
                mean_time_to_recovery = 10,
                outage_transition_probability = 0.5,
                monitored_components = monitored,
            ),
        )
    end

    nr = NetworkReduction[RadialReduction(), DegreeTwoReduction()]
    template = get_thermal_dispatch_template_network(
        NetworkModel(
            PTDFNetworkModel;
            network_source = SystemNetworkSource(nr),
        ),
    )
    set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)

    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    nm = IOM.get_network_model(IOM.get_template(model))
    ptdf_retained = _sc_retained_buses(
        PNM.get_network_reduction_data(IOM.get_network_matrix(nm)),
    )
    modf_retained = _sc_retained_buses(
        PNM.get_network_reduction_data(IOM.get_contingency_matrix(nm)),
    )
    @test ptdf_retained == modf_retained
    @test _sc_retained_buses(IOM.get_network_reduction(nm)) == modf_retained

    # The container nodal balance must be dimensioned on the same bus set the
    # MODF columns are indexed on (the guard's invariant).
    container = IOM.get_optimization_container(model)
    nodal = IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus)
    @test size(nodal.data, 1) == length(modf_retained)
end

# Ported from PowerSimulations.jl PR #1633 ("sc slacks"): with `use_slacks=true`
# the POST-contingency (N-1) rate constraints must receive relaxation slacks too,
# not just the PRE-contingency flow limits. Asserts both new slack variable
# containers exist, each post-contingency lb/ub constraint references a slack,
# the model solves, and that with `use_slacks=false` neither container exists.
@testset "SecurityConstrainedStaticBranch post-contingency slacks (use_slacks)" begin
    c_sys5 = _attach_some_branch_outages!(PSB.build_system(PSITestSystems, "c_sys5"))

    function _build_sc_slack_model(use_slacks)
        template = get_thermal_dispatch_template_network(
            NetworkModel(PTDFNetworkModel),
        )
        set_device_model!(
            template,
            DeviceModel(
                PSY.Line,
                POM.SecurityConstrainedStaticBranch;
                use_slacks = use_slacks,
            ),
        )
        set_device_model!(
            template, PSY.TwoWindingTransformer, POM.SecurityConstrainedStaticBranch,
        )
        set_device_model!(
            template, PSY.TwoWindingTransformer, POM.SecurityConstrainedStaticBranch,
        )
        ps_model = DecisionModel(template, c_sys5; optimizer = HiGHS_optimizer)
        @test build!(ps_model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        return ps_model
    end

    # use_slacks = true: both post-contingency slack containers must exist, and
    # each lb/ub constraint must reference its slack (nonzero variable coeff).
    slack_model = _build_sc_slack_model(true)
    slack_container = IOM.get_optimization_container(slack_model)

    ub_key =
        IOM.VariableKey(POM.PostContingencyFlowActivePowerSlackUpperBound, PSY.Line)
    lb_key =
        IOM.VariableKey(POM.PostContingencyFlowActivePowerSlackLowerBound, PSY.Line)
    @test IOM.has_container_key(
        slack_container, POM.PostContingencyFlowActivePowerSlackUpperBound, PSY.Line,
    )
    @test IOM.has_container_key(
        slack_container, POM.PostContingencyFlowActivePowerSlackLowerBound, PSY.Line,
    )

    slack_ub = IOM.get_variable(slack_container, ub_key)
    slack_lb = IOM.get_variable(slack_container, lb_key)
    @test !isempty(slack_ub.data)
    @test !isempty(slack_lb.data)

    con_ub = IOM.get_constraint(
        slack_container,
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "ub"),
    )
    con_lb = IOM.get_constraint(
        slack_container,
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, PSY.Line, "lb"),
    )
    # Each post-contingency constraint must contain its corresponding slack with a
    # nonzero coefficient (subtracted on ub, added on lb).
    for k in keys(slack_ub.data)
        @test JuMP.normalized_coefficient(con_ub[k...], slack_ub[k...]) == -1.0
    end
    for k in keys(slack_lb.data)
        @test JuMP.normalized_coefficient(con_lb[k...], slack_lb[k...]) == 1.0
    end

    @test solve!(slack_model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    # use_slacks = false: neither post-contingency slack container exists.
    no_slack_model = _build_sc_slack_model(false)
    no_slack_container = IOM.get_optimization_container(no_slack_model)
    @test !IOM.has_container_key(
        no_slack_container, POM.PostContingencyFlowActivePowerSlackUpperBound, PSY.Line,
    )
    @test !IOM.has_container_key(
        no_slack_container, POM.PostContingencyFlowActivePowerSlackLowerBound, PSY.Line,
    )
end

@testset "post-contingency emergency limits: raw ACTransmission uses rating_b in system pu" begin
    # Pins the numeric behavior of the raw-device emergency-limit method so the
    # delegation refactor to PNM.get_equivalent_emergency_rating stays a no-op on values.
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = first(PSY.get_components(PSY.Line, sys))
    PSY.set_rating_b!(line, 0.9 * u"SU")
    lim = POM._emergency_flow_limits(line)
    rb = PSY.get_rating_b(line, u"SU")
    @test lim.max ≈ rb
    @test lim.min ≈ -rb
end

# Attach a single outage (monitoring every branch) to every branch of the system,
# so every branch is both an outaged and a monitored component.
function _attach_all_branch_outages!(sys)
    all_branches = collect(PSY.get_components(PSY.ACTransmission, sys))
    for branch in all_branches
        outage = PSY.GeometricDistributionForcedOutage(;
            mean_time_to_recovery = 10,
            outage_transition_probability = 0.9999,
            monitored_components = all_branches,
        )
        PSY.add_supplemental_attribute!(sys, branch, outage)
    end
    return sys
end

# Every monitored post-contingency rate constraint references the slack
# variable for its `(outage_id, name, t)`. A constraint without a slack term
# means `use_slacks` was honored only for the pre-contingency flow limits.
function _post_contingency_constraints_have_slack(container, slack_refs)
    has_slack(ref) =
        any(haskey(JuMP.constraint_object(ref).func.terms, v) for v in slack_refs)
    all_have = true
    n = 0
    for meta in ("lb", "ub")
        cons = IOM.get_constraints(container)[IOM.ConstraintKey(
            POM.PostContingencyFlowRateConstraint, PSY.Line, meta,
        )]
        for ref in values(cons.data)
            n += 1
            all_have &= has_slack(ref)
        end
    end
    return n, all_have
end

@testset "Security Constrained branch slacks reach post-contingency flow constraints" begin
    c_sys5 = _attach_all_branch_outages!(PSB.build_system(PSITestSystems, "c_sys5"))

    function _build_sc(use_slacks)
        template = get_thermal_dispatch_template_network(
            NetworkModel(PTDFNetworkModel),
        )
        set_device_model!(
            template,
            DeviceModel(
                PSY.Line,
                POM.SecurityConstrainedStaticBranch;
                use_slacks = use_slacks,
            ),
        )
        set_device_model!(
            template,
            DeviceModel(
                PSY.TwoWindingTransformer,
                POM.SecurityConstrainedStaticBranch;
                use_slacks = use_slacks,
            ),
        )
        set_device_model!(
            template,
            DeviceModel(
                PSY.TwoWindingTransformer,
                POM.SecurityConstrainedStaticBranch;
                use_slacks = use_slacks,
            ),
        )
        model = DecisionModel(template, c_sys5; optimizer = HiGHS_optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        return model
    end

    # use_slacks = true: per-contingency slack variables exist and are wired
    # into every post-contingency rate inequality.
    model = _build_sc(true)
    container = IOM.get_optimization_container(model)
    @test IOM.has_container_key(
        container,
        POM.PostContingencyFlowActivePowerSlackUpperBound,
        PSY.Line,
    )
    @test IOM.has_container_key(
        container,
        POM.PostContingencyFlowActivePowerSlackLowerBound,
        PSY.Line,
    )
    slack_ub =
        IOM.get_variable(
            container,
            POM.PostContingencyFlowActivePowerSlackUpperBound,
            PSY.Line,
        )
    slack_lb =
        IOM.get_variable(
            container,
            POM.PostContingencyFlowActivePowerSlackLowerBound,
            PSY.Line,
        )
    @test !isempty(slack_ub.data)
    @test !isempty(slack_lb.data)
    slack_refs = Set{JuMP.VariableRef}()
    union!(slack_refs, values(slack_ub.data))
    union!(slack_refs, values(slack_lb.data))
    n, all_have = _post_contingency_constraints_have_slack(container, slack_refs)
    @test n > 0
    @test all_have
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    # use_slacks = false: no post-contingency slack variables, hard limits.
    model_hard = _build_sc(false)
    container_hard = IOM.get_optimization_container(model_hard)
    @test !IOM.has_container_key(
        container_hard,
        POM.PostContingencyFlowActivePowerSlackUpperBound,
        PSY.Line,
    )
    @test !IOM.has_container_key(
        container_hard,
        POM.PostContingencyFlowActivePowerSlackLowerBound,
        PSY.Line,
    )
end

# An outage attached to components of more than one branch type makes multiple SC
# DeviceModels claim the same monitored `(outage, name, t)` constraints. The second
# model to build reuses the first's constraint refs; the slack-container aliasing
# registers those slacks under the reusing type too, so `has_container_key` /
# `get_variable` stay consistent regardless of the Dict-ordered build order.
@testset "Multi-type outage post-contingency slacks reach every reusing branch type" begin
    c_sys14 = PSB.build_system(PSITestSystems, "c_sys14")
    all_branches = collect(PSY.get_components(PSY.ACTransmission, c_sys14))
    line = PSY.get_component(PSY.Line, c_sys14, "Line1")
    transformer = first(PSY.get_components(PSY.TwoWindingTransformer, c_sys14))
    # One outage attached to both a Line and a TwoWindingTransformer: a multi-type outage.
    outage = PSY.GeometricDistributionForcedOutage(;
        mean_time_to_recovery = 10,
        outage_transition_probability = 0.9999,
        monitored_components = all_branches,
    )
    PSY.add_supplemental_attribute!(c_sys14, line, outage)
    PSY.add_supplemental_attribute!(c_sys14, transformer, outage)

    template = get_thermal_dispatch_template_network(
        NetworkModel(
            PTDFNetworkModel;
            network_source = PrebuiltMatrixSource(PNM.VirtualPTDF(c_sys14)),
        ),
    )
    set_device_model!(
        template,
        DeviceModel(PSY.Line, POM.SecurityConstrainedStaticBranch; use_slacks = true),
    )
    set_device_model!(
        template,
        DeviceModel(
            PSY.TwoWindingTransformer,
            POM.SecurityConstrainedStaticBranch;
            use_slacks = true,
        ),
    )
    set_device_model!(
        template,
        DeviceModel(
            PSY.TwoWindingTransformer,
            POM.SecurityConstrainedStaticBranch;
            use_slacks = true,
        ),
    )
    model = DecisionModel(template, c_sys14; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    container = IOM.get_optimization_container(model)

    # Both reusing branch types own non-empty slack containers: the second to build
    # aliases the first's refs instead of registering an empty container.
    slack_refs = Set{JuMP.VariableRef}()
    for V in (PSY.Line, PSY.TwoWindingTransformer),
        S in (
            POM.PostContingencyFlowActivePowerSlackUpperBound,
            POM.PostContingencyFlowActivePowerSlackLowerBound,
        )

        @test IOM.has_container_key(container, S, V)
        slacks = IOM.get_variable(container, S, V)
        @test !isempty(slacks.data)
        union!(slack_refs, values(slacks.data))
    end

    # The aliased slacks are shared between the two component-type containers.
    line_ub = IOM.get_variable(
        container,
        POM.PostContingencyFlowActivePowerSlackUpperBound,
        PSY.Line,
    )
    transformer_ub = IOM.get_variable(
        container,
        POM.PostContingencyFlowActivePowerSlackUpperBound,
        PSY.TwoWindingTransformer,
    )
    @test !isempty(intersect(Set(values(line_ub.data)), Set(values(transformer_ub.data))))

    # Every post-contingency rate constraint, including the reused ones stored under
    # the second component type, references a registered slack.
    has_slack(ref) =
        any(haskey(JuMP.constraint_object(ref).func.terms, v) for v in slack_refs)
    n = 0
    all_have = true
    for V in (PSY.Line, PSY.TwoWindingTransformer), meta in ("lb", "ub")
        cons = IOM.get_constraints(container)[IOM.ConstraintKey(
            POM.PostContingencyFlowRateConstraint, V, meta,
        )]
        for ref in values(cons.data)
            n += 1
            all_have &= has_slack(ref)
        end
    end
    @test n > 0
    @test all_have
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

const _PC_RATING_TS_NAME = "pc_branch_rating"
const _PC_RATING_FACTORS = vcat([fill(x, 6) for x in [0.99, 0.98, 1.0, 0.95]]...)

_set_rating_b!(l::PSY.Line, r) = PSY.set_rating_b!(l, r)
_set_rating_b!(t::PSY.TwoWindingTransformer, r) = PSY.set_rating_b!(t.circuit, r)

# `c_sys14` with `rating_b = 1.2 * rating` and a post-contingency rating forecast
# on Line1, Line2, Line6, and Trans1. Every branch monitored. Line1, Line2, Line3 outaged.
function _pc_rating_ts_system()
    sys = PSB.build_system(PSITestSystems, "c_sys14")
    lines_with_ts = ["Line1", "Line2", "Line6", "Trans1"]
    for name in lines_with_ts
        line = PSY.get_component(PSY.ACTransmission, sys, name)
        _set_rating_b!(line, (1.2 * branch_rating_su(line)) * u"SU")
    end
    add_branch_rating_time_series_to_system!(
        sys, lines_with_ts, 2, _PC_RATING_FACTORS;
        initial_date = "2024-01-01", ts_name = _PC_RATING_TS_NAME,
    )
    branches = collect(get_components(PSY.ACTransmission, sys))
    for line_name in ("Line1", "Line2", "Line3")
        PSY.add_supplemental_attribute!(
            sys,
            get_component(PSY.ACTransmission, sys, line_name),
            PSY.GeometricDistributionForcedOutage(;
                mean_time_to_recovery = 10,
                outage_transition_probability = 0.9999,
                monitored_components = branches,
            ),
        )
    end
    return sys, lines_with_ts
end

function _build_pc_rating_ts_model(sys)
    template = get_thermal_dispatch_template_network(
        NetworkModel(
            PTDFNetworkModel;
            network_source = PrebuiltMatrixSource(PNM.VirtualPTDF(sys)),
        ),
    )
    set_device_model!(
        template,
        DeviceModel(
            PSY.Line,
            POM.SecurityConstrainedStaticBranch;
            time_series_names = Dict(
                POM.PostContingencyBranchRatingTimeSeriesParameter =>
                    _PC_RATING_TS_NAME,
            ),
        ),
    )
    set_device_model!(
        template,
        DeviceModel(
            PSY.TwoWindingTransformer,
            POM.StaticBranch;
            time_series_names = Dict(
                POM.PostContingencyBranchRatingTimeSeriesParameter => _PC_RATING_TS_NAME,
            ),
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    status = build!(model; output_dir = mktempdir(; cleanup = true))
    return model, status
end

@testset "post-contingency rate limit follows the post-contingency rating time series" begin
    sys, lines_with_ts = _pc_rating_ts_system()
    model, status = _build_pc_rating_ts_model(sys)
    @test status == IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(model)
    @test IOM.has_container_key(
        container, POM.PostContingencyBranchRatingTimeSeriesParameter, PSY.Line,
    )

    pcbf = IOM.get_expression(container, POM.PostContingencyBranchFlow, PSY.Line)
    con_ub = IOM.get_constraints(container)[IOM.ConstraintKey(
        POM.PostContingencyFlowRateConstraint, PSY.Line, "ub",
    )]
    con_lb = IOM.get_constraints(container)[IOM.ConstraintKey(
        POM.PostContingencyFlowRateConstraint, PSY.Line, "lb",
    )]

    # Non-degeneracy: `rating_b` must differ from `rating` and the forecast must
    # actually vary, else the assertions below could not tell the parameterized
    # RHS apart from the static one.
    for name in lines_with_ts
        line = PSY.get_component(PSY.ACTransmission, sys, name)
        @test branch_rating_b_su(line) > branch_rating_su(line)
    end
    @test length(unique(_PC_RATING_FACTORS)) > 1

    n_factors = length(_PC_RATING_FACTORS)
    n_checked = 0
    seen_rhs = Set{Float64}()
    for (outage_id, name, t) in keys(pcbf.data)
        name in lines_with_ts || continue
        rating_b = branch_rating_b_su(PSY.get_component(PSY.ACTransmission, sys, name))
        expected = rating_b * _PC_RATING_FACTORS[mod1(t, n_factors)]
        push!(seen_rhs, expected)
        # JuMP migrates the expression's affine constant to the RHS; add it back
        # to recover the raw limit.
        expr_const = JuMP.constant(pcbf[outage_id, name, t])
        @test JuMP.normalized_rhs(con_ub[outage_id, name, t]) + expr_const ≈ expected
        @test JuMP.normalized_rhs(con_lb[outage_id, name, t]) + expr_const ≈ -expected
        n_checked += 1
    end
    @test n_checked > 0
    # The RHS tracks the forecast, so it takes more than one distinct value —
    # this is what separates the parameterized limit from the static one.
    @test length(seen_rhs) > 1
end

@testset "a branch without a post-contingency rating forecast keeps the static limit" begin
    sys, lines_with_ts = _pc_rating_ts_system()
    model, status = _build_pc_rating_ts_model(sys)
    @test status == IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(model)
    pcbf = IOM.get_expression(container, POM.PostContingencyBranchFlow, PSY.Line)
    con_ub = IOM.get_constraints(container)[IOM.ConstraintKey(
        POM.PostContingencyFlowRateConstraint, PSY.Line, "ub",
    )]

    n_checked = 0
    for (outage_id, name, t) in keys(pcbf.data)
        name in lines_with_ts && continue
        line = PSY.get_component(PSY.ACTransmission, sys, name)
        isnothing(line) && continue
        expected = POM._emergency_flow_limits(line).max
        expr_const = JuMP.constant(pcbf[outage_id, name, t])
        @test JuMP.normalized_rhs(con_ub[outage_id, name, t]) + expr_const ≈ expected
        n_checked += 1
    end
    @test n_checked > 0
end

@testset "pre-contingency rate limit follows the branch rating time series" begin
    sys = PSB.build_system(PSITestSystems, "c_sys14")
    lines_with_ts = ["Line1", "Line2", "Line6"]
    add_branch_rating_time_series_to_system!(
        sys, lines_with_ts, 2, _PC_RATING_FACTORS;
        initial_date = "2024-01-01", ts_name = "branch_rating",
    )
    branches = collect(get_components(PSY.ACTransmission, sys))
    PSY.add_supplemental_attribute!(
        sys,
        get_component(PSY.ACTransmission, sys, "Line3"),
        PSY.GeometricDistributionForcedOutage(;
            mean_time_to_recovery = 10,
            outage_transition_probability = 0.9999,
            monitored_components = branches,
        ),
    )
    template = get_thermal_dispatch_template_network(
        NetworkModel(
            PTDFNetworkModel;
            network_source = PrebuiltMatrixSource(PNM.VirtualPTDF(sys)),
        ),
    )
    set_device_model!(
        template,
        DeviceModel(
            PSY.Line,
            POM.SecurityConstrainedStaticBranch;
            time_series_names = Dict(
                POM.BranchRatingTimeSeriesParameter => "branch_rating",
            ),
        ),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(model)
    flow = IOM.get_expression(container, POM.PTDFBranchFlow, PSY.Line)
    con_ub = IOM.get_constraints(container)[IOM.ConstraintKey(
        POM.FlowRateConstraint, PSY.Line, "ub",
    )]
    n_factors = length(_PC_RATING_FACTORS)
    n_ts = 0
    n_static = 0
    for line in get_components(PSY.Line, sys), t in axes(con_ub, 2)
        name = PSY.get_name(line)
        rating = branch_rating_su(line)
        expected =
            name in lines_with_ts ?
            rating * _PC_RATING_FACTORS[mod1(t, n_factors)] : rating
        # JuMP migrates the expression's affine constant to the RHS; add it back.
        expr_const = JuMP.constant(flow[name, t])
        @test JuMP.normalized_rhs(con_ub[name, t]) + expr_const ≈ expected
        name in lines_with_ts ? (n_ts += 1) : (n_static += 1)
    end
    @test n_ts > 0 && n_static > 0
end

@testset "a monitored branch keeps its rating forecast when another type carries the outage" begin
    # An outage is assigned to a security-constrained `DeviceModel` by the type of the
    # component it is *attached* to, not by the types it monitors. With the outage on a
    # transformer and only `Line`s monitored, the `Line` model's outage set is empty, so
    # its post-contingency rating parameter has to be built from the full device list --
    # the transformer model reads it cross-type when it builds the rate limits.
    sys = PSB.build_system(PSITestSystems, "c_sys14")
    branches_with_ts = ["Line1", "Line2"]
    for name in branches_with_ts
        branch = PSY.get_component(PSY.ACTransmission, sys, name)
        _set_rating_b!(branch, (1.2 * branch_rating_su(branch)) * u"SU")
    end
    add_branch_rating_time_series_to_system!(
        sys, branches_with_ts, 2, _PC_RATING_FACTORS;
        initial_date = "2024-01-01", ts_name = _PC_RATING_TS_NAME,
    )
    PSY.add_supplemental_attribute!(
        sys,
        get_component(PSY.ACTransmission, sys, "Trans1"),
        PSY.GeometricDistributionForcedOutage(;
            mean_time_to_recovery = 10,
            outage_transition_probability = 0.9999,
            monitored_components = [
                PSY.get_component(PSY.ACTransmission, sys, n) for n in branches_with_ts
            ],
        ),
    )

    template = get_thermal_dispatch_template_network(
        NetworkModel(
            PTDFNetworkModel;
            network_source = PrebuiltMatrixSource(PNM.VirtualPTDF(sys)),
        ),
    )
    for T in (PSY.Line, PSY.TwoWindingTransformer)
        set_device_model!(
            template,
            DeviceModel(
                T,
                POM.SecurityConstrainedStaticBranch;
                time_series_names = Dict(
                    POM.PostContingencyBranchRatingTimeSeriesParameter =>
                        _PC_RATING_TS_NAME,
                ),
            ),
        )
    end
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(model)
    branch_models = get_branch_models(get_template(model))
    @test isempty(IOM.get_outages(branch_models[:Line]))
    @test !isempty(IOM.get_outages(branch_models[:TwoWindingTransformer]))
    @test IOM.has_container_key(
        container, POM.PostContingencyBranchRatingTimeSeriesParameter, PSY.Line,
    )

    pcbf = IOM.get_expression(
        container, POM.PostContingencyBranchFlow, PSY.TwoWindingTransformer,
    )
    con_ub = IOM.get_constraints(container)[IOM.ConstraintKey(
        POM.PostContingencyFlowRateConstraint, PSY.TwoWindingTransformer, "ub",
    )]

    n_checked = 0
    for (outage_id, name, t) in keys(pcbf.data)
        name in branches_with_ts || continue
        branch = PSY.get_component(PSY.ACTransmission, sys, name)
        expected = branch_rating_b_su(branch) * _PC_RATING_FACTORS[t]
        expr_const = JuMP.constant(pcbf[outage_id, name, t])
        @test JuMP.normalized_rhs(con_ub[outage_id, name, t]) + expr_const ≈ expected
        # The forecast has to actually move the limit off the static value.
        @test !isapprox(expected, branch_rating_b_su(branch); atol = 1e-8) ||
              _PC_RATING_FACTORS[t] == 1.0
        n_checked += 1
    end
    @test n_checked > 0
end

@testset "Unavailable monitored components are dropped, not fatal" begin
    # An unavailable branch is absent from the branch catalog, so a monitored
    # reference to one cannot resolve to a representative arc. Discovery skips it
    # and reports once rather than failing the build.
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    all_branches = collect(get_components(PSY.ACTransmission, sys))
    outage = PSY.GeometricDistributionForcedOutage(;
        mean_time_to_recovery = 10,
        outage_transition_probability = 0.9999,
        monitored_components = all_branches,
    )
    PSY.add_supplemental_attribute!(
        sys,
        get_component(PSY.ACTransmission, sys, "1"),
        outage,
    )
    outage_id = IS.get_id(outage)

    de_energized = get_component(PSY.ACTransmission, sys, "6")
    PSY.set_available!(de_energized, false)

    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT

    # The unavailable branch is dropped; the available ones survive.
    device_model = get_branch_models(get_template(model))[:Line]
    monitored = get_outages(device_model)[outage_id][PSY.Line]
    @test !("6" in monitored)
    @test "1" in monitored

    # Discovery runs inside `build!`'s `with_logger`, so the warning lands in the
    # build log rather than at the call site.
    log = read(joinpath(output_dir, "operation_problem.log"), String)
    @test occursin("1 monitored component(s) across 1 outage(s) are unavailable", log)
    @test occursin("$(outage_id) => 1", log)
end

# Emergency ratings (system base) of line "1" and of its parallel copy "1_copy" in c_sys5.
const _N1_LINE_RATING_B = 0.6
const _N1_COPY_RATING_B = 0.4

# c_sys5 with line "1" doubled into a parallel pair. Four outages monitor the pair. They trip
# "1", "1_copy", line "2", and both members of the pair ("1+1_copy").
function _n1_parallel_system()
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(PSY.Line, sys, "1")
    add_equivalent_ac_transmission_with_parallel_circuits!(sys, line, PSY.Line)
    copy_line = PSY.get_component(PSY.Line, sys, "1_copy")
    _set_rating_b!(line, _N1_LINE_RATING_B * u"SU")
    _set_rating_b!(copy_line, _N1_COPY_RATING_B * u"SU")
    outages = Dict{String, PSY.FixedForcedOutage}()
    for names in (("1",), ("1_copy",), ("2",), ("1", "1_copy"))
        outage = PSY.FixedForcedOutage(;
            outage_status = 1.0,
            monitored_components = [line, copy_line],
        )
        for name in names
            PSY.add_supplemental_attribute!(
                sys,
                PSY.get_component(PSY.Line, sys, name),
                outage,
            )
        end
        outages[join(names, "+")] = outage
    end
    return sys, outages
end

# Build the model and return its container and the reduction entry that represents line "1".
function _build_sc_container(template, sys)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    catalog = POM.get_branch_catalog(IOM.get_network_model(IOM.get_template(model)))
    pair = PNM.get_component_to_reduction_name_map(catalog)[PSY.Line]["1"]
    return IOM.get_optimization_container(model), pair
end

# Raw post-contingency upper limit of `name` under `outage` at `t` in the `V` container.
# JuMP moves the affine constant of the flow expression to the RHS; add it back.
function _pc_upper_limit(container, ::Type{V}, outage, name, t) where {V}
    key = (string(IS.get_id(outage)), name, t)
    flow = IOM.get_expression(container, POM.PostContingencyBranchFlow, V)
    con_ub = IOM.get_constraint(
        container,
        IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, V, "ub"),
    )
    return JuMP.normalized_rhs(con_ub[key...]) + JuMP.constant(flow[key...])
end

# Limits of the pair under each outage of `_n1_parallel_system`, times the rating factor of
# the time step. A full trip keeps the intact limit because the MODF row is zero.
function _test_pair_limits(container, outages, pair, factors::Vector{Float64})
    intact = _N1_LINE_RATING_B + _N1_COPY_RATING_B
    for t in IOM.get_time_steps(container)
        f = factors[mod1(t, length(factors))]
        @test _pc_upper_limit(container, PSY.Line, outages["1"], pair, t) ≈
              f * _N1_COPY_RATING_B
        @test _pc_upper_limit(container, PSY.Line, outages["1_copy"], pair, t) ≈
              f * _N1_LINE_RATING_B
        @test _pc_upper_limit(container, PSY.Line, outages["2"], pair, t) ≈ f * intact
        @test _pc_upper_limit(container, PSY.Line, outages["1+1_copy"], pair, t) ≈
              f * intact
    end
    return
end

@testset "post-contingency limit of a parallel pair counts only the circuits in service" begin
    for network_model in (NetworkModel(PTDFNetworkModel), NetworkModel(DCPNetworkModel))
        sys, outages = _n1_parallel_system()
        template = get_thermal_dispatch_template_network(network_model)
        set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
        container, pair = _build_sc_container(template, sys)
        _test_pair_limits(container, outages, pair, [1.0])
    end
end

@testset "post-contingency limit of a mixed parallel pair counts only the circuit in service" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    line = PSY.get_component(PSY.Line, sys, "1")
    add_equivalent_ac_transmission_with_parallel_circuits!(
        sys,
        line,
        PSY.Line,
        PSY.TwoWindingTransformer,
    )
    transformer = PSY.get_component(PSY.TwoWindingTransformer, sys, "1_copy")
    _set_rating_b!(line, _N1_LINE_RATING_B * u"SU")
    _set_rating_b!(transformer, _N1_COPY_RATING_B * u"SU")
    outage = PSY.FixedForcedOutage(;
        outage_status = 1.0,
        monitored_components = [line, transformer],
    )
    PSY.add_supplemental_attribute!(sys, transformer, outage)
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, PSY.Line, POM.SecurityConstrainedStaticBranch)
    set_device_model!(
        template,
        PSY.TwoWindingTransformer,
        POM.SecurityConstrainedStaticBranch,
    )
    container, pair = _build_sc_container(template, sys)
    outage_id = string(IS.get_id(outage))
    n_checked = 0
    for V in (PSY.Line, PSY.TwoWindingTransformer)
        con_ub = IOM.get_constraint(
            container,
            IOM.ConstraintKey(POM.PostContingencyFlowRateConstraint, V, "ub"),
        )
        for t in IOM.get_time_steps(container)
            if !haskey(con_ub.data, (outage_id, pair, t))
                continue
            end
            @test _pc_upper_limit(container, V, outage, pair, t) ≈ _N1_LINE_RATING_B
            n_checked += 1
        end
    end
    @test n_checked > 0
end

@testset "post-contingency rating series of a parallel pair scales to the circuits in service" begin
    sys, outages = _n1_parallel_system()
    add_branch_rating_time_series_to_system!(
        sys, ["1"], 2, _PC_RATING_FACTORS;
        initial_date = "2024-01-01", ts_name = _PC_RATING_TS_NAME,
    )
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(
        template,
        DeviceModel(
            PSY.Line,
            POM.SecurityConstrainedStaticBranch;
            time_series_names = Dict(
                POM.PostContingencyBranchRatingTimeSeriesParameter => _PC_RATING_TS_NAME,
            ),
        ),
    )
    container, pair = _build_sc_container(template, sys)
    _test_pair_limits(container, outages, pair, _PC_RATING_FACTORS)
end

@testset "Post-contingency slacks are priced through the post_contingency_slack_cost attribute" begin
    default_cost = POM.CONSTRAINT_VIOLATION_SLACK_COST

    function slack_costs(attributes)
        c_sys5 = _attach_some_branch_outages!(PSB.build_system(PSITestSystems, "c_sys5"))
        template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
        set_device_model!(
            template,
            DeviceModel(
                PSY.Line,
                POM.SecurityConstrainedStaticBranch;
                use_slacks = true,
                attributes,
            ),
        )
        set_device_model!(
            template, PSY.TwoWindingTransformer, POM.SecurityConstrainedStaticBranch,
        )
        model = DecisionModel(template, c_sys5; optimizer = HiGHS_optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        invariant = IOM.get_invariant_terms(IOM.get_objective_expression(container))
        costs = Dict{String, Set{Float64}}()
        for S in (
            POM.PostContingencyFlowActivePowerSlackUpperBound,
            POM.PostContingencyFlowActivePowerSlackLowerBound,
        )
            slack = IOM.get_variable(container, S, PSY.Line)
            for (k, v) in slack.data
                push!(get!(costs, k[2], Set{Float64}()), JuMP.coefficient(invariant, v))
            end
        end
        return costs
    end

    costs = slack_costs(Dict{String, Any}())
    @test !isempty(costs)
    @test all(c == Set([default_cost]) for c in values(costs))

    priced = first(sort!(collect(keys(costs))))
    costs = slack_costs(
        Dict{String, Any}(
            "post_contingency_slack_cost" =>
                Dict(priced => 123.0, "no_such_line" => 5.0),
        ),
    )
    @test costs[priced] == Set([123.0])
    @test all(c == Set([default_cost]) for (n, c) in costs if n != priced)

    costs = slack_costs(Dict{String, Any}("post_contingency_slack_cost" => 7.0))
    @test all(c == Set([7.0]) for c in values(costs))
end
