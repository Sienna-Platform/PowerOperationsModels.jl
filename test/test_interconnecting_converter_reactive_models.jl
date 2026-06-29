# VoltageControlConverter: AC-side reactive power + AC/DC control for
# `PSY.InterconnectingConverter` under AC network models (ACP/ACR/IVR).

# Build the 10-bus AC/DC system and configure every InterconnectingConverter with
# the requested control modes / setpoints and finite reactive_power_limits so the
# converters can be modeled under an AC network.
function _build_ic_reactive_sys(;
    ac_control = VSCACControlModes.AC_VOLTAGE,
    ac_setpoint = 1.0,
    dc_control = VSCDCControlModes.DC_VOLTAGE,
    dc_setpoint = 1.0,
    dc_voltage_droop = 0.0,
    reactive_limit = 1.5,
)
    sys = build_system(PSISystems, "sys10_pjm_ac_dc"; force_build = true)
    for ic in get_components(InterconnectingConverter, sys)
        set_loss_function!(ic, QuadraticCurve(0.01, 0.01, 0.0))
        set_max_dc_current!(ic, 2.0)
        set_reactive_power_limits!(
            ic, (min = -reactive_limit * PSY.SU, max = reactive_limit * PSY.SU),
        )
        set_ac_control!(ic, ac_control)
        set_ac_setpoint!(ic, ac_setpoint)
        set_dc_control!(ic, dc_control)
        set_dc_setpoint!(ic, dc_setpoint)
        set_dc_voltage_droop!(ic, dc_voltage_droop)
    end
    return sys
end

function _ic_reactive_template(network)
    template = PowerOperationsProblemTemplate(NetworkModel(network))
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(template, DeviceModel(TModelHVDCLine, DCLossyLine))
    set_device_model!(
        template, DeviceModel(InterconnectingConverter, VoltageControlConverter),
    )
    set_hvdc_network_model!(template, VoltageDispatchHVDCNetworkModel)
    return template
end

@testset "VoltageControlConverter — type definitions" begin
    @test VoltageControlConverter <: POM.AbstractQuadraticLossConverter
    @test POM.models_reactive_power(VoltageControlConverter)
    @test !POM.models_reactive_power(QuadraticLossConverter)
end

@testset "VoltageControlConverter builds and solves under ACPNetworkModel" begin
    sys = _build_ic_reactive_sys()
    template = _ic_reactive_template(ACPNetworkModel)
    model = DecisionModel(
        template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    # The converter reactive injection is finite-bounded (Principle 0 / IPOPT).
    @test check_variable_bounded(model, ReactivePowerVariable, InterconnectingConverter)
end

@testset "VoltageControlConverter AC_VOLTAGE pins the regulated AC bus voltage" begin
    setpoint = 1.0
    sys = _build_ic_reactive_sys(;
        ac_control = VSCACControlModes.AC_VOLTAGE, ac_setpoint = setpoint,
    )
    regulated_buses = [get_name(get_bus(ic)) for
     ic in get_components(InterconnectingConverter, sys)]

    template = _ic_reactive_template(ACPNetworkModel)
    model = DecisionModel(
        template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    res = IOM.OptimizationProblemOutputs(model)
    vm = read_variable(res, "VoltageMagnitude__ACBus"; table_format = TableFormat.WIDE)
    for bus in regulated_buses
        @test bus in names(vm)
        for r in 1:nrow(vm)
            @test isapprox(vm[r, bus], setpoint; atol = 1e-6)
        end
    end
end

@testset "VoltageControlConverter AC_REACTIVE_POWER pins the reactive injection" begin
    q_sp = 0.3
    sys = _build_ic_reactive_sys(;
        ac_control = VSCACControlModes.AC_REACTIVE_POWER, ac_setpoint = q_sp,
    )
    template = _ic_reactive_template(ACPNetworkModel)
    model = DecisionModel(
        template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    c = IOM.get_optimization_container(model)
    q = JuMP.value.(IOM.get_variable(c, ReactivePowerVariable, InterconnectingConverter))
    @test all(isapprox.(q, q_sp; atol = 1e-6))
end

@testset "VoltageControlConverter DC_VOLTAGE_DROOP satisfies vdc + k*P == setpoint" begin
    droop = 0.05
    dc_sp = 1.0
    sys = _build_ic_reactive_sys(;
        dc_control = VSCDCControlModes.DC_VOLTAGE_DROOP,
        dc_setpoint = dc_sp,
        dc_voltage_droop = droop,
    )
    template = _ic_reactive_template(ACPNetworkModel)
    model = DecisionModel(
        template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    c = IOM.get_optimization_container(model)
    vdc = JuMP.value.(IOM.get_variable(c, DCVoltage, DCBus))
    p = JuMP.value.(IOM.get_variable(c, ActivePowerVariable, InterconnectingConverter))
    time_steps = axes(p)[2]
    for ic in get_components(InterconnectingConverter, sys)
        name = get_name(ic)
        dc_bus = get_name(get_dc_bus(ic))
        for t in time_steps
            @test isapprox(vdc[dc_bus, t] + droop * p[name, t], dc_sp; atol = 1e-5)
        end
    end
end

@testset "VoltageControlConverter is count-invariant across AC control modes (ACP)" begin
    function _container_for_ac_mode(mode, setpoint)
        sys = _build_ic_reactive_sys(; ac_control = mode, ac_setpoint = setpoint)
        template = _ic_reactive_template(ACPNetworkModel)
        model = DecisionModel(
            template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        return IOM.get_optimization_container(model)
    end

    c_v = _container_for_ac_mode(VSCACControlModes.AC_VOLTAGE, 1.0)
    c_q = _container_for_ac_mode(VSCACControlModes.AC_REACTIVE_POWER, 0.0)

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

@testset "VoltageControlConverter is count-invariant across DC control modes (ACP)" begin
    function _container_for_dc_mode(mode; droop = 0.0)
        sys = _build_ic_reactive_sys(;
            dc_control = mode, dc_setpoint = 1.0, dc_voltage_droop = droop,
        )
        template = _ic_reactive_template(ACPNetworkModel)
        model = DecisionModel(
            template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        return IOM.get_optimization_container(model)
    end

    c_v = _container_for_dc_mode(VSCDCControlModes.DC_VOLTAGE)
    c_d = _container_for_dc_mode(VSCDCControlModes.DC_VOLTAGE_DROOP; droop = 0.05)

    var_v = IOM.get_variables(c_v)
    var_d = IOM.get_variables(c_d)
    @test Set(keys(var_v)) == Set(keys(var_d))
    for k in keys(var_v)
        @test size(var_v[k]) == size(var_d[k])
    end

    con_v = IOM.get_constraints(c_v)
    con_d = IOM.get_constraints(c_d)
    @test Set(keys(con_v)) == Set(keys(con_d))
    for k in keys(con_v)
        @test size(con_v[k]) == size(con_d[k])
    end
end

@testset "VoltageControlConverter AC_VOLTAGE pins the regulated bus voltage (ACR)" begin
    setpoint = 1.0
    sys = _build_ic_reactive_sys(;
        ac_control = VSCACControlModes.AC_VOLTAGE, ac_setpoint = setpoint,
    )
    regulated_buses = [get_name(get_bus(ic)) for
     ic in get_components(InterconnectingConverter, sys)]

    template = _ic_reactive_template(ACRNetworkModel)
    model = DecisionModel(
        template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    res = IOM.OptimizationProblemOutputs(model)
    vr = read_variable(res, "VoltageReal__ACBus"; table_format = TableFormat.WIDE)
    vi = read_variable(res, "VoltageImaginary__ACBus"; table_format = TableFormat.WIDE)
    for bus in regulated_buses
        @test bus in names(vr)
        for r in 1:nrow(vr)
            mag = sqrt(vr[r, bus]^2 + vi[r, bus]^2)
            @test isapprox(mag, setpoint; atol = 1e-4)
        end
    end
end

@testset "VoltageControlConverter is count-invariant across AC control modes (ACR)" begin
    function _acr_container_for_ac_mode(mode, setpoint)
        sys = _build_ic_reactive_sys(; ac_control = mode, ac_setpoint = setpoint)
        template = _ic_reactive_template(ACRNetworkModel)
        model = DecisionModel(
            template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        return IOM.get_optimization_container(model)
    end

    c_v = _acr_container_for_ac_mode(VSCACControlModes.AC_VOLTAGE, 1.0)
    c_q = _acr_container_for_ac_mode(VSCACControlModes.AC_REACTIVE_POWER, 0.0)

    var_v = IOM.get_variables(c_v)
    var_q = IOM.get_variables(c_q)
    @test any(k -> occursin("RegulatedVoltageMagnitude", string(k)), keys(var_v))
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

@testset "VoltageControlConverter drops under DCPNetworkModel" begin
    sys = _build_ic_reactive_sys()
    template = _ic_reactive_template(DCPNetworkModel)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    # VoltageControlConverter models reactive power, so under an active-power-only DC
    # network it is dropped from the template during validation.
    build!(model; output_dir = mktempdir(; cleanup = true))
    @test !haskey(
        get_device_models(get_template(model)), :InterconnectingConverter,
    )
end

@testset "VoltageControlConverter errors when reactive_power_limits is missing" begin
    sys = _build_ic_reactive_sys()
    ic = first(get_components(InterconnectingConverter, sys))
    set_reactive_power_limits!(ic, nothing)
    template = _ic_reactive_template(ACPNetworkModel)
    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    # The missing-limit guard surfaces as a failed build (non-finite bound refused).
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.FAILED
end

# Helper: assert the JuMP model is a pure continuous program.
function _ic_no_integer_vars(model)
    jm = POM.get_jump_model(IOM.get_optimization_container(model))
    vars = JuMP.all_variables(jm)
    return count(JuMP.is_binary, vars) == 0 && count(JuMP.is_integer, vars) == 0
end

@testset "VoltageControlConverter AC loss is parameterized on AC apparent current" begin
    # Pin every converter's reactive injection to a non-zero setpoint so they carry
    # reactive power; the loss must then reflect Q via the AC apparent current.
    sys = _build_ic_reactive_sys(;
        ac_control = VSCACControlModes.AC_REACTIVE_POWER,
        ac_setpoint = 0.8,
        reactive_limit = 1.5,
    )
    template = _ic_reactive_template(ACPNetworkModel)
    model = DecisionModel(
        template, sys; store_variable_names = true, optimizer = ipopt_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    # Exact continuous NLP: no binary/integer variables.
    @test _ic_no_integer_vars(model)

    c = IOM.get_optimization_container(model)
    vars = IOM.get_variables(c)
    @test any(k -> occursin("ConverterACCurrentVariable", string(k)), keys(vars))
    @test !any(k -> occursin("CurrentAbsoluteValueVariable", string(k)), keys(vars))

    iac = POM.get_variable(c, ConverterACCurrentVariable, InterconnectingConverter)
    p = POM.get_variable(c, POM.ActivePowerVariable, InterconnectingConverter)
    q = POM.get_variable(c, POM.ReactivePowerVariable, InterconnectingConverter)
    vm = POM.get_variable(c, POM.VoltageMagnitude, PSY.ACBus)

    loaded = 0
    for d in get_components(InterconnectingConverter, sys)
        n = get_name(d)
        bn = get_name(get_bus(d))
        iacv = JuMP.value(iac[n, 1])
        pv = JuMP.value(p[n, 1])
        qv = JuMP.value(q[n, 1])
        vv = JuMP.value(vm[bn, 1])
        rhs = pv^2 + qv^2
        if rhs > 1e-3
            # Defining relation I_ac^2 * V_ac^2 == p^2 + q^2 holds tightly.
            @test isapprox(iacv^2 * vv^2, rhs; atol = 1e-3, rtol = 1e-2)
            # Reactive loading raises I_ac above |p|/V_ac (loss now depends on Q).
            @test iacv * vv > abs(pv) + 1e-4
            loaded += 1
        end
    end
    @test loaded >= 1
end
