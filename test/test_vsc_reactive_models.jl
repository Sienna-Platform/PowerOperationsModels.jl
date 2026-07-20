# Family C: VSC converter reactive / voltage-control NLP formulation
# (`VoltageControlVSC` on `PSY.TwoTerminalVSCLine`).

# Build a small AC system and replace an AC line with a TwoTerminalVSCLine carrying
# configurable per-terminal control modes / setpoints.
function _build_vsc_reactive_sys(;
    ac_control_from = VSCACControlModes.AC_VOLTAGE,
    ac_setpoint_from = 1.0,
    dc_control_from = VSCDCControlModes.DC_VOLTAGE,
    dc_setpoint_from = 1.0,
    ac_control_to = VSCACControlModes.AC_REACTIVE_POWER,
    ac_setpoint_to = 0.0,
    dc_control_to = VSCDCControlModes.DC_POWER,
    dc_setpoint_to = 0.0,
    dc_voltage_droop_from = 0.0,
    dc_voltage_droop_to = 0.0,
    rating = 2.0,
)
    sys = build_system(PSITestSystems, "c_sys5_uc"; force_build = true)
    line = get_component(Line, sys, "1")
    remove_component!(sys, line)
    vsc = TwoTerminalVSCLine(;
        name = get_name(line),
        available = true,
        arc = get_arc(line),
        active_power_flow = 0.0,
        rating = rating,
        active_power_limits_from = (min = -rating, max = rating),
        active_power_limits_to = (min = -rating, max = rating),
        g = 50.0,
        dc_current = 0.0,
        reactive_power_from = 0.0,
        dc_control_from = dc_control_from,
        ac_control_from = ac_control_from,
        dc_setpoint_from = dc_setpoint_from,
        ac_setpoint_from = ac_setpoint_from,
        converter_loss_from = QuadraticCurve(0.01, 0.0, 0.0),
        max_dc_current_from = 5.0,
        rating_from = rating,
        reactive_power_limits_from = (min = -rating, max = rating),
        power_factor_weighting_fraction_from = 1.0,
        voltage_limits_from = (min = 0.95, max = 1.05),
        dc_voltage_droop_from = dc_voltage_droop_from,
        reactive_power_to = 0.0,
        dc_control_to = dc_control_to,
        ac_control_to = ac_control_to,
        dc_setpoint_to = dc_setpoint_to,
        ac_setpoint_to = ac_setpoint_to,
        converter_loss_to = QuadraticCurve(0.01, 0.0, 0.0),
        max_dc_current_to = 5.0,
        rating_to = rating,
        reactive_power_limits_to = (min = -rating, max = rating),
        power_factor_weighting_fraction_to = 1.0,
        voltage_limits_to = (min = 0.95, max = 1.05),
        dc_voltage_droop_to = dc_voltage_droop_to,
    )
    add_component!(sys, vsc)
    return sys
end

function _vsc_reactive_template(network)
    template = PowerOperationsProblemTemplate(NetworkModel(network))
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(template, DeviceModel(TwoTerminalVSCLine, VoltageControlVSC))
    return template
end

@testset "VoltageControlVSC builds and solves under ACPNetworkModel" begin
    # Both AC terminals in AC_VOLTAGE mode so the reactive injections float
    # (bounded) while the bus voltages are pinned.
    sys = _build_vsc_reactive_sys(;
        ac_control_to = VSCACControlModes.AC_VOLTAGE,
        ac_setpoint_to = 1.0,
    )
    template = _vsc_reactive_template(ACPNetworkModel)
    model = DecisionModel(
        template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    # Reactive injection variables are finite-bounded (Principle 0 / IPOPT).
    @test check_variable_bounded(model, HVDCReactivePowerFromVariable, TwoTerminalVSCLine)
    @test check_variable_bounded(model, HVDCReactivePowerToVariable, TwoTerminalVSCLine)
end

@testset "VoltageControlVSC AC_VOLTAGE pins the regulated bus voltage" begin
    sys = _build_vsc_reactive_sys(;
        ac_control_from = VSCACControlModes.AC_VOLTAGE,
        ac_setpoint_from = 1.0,
    )
    vsc = get_component(TwoTerminalVSCLine, sys, "1")
    regulated_bus = get_name(get_from(get_arc(vsc)))
    setpoint = get_ac_setpoint_from(vsc)

    template = _vsc_reactive_template(ACPNetworkModel)
    model = DecisionModel(
        template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    res = IOM.OptimizationProblemOutputs(model)
    vm = read_variable(res, "VoltageMagnitude__ACBus"; table_format = TableFormat.WIDE)
    @test regulated_bus in names(vm)
    for r in 1:nrow(vm)
        @test isapprox(vm[r, regulated_bus], setpoint; atol = 1e-6)
    end
end

@testset "VoltageControlVSC is count-invariant across AC control modes" begin
    function _container_for_ac_mode(mode)
        sys = _build_vsc_reactive_sys(;
            ac_control_from = mode,
            ac_setpoint_from = 1.0,
        )
        template = _vsc_reactive_template(ACPNetworkModel)
        model = DecisionModel(
            template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        return IOM.get_optimization_container(model)
    end

    c_v = _container_for_ac_mode(VSCACControlModes.AC_VOLTAGE)
    c_q = _container_for_ac_mode(VSCACControlModes.AC_REACTIVE_POWER)

    var_v = IOM.get_variables(c_v)
    var_q = IOM.get_variables(c_q)
    @test Set(keys(var_v)) == Set(keys(var_q))
    for k in keys(var_v)
        @test size(var_v[k]) == size(var_q[k])
    end

    con_v = IOM.get_constraints(c_v)
    con_q = IOM.get_constraints(c_q)
    @test Set(keys(con_v)) == Set(keys(con_q))
    for k in keys(con_v)
        @test size(con_v[k]) == size(con_q[k])
    end
end

@testset "VoltageControlVSC AC_VOLTAGE pins the regulated bus voltage (ACR)" begin
    sys = _build_vsc_reactive_sys(;
        ac_control_from = VSCACControlModes.AC_VOLTAGE,
        ac_setpoint_from = 1.0,
    )
    vsc = get_component(TwoTerminalVSCLine, sys, "1")
    regulated_bus = get_name(get_from(get_arc(vsc)))
    setpoint = get_ac_setpoint_from(vsc)

    template = _vsc_reactive_template(ACRNetworkModel)
    model = DecisionModel(
        template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    res = IOM.OptimizationProblemOutputs(model)
    vr = read_variable(res, "VoltageReal__ACBus"; table_format = TableFormat.WIDE)
    vi = read_variable(res, "VoltageImaginary__ACBus"; table_format = TableFormat.WIDE)
    @test regulated_bus in names(vr)
    for r in 1:nrow(vr)
        mag = sqrt(vr[r, regulated_bus]^2 + vi[r, regulated_bus]^2)
        @test isapprox(mag, setpoint; atol = 1e-4)
    end
end

@testset "VoltageControlVSC is count-invariant across AC control modes (ACR)" begin
    function _acr_container_for_ac_mode(mode)
        sys = _build_vsc_reactive_sys(;
            ac_control_from = mode,
            ac_setpoint_from = 1.0,
        )
        template = _vsc_reactive_template(ACRNetworkModel)
        model = DecisionModel(
            template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        return IOM.get_optimization_container(model)
    end

    c_v = _acr_container_for_ac_mode(VSCACControlModes.AC_VOLTAGE)
    c_q = _acr_container_for_ac_mode(VSCACControlModes.AC_REACTIVE_POWER)

    var_v = IOM.get_variables(c_v)
    var_q = IOM.get_variables(c_q)
    @test any(k -> occursin("RegulatedVoltageMagnitude", string(k)), keys(var_v))
    @test Set(keys(var_v)) == Set(keys(var_q))
    for k in keys(var_v)
        @test size(var_v[k]) == size(var_q[k])
    end

    con_v = IOM.get_constraints(c_v)
    con_q = IOM.get_constraints(c_q)
    @test any(k -> occursin("RegulatedVoltageMagnitudeConstraint", string(k)), keys(con_v))
    @test Set(keys(con_v)) == Set(keys(con_q))
    for k in keys(con_v)
        @test size(con_v[k]) == size(con_q[k])
    end
end

@testset "VoltageControlVSC @info-drop under DCPNetworkModel" begin
    sys = _build_vsc_reactive_sys()
    template = _vsc_reactive_template(DCPNetworkModel)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    # VoltageControlVSC models reactive power, so under an active-power-only DC
    # network it is dropped (with an @info) from the template during validation.
    build!(model; output_dir = mktempdir(; cleanup = true))
    @test !haskey(get_branch_models(get_template(model)), :TwoTerminalVSCLine)
end

@testset "VoltageControlVSC is count-invariant across DC control modes (ACP)" begin
    function _acp_container_for_dc_mode(mode; droop = 0.0)
        sys = _build_vsc_reactive_sys(;
            dc_control_from = mode,
            dc_setpoint_from = 1.0,
            dc_voltage_droop_from = droop,
            ac_control_to = VSCACControlModes.AC_VOLTAGE,
            ac_setpoint_to = 1.0,
        )
        template = _vsc_reactive_template(ACPNetworkModel)
        model = DecisionModel(
            template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        return IOM.get_optimization_container(model)
    end

    c_v = _acp_container_for_dc_mode(VSCDCControlModes.DC_VOLTAGE)
    c_d = _acp_container_for_dc_mode(VSCDCControlModes.DC_VOLTAGE_DROOP; droop = 0.05)

    var_v = IOM.get_variables(c_v)
    var_d = IOM.get_variables(c_d)
    @test Set(keys(var_v)) == Set(keys(var_d))
    for key in keys(var_v)
        @test size(var_v[key]) == size(var_d[key])
    end

    con_v = IOM.get_constraints(c_v)
    con_d = IOM.get_constraints(c_d)
    @test Set(keys(con_v)) == Set(keys(con_d))
    for key in keys(con_v)
        @test size(con_v[key]) == size(con_d[key])
    end
end

# Helpers for the AC apparent-current loss assertions.
function _vsc_no_integer_vars(model)
    jm = POM.get_jump_model(IOM.get_optimization_container(model))
    vars = JuMP.all_variables(jm)
    return count(JuMP.is_binary, vars) == 0 && count(JuMP.is_integer, vars) == 0
end

@testset "VoltageControlVSC AC loss is parameterized on AC apparent current" begin
    # Pin the to-terminal reactive injection to a non-zero value so the converter
    # carries reactive power; the loss must then exceed the active-only (Q=0) loss.
    sys = _build_vsc_reactive_sys(;
        ac_control_from = VSCACControlModes.AC_VOLTAGE,
        ac_setpoint_from = 1.0,
        ac_control_to = VSCACControlModes.AC_REACTIVE_POWER,
        ac_setpoint_to = 0.6,
    )
    template = _vsc_reactive_template(ACPNetworkModel)
    model = DecisionModel(
        template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    # Exact continuous NLP: no binary/integer variables.
    @test _vsc_no_integer_vars(model)

    # The per-terminal AC apparent-current variables exist (AC path), and the |I_dc|
    # surrogate (CurrentAbsoluteValueVariable) does not (it belongs to the DC path).
    c = IOM.get_optimization_container(model)
    vars = IOM.get_variables(c)
    @test any(k -> occursin("ConverterACCurrentToVariable", string(k)), keys(vars))
    @test any(k -> occursin("ConverterACCurrentFromVariable", string(k)), keys(vars))
    @test !any(k -> occursin("CurrentAbsoluteValueVariable", string(k)), keys(vars))

    i_ac_t = POM.get_variable(c, ConverterACCurrentToVariable, TwoTerminalVSCLine)
    p_tf = POM.get_variable(c, POM.FlowActivePowerToFromVariable, TwoTerminalVSCLine)
    q_t = POM.get_variable(c, POM.HVDCReactivePowerToVariable, TwoTerminalVSCLine)
    vm = POM.get_variable(c, POM.VoltageMagnitude, PSY.ACBus)
    vsc = get_component(TwoTerminalVSCLine, sys, "1")
    to_bus = get_name(get_to(get_arc(vsc)))
    loss_to = get_converter_loss_to(vsc)
    a = POM._get_quadratic_term(loss_to)

    for t in 1:length(POM.get_time_steps(c))
        iac = JuMP.value(i_ac_t["1", t])
        pv = JuMP.value(p_tf["1", t])
        qv = JuMP.value(q_t["1", t])
        vv = JuMP.value(vm[to_bus, t])
        # Defining relation I_ac^2 * V_ac^2 == p^2 + q^2 holds tightly at the optimum.
        @test isapprox(iac^2 * vv^2, pv^2 + qv^2; atol = 1e-4, rtol = 1e-3)
        # Reactive loading strictly raises the apparent current above |p|/V_ac, so
        # the quadratic loss a*I_ac^2 strictly exceeds the active-only loss a*(p/V)^2.
        @test abs(qv) > 1e-3
        @test iac * vv > abs(pv) + 1e-4
        @test a * iac^2 > a * (pv / vv)^2 + 1e-6
    end
end

@testset "VoltageControlVSC BOTH terminals AC_VOLTAGE builds and solves (ACR)" begin
    sys = _build_vsc_reactive_sys(;
        ac_control_from = VSCACControlModes.AC_VOLTAGE,
        ac_setpoint_from = 1.0,
        ac_control_to = VSCACControlModes.AC_VOLTAGE,
        ac_setpoint_to = 1.0,
    )
    vsc = get_component(TwoTerminalVSCLine, sys, "1")
    arc = get_arc(vsc)
    from_bus = get_name(get_from(arc))
    to_bus = get_name(get_to(arc))

    template = _vsc_reactive_template(ACRNetworkModel)
    model = DecisionModel(
        template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    res = IOM.OptimizationProblemOutputs(model)
    vr = read_variable(res, "VoltageReal__ACBus"; table_format = TableFormat.WIDE)
    vi = read_variable(res, "VoltageImaginary__ACBus"; table_format = TableFormat.WIDE)
    @test from_bus in names(vr)
    @test to_bus in names(vr)
    for r in 1:nrow(vr)
        mag_from = sqrt(vr[r, from_bus]^2 + vi[r, from_bus]^2)
        @test isapprox(mag_from, 1.0; atol = 1e-4)
        mag_to = sqrt(vr[r, to_bus]^2 + vi[r, to_bus]^2)
        @test isapprox(mag_to, 1.0; atol = 1e-4)
    end
end

@testset "VoltageControlVSC count-invariant: both-voltage vs both-reactive (ACR)" begin
    function _acr_container_two_mode(ac_from_mode, ac_to_mode)
        sys = _build_vsc_reactive_sys(;
            ac_control_from = ac_from_mode,
            ac_setpoint_from = 1.0,
            ac_control_to = ac_to_mode,
            ac_setpoint_to = 0.0,
        )
        template = _vsc_reactive_template(ACRNetworkModel)
        model = DecisionModel(
            template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        return IOM.get_optimization_container(model)
    end

    c_vv = _acr_container_two_mode(
        VSCACControlModes.AC_VOLTAGE, VSCACControlModes.AC_VOLTAGE,
    )
    c_qq = _acr_container_two_mode(
        VSCACControlModes.AC_REACTIVE_POWER, VSCACControlModes.AC_REACTIVE_POWER,
    )

    var_vv = IOM.get_variables(c_vv)
    var_qq = IOM.get_variables(c_qq)
    @test any(k -> occursin("RegulatedVoltageMagnitude", string(k)), keys(var_vv))
    @test Set(keys(var_vv)) == Set(keys(var_qq))
    for k in keys(var_vv)
        @test size(var_vv[k]) == size(var_qq[k])
    end

    con_vv = IOM.get_constraints(c_vv)
    con_qq = IOM.get_constraints(c_qq)
    reg_keys = [
        k for
        k in keys(con_vv) if occursin("RegulatedVoltageMagnitudeConstraint", string(k))
    ]
    @test length(reg_keys) == 2
    @test Set(keys(con_vv)) == Set(keys(con_qq))
    for k in keys(con_vv)
        @test size(con_vv[k]) == size(con_qq[k])
    end
end

# HVDCTwoTerminalVSC under a linearizing bilinear scheme on a reactive-carrying network:
# the combination that reaches the box/octagon apparent-power limit. No optimizer is
# attached — bin2 adds SOS2 constraints and ACP is nonlinear, so the model is a MINLP no
# configured solver supports, but build! still succeeds and the coefficients are inspectable.
function _vsc_octagon_model(sys; use_octagon)
    template = PowerOperationsProblemTemplate(NetworkModel(ACPNetworkModel))
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(
        template,
        DeviceModel(
            TwoTerminalVSCLine, HVDCTwoTerminalVSC;
            attributes = Dict{String, Any}(
                "bilinear_approximation" => "bin2",
                "use_octagon" => use_octagon,
            ),
        ),
    )
    return DecisionModel(template, sys; store_variable_names = true)
end

# Apparent-power-limit rows are keyed by a per-face tag; wrap the repeated lookup.
function _vsc_apparent_power_constraint(container, tag)
    return IOM.get_constraint(
        container,
        POM.HVDCVSCApparentPowerLimitConstraint,
        TwoTerminalVSCLine,
        tag,
    )
end

const _VSC_OCTAGON_BOX_TAGS = (
    "from_p_ub", "from_p_lb", "from_q_ub", "from_q_lb",
    "to_p_ub", "to_p_lb", "to_q_ub", "to_q_lb",
)
const _VSC_OCTAGON_DIAG_TAGS = (
    "from_pp", "from_pn", "from_np", "from_nn",
    "to_pp", "to_pn", "to_np", "to_nn",
)

@testset "VSC apparent power box pins per-terminal rating on all four faces" begin
    rating = 2.0
    sys = _build_vsc_reactive_sys(; rating = rating)
    model = _vsc_octagon_model(sys; use_octagon = false)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(model)
    t1 = first(IOM.get_time_steps(container))
    p_ft = IOM.get_variable(container, FlowActivePowerFromToVariable, TwoTerminalVSCLine)
    q_f = IOM.get_variable(container, HVDCReactivePowerFromVariable, TwoTerminalVSCLine)

    # Box rows: coefficient +/-1 on exactly one variable, RHS = rating.
    for (tag, var, coeff) in (
        ("from_p_ub", p_ft, 1.0), ("from_p_lb", p_ft, -1.0),
        ("from_q_ub", q_f, 1.0), ("from_q_lb", q_f, -1.0),
    )
        con = _vsc_apparent_power_constraint(container, tag)
        @test !isempty(con)
        c = con["1", t1]
        @test JuMP.normalized_coefficient(c, var["1", t1]) == coeff
        @test JuMP.normalized_rhs(c) ≈ rating
    end

    # With use_octagon = false the diagonals must not exist at all.
    for tag in _VSC_OCTAGON_DIAG_TAGS
        @test_throws Exception _vsc_apparent_power_constraint(container, tag)
    end
end

@testset "VSC octagon diagonals carry the rating*sqrt(2) outer approximation" begin
    rating = 2.0
    diag = rating * sqrt(2.0)
    sys = _build_vsc_reactive_sys(; rating = rating)
    model = _vsc_octagon_model(sys; use_octagon = true)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(model)
    t1 = first(IOM.get_time_steps(container))
    p_ft = IOM.get_variable(container, FlowActivePowerFromToVariable, TwoTerminalVSCLine)
    q_f = IOM.get_variable(container, HVDCReactivePowerFromVariable, TwoTerminalVSCLine)

    # All four sign combinations on the "from" terminal, hand-derived from
    # |p| +/- q <= rating*sqrt(2). A pn/np transposition fails here and nowhere else.
    for (tag, p_coeff, q_coeff) in (
        ("from_pp", 1.0, 1.0),
        ("from_pn", 1.0, -1.0),
        ("from_np", -1.0, 1.0),
        ("from_nn", -1.0, -1.0),
    )
        con = _vsc_apparent_power_constraint(container, tag)
        @test !isempty(con)
        c = con["1", t1]
        @test JuMP.normalized_coefficient(c, p_ft["1", t1]) == p_coeff
        @test JuMP.normalized_coefficient(c, q_f["1", t1]) == q_coeff
        @test JuMP.normalized_rhs(c) ≈ diag
    end

    # Both terminals get the full tag set.
    for tag in (_VSC_OCTAGON_BOX_TAGS..., _VSC_OCTAGON_DIAG_TAGS...)
        @test !isempty(_vsc_apparent_power_constraint(container, tag))
    end
end

@testset "VSC octagon is a tightening of the box, and both contain the rating disk" begin
    rating = 2.0
    diag = rating * sqrt(2.0)

    function _built_container(use_octagon)
        sys = _build_vsc_reactive_sys(; rating = rating)
        model = _vsc_octagon_model(sys; use_octagon = use_octagon)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        return IOM.get_optimization_container(model)
    end

    boxed = _built_container(false)
    octagon = _built_container(true)
    t1 = first(IOM.get_time_steps(octagon))

    # The octagon adds the four 45-degree diagonals on top of the axis-aligned box,
    # so its feasible region is a subset of the box's: every box tag is present in
    # both models, and the diagonals exist only with use_octagon = true.
    for tag in _VSC_OCTAGON_BOX_TAGS
        @test !isempty(_vsc_apparent_power_constraint(boxed, tag))
        @test !isempty(_vsc_apparent_power_constraint(octagon, tag))
    end
    for tag in _VSC_OCTAGON_DIAG_TAGS
        @test_throws Exception _vsc_apparent_power_constraint(boxed, tag)
        @test !isempty(_vsc_apparent_power_constraint(octagon, tag))
    end

    # Both regions contain the rating disk p^2 + q^2 <= rating^2. The box |p|,|q| <= rating
    # circumscribes it directly; the diagonals |p| +/- q <= rating*sqrt(2) circumscribe it
    # by Cauchy-Schwarz, (|p|+|q|)^2 <= 2*(p^2+q^2) <= 2*rating^2. The diagonal RHS is
    # strictly larger than the box RHS, so the octagon tightens only the box corners and
    # never cuts into the disk.
    for tag in _VSC_OCTAGON_DIAG_TAGS
        c = _vsc_apparent_power_constraint(octagon, tag)["1", t1]
        @test JuMP.normalized_rhs(c) ≈ diag
        @test JuMP.normalized_rhs(c) > rating
    end
    for tag in _VSC_OCTAGON_BOX_TAGS
        c = _vsc_apparent_power_constraint(octagon, tag)["1", t1]
        @test JuMP.normalized_rhs(c) ≈ rating
    end
end
