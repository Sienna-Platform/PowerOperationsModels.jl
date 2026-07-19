@testset "ShuntSusceptance bounds are finite (Principle 0 — SwitchedAdmittance)" begin
    # A device with one adjustable block: b ∈ [0.1, 0.1 + 3*0.05] = [0.1, 0.25]
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    bus = first(PSY.get_components(PSY.ACBus, sys))
    sa = PSY.SwitchedAdmittance(;
        name = "sa_test",
        available = true,
        bus = bus,
        Y = 0.0 + 0.1im,
        number_of_steps = [3],
        Y_increase = [0.0 + 0.05im],
    )
    lim = POM._shunt_susceptance_limits(sa)
    @test isfinite(lim.min)
    @test isfinite(lim.max)
    @test lim.max >= lim.min
    @test isapprox(lim.min, 0.1; atol = 1e-10)
    @test isapprox(lim.max, 0.25; atol = 1e-10)
end

@testset "ShuntSusceptanceDispatch build — ACPNetworkModel (SwitchedAdmittance)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")

    # Add a SwitchedAdmittance to the system
    bus = PSY.get_component(PSY.ACBus, sys, "BUS 1")
    if isnothing(bus)
        bus = first(PSY.get_components(PSY.ACBus, sys))
    end
    sa = PSY.SwitchedAdmittance(;
        name = "shunt_cap",
        available = true,
        bus = bus,
        Y = 0.0 + 0.1im,
        number_of_steps = [2],
        Y_increase = [0.0 + 0.1im],
    )
    PSY.add_component!(sys, sa)

    template = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    set_device_model!(template, PSY.SwitchedAdmittance, ShuntSusceptanceDispatch)

    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    @test check_variable_bounded(model, ShuntSusceptanceVariable, PSY.SwitchedAdmittance)
    @test check_variable_bounded(model, ReactivePowerVariable, PSY.SwitchedAdmittance)
end

@testset "ShuntSusceptanceDispatch build+solve — ACPNetworkModel (FACTSControlDevice)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    bus = PSY.get_component(PSY.ACBus, sys, "nodeA")
    facts = PSY.FACTSControlDevice(;
        name = "facts_acp_test",
        available = true,
        bus = bus,
        control_mode = nothing,
        max_shunt_current = 100.0,
    )
    PSY.add_component!(sys, facts)

    template = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    set_device_model!(template, PSY.FACTSControlDevice, ShuntSusceptanceDispatch)

    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    @test check_variable_bounded(model, ShuntSusceptanceVariable, PSY.FACTSControlDevice)
    @test check_variable_bounded(model, ReactivePowerVariable, PSY.FACTSControlDevice)
end

@testset "ShuntSusceptanceDispatch is count-invariant across control modes (FACTSControlDevice)" begin
    function _facts_container_for_mode(control_mode)
        sys = PSB.build_system(PSITestSystems, "c_sys5")
        bus = PSY.get_component(PSY.ACBus, sys, "nodeA")
        facts = PSY.FACTSControlDevice(;
            name = "facts_ci_test",
            available = true,
            bus = bus,
            control_mode = control_mode,
            voltage_setpoint = 1.0,
            max_shunt_current = 100.0,
        )
        PSY.add_component!(sys, facts)
        template = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
        set_device_model!(template, PSY.FACTSControlDevice, ShuntSusceptanceDispatch)
        model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        return IOM.get_optimization_container(model)
    end

    c_nml = _facts_container_for_mode(PSY.FACTSOperationModes.NML)
    c_free = _facts_container_for_mode(nothing)

    var_nml = IOM.get_variables(c_nml)
    var_free = IOM.get_variables(c_free)
    @test Set(keys(var_nml)) == Set(keys(var_free))
    for k in keys(var_nml)
        @test size(var_nml[k]) == size(var_free[k])
    end

    con_nml = IOM.get_constraints(c_nml)
    con_free = IOM.get_constraints(c_free)
    @test Set(keys(con_nml)) == Set(keys(con_free))
    for k in keys(con_nml)
        @test size(con_nml[k]) == size(con_free[k])
    end
end

@testset "ShuntSusceptanceDispatch VOLTAGE objective pins regulated bus (ACR, FACTS)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    bus = PSY.get_component(PSY.ACBus, sys, "nodeA")
    facts = PSY.FACTSControlDevice(;
        name = "facts_acr_test",
        available = true,
        bus = bus,
        control_mode = PSY.FACTSOperationModes.NML,
        voltage_setpoint = 1.0,
        max_shunt_current = 100.0,
    )
    PSY.add_component!(sys, facts)
    regulated_bus = PSY.get_name(bus)
    setpoint = PSY.get_voltage_setpoint(facts)

    template = get_thermal_dispatch_template_network(NetworkModel(ACRNetworkModel))
    set_device_model!(template, PSY.FACTSControlDevice, ShuntSusceptanceDispatch)

    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
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

@testset "ShuntSusceptanceDispatch VOLTAGE objective pins regulated bus (IVR, FACTS)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    bus = PSY.get_component(PSY.ACBus, sys, "nodeA")
    facts = PSY.FACTSControlDevice(;
        name = "facts_ivr_test",
        available = true,
        bus = bus,
        control_mode = PSY.FACTSOperationModes.NML,
        voltage_setpoint = 1.0,
        max_shunt_current = 100.0,
    )
    PSY.add_component!(sys, facts)
    regulated_bus = PSY.get_name(bus)
    setpoint = PSY.get_voltage_setpoint(facts)

    template = get_thermal_dispatch_template_network(NetworkModel(IVRNetworkModel))
    set_device_model!(template, PSY.FACTSControlDevice, ShuntSusceptanceDispatch)

    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
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

@testset "ShuntSusceptanceDispatch is count-invariant across control modes (ACR, FACTS)" begin
    function _facts_acr_container_for_mode(control_mode)
        sys = PSB.build_system(PSITestSystems, "c_sys5")
        bus = PSY.get_component(PSY.ACBus, sys, "nodeA")
        facts = PSY.FACTSControlDevice(;
            name = "facts_ci_acr",
            available = true,
            bus = bus,
            control_mode = control_mode,
            voltage_setpoint = 1.0,
            max_shunt_current = 100.0,
        )
        PSY.add_component!(sys, facts)
        template = get_thermal_dispatch_template_network(NetworkModel(ACRNetworkModel))
        set_device_model!(template, PSY.FACTSControlDevice, ShuntSusceptanceDispatch)
        model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        return IOM.get_optimization_container(model)
    end

    c_nml = _facts_acr_container_for_mode(PSY.FACTSOperationModes.NML)
    c_free = _facts_acr_container_for_mode(nothing)

    # The always-present RegulatedVoltageMagnitude var + its defining constraint must
    # appear in both containers with identical sizes (only the JuMP.fix differs).
    var_nml = IOM.get_variables(c_nml)
    var_free = IOM.get_variables(c_free)
    @test any(k -> occursin("RegulatedVoltageMagnitude", string(k)), keys(var_nml))
    @test Set(keys(var_nml)) == Set(keys(var_free))
    for k in keys(var_nml)
        @test size(var_nml[k]) == size(var_free[k])
    end

    con_nml = IOM.get_constraints(c_nml)
    con_free = IOM.get_constraints(c_free)
    @test any(
        k -> occursin("RegulatedVoltageMagnitudeConstraint", string(k)),
        keys(con_nml),
    )
    @test Set(keys(con_nml)) == Set(keys(con_free))
    for k in keys(con_nml)
        @test size(con_nml[k]) == size(con_free[k])
    end
end

@testset "SwitchedAdmittance mixed-sign blocks: separate cap/inductive accounting" begin
    # A device whose blocks mix capacitive (+imag) and inductive (-imag) increments:
    # the bounds must sum increase and decrease separately, not net them into one span
    # (which collapses to [0,0] here).
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    bus = first(PSY.get_components(PSY.ACBus, sys))
    sa_mixed = PSY.SwitchedAdmittance(;
        name = "sa_mixed_test",
        available = true,
        bus = bus,
        Y = 0.0 + 0.0im,
        number_of_steps = [2, 2],
        Y_increase = [0.0 + 0.1im, 0.0 - 0.1im],
    )

    lim = POM._shunt_susceptance_limits(sa_mixed)
    @test isapprox(lim.min, -0.2; atol = 1e-10)
    @test isapprox(lim.max, 0.2; atol = 1e-10)
    @test lim.min < lim.max

    # Build + solve to confirm the optimizer sees a non-degenerate b variable.
    PSY.add_component!(sys, sa_mixed)
    template = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    set_device_model!(template, PSY.SwitchedAdmittance, ShuntSusceptanceDispatch)
    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED

    # Variable must be bounded and have strictly non-degenerate bounds.
    @test check_variable_bounded(model, ShuntSusceptanceVariable, PSY.SwitchedAdmittance)
    cont = IOM.get_optimization_container(model)
    var_arr = IOM.get_variable(cont, ShuntSusceptanceVariable, PSY.SwitchedAdmittance)
    for v in var_arr
        @test JuMP.lower_bound(v) < JuMP.upper_bound(v)
    end
end

@testset "ShuntSusceptanceDispatch construct_device! resolves only for shunt devices" begin
    for stage in (IOM.ArgumentConstructStage, IOM.ModelConstructStage)
        for D in (PSY.SwitchedAdmittance, PSY.FACTSControlDevice)
            m = which(
                POM.construct_device!,
                Tuple{
                    IOM.OptimizationContainer,
                    PSY.System,
                    stage,
                    IOM.DeviceModel{D, ShuntSusceptanceDispatch},
                    IOM.NetworkModel{ACPNetworkModel},
                },
            )
            @test basename(string(m.file)) == "shunt_constructor.jl"
        end
        # Non-shunt devices must fall through to the error fallback in
        # core/interfaces.jl — susceptance dispatch is meaningless for them.
        for D in (PSY.FixedAdmittance, PSY.ThermalStandard, PSY.PowerLoad)
            m = which(
                POM.construct_device!,
                Tuple{
                    IOM.OptimizationContainer,
                    PSY.System,
                    stage,
                    IOM.DeviceModel{D, ShuntSusceptanceDispatch},
                    IOM.NetworkModel{ACPNetworkModel},
                },
            )
            @test basename(string(m.file)) == "interfaces.jl"
        end
    end
end

@testset "ShuntSusceptanceDispatch @info-drop under DCPNetworkModel" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")

    bus = first(PSY.get_components(PSY.ACBus, sys))
    sa = PSY.SwitchedAdmittance(;
        name = "shunt_dc_test",
        available = true,
        bus = bus,
        Y = 0.0 + 0.1im,
        number_of_steps = [1],
        Y_increase = [0.0 + 0.1im],
    )
    PSY.add_component!(sys, sa)

    template = get_thermal_dispatch_template_network(NetworkModel(DCPNetworkModel))
    set_device_model!(template, PSY.SwitchedAdmittance, ShuntSusceptanceDispatch)

    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    output_dir = mktempdir(; cleanup = true)
    @test build!(model; output_dir = output_dir) == IOM.ModelBuildStatus.BUILT

    # The shunt device model should have been dropped from the template since
    # DCPNetworkModel has no reactive power balance.
    @test !haskey(get_device_models(get_template(model)), :SwitchedAdmittance)
end

@testset "FixedShuntAdmittance builds the fixed Q-V layer on LPACC (SwitchedAdmittance)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    bus = PSY.get_component(PSY.ACBus, sys, "nodeA")
    sa = PSY.SwitchedAdmittance(;
        name = "shunt_lpacc", available = true, bus = bus, Y = 0.0 + 0.1im,
        number_of_steps = [2], Y_increase = [0.0 + 0.1im],
    )
    PSY.add_component!(sys, sa)
    b_nominal = imag(PSY.get_Y(sa))

    template = get_thermal_dispatch_template_network(NetworkModel(LPACCNetworkModel))
    set_device_model!(template, PSY.SwitchedAdmittance, FixedShuntAdmittance)
    model = DecisionModel(
        template, sys; optimizer = ipopt_optimizer, store_variable_names = true,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(model)
    q = IOM.get_variable(container, ReactivePowerVariable, PSY.SwitchedAdmittance)
    phi = IOM.get_variable(container, POM.VoltageDeviation, PSY.ACBus)
    q_expr = IOM.get_expression(container, POM.ReactivePowerBalance, PSY.ACBus)
    cons = IOM.get_constraint(
        container, POM.ShuntReactivePowerConstraint, PSY.SwitchedAdmittance,
    )
    @test length(cons) > 0
    bus_no = PSY.get_number(bus)
    bus_name = PSY.get_name(bus)
    for t in IOM.get_time_steps(container)
        # The shunt reactive injection enters the bus reactive balance with +1.
        @test JuMP.coefficient(q_expr[bus_no, t], q["shunt_lpacc", t]) == 1.0
        # q == b_nominal*(1 + 2phi) canonicalizes to q - 2*b_nominal*phi == b_nominal, with
        # b_nominal a constant (no susceptance variable, so phi is linear not bilinear).
        f = JuMP.constraint_object(cons["shunt_lpacc", t]).func
        @test JuMP.coefficient(f, q["shunt_lpacc", t]) == 1.0
        @test isapprox(
            JuMP.coefficient(f, phi[bus_name, t]),
            -2.0 * b_nominal;
            atol = 1e-12,
        )
        @test isapprox(JuMP.normalized_rhs(cons["shunt_lpacc", t]), b_nominal; atol = 1e-12)
    end

    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "FixedShuntAdmittance builds+solves on LPACC (FACTS)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    bus = PSY.get_component(PSY.ACBus, sys, "nodeA")
    facts = PSY.FACTSControlDevice(;
        name = "facts_lpacc_fixed", available = true, bus = bus,
        control_mode = PSY.FACTSOperationModes.NML, voltage_setpoint = 1.0,
        max_shunt_current = 100.0,
    )
    PSY.set_reactive_power_required!(facts, 10.0)
    PSY.add_component!(sys, facts)
    b_nominal = PSY.get_reactive_power_required(facts) / PSY.get_base_power(facts)

    template = get_thermal_dispatch_template_network(NetworkModel(LPACCNetworkModel))
    set_device_model!(template, PSY.FACTSControlDevice, FixedShuntAdmittance)
    model = DecisionModel(
        template, sys; optimizer = ipopt_optimizer, store_variable_names = true,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(model)
    q = IOM.get_variable(container, ReactivePowerVariable, PSY.FACTSControlDevice)
    phi = IOM.get_variable(container, POM.VoltageDeviation, PSY.ACBus)
    cons = IOM.get_constraint(
        container, POM.ShuntReactivePowerConstraint, PSY.FACTSControlDevice,
    )
    @test length(cons) > 0
    bus_name = PSY.get_name(bus)
    for t in IOM.get_time_steps(container)
        f = JuMP.constraint_object(cons["facts_lpacc_fixed", t]).func
        @test JuMP.coefficient(f, q["facts_lpacc_fixed", t]) == 1.0
        @test isapprox(
            JuMP.coefficient(f, phi[bus_name, t]),
            -2.0 * b_nominal;
            atol = 1e-12,
        )
        @test isapprox(
            JuMP.normalized_rhs(cons["facts_lpacc_fixed", t]),
            b_nominal;
            atol = 1e-12,
        )
    end

    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "FixedShuntAdmittance builds+solves on ACPNetworkModel (SwitchedAdmittance)" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    bus = PSY.get_component(PSY.ACBus, sys, "nodeA")
    sa = PSY.SwitchedAdmittance(;
        name = "shunt_acp_fixed", available = true, bus = bus, Y = 0.0 + 0.1im,
        number_of_steps = [2], Y_increase = [0.0 + 0.1im],
    )
    PSY.add_component!(sys, sa)
    b_nominal = imag(PSY.get_Y(sa))

    template = get_thermal_dispatch_template_network(NetworkModel(ACPNetworkModel))
    set_device_model!(template, PSY.SwitchedAdmittance, FixedShuntAdmittance)
    model = DecisionModel(
        template, sys; optimizer = ipopt_optimizer, store_variable_names = true,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    container = IOM.get_optimization_container(model)
    q = IOM.get_variable(container, ReactivePowerVariable, PSY.SwitchedAdmittance)
    vm = IOM.get_variable(container, VoltageMagnitude, PSY.ACBus)
    cons = IOM.get_constraint(
        container, POM.ShuntReactivePowerConstraint, PSY.SwitchedAdmittance,
    )
    @test length(cons) > 0
    bus_name = PSY.get_name(bus)
    for t in IOM.get_time_steps(container)
        # q == b_nominal*vm^2: the quadratic voltage term carries -b_nominal.
        f = JuMP.constraint_object(cons["shunt_acp_fixed", t]).func
        @test JuMP.coefficient(f, q["shunt_acp_fixed", t]) == 1.0
        @test isapprox(
            JuMP.coefficient(f, vm[bus_name, t], vm[bus_name, t]), -b_nominal; atol = 1e-12,
        )
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end
