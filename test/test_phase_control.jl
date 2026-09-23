######################################## helpers #######################################

# The active-flow object the ACTIVE_POWER_FLOW band is written against, one per
# network x formulation pair — the test-side mirror of `POM._flow_array`.
_phase_flows(container, ::Type{StaticBranch}, ::Type{DCPNetworkModel}, device_type) =
    IOM.get_expression(container, BThetaBranchFlow, device_type)
_phase_flows(
    container,
    ::Type{StaticBranch},
    ::Type{<:AbstractPTDFNetworkModel},
    device_type,
) = IOM.get_expression(container, PTDFBranchFlow, device_type)
_phase_flows(
    container,
    ::Type{<:Union{StaticBranch, StaticBranchBounds}},
    ::Type{DCPLLNetworkModel},
    device_type,
) = IOM.get_variable(container, FlowActivePowerFromToVariable, device_type)
_phase_flows(
    container,
    ::Type{StaticBranchBounds},
    ::Type{<:Union{DCPNetworkModel, AbstractPTDFNetworkModel}},
    device_type,
) = IOM.get_variable(container, FlowActivePowerVariable, device_type)

_has_phase_variable(container) = any(
    k -> occursin("PhaseShifterAngle", string(k)),
    keys(IOM.get_variables(container)),
)

_has_phase_constraints(container) = any(
    k -> occursin("ActivePowerFlowControlConstraint", string(k)),
    keys(IOM.get_constraints(container)),
)

function _phase_constraints(container, device_type)
    key = IOM.ConstraintKey(ActivePowerFlowControlConstraint, device_type)
    haskey(IOM.get_constraints(container), key) || return nothing
    return IOM.get_constraint(container, key)
end

# Free (uncontrolled) value of the circuit flow, the reference the efficacy bands are cut
# from — without it a band that happens to contain the free solution would prove nothing.
function _free_flow(network_formulation, branch_formulation, axis_name)
    sys = PSB.build_system(PSITestSystems, "c_sys14")
    model, status = _build_controlled(
        sys, network_formulation, PSY.TwoWindingTransformer;
        enable = false, optimizer = ipopt_optimizer, formulation = branch_formulation,
    )
    @test status == IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    container = IOM.get_optimization_container(model)
    flows = _phase_flows(
        container, branch_formulation, network_formulation, PSY.TwoWindingTransformer,
    )
    return JuMP.value(flows[axis_name, first(get_time_steps(container))])
end

_meshed_fixture(; kwargs...) =
    _controlled_sys14(P_FLOW_CONTROL; circuit_index = MESHED_TRANSFORMER_INDEX, kwargs...)

################################### attribute plumbing #################################

@testset "a phase-controlled circuit builds nothing while enable_controls is off" begin
    for network_formulation in PHASE_NETWORKS,
        branch_formulation in CONTROL_FORMULATIONS

        fixture = _meshed_fixture()
        model, status = _build_controlled(
            fixture.sys, network_formulation, PSY.TwoWindingTransformer;
            enable = false, optimizer = ipopt_optimizer,
            formulation = branch_formulation,
        )
        @test status == IOM.ModelBuildStatus.BUILT

        container = IOM.get_optimization_container(model)
        @test !_has_phase_variable(container)
        @test !_has_phase_constraints(container)
    end
end

@testset "PhaseShifterAngle and its constraint are created only for controlled circuits" begin
    band = (min = -0.25, max = 0.2)
    for network_formulation in PHASE_NETWORKS,
        branch_formulation in CONTROL_FORMULATIONS

        # Deliberately not circuit 1: the untouched circuits are left UNDEFINED, so only
        # the controlled one may appear on the axis.
        fixture = _controlled_sys14(
            P_FLOW_CONTROL;
            circuit_index = length(TRANSFORMER_NAMES),
            control_limits = band,
        )
        model, status = _build_controlled(
            fixture.sys, network_formulation, PSY.TwoWindingTransformer;
            optimizer = ipopt_optimizer, formulation = branch_formulation,
        )
        @test status == IOM.ModelBuildStatus.BUILT

        container = IOM.get_optimization_container(model)
        alpha =
            IOM.get_variable(container, PhaseShifterAngle, PSY.TwoWindingTransformer)
        @test axes(alpha)[1] == [fixture.axis_name]

        for t in get_time_steps(container)
            var = alpha[fixture.axis_name, t]
            @test JuMP.has_lower_bound(var)
            @test JuMP.has_upper_bound(var)
            @test JuMP.lower_bound(var) ≈ band.min
            @test JuMP.upper_bound(var) ≈ band.max
            @test JuMP.start_value(var) ≈ 0.0
        end

        cons = _phase_constraints(container, PSY.TwoWindingTransformer)
        @test cons !== nothing
        if cons !== nothing
            @test axes(cons)[1] == [fixture.axis_name]
            @test size(cons) == (1, 2, length(get_time_steps(container)))
            @test all(isassigned(cons.data, i) for i in eachindex(cons.data))
        end
    end
end

@testset "a three-winding circuit carries the phase variable and constraint too" begin
    for branch_formulation in CONTROL_FORMULATIONS, index in 1:3
        fixture = _controlled_sys3w(P_FLOW_CONTROL; circuit_index = index)
        model, status = _build_controlled(
            fixture.sys, DCPNetworkModel, PSY.ThreeWindingTransformer;
            optimizer = ipopt_optimizer, formulation = branch_formulation,
        )
        @test status == IOM.ModelBuildStatus.BUILT

        container = IOM.get_optimization_container(model)
        alpha =
            IOM.get_variable(container, PhaseShifterAngle, PSY.ThreeWindingTransformer)
        @test axes(alpha)[1] == [fixture.axis_name]

        cons = _phase_constraints(container, PSY.ThreeWindingTransformer)
        @test cons !== nothing
        cons === nothing || @test axes(cons)[1] == [fixture.axis_name]
    end
end

@testset "a phase control scheme builds nothing on an AC or NFA network" begin
    for network_formulation in (AC_NETWORKS..., NFANetworkModel),
        branch_formulation in CONTROL_FORMULATIONS

        fixture = _meshed_fixture()
        output_dir = mktempdir(; cleanup = true)
        model, status = _build_controlled(
            fixture.sys, network_formulation, PSY.TwoWindingTransformer;
            optimizer = ipopt_optimizer, output_dir = output_dir,
            formulation = branch_formulation,
        )
        @test status == IOM.ModelBuildStatus.BUILT

        container = IOM.get_optimization_container(model)
        @test !_has_phase_variable(container)
        @test !_has_phase_constraints(container)

        # Build warnings go to the build's own log, not to the caller's logger.
        log = read(joinpath(output_dir, "operation_problem.log"), String)
        @test occursin("phase control is not supported on", log)
    end
end

################################### model invariants ###################################

@testset "an angle pinned at the stored shift reproduces the uncontrolled model" begin
    # The sign test. PNM's convention is `f = b·(θ_f − θ_t − α)`; under the opposite sign
    # (legacy PSI's `+α`) a non-zero stored shift would give a different solution here.
    for network_formulation in PHASE_NETWORKS,
        branch_formulation in CONTROL_FORMULATIONS,
        stored in (0.0, 0.12)

        fixed = _meshed_fixture(; alpha = stored)
        model_fixed, status_fixed = _build_controlled(
            fixed.sys, network_formulation, PSY.TwoWindingTransformer;
            enable = false, optimizer = ipopt_optimizer,
            formulation = branch_formulation,
        )
        @test status_fixed == IOM.ModelBuildStatus.BUILT
        @test solve!(model_fixed) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

        varying = _meshed_fixture(; alpha = stored)
        model_var, status_var = _build_controlled(
            varying.sys, network_formulation, PSY.TwoWindingTransformer;
            optimizer = ipopt_optimizer, formulation = branch_formulation,
        )
        @test status_var == IOM.ModelBuildStatus.BUILT

        container = IOM.get_optimization_container(model_var)
        alpha =
            IOM.get_variable(container, PhaseShifterAngle, PSY.TwoWindingTransformer)
        for t in get_time_steps(container)
            JuMP.fix(alpha[varying.axis_name, t], stored; force = true)
        end
        @test solve!(model_var) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

        res_fixed = IOM.OptimizationProblemOutputs(model_fixed)
        res_var = IOM.OptimizationProblemOutputs(model_var)
        @test isapprox(
            IOM.get_objective_value(res_var),
            IOM.get_objective_value(res_fixed);
            rtol = 1e-4,
        )

        flows_fixed = _phase_flows(
            IOM.get_optimization_container(model_fixed),
            branch_formulation,
            network_formulation,
            PSY.TwoWindingTransformer,
        )
        flows_var = _phase_flows(
            container, branch_formulation, network_formulation,
            PSY.TwoWindingTransformer,
        )
        for name in axes(flows_var)[1], t in get_time_steps(container)
            @test isapprox(
                JuMP.value(flows_var[name, t]),
                JuMP.value(flows_fixed[name, t]);
                atol = 1e-4,
            )
        end
    end
end

@testset "ACTIVE_POWER_FLOW control holds the circuit flow inside its limits" begin
    axis_name = TRANSFORMER_NAMES[MESHED_TRANSFORMER_INDEX]
    for network_formulation in PHASE_NETWORKS,
        branch_formulation in CONTROL_FORMULATIONS

        free = _free_flow(network_formulation, branch_formulation, axis_name)
        # Strictly inside the free solution, so the band can only be met by moving α.
        band = (min = free - 0.10, max = free - 0.05)

        fixture = _meshed_fixture(; quantity_limits = band)
        model, status = _build_controlled(
            fixture.sys, network_formulation, PSY.TwoWindingTransformer;
            optimizer = ipopt_optimizer, formulation = branch_formulation,
        )
        @test status == IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

        container = IOM.get_optimization_container(model)
        flows = _phase_flows(
            container, branch_formulation, network_formulation,
            PSY.TwoWindingTransformer,
        )
        for t in get_time_steps(container)
            value = JuMP.value(flows[axis_name, t])
            @test value >= band.min - 1e-5
            @test value <= band.max + 1e-5
        end
    end
end

@testset "DCP and PTDF agree on every flow at the same phase angle" begin
    # Independent of the DCP angle path: pins the PTDF nodal-injection pair (`±b·α`) and
    # the `-b·α` flow offset against the B-theta Ohm's law.
    for branch_formulation in CONTROL_FORMULATIONS, pinned in (0.0, 0.12, -0.2)
        flows_by_network = Dict{DataType, Dict{String, Float64}}()
        for network_formulation in (DCPNetworkModel, PTDFNetworkModel)
            fixture = _meshed_fixture()
            model, status = _build_controlled(
                fixture.sys, network_formulation, PSY.TwoWindingTransformer;
                optimizer = ipopt_optimizer, formulation = branch_formulation,
            )
            @test status == IOM.ModelBuildStatus.BUILT

            container = IOM.get_optimization_container(model)
            alpha =
                IOM.get_variable(container, PhaseShifterAngle, PSY.TwoWindingTransformer)
            for t in get_time_steps(container)
                JuMP.fix(alpha[fixture.axis_name, t], pinned; force = true)
            end
            @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

            flows = _phase_flows(
                container, branch_formulation, network_formulation,
                PSY.TwoWindingTransformer,
            )
            t1 = first(get_time_steps(container))
            flows_by_network[network_formulation] =
                Dict(name => JuMP.value(flows[name, t1]) for name in axes(flows)[1])
        end
        for (name, value) in flows_by_network[DCPNetworkModel]
            @test isapprox(value, flows_by_network[PTDFNetworkModel][name]; atol = 1e-5)
        end
    end
end

################################ static phase shift ####################################

@testset "a non-zero static phase shift agrees with a PowerFlows DC solve (c_sys14)" begin
    # Guards `_dc_shift`'s sign against an independent DC solve. Static only: a variable α
    # is not pushed to the power-flow evaluator.
    for branch_formulation in CONTROL_FORMULATIONS
        sys = PSB.build_system(PSITestSystems, "c_sys14")
        transformer =
            PSY.get_component(PSY.TwoWindingTransformer, sys, "Trans1")
        PSY.set_α!(PSY.get_circuit(transformer), 0.15)

        template = get_thermal_dispatch_template_network(
            NetworkModel(
                DCPNetworkModel;
                evaluations = power_flow_evaluations(DCPowerFlow()),
            ),
        )
        set_device_model!(template, PSY.TwoWindingTransformer, branch_formulation)
        # Ipopt rather than HiGHS: HiGHS errors out on this QP (issue #230).
        model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

        container = IOM.get_optimization_container(model)
        flows = _phase_flows(
            container, branch_formulation, DCPNetworkModel, PSY.TwoWindingTransformer,
        )
        pf_flows = lookup_value(
            container,
            AuxVarKey(POM.PowerFlowBranchActivePowerFromTo, PSY.TwoWindingTransformer),
        )
        for name in axes(flows)[1], t in get_time_steps(container)
            @test isapprox(JuMP.value(flows[name, t]), pf_flows[name, t]; atol = 1e-6)
        end
    end
end

################################## network reduction ###################################

@testset "a phase-controlled circuit and its arc survive a network reduction" begin
    for index in 1:length(TRANSFORMER_NAMES)
        fixture = _controlled_sys14(P_FLOW_CONTROL; circuit_index = index)
        model, status = _build_controlled(
            fixture.sys, DCPNetworkModel, PSY.TwoWindingTransformer;
            optimizer = ipopt_optimizer,
            network_source = SystemNetworkSource([
                PNM.RadialReduction(),
                PNM.DegreeTwoReduction(),
            ]),
        )
        @test status == IOM.ModelBuildStatus.BUILT

        container = IOM.get_optimization_container(model)
        alpha =
            IOM.get_variable(container, PhaseShifterAngle, PSY.TwoWindingTransformer)
        @test axes(alpha)[1] == [fixture.axis_name]
    end
end

@testset "a phase-controlled circuit merged with a parallel branch fails with a clear error" begin
    # Pinning the endpoint buses keeps the circuit off the radial/degree-two paths, but a
    # parallel branch on the same arc is merged regardless, which would silently drop the
    # control.
    fixture = _meshed_fixture()
    circuit = fixture.circuit
    PSY.add_component!(
        fixture.sys,
        PSY.TwoWindingTransformer(;
            name = "parallel_to_$(fixture.axis_name)",
            circuit = PSY.TransformerCircuit(;
                available = true,
                arc = PSY.get_arc(circuit),
                r = PSY.get_r(circuit, PSY.SU),
                x = PSY.get_x(circuit, PSY.SU),
                tap = 1.0,
                α = 0.0,
                rating = PSY.get_rating(circuit, PSY.SU),
                base_power = PSY.get_base_power(fixture.sys, PSY.NU),
                input_basis = CU,
            ),
            magnetizing_shunt = 0.0 + 0.0im,
            shunt_location = PSY.TwoWindingTransformerShuntLocation.PRIMARY,
            input_basis = CU,
        ),
    )
    template = _controlled_template(DCPNetworkModel, PSY.TwoWindingTransformer)
    model = DecisionModel(template, fixture.sys; optimizer = ipopt_optimizer)
    out = mktempdir(; cleanup = true)
    @test build!(model; output_dir = out, console_level = Logging.Error) ==
          IOM.ModelBuildStatus.FAILED
    log = read(joinpath(out, "operation_problem.log"), String)
    @test occursin("Controlled transformer circuit", log)
    @test occursin(fixture.axis_name, log)
end

############################ phase shift under N-1 (MODF) ##############################

const _PST_NAME = TRANSFORMER_NAMES[MESHED_TRANSFORMER_INDEX]

# `c_sys14` with `Trans1` set up as a phase shifter and a forced outage attached to
# `outage_on`. `control` toggles the ACTIVE_POWER_FLOW objective, `alpha` the stored static
# shift, and `monitor_transformer` whether `Trans1` is in the outage's monitored set.
function _sc_phase_system(;
    control::Bool = true,
    alpha = nothing,
    monitor_transformer::Bool = true,
    outage_on::String = "Line1",
)
    sys = if control
        _meshed_fixture(; alpha = alpha).sys
    else
        s = PSB.build_system(PSITestSystems, "c_sys14")
        isnothing(alpha) || PSY.set_α!(
            PSY.get_circuit(
                PSY.get_component(PSY.TwoWindingTransformer, s, _PST_NAME),
            ),
            alpha,
        )
        s
    end
    transformer = PSY.get_component(PSY.TwoWindingTransformer, sys, _PST_NAME)

    monitored = PSY.ACTransmission[get_components(PSY.Line, sys)...]
    monitor_transformer && push!(monitored, transformer)
    outage = PSY.GeometricDistributionForcedOutage(;
        mean_time_to_recovery = 10,
        outage_transition_probability = 0.9999,
        monitored_components = monitored,
    )
    PSY.add_supplemental_attribute!(
        sys,
        PSY.get_component(PSY.ACTransmission, sys, outage_on),
        outage,
    )
    return sys, transformer, IS.get_id(outage)
end

function _sc_phase_model(
    network_formulation,
    sys;
    transformer_formulation = StaticBranch,
    enable::Bool = true,
)
    template = get_thermal_dispatch_template_network(NetworkModel(network_formulation))
    set_device_model!(template, DeviceModel(PSY.Line, POM.SecurityConstrainedStaticBranch))
    set_device_model!(
        template,
        DeviceModel(
            PSY.TwoWindingTransformer,
            transformer_formulation;
            attributes = Dict(POM.ENABLE_CONTROLS_KEY => enable),
        ),
    )
    return DecisionModel(template, sys; optimizer = HiGHS_optimizer)
end

# Two independent factorizations of the same ABA matrix differ by ~1e-15 on the Accelerate
# backend, so compare the affine expressions up to that round-off. See the note in
# `test_ac_transmission_security_constrained_models.jl`.
function _phase_affexpr_approx_equal(actual, expected; atol = 1e-8)
    d = actual - expected
    coeff_resid = maximum((abs(c) for (c, _) in JuMP.linear_terms(d)); init = 0.0)
    return coeff_resid <= atol && abs(JuMP.constant(d)) <= atol
end

@testset "N-1 on a DCP network rejects any transformer phase shift" begin
    # The DCP post-contingency flow is `MODF * injections`, and the injections are recovered
    # from the branch-flow variables of the nodal balance, which carry no phase-shift term
    # (on DCP the shift lives in the Ohm's law constraint instead). Either shift source
    # would leave the N-1 rows silently wrong. `build!` swallows the throw into a FAILED
    # status, so assert against `validate_template` directly.
    for (control, alpha, enable) in ((true, nothing, true), (false, 0.05, false))
        sys, _, _ = _sc_phase_system(; control = control, alpha = alpha)
        model = _sc_phase_model(DCPNetworkModel, sys; enable = enable)
        @test_throws IS.ConflictingInputsError POM.validate_template(model)
    end
end

@testset "N-1 on a DCP network accepts a transformer with no effective phase shift" begin
    # A control objective with `enable_controls` off builds no PhaseShifterAngle, and α = 0
    # contributes no constant shift, so neither case may be rejected.
    for control in (true, false)
        sys, _, _ = _sc_phase_system(; control = control)
        model = _sc_phase_model(DCPNetworkModel, sys; enable = false)
        @test isnothing(POM.validate_template(model))
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
    end
end

@testset "N-1 on a PTDF network accepts a phase-controlled transformer" begin
    # `AbstractPTDFNetworkModel <: AbstractDCPNetworkModel`, so a rejection dispatched on
    # the abstract network type would swallow PTDF too. PTDF folds the shift into the nodal
    # balance and must keep building.
    sys, _, _ = _sc_phase_system(; control = true)
    model = _sc_phase_model(PTDFNetworkModel, sys; enable = true)
    @test isnothing(POM.validate_template(model))
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
end

@testset "a phase shifter may be the outaged element on a PTDF network" begin
    # The MODF handles the tripped shifter's susceptance; its `±b·α` injection pair is
    # removed from the post-contingency rows by the outage shift adjustments.
    function _outaged_transformer_model(; control::Bool, alpha = nothing)
        sys, transformer, _ = _sc_phase_system(;
            control = control,
            alpha = alpha,
            monitor_transformer = false,
        )
        PSY.add_supplemental_attribute!(
            sys,
            transformer,
            PSY.GeometricDistributionForcedOutage(;
                mean_time_to_recovery = 10,
                outage_transition_probability = 0.9999,
                monitored_components = collect(get_components(PSY.Line, sys)),
            ),
        )
        return _sc_phase_model(
            PTDFNetworkModel,
            sys;
            transformer_formulation = POM.SecurityConstrainedStaticBranch,
            enable = control,
        )
    end

    for (control, alpha) in ((true, nothing), (false, 0.05), (false, nothing))
        model = _outaged_transformer_model(; control = control, alpha = alpha)
        @test isnothing(POM.validate_template(model))
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
    end
end

@testset "PhaseShifterAngle reaches the N-1 PTDF post-contingency flows" begin
    # Ground truth is rebuilt from an independent VirtualMODF. Every post-contingency row
    # must equal `dot(modf_col, nodal_balance[:, t])`, MINUS the branch's own `b·α` when the
    # monitored branch IS the shifter. The PTDF nodal balance already carries the shifter's
    # `±b·α` injection pair, so the first term alone accounts for the angle on every other
    # monitored branch — which is exactly the "shifter is not monitored" case.
    for monitor_transformer in (true, false)
        sys, transformer, outage_id =
            _sc_phase_system(; monitor_transformer = monitor_transformer)
        model = _sc_phase_model(PTDFNetworkModel, sys; enable = true)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT

        container = IOM.get_optimization_container(model)
        network_model = IOM.get_network_model(IOM.get_template(model))

        # The control variable is owned by the transformer model, while the
        # post-contingency rows are built by the Line security-constrained model.
        @test IOM.has_container_key(
            container,
            PhaseShifterAngle,
            PSY.TwoWindingTransformer,
        )
        alpha = IOM.get_variable(container, PhaseShifterAngle, PSY.TwoWindingTransformer)
        @test axes(alpha)[1] == [_PST_NAME]

        pcbf = IOM.get_expression(container, POM.PostContingencyBranchFlow, PSY.Line)
        @test (_PST_NAME in Set(k[2] for k in keys(pcbf.data))) == monitor_transformer

        modf = PNM.VirtualMODF(sys)
        contingency = PNM.get_registered_contingencies(modf)[outage_id]
        nodal_balance =
            IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus).data
        name_to_arc_maps =
            PNM.get_name_to_arc_maps(POM.get_branch_catalog(network_model))
        b = PNM.get_series_susceptance(transformer, PSY.SU)
        @test !iszero(b)

        function _arc(name)
            for n2a in values(name_to_arc_maps)
                haskey(n2a, name) && return n2a[name]
            end
            error("monitored name $name not found in any reduction map")
        end

        # `MODF * P` alone, i.e. the row the shifter's own `-b·α` term is missing from.
        function _modf_product(name, t)
            expr = zero(JuMP.AffExpr)
            modf_col = modf[_arc(name), contingency]
            for i in eachindex(modf_col)
                abs(modf_col[i]) > POM.PTDF_ZERO_TOL || continue
                JuMP.add_to_expression!(expr, modf_col[i], nodal_balance[i, t])
            end
            return expr
        end

        rows_carrying_angle = 0
        for (outage_str, name, t) in keys(pcbf.data)
            expected = _modf_product(name, t)
            name == _PST_NAME &&
                JuMP.add_to_expression!(expected, -b, alpha[name, t])
            actual = pcbf.data[(outage_str, name, t)]
            @test _phase_affexpr_approx_equal(actual, expected)
            if !iszero(JuMP.coefficient(actual, alpha[_PST_NAME, t]))
                rows_carrying_angle += 1
            end
        end
        # The angle must actually reach the post-contingency rows, not merely cancel out.
        @test rows_carrying_angle > 0

        # The shifter's own row differs from the bare `MODF * P` product by exactly `-b`;
        # that term is what separates the monitored case from the unmonitored one.
        if monitor_transformer
            t = first(get_time_steps(container))
            own = pcbf.data[(string(outage_id), _PST_NAME, t)]
            angle = alpha[_PST_NAME, t]
            @test isapprox(
                JuMP.coefficient(own, angle) -
                JuMP.coefficient(_modf_product(_PST_NAME, t), angle),
                -b;
                atol = 1e-8,
            )
        end
    end
end

############################ phase shifter as the outaged element ######################

# `sys` with a second forced outage hanging off `_PST_NAME`, monitoring every line.
function _add_pst_outage!(sys, transformer)
    outage = PSY.GeometricDistributionForcedOutage(;
        mean_time_to_recovery = 10,
        outage_transition_probability = 0.9999,
        monitored_components = collect(get_components(PSY.Line, sys)),
    )
    PSY.add_supplemental_attribute!(sys, transformer, outage)
    return string(IS.get_id(outage))
end

@testset "N-1 on a DCP network rejects a phase shifter as the outaged element" begin
    # The DCP check sweeps every transformer with a DeviceModel; an outaged shifter must
    # be caught whether its angle is static or controlled.
    for (control, alpha, enable) in ((true, nothing, true), (false, 0.05, false))
        sys, transformer, _ = _sc_phase_system(;
            control = control,
            alpha = alpha,
            monitor_transformer = false,
        )
        _add_pst_outage!(sys, transformer)
        model = _sc_phase_model(
            DCPNetworkModel,
            sys;
            transformer_formulation = POM.SecurityConstrainedStaticBranch,
            enable = enable,
        )
        err = try
            POM.validate_template(model)
            nothing
        catch e
            e
        end
        @test err isa IS.ConflictingInputsError
        @test occursin("DCP", sprint(showerror, err))
    end
end

# PTDF of `sys` with `name` out of service: the reference every outaged-shifter row is
# checked against, built without the MODF.
function _reference_ptdf_without(sys, name)
    reduced = deepcopy(sys)
    PSY.set_available!(
        PSY.get_component(PSY.TwoWindingTransformer, reduced, name),
        false,
    )
    return PNM.VirtualPTDF(reduced)
end

# Post-contingency rows are stored in the container of the OUTAGED device's model, so a
# transformer outage's rows sit under `TwoWindingTransformer` while a line outage's sit
# under `Line`, whatever types the monitored branches have.
function _all_post_contingency_rows(container)
    rows = Dict{Tuple{String, String, Int}, JuMP.AffExpr}()
    for T in (PSY.Line, PSY.TwoWindingTransformer)
        IOM.has_container_key(container, POM.PostContingencyBranchFlow, T) || continue
        merge!(rows, IOM.get_expression(container, POM.PostContingencyBranchFlow, T).data)
    end
    return rows
end

# `Σ_i col[i]·balance[i, t]` over the MODF bus axis, skipping numerically zero entries.
function _ptdf_product(col, nodal_balance, t)
    expr = zero(JuMP.AffExpr)
    for i in eachindex(col)
        abs(col[i]) > POM.PTDF_ZERO_TOL || continue
        JuMP.add_to_expression!(expr, col[i], nodal_balance[i, t])
    end
    return expr
end

@testset "a static phase shifter as the outaged element matches a rebuilt PTDF" begin
    alpha = 0.05
    sys, transformer, _ =
        _sc_phase_system(; control = false, alpha = alpha, monitor_transformer = false)
    pst_outage = _add_pst_outage!(sys, transformer)
    model = _sc_phase_model(
        PTDFNetworkModel,
        sys;
        transformer_formulation = POM.SecurityConstrainedStaticBranch,
        enable = false,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(model)
    network_model = IOM.get_network_model(IOM.get_template(model))
    modf = IOM.get_contingency_matrix(network_model)
    nodal_balance = IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus).data
    pcbf = _all_post_contingency_rows(container)

    ptdf_ref = _reference_ptdf_without(sys, _PST_NAME)
    @test PNM.get_bus_axis(ptdf_ref) == PNM.get_bus_axis(modf)
    bus_lookup = PNM.get_bus_lookup(ptdf_ref)
    arc = PNM.get_arc_tuple(transformer)
    from_pos, to_pos = bus_lookup[arc[1]], bus_lookup[arc[2]]
    injection = PNM.get_series_susceptance(transformer, PSY.SU) * alpha
    @test injection ≈
          PNM.arc_dc_shift_injection(PNM.get_network_reduction_data(modf), arc)

    name_to_arc = PNM.get_name_to_arc_map(POM.get_branch_catalog(network_model), PSY.Line)
    n_rows = 0
    for (outage_str, name, t) in keys(pcbf)
        outage_str == pst_outage || continue
        col = ptdf_ref[name_to_arc[name], :]
        expected = _ptdf_product(col, nodal_balance, t)
        # The nodal balance still carries the tripped shifter's `±b·α` pair; the reference
        # network has no shifter, so strip it.
        JuMP.add_to_expression!(expected, -injection * (col[from_pos] - col[to_pos]))
        @test _phase_affexpr_approx_equal(pcbf[(outage_str, name, t)], expected)
        n_rows += 1
    end
    @test n_rows > 0
end

@testset "a controlled phase shifter as the outaged element drops out of its own rows" begin
    sys, transformer, line_outage_id =
        _sc_phase_system(; control = true, monitor_transformer = false)
    pst_outage = _add_pst_outage!(sys, transformer)
    model = _sc_phase_model(
        PTDFNetworkModel,
        sys;
        transformer_formulation = POM.SecurityConstrainedStaticBranch,
        enable = true,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(model)
    network_model = IOM.get_network_model(IOM.get_template(model))
    modf = IOM.get_contingency_matrix(network_model)
    nodal_balance = IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus).data
    pcbf = _all_post_contingency_rows(container)
    angle = IOM.get_variable(container, PhaseShifterAngle, PSY.TwoWindingTransformer)

    ptdf_ref = _reference_ptdf_without(sys, _PST_NAME)
    @test PNM.get_bus_axis(ptdf_ref) == PNM.get_bus_axis(modf)
    bus_lookup = PNM.get_bus_lookup(ptdf_ref)
    arc = PNM.get_arc_tuple(transformer)
    from_pos, to_pos = bus_lookup[arc[1]], bus_lookup[arc[2]]
    b = PNM.get_series_susceptance(transformer, PSY.SU)

    name_to_arc = PNM.get_name_to_arc_map(POM.get_branch_catalog(network_model), PSY.Line)
    own_rows = 0
    other_rows_with_angle = 0
    for (outage_str, name, t) in keys(pcbf)
        actual = pcbf[(outage_str, name, t)]
        if outage_str == pst_outage
            col = ptdf_ref[name_to_arc[name], :]
            expected = _ptdf_product(col, nodal_balance, t)
            JuMP.add_to_expression!(
                expected,
                -b * (col[from_pos] - col[to_pos]),
                angle[_PST_NAME, t],
            )
            @test _phase_affexpr_approx_equal(actual, expected)
            # A tripped shifter has no influence on the network, so its angle must vanish
            # from every row of its own outage.
            @test abs(JuMP.coefficient(actual, angle[_PST_NAME, t])) < 1e-8
            own_rows += 1
        elseif outage_str == string(line_outage_id)
            if !iszero(JuMP.coefficient(actual, angle[_PST_NAME, t]))
                other_rows_with_angle += 1
            end
        end
    end
    @test own_rows > 0
    # Under a different outage the live shifter still steers the flows.
    @test other_rows_with_angle > 0
end

@testset "post-contingency flows under a static shifter outage match a model built without it" begin
    alpha = 0.05
    sys, transformer, _ =
        _sc_phase_system(; control = false, alpha = alpha, monitor_transformer = false)
    pst_outage = _add_pst_outage!(sys, transformer)
    model = _sc_phase_model(
        PTDFNetworkModel,
        sys;
        transformer_formulation = POM.SecurityConstrainedStaticBranch,
        enable = false,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    container = IOM.get_optimization_container(model)
    pcbf = _all_post_contingency_rows(container)
    dispatch = IOM.get_variable(container, ActivePowerVariable, PSY.ThermalStandard)

    # Independent model: the physically reduced system on a plain PTDF network, generation
    # pinned to the security-constrained solution. Its line flows are the true
    # post-contingency flows.
    reduced = deepcopy(sys)
    PSY.set_available!(
        PSY.get_component(PSY.TwoWindingTransformer, reduced, _PST_NAME),
        false,
    )
    template = get_thermal_dispatch_template_network(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, DeviceModel(PSY.Line, StaticBranch))
    set_device_model!(template, DeviceModel(PSY.TwoWindingTransformer, StaticBranch))
    reference = DecisionModel(template, reduced; optimizer = HiGHS_optimizer)
    @test build!(reference; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    ref_container = IOM.get_optimization_container(reference)
    ref_dispatch = IOM.get_variable(ref_container, ActivePowerVariable, PSY.ThermalStandard)
    for name in axes(ref_dispatch)[1], t in axes(ref_dispatch)[2]
        JuMP.fix(ref_dispatch[name, t], JuMP.value(dispatch[name, t]); force = true)
    end
    @test solve!(reference) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    ref_flows = IOM.get_expression(ref_container, PTDFBranchFlow, PSY.Line)

    n_rows = 0
    for (outage_str, name, t) in keys(pcbf)
        outage_str == pst_outage || continue
        @test isapprox(
            JuMP.value(pcbf[(outage_str, name, t)]),
            JuMP.value(ref_flows[name, t]);
            atol = 1e-6,
        )
        n_rows += 1
    end
    @test n_rows > 0
end

@testset "a shifted parallel member as the outaged element corrects the surviving arc" begin
    sys = PSB.build_system(PSITestSystems, "c_sys14")
    line = PSY.get_component(PSY.Line, sys, "Line1")
    alpha = 0.1
    pst = PSY.TwoWindingTransformer(;
        name = "PST_parallel_Line1",
        circuit = PSY.TransformerCircuit(;
            available = true,
            arc = PSY.get_arc(line),
            r = 0.0,
            x = PSY.get_x(line, PSY.SU),
            tap = 1.0,
            α = alpha,
            rating = PSY.get_rating(line, PSY.SU),
            base_power = PSY.get_base_power(sys, PSY.NU),
            input_basis = CU,
        ),
        magnetizing_shunt = 0.0 + 0.0im,
        shunt_location = PSY.TwoWindingTransformerShuntLocation.PRIMARY,
        input_basis = CU,
    )
    PSY.add_component!(sys, pst)
    outage = PSY.GeometricDistributionForcedOutage(;
        mean_time_to_recovery = 10,
        outage_transition_probability = 0.9999,
        monitored_components = collect(get_components(PSY.Line, sys)),
    )
    PSY.add_supplemental_attribute!(sys, pst, outage)
    pst_outage = string(IS.get_id(outage))

    model = _sc_phase_model(
        PTDFNetworkModel,
        sys;
        transformer_formulation = POM.SecurityConstrainedStaticBranch,
        enable = false,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(model)
    network_model = IOM.get_network_model(IOM.get_template(model))
    modf = IOM.get_contingency_matrix(network_model)
    nr = PNM.get_network_reduction_data(modf)
    nodal_balance = IOM.get_expression(container, POM.ActivePowerBalance, PSY.ACBus).data
    pcbf = _all_post_contingency_rows(container)

    arc = PNM.get_arc_tuple(line)
    @test haskey(PNM.get_parallel_branch_map(nr), arc)
    injection = PNM.get_series_susceptance(pst, PSY.SU) * alpha
    # The group's injection is the sum of its members', and the line contributes none.
    @test PNM.arc_dc_shift_injection(nr, arc) ≈ injection

    ptdf_ref = _reference_ptdf_without(sys, "PST_parallel_Line1")
    @test PNM.get_bus_axis(ptdf_ref) == PNM.get_bus_axis(modf)
    bus_lookup = PNM.get_bus_lookup(ptdf_ref)
    from_pos, to_pos = bus_lookup[arc[1]], bus_lookup[arc[2]]

    name_to_arc_maps = PNM.get_name_to_arc_maps(POM.get_branch_catalog(network_model))
    function _arc(name)
        for n2a in values(name_to_arc_maps)
            haskey(n2a, name) && return n2a[name]
        end
        error("monitored name $name not found in any reduction map")
    end

    surviving_rows = 0
    n_rows = 0
    for (outage_str, name, t) in keys(pcbf)
        outage_str == pst_outage || continue
        row_arc = _arc(name)
        col = ptdf_ref[row_arc, :]
        expected = _ptdf_product(col, nodal_balance, t)
        JuMP.add_to_expression!(expected, -injection * (col[from_pos] - col[to_pos]))
        # The reference network has no shifted arc, so no own-shift term applies anywhere,
        # including on the surviving line. The tolerance carries the round-off between the
        # MODF update and the independently factorized reference PTDF, amplified by this
        # arc's 16.9 pu susceptance.
        @test _phase_affexpr_approx_equal(
            pcbf[(outage_str, name, t)],
            expected;
            atol = 1e-7,
        )
        row_arc == arc && (surviving_rows += 1)
        n_rows += 1
    end
    @test n_rows > 0
    @test surviving_rows > 0
end

@testset "a controlled shifter that is outaged and monitored has an identically zero row" begin
    # Its MODF row is zero and its own-shift term cancels against the adjustment, so
    # nothing may remain: no variable coefficient and no constant.
    sys, transformer, _ = _sc_phase_system(; control = true, monitor_transformer = true)
    # Monitor the shifter itself under its own outage as well.
    monitored = PSY.ACTransmission[get_components(PSY.Line, sys)...]
    push!(monitored, transformer)
    outage = PSY.GeometricDistributionForcedOutage(;
        mean_time_to_recovery = 10,
        outage_transition_probability = 0.9999,
        monitored_components = monitored,
    )
    PSY.add_supplemental_attribute!(sys, transformer, outage)
    outage_id = string(IS.get_id(outage))

    model = _sc_phase_model(
        PTDFNetworkModel,
        sys;
        transformer_formulation = POM.SecurityConstrainedStaticBranch,
        enable = true,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(model)
    pcbf = _all_post_contingency_rows(container)

    n_rows = 0
    for t in get_time_steps(container)
        haskey(pcbf, (outage_id, _PST_NAME, t)) || continue
        row = pcbf[(outage_id, _PST_NAME, t)]
        @test abs(JuMP.constant(row)) < 1e-8
        for (coef, _) in JuMP.linear_terms(row)
            @test abs(coef) < 1e-8
        end
        n_rows += 1
    end
    @test n_rows > 0
end
