_var(model, T, D) = IOM.get_variable(IOM.get_optimization_container(model), T, D)
_mult(model, T, D) =
    IOM.get_parameter_multiplier_array(IOM.get_optimization_container(model), T, D)
_renewable_limit_rows(model) = IOM.get_constraint(
    IOM.get_optimization_container(model),
    IOM.ConstraintKey(
        ActivePowerVariableTimeSeriesLimitsConstraint,
        PSY.RenewableDispatch,
        "ub",
    ),
)

function _renewable_template()
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, ThermalStandard, ThermalBasicDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    return template
end

# c_sys5_bat with one wind unit out at `steps`; the wind units share one series.
function _sys_with_renewable_out(steps)
    sys = PSB.build_system(PSITestSystems, "c_sys5_bat"; add_forecasts = true)
    units = _sorted(PSY.RenewableDispatch, sys)
    unit = first(units)
    forecast = PSY.get_time_series(PSY.Deterministic, unit, "max_active_power")
    for u in units
        PSY.remove_time_series!(sys, PSY.Deterministic, u, "max_active_power")
    end
    PSY.add_time_series!(sys, units, forecast)
    _schedule_outage!(sys, unit, "out", _out_at(steps))
    return sys, unit
end

# Steps at which the shared wind series is positive, so an outage there changes its limit.
const _WINDY_STEPS = 12:14

@testset "An out renewable is fixed and its series limit is zero at its out steps" begin
    sys, unit = _sys_with_renewable_out(_WINDY_STEPS)
    name = PSY.get_name(unit)
    model = _built_model(_renewable_template(), sys)
    container = IOM.get_optimization_container(model)
    p = _var(model, ActivePowerVariable, PSY.RenewableDispatch)
    param =
        IOM.get_parameter(container, ActivePowerTimeSeriesParameter, PSY.RenewableDispatch)
    mult = IOM.get_multiplier_array(param)
    shared = IOM.get_parameter_column_refs(param, name)
    @test all(
        IOM.get_parameter_column_refs(param, PSY.get_name(other)) == shared for
        other in _sorted(PSY.RenewableDispatch, sys)
    )
    limit = _renewable_limit_rows(model)
    @test all(t -> shared[t] > 0.0, _WINDY_STEPS)
    for t in IOM.get_time_steps(container)
        out = t in _WINDY_STEPS
        @test _fixed_at_zero(p[name, t]) == out
        @test mult[name, t] == PSY.get_max_active_power(unit, u"SU")
        @test JuMP.normalized_rhs(limit[name, t]) ≈ (out ? 0.0 : mult[name, t] * shared[t])
        for other in _sorted(PSY.RenewableDispatch, sys)
            other == unit && continue
            n = PSY.get_name(other)
            @test JuMP.normalized_rhs(limit[n, t]) ≈ mult[n, t] * shared[t]
            @test !JuMP.is_fixed(p[n, t])
        end
    end
end

_nodal_constant(model, bus, t) = JuMP.constant(
    IOM.get_expression(
        IOM.get_optimization_container(model),
        POM.ActivePowerBalance,
        PSY.ACBus,
    )[
        bus,
        t,
    ],
)

@testset "An out load leaves the nodal balance at its out steps" begin
    sys = _c_sys5_uc()
    load = first(_sorted(PSY.PowerLoad, sys))
    name = PSY.get_name(load)
    _schedule_outage!(sys, load, "out", _out_at(3:5))
    model = _ptdf_model(sys)
    ref = _ptdf_model(_c_sys5_uc())
    bus = PSY.get_number(PSY.get_bus(load))
    ref_container = IOM.get_optimization_container(ref)
    param = IOM.get_parameter(ref_container, ActivePowerTimeSeriesParameter, PSY.PowerLoad)
    refs = IOM.get_parameter_column_refs(param, name)
    ref_mult = IOM.get_multiplier_array(param)
    for t in IOM.get_time_steps(ref_container)
        demand = ref_mult[name, t] * refs[t]
        @test demand != 0.0
        shift = t in 3:5 ? -demand : 0.0
        @test isapprox(
            _nodal_constant(model, bus, t),
            _nodal_constant(ref, bus, t) + shift;
            atol = 1e-9,
        )
    end
end

function _basic_uc_template()
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    return template
end

# Initially online and committed through step 3 because it is the cheapest unit.
const _UC_UNIT = "Brighton"

@testset "A committed unit that goes out shuts down" begin
    sys = _c_sys5_uc()
    unit = PSY.get_component(PSY.ThermalStandard, sys, _UC_UNIT)
    @test POM.is_online(unit)
    _schedule_outage!(sys, unit, "out", _out_at(4:6))
    model = _built_model(_basic_uc_template(), sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    on = _var(model, OnVariable, PSY.ThermalStandard)
    p = _var(model, ActivePowerVariable, PSY.ThermalStandard)
    start = _var(model, StartVariable, PSY.ThermalStandard)
    stop = _var(model, StopVariable, PSY.ThermalStandard)
    for t in 4:6
        @test _fixed_at_zero(on[_UC_UNIT, t])
        @test _fixed_at_zero(p[_UC_UNIT, t])
        @test JuMP.value(on[_UC_UNIT, t]) == 0.0
        @test JuMP.value(p[_UC_UNIT, t]) == 0.0
    end
    @test JuMP.value(on[_UC_UNIT, 3]) ≈ 1.0
    @test JuMP.value(stop[_UC_UNIT, 4]) ≈ 1.0
    for t in IOM.get_time_steps(IOM.get_optimization_container(model))
        @test !JuMP.is_fixed(start[_UC_UNIT, t])
        @test !JuMP.is_fixed(stop[_UC_UNIT, t])
    end
end

@testset "An out unit provides no reserve at its out steps" begin
    sys = PSB.build_system(
        PSITestSystems,
        "c_sys5_uc";
        add_forecasts = true,
        add_reserves = true,
    )
    unit = PSY.get_component(PSY.ThermalStandard, sys, _UC_UNIT)
    _schedule_outage!(sys, unit, "out", _out_at(4:6))
    template = _basic_uc_template()
    set_service_model!(template, ServiceModel(OnlineReserve{ReserveUp}, RangeReserve))
    model = _built_model(template, sys)
    container = IOM.get_optimization_container(model)
    key = IOM.ComponentPairKey{PSY.ThermalStandard, OnlineReserve{ReserveUp}}
    reserve = IOM.get_variable(container, ActivePowerReserveVariable, key)
    entries = [(index, v) for (index, v) in reserve.data if index[2] == _UC_UNIT]
    @test !isempty(entries)
    for (index, v) in entries
        @test _fixed_at_zero(v) == (last(index) in 4:6)
    end
end

# Both power limits have a positive minimum, so the reservation rows bound the charge or the
# discharge from below at every step the unit is in service.
function _sys_with_storage_minimums(; out = true)
    sys = PSB.build_system(PSITestSystems, "c_sys5_bat"; add_forecasts = true)
    battery = only(PSY.get_components(PSY.EnergyReservoirStorage, sys))
    input = PSY.get_input_active_power_limits(battery, u"SU")
    output = PSY.get_output_active_power_limits(battery, u"SU")
    PSY.set_input_active_power_limits!(
        battery,
        (min = 0.1 * u"SU", max = input.max * u"SU"),
    )
    PSY.set_output_active_power_limits!(
        battery,
        (min = 0.1 * u"SU", max = output.max * u"SU"),
    )
    out && _schedule_outage!(sys, battery, "out", _out_at(3:5))
    return sys, battery
end

@testset "An out storage unit with minimum charge and discharge power is off" begin
    template = _renewable_template()
    set_device_model!(
        template,
        DeviceModel(EnergyReservoirStorage, StorageDispatchWithReserves),
    )
    ref_sys, _ = _sys_with_storage_minimums(; out = false)
    @test solve!(_built_model(template, ref_sys)) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    sys, battery = _sys_with_storage_minimums()
    name = PSY.get_name(battery)
    model = _built_model(template, sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    p_in = _var(model, ActivePowerInVariable, PSY.EnergyReservoirStorage)
    p_out = _var(model, ActivePowerOutVariable, PSY.EnergyReservoirStorage)
    for t in 3:5
        @test JuMP.value(p_in[name, t]) == 0.0
        @test JuMP.value(p_out[name, t]) == 0.0
    end
end

@testset "An out storage unit keeps its energy" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_bat"; add_forecasts = true)
    battery = only(PSY.get_components(PSY.EnergyReservoirStorage, sys))
    name = PSY.get_name(battery)
    _schedule_outage!(sys, battery, "out", _out_at(3:5))
    template = _renewable_template()
    set_device_model!(
        template,
        DeviceModel(EnergyReservoirStorage, StorageDispatchWithReserves),
    )
    model = _built_model(template, sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    p_in = _var(model, ActivePowerInVariable, PSY.EnergyReservoirStorage)
    p_out = _var(model, ActivePowerOutVariable, PSY.EnergyReservoirStorage)
    energy = _var(model, EnergyVariable, PSY.EnergyReservoirStorage)
    for t in 3:5
        @test _fixed_at_zero(p_in[name, t])
        @test _fixed_at_zero(p_out[name, t])
    end
    for t in IOM.get_time_steps(IOM.get_optimization_container(model))
        @test !JuMP.is_fixed(energy[name, t])
    end
    @test isapprox(JuMP.value(energy[name, 5]), JuMP.value(energy[name, 2]); atol = 1e-6)
end

function _hydro_template()
    template = get_thermal_dispatch_template_network(CopperPlateNetworkModel)
    set_device_model!(template, HydroTurbine, HydroTurbineEnergyDispatch)
    set_device_model!(template, HydroReservoir, HydroEnergyModelReservoir)
    return template
end

_hydro_sys() =
    PSB.build_system(PSITestSystems, "c_sys5_hy_turbine_energy"; add_forecasts = true)

@testset "An out hydro turbine leaves the reservoir inflow untouched" begin
    sys = _hydro_sys()
    turbine = only(PSY.get_components(PSY.HydroTurbine, sys))
    _schedule_outage!(sys, turbine, "out", _out_at(3:5))
    model = _built_model(_hydro_template(), sys)
    ref = _built_model(_hydro_template(), _hydro_sys())
    inflow = _mult(model, InflowTimeSeriesParameter, PSY.HydroReservoir)
    ref_inflow = _mult(ref, InflowTimeSeriesParameter, PSY.HydroReservoir)
    @test axes(inflow) == axes(ref_inflow)
    @test inflow.data == ref_inflow.data
    @test any(!=(0.0), inflow.data)
    p = _var(model, ActivePowerVariable, PSY.HydroTurbine)
    @test all(_fixed_at_zero(p[PSY.get_name(turbine), t]) for t in 3:5)
end

@testset "A rebuild with the unit back in service restores it" begin
    sys, unit = _sys_with_renewable_out(_WINDY_STEPS)
    name = PSY.get_name(unit)
    model = _built_model(_renewable_template(), sys)
    container = IOM.get_optimization_container(model)
    status =
        IOM.get_parameter_array(
            container,
            POM.InjectorStatusParameter,
            PSY.RenewableDispatch,
        )
    status[name, :] .= 1.0
    _rebuild!(model, sys)
    mult = _mult(model, ActivePowerTimeSeriesParameter, PSY.RenewableDispatch)
    param =
        IOM.get_parameter(container, ActivePowerTimeSeriesParameter, PSY.RenewableDispatch)
    refs = IOM.get_parameter_column_refs(param, name)
    limit = _renewable_limit_rows(model)
    @test all(
        JuMP.normalized_rhs(limit[name, t]) ≈ mult[name, t] * refs[t] for
        t in IOM.get_time_steps(container)
    )
    @test all(t -> refs[t] > 0.0, _WINDY_STEPS)
    @test !any(JuMP.is_fixed, JuMP.all_variables(IOM.get_jump_model(container)))
end

# Σ over the system rows of the `ActivePowerBalance` constant at step `t`.
_system_constant(model, t) = sum(
    JuMP.constant(e) for e in IOM.get_expression(
        IOM.get_optimization_container(model),
        POM.ActivePowerBalance,
        PSY.System,
    )[
        :,
        t,
    ]
)

function _check_constant_shift(model, ref, shift_at; bus = nothing)
    for t in IOM.get_time_steps(IOM.get_optimization_container(model))
        shift = shift_at(t)
        @test isapprox(
            _system_constant(model, t),
            _system_constant(ref, t) + shift;
            atol = 1e-9,
        )
        isnothing(bus) && continue
        @test isapprox(
            _nodal_constant(model, bus, t),
            _nodal_constant(ref, bus, t) + shift;
            atol = 1e-9,
        )
    end
    return
end

function _sys_with_motor_load()
    sys = _c_sys5_uc()
    load = PSY.get_component(PSY.PowerLoad, sys, "Bus2")
    motor = PSY.MotorLoad(;
        name = "motor",
        available = true,
        bus = load.bus,
        active_power = load.active_power / 10.0,
        reactive_power = load.reactive_power / 10.0,
        base_power = load.base_power,
        rating = load.max_active_power / 10.0,
        max_active_power = load.max_active_power / 10.0,
        reactive_power_limits = nothing,
        input_basis = u"CU",
    )
    PSY.add_component!(sys, motor)
    return sys
end

@testset "An out motor load leaves the balance at its out steps on $(net)" for net in
                                                                               (
    CopperPlateNetworkModel,
    PTDFNetworkModel,
)
    template() = begin
        t = get_thermal_dispatch_template_network(NetworkModel(net))
        set_device_model!(t, MotorLoad, StaticPowerLoad)
        t
    end
    sys = _sys_with_motor_load()
    motor = PSY.get_component(PSY.MotorLoad, sys, "motor")
    _schedule_outage!(sys, motor, "out", _out_at(3:5))
    model = _built_model(template(), sys)
    ref = _built_model(template(), _sys_with_motor_load())
    power = PSY.get_active_power(motor, u"SU")
    @test power > 0.0
    bus = net == PTDFNetworkModel ? PSY.get_number(PSY.get_bus(motor)) : nothing
    _check_constant_shift(model, ref, t -> t in 3:5 ? power : 0.0; bus = bus)
end

# c_sys5_uc with the `Bus2` load's demand series removed, so it falls back to its static
# demand.
function _sys_with_static_load()
    sys = _c_sys5_uc()
    load = PSY.get_component(PSY.PowerLoad, sys, "Bus2")
    PSY.remove_time_series!(sys, PSY.Deterministic, load, "max_active_power")
    return sys
end

@testset "An out load without a series leaves the balance at its out steps on $(net)" for net in
                                                                                          (
    CopperPlateNetworkModel,
    PTDFNetworkModel,
)
    template() = get_thermal_dispatch_template_network(NetworkModel(net))
    sys = _sys_with_static_load()
    load = PSY.get_component(PSY.PowerLoad, sys, "Bus2")
    _schedule_outage!(sys, load, "out", _out_at(3:5))
    model = _built_model(template(), sys)
    ref = _built_model(template(), _sys_with_static_load())
    demand = PSY.get_max_active_power(load, u"SU")
    @test demand > 0.0
    bus = net == PTDFNetworkModel ? PSY.get_number(PSY.get_bus(load)) : nothing
    _check_constant_shift(model, ref, t -> t in 3:5 ? demand : 0.0; bus = bus)
end

const _MUST_RUN_UNIT = "Sundance"

function _sys_with_must_run(; out = true)
    sys = _c_sys5_uc()
    unit = PSY.get_component(PSY.ThermalStandard, sys, _MUST_RUN_UNIT)
    PSY.set_commitment_mode!(unit, PSY.CommitmentModes.MUST_RUN)
    out && _schedule_outage!(sys, unit, "out", _out_at(4:6))
    return sys, unit
end

function _uc_template(formulation)
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, ThermalStandard, formulation)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    return template
end

@testset "An out must-run unit is off at its out steps under $(formulation)" for formulation in
                                                                                 (
    ThermalBasicUnitCommitment,
    ThermalCompactUnitCommitment,
)
    sys, unit = _sys_with_must_run()
    model = _built_model(_uc_template(formulation), sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    ref_sys, _ = _sys_with_must_run(; out = false)
    ref = _built_model(_uc_template(formulation), ref_sys)
    p_min = PSY.get_active_power_limits(unit, u"SU").min
    # The compact formulation carries a must-run unit's p_min as a balance constant.
    pmin_constant = formulation == ThermalCompactUnitCommitment ? p_min : 0.0
    _check_constant_shift(model, ref, t -> t in 4:6 ? -pmin_constant : 0.0)
    outputs = IOM.OptimizationProblemOutputs(model)
    base_power = IOM.get_model_base_power(outputs)
    power = if formulation == ThermalCompactUnitCommitment
        read_aux_variable(
            outputs,
            "PowerOutput__ThermalStandard";
            table_format = TableFormat.WIDE,
        )
    else
        read_variable(
            outputs,
            "ActivePowerVariable__ThermalStandard";
            table_format = TableFormat.WIDE,
        )
    end
    output = power[!, _MUST_RUN_UNIT] ./ base_power
    for t in eachindex(output)
        if t in 4:6
            @test isapprox(output[t], 0.0; atol = 1e-6)
        else
            @test output[t] >= p_min - 1e-6
        end
    end
end

@testset "A must-run unit's time on and off follow its outage under $(formulation)" for formulation in
                                                                                        (
    ThermalBasicUnitCommitment,
    ThermalCompactUnitCommitment,
)
    durations(model) = (
        on = read_aux_variable(
            IOM.OptimizationProblemOutputs(model),
            "TimeDurationOn__ThermalStandard";
            table_format = TableFormat.WIDE,
        )[
            !,
            _MUST_RUN_UNIT,
        ],
        off = read_aux_variable(
            IOM.OptimizationProblemOutputs(model),
            "TimeDurationOff__ThermalStandard";
            table_format = TableFormat.WIDE,
        )[
            !,
            _MUST_RUN_UNIT,
        ],
    )
    sys, _ = _sys_with_must_run()
    model = _built_model(_uc_template(formulation), sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    n = _n_steps(model)
    expected_on = Float64[t < 4 ? t : (t <= 6 ? 0 : t - 6) for t in 1:n]
    expected_off = Float64[t in 4:6 ? t - 3 : 0 for t in 1:n]
    @test durations(model).on == expected_on
    @test durations(model).off == expected_off

    ref_sys, _ = _sys_with_must_run(; out = false)
    ref = _built_model(_uc_template(formulation), ref_sys)
    @test solve!(ref) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test durations(ref).on == collect(1.0:n)
    @test durations(ref).off == zeros(n)
end

@testset "Time duration counting does not allocate per step" begin
    sys, _ = _sys_with_must_run()
    model = _built_model(_uc_template(ThermalBasicUnitCommitment), sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    container = IOM.get_optimization_container(model)
    durations = IOM.get_aux_variable(container, TimeDurationOn, PSY.ThermalStandard)
    time_steps = IOM.get_time_steps(container)
    committed = IOM.lookup_value(container, OnVariable, PSY.ThermalStandard)["Alta", :]
    must_run = ones(length(time_steps))
    for (name, on) in (("Alta", committed), (_MUST_RUN_UNIT, must_run))
        POM._count_durations!(durations, name, on, time_steps, 0.0, true)
        @test (@allocated POM._count_durations!(
            durations,
            name,
            on,
            time_steps,
            0.0,
            true,
        )) ==
              0
    end
end

@testset "An outage that respects min up time and ramps solves under ThermalStandardUnitCommitment" begin
    sys = _c_sys5_uc()
    unit = PSY.get_component(PSY.ThermalStandard, sys, _MUST_RUN_UNIT)
    @test !POM.is_online(unit)
    _schedule_outage!(sys, unit, "out", _out_at(4:6))
    model = _built_model(_uc_template(ThermalStandardUnitCommitment), sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    on = _var(model, OnVariable, PSY.ThermalStandard)
    p = _var(model, ActivePowerVariable, PSY.ThermalStandard)
    for t in 4:6
        @test _fixed_at_zero(on[_MUST_RUN_UNIT, t])
        @test JuMP.value(on[_MUST_RUN_UNIT, t]) == 0.0
        @test JuMP.value(p[_MUST_RUN_UNIT, t]) == 0.0
    end
end

# Its minimum is positive and the other units can cover its output.
const _DISPATCH_UNIT = "Brighton"

# Ramp rows stay in the model, so every unit gets a ramp rate that covers its whole range in
# one step: the unit can drop to zero and the others can pick up its output. Slower ramps
# would make the outage infeasible by design.
function _sys_with_dispatch_unit(; out = true)
    sys = _c_sys5_uc()
    for g in PSY.get_components(PSY.ThermalStandard, sys)
        ramp = PSY.get_active_power_limits(g, u"SU").max
        PSY.set_ramp_limits!(g, (up = ramp * u"SU/minute", down = ramp * u"SU/minute"))
    end
    unit = PSY.get_component(PSY.ThermalStandard, sys, _DISPATCH_UNIT)
    out && _schedule_outage!(sys, unit, "out", _out_at(4:6))
    return sys, unit
end

function _dispatch_template(formulation, net)
    template = PowerOperationsProblemTemplate(NetworkModel(net))
    set_device_model!(template, ThermalStandard, formulation)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, Line, StaticBranchUnbounded)
    set_device_model!(template, TwoWindingTransformer, StaticBranchUnbounded)
    return template
end

@testset "An out unit with a minimum is off under $(formulation) on $(net)" for formulation in
                                                                                (
        ThermalBasicDispatch,
        ThermalCompactDispatch,
    ),
    net in (CopperPlateNetworkModel, PTDFNetworkModel)

    sys, unit = _sys_with_dispatch_unit()
    p_min = PSY.get_active_power_limits(unit, u"SU").min
    @test p_min > 0.0
    @test POM.is_online(unit)
    model = _built_model(_dispatch_template(formulation, net), sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    ref_sys, _ = _sys_with_dispatch_unit(; out = false)
    ref = _built_model(_dispatch_template(formulation, net), ref_sys)
    # The compact formulation carries a committed unit's p_min as a balance constant.
    pmin_constant = formulation == ThermalCompactDispatch ? p_min : 0.0
    bus = net == PTDFNetworkModel ? PSY.get_number(PSY.get_bus(unit)) : nothing
    _check_constant_shift(model, ref, t -> t in 4:6 ? -pmin_constant : 0.0; bus = bus)
    outputs = IOM.OptimizationProblemOutputs(model)
    base_power = IOM.get_model_base_power(outputs)
    power = if formulation == ThermalCompactDispatch
        read_aux_variable(
            outputs,
            "PowerOutput__ThermalStandard";
            table_format = TableFormat.WIDE,
        )
    else
        read_variable(
            outputs,
            "ActivePowerVariable__ThermalStandard";
            table_format = TableFormat.WIDE,
        )
    end
    output = power[!, _DISPATCH_UNIT] ./ base_power
    for t in eachindex(output)
        if t in 4:6
            @test isapprox(output[t], 0.0; atol = 1e-6)
        else
            @test output[t] >= p_min - 1e-6
        end
    end
end

# Feedforwards carry an upstream model's values, which an outage scheduled only in this
# model's system does not change. Every feedforward row that bounds or fixes a variable the
# outage fixes to zero is scaled by the unit's status.
function _feedforward_template(formulation, feedforwards...)
    template = PowerOperationsProblemTemplate(NetworkModel(CopperPlateNetworkModel))
    device_model = DeviceModel(ThermalStandard, formulation)
    for ff in feedforwards
        attach_feedforward!(device_model, ff)
    end
    set_device_model!(template, device_model)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    return template
end

_ff_constraint(model, T, meta) =
    IOM.get_constraint(_container(model), IOM.ConstraintKey(T, PSY.ThermalStandard, meta))

_semicontinuous(variable) = SemiContinuousFeedforward(;
    component_type = ThermalStandard,
    source = OnVariable,
    affected_values = [variable],
)

# Without a recurrent build the parameters are numbers, so a row `p >= value` has `value` as
# its right-hand side. The commitment parameters start from the units' statuses; every unit is
# online, as in a dispatch without feedforward, so only the outage can take the unit off.
# Each row is the meta of a semi-continuous row and the multiplier of the commitment in it.
# The compact formulation carries the minimum in the balance, so its lower-bound row has no
# commitment term and is not checked.
@testset "A semi-continuous feedforward does not hold an out unit at its minimum under $(formulation)" for (
    formulation,
    variable,
    rows,
) in (
    (
        ThermalBasicDispatch,
        ActivePowerVariable,
        (("ActivePowerVariable_lb", l -> l.min), ("ActivePowerVariable_ub", l -> l.max)),
    ),
    (
        ThermalCompactDispatch,
        PowerAboveMinimumVariable,
        (("PowerAboveMinimumVariable_ub", l -> l.max - l.min),),
    ),
)
    sys, unit = _sys_with_dispatch_unit()
    for g in PSY.get_components(PSY.ThermalStandard, sys)
        PSY.set_status!(g, PSY.OperationalStates.ONLINE)
    end
    limits = PSY.get_active_power_limits(unit, u"SU")
    model = _built_model(_feedforward_template(formulation, _semicontinuous(variable)), sys)
    on = IOM.get_parameter_array(_container(model), OnStatusParameter, ThermalStandard)
    @test all(isone, on)
    for (meta, limit) in rows
        con = _ff_constraint(model, FeedforwardSemiContinuousConstraint, meta)
        @test limit(limits) > 0.0
        for t in axes(con, 2)
            status = t in 4:6 ? 0.0 : 1.0
            @test JuMP.normalized_rhs(con[_DISPATCH_UNIT, t]) ≈
                  limit(limits) * on[_DISPATCH_UNIT, t] * status
        end
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    power = IOM.get_variable(_container(model), variable, ThermalStandard)
    for t in 4:6
        @test JuMP.value(power[_DISPATCH_UNIT, t]) == 0.0
    end
end

# A semi-continuous feedforward on a variable other than the scheduled power bounds it by the
# variable's own limits times the commitment; an out unit's rows read zero.
@testset "A semi-continuous feedforward on reactive power bounds an out unit by zero" begin
    sys, unit = _sys_with_dispatch_unit()
    template = PowerOperationsProblemTemplate(NetworkModel(ACPNetworkModel))
    device_model = DeviceModel(ThermalStandard, ThermalBasicDispatch)
    attach_feedforward!(device_model, _semicontinuous(ReactivePowerVariable))
    set_device_model!(template, device_model)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, Line, StaticBranchUnbounded)
    set_device_model!(template, TwoWindingTransformer, StaticBranchUnbounded)
    model = DecisionModel(template, sys; optimizer = ipopt_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    on = IOM.get_parameter_array(_container(model), OnStatusParameter, ThermalStandard)
    limits = PSY.get_reactive_power_limits(unit, u"SU")
    @test limits.min < 0.0 < limits.max
    for (meta, limit) in (("ReactivePowerVariable_lb", limits.min),
        ("ReactivePowerVariable_ub", limits.max))
        con = _ff_constraint(model, FeedforwardSemiContinuousConstraint, meta)
        @test on[_DISPATCH_UNIT, 1] != 0.0
        for t in axes(con, 2)
            status = t in 4:6 ? 0.0 : 1.0
            @test JuMP.normalized_rhs(con[_DISPATCH_UNIT, t]) ≈
                  limit * on[_DISPATCH_UNIT, t] * status
        end
    end
end

@testset "The $(nameof(typeof(ff))) row on an out unit is zero" for (ff, P, T, meta) in (
    (
        LowerBoundFeedforward(;
            component_type = ThermalStandard,
            source = ActivePowerVariable,
            affected_values = [ActivePowerVariable],
        ),
        LowerBoundValueParameter,
        FeedforwardLowerBoundConstraint,
        "ActivePowerVariablelb",
    ),
    (
        UpperBoundFeedforward(;
            component_type = ThermalStandard,
            source = ActivePowerVariable,
            affected_values = [ActivePowerVariable],
        ),
        UpperBoundValueParameter,
        FeedforwardUpperBoundConstraint,
        "ActivePowerVariableub",
    ),
    (
        FixValueFeedforward(;
            component_type = ThermalStandard,
            source = ActivePowerVariable,
            affected_values = [ActivePowerVariable],
        ),
        FixValueParameter,
        FeedforwardFixValueConstraint,
        "ActivePowerVariable",
    ),
)
    sys, _ = _sys_with_dispatch_unit()
    model = _built_model(_feedforward_template(ThermalBasicDispatch, ff), sys)
    param_meta = P == FixValueParameter ? "ActivePowerVariable" : ""
    param = IOM.get_parameter_array(_container(model), P, ThermalStandard, param_meta)
    mult = IOM.get_parameter_multiplier_array(_container(model), P, ThermalStandard,
        param_meta)
    con = _ff_constraint(model, T, meta)
    for name in axes(con, 1), t in axes(con, 2)
        status = (name == _DISPATCH_UNIT && t in 4:6) ? 0.0 : 1.0
        @test JuMP.normalized_rhs(con[name, t]) ≈ param[name, t] * mult[name, t] * status
    end
    @test any(t -> param[_DISPATCH_UNIT, t] * mult[_DISPATCH_UNIT, t] != 0.0, 4:6)
end

function _sys_with_hvdc_tie_out(steps)
    sys = _c_sys5_uc()
    arc = PSY.get_arc(first(_sorted(PSY.Line, sys)))
    hvdc = PSY.TwoTerminalGenericHVDCLine(;
        name = "hvdc_tie",
        available = true,
        active_power_flow = 0.0,
        rating = 2.0,
        rating_from = 2.0,
        rating_to = 2.0,
        reactive_power_limits_from = (min = -1.0, max = 1.0),
        reactive_power_limits_to = (min = -1.0, max = 1.0),
        arc = arc,
        loss = PSY.LossCurve(PSY.LinearCurve(0.05, 0.01), PSY.CU),
        input_basis = u"CU",
    )
    PSY.add_component!(sys, hvdc)
    _schedule_outage!(sys, hvdc, "out", _out_at(steps))
    return sys
end

function _hvdc_template(net, formulation)
    template = get_thermal_dispatch_template_network(NetworkModel(net))
    set_device_model!(template, PSY.TwoTerminalGenericHVDCLine, formulation)
    return template
end

function _check_fixed_only_when_out(variable, name, steps)
    for t in axes(variable, 2)
        @test _fixed_at_zero(variable[name, t]) == (t in steps)
    end
    return
end

@testset "An out HVDC line has zero flow under HVDCTwoTerminalLossless on $(net)" for net in
                                                                                      (
    PTDFNetworkModel,
    DCPNetworkModel,
)
    sys = _sys_with_hvdc_tie_out(3:5)
    model = _built_model(_hvdc_template(net, HVDCTwoTerminalLossless), sys)
    flow = _var(model, FlowActivePowerVariable, PSY.TwoTerminalGenericHVDCLine)
    _check_fixed_only_when_out(flow, "hvdc_tie", 3:5)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    for t in 3:5
        @test JuMP.value(flow["hvdc_tie", t]) == 0.0
    end
end

@testset "An out HVDC line has no flow or losses under HVDCTwoTerminalDispatch" begin
    sys = _sys_with_hvdc_tie_out(3:5)
    model = _built_model(_hvdc_template(PTDFNetworkModel, HVDCTwoTerminalDispatch), sys)
    D = PSY.TwoTerminalGenericHVDCLine
    for T in (FlowActivePowerFromToVariable, FlowActivePowerToFromVariable, HVDCLosses)
        _check_fixed_only_when_out(_var(model, T, D), "hvdc_tie", 3:5)
    end
    direction = _var(model, HVDCFlowDirectionVariable, D)
    for t in axes(direction, 2)
        @test !JuMP.is_fixed(direction["hvdc_tie", t])
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "An out HVDC line has no flow under HVDCTwoTerminalPiecewiseLoss" begin
    sys = _sys_with_hvdc_tie_out(3:5)
    model =
        _built_model(_hvdc_template(PTDFNetworkModel, HVDCTwoTerminalPiecewiseLoss), sys)
    D = PSY.TwoTerminalGenericHVDCLine
    for T in (
        POM.HVDCActivePowerReceivedFromVariable,
        POM.HVDCActivePowerReceivedToVariable,
    )
        _check_fixed_only_when_out(_var(model, T, D), "hvdc_tie", 3:5)
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "An out TModelHVDCLine has zero flow under LosslessLine" begin
    sys = PSB.build_system(PSISystems, "sys10_pjm_ac_dc")
    line = first(_sorted(PSY.TModelHVDCLine, sys))
    _schedule_outage!(sys, line, "out", _out_at(2:2))
    template = PowerOperationsProblemTemplate(NetworkModel(DCPNetworkModel))
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(template, TModelHVDCLine, LosslessLine)
    set_device_model!(template, InterconnectingConverter, LosslessConverter)
    set_hvdc_network_model!(template, TransportHVDCNetworkModel)
    model = _built_model(template, sys; horizon = _SHORT_HORIZON)
    flow = _var(model, FlowActivePowerVariable, PSY.TModelHVDCLine)
    _check_fixed_only_when_out(flow, PSY.get_name(line), 2:2)
    for other in _sorted(PSY.TModelHVDCLine, sys)
        PSY.get_name(other) == PSY.get_name(line) && continue
        _check_fixed_only_when_out(flow, PSY.get_name(other), 1:0)
    end
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    @test JuMP.value(flow[PSY.get_name(line), 2]) == 0.0
end

@testset "An out AC line keeps a free flow variable and carries no flow" begin
    sys = _c_sys5_uc()
    line = first(_sorted(PSY.Line, sys))
    _schedule_outage!(sys, line, "out", _out_at(3:5))
    template = PowerOperationsProblemTemplate(NetworkModel(PTDFNetworkModel))
    set_device_model!(template, ThermalStandard, ThermalBasicDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, Line, StaticBranchBounds)
    set_device_model!(template, TwoWindingTransformer, StaticBranchUnbounded)
    model = _built_model(template, sys)
    flow = _var(model, FlowActivePowerVariable, PSY.Line)
    _check_fixed_only_when_out(flow, PSY.get_name(line), 1:0)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    for t in 3:5
        @test isapprox(JuMP.value(flow[PSY.get_name(line), t]), 0.0; atol = 1e-6)
    end
end

struct _StatusProbeConstraint <: POM.PowerVariableLimitsConstraint end
IOM.get_min_max_limits(
    d::PSY.ThermalStandard,
    ::Type{_StatusProbeConstraint},
    ::Type{ThermalBasicDispatch},
) = PSY.get_active_power_limits(d, u"SU")

@testset "Status-scaled power limits cover every device collection IOM accepts" begin
    sys = _c_sys5_uc()
    unit = first(_sorted(PSY.ThermalStandard, sys))
    name = PSY.get_name(unit)
    _schedule_outage!(sys, unit, "out", _out_at(3:5))
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, ThermalStandard, ThermalBasicDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    model = _built_model(template, sys)
    container = IOM.get_optimization_container(model)
    device_model = DeviceModel(PSY.ThermalStandard, ThermalBasicDispatch)
    limits = PSY.get_active_power_limits(unit, u"SU")
    for (i, devices) in enumerate((
        _sorted(PSY.ThermalStandard, sys),
        PSY.get_components(PSY.ThermalStandard, sys),
    ))
        # The constraints built for the collection carry the status: an out step bounds the
        # variable at zero, and an in-service step keeps the plain limits.
        IOM.add_range_constraints!(
            container,
            _StatusProbeConstraint,
            POM.ActivePowerVariable,
            devices,
            device_model,
            CopperPlateNetworkModel,
        )
        constraints = IOM.get_constraints(container)
        key(meta) = IOM.ConstraintKey(_StatusProbeConstraint, PSY.ThermalStandard, meta)
        lb = constraints[key("lb")]
        ub = constraints[key("ub")]
        for t in IOM.get_time_steps(container)
            out = t in 3:5
            @test JuMP.normalized_rhs(ub[name, t]) ==
                  (out ? 0.0 : limits.max)
            @test JuMP.normalized_rhs(lb[name, t]) ==
                  (out ? 0.0 : limits.min)
        end
        # The next collection type needs a fresh constraint container.
        delete!(constraints, key("lb"))
        delete!(constraints, key("ub"))
    end
end

@testset "Component statuses come from the injector and HVDC schedules only" begin
    sys = _sys_with_hvdc_tie_out(3:5)
    unit = first(_sorted(PSY.ThermalStandard, sys))
    other = last(_sorted(PSY.ThermalStandard, sys))
    line = first(_sorted(PSY.Line, sys))
    _schedule_outage!(sys, unit, "unit_out", _out_at(2:2))
    _schedule_outage!(sys, line, "line_out", _out_at(4:4))
    model = _built_model(_hvdc_template(PTDFNetworkModel, HVDCTwoTerminalLossless), sys)
    container = _container(model)
    @test IOM.has_container_key(container, POM.BranchStatusParameter, PSY.Line)
    thermal = IOM.get_component_statuses(container, PSY.ThermalStandard)
    @test thermal isa IOM.ComponentStatusArray
    # Built once per container: every builder reuses the same name lookup.
    @test IOM.get_component_statuses(container, PSY.ThermalStandard) === thermal
    @test IOM.get_component_status(thermal, PSY.get_name(unit), 2) == 0.0
    @test IOM.get_component_status(thermal, PSY.get_name(unit), 1) == 1.0
    @test IOM.get_component_status(thermal, PSY.get_name(other), 2) == 1.0
    hvdc = IOM.get_component_statuses(container, PSY.TwoTerminalGenericHVDCLine)
    @test IOM.get_component_status(hvdc, "hvdc_tie", 3) == 0.0
    @test IOM.get_component_status(hvdc, "hvdc_tie", 2) == 1.0
    @test IOM.get_component_statuses(container, PSY.PowerLoad) isa IOM.AllComponentsActive
    @test IOM.get_component_statuses(container, PSY.Line) isa IOM.AllComponentsActive
end

@testset "Topology and status vectors require steps starting at 1" begin
    @test isnothing(POM._check_steps_start_at_one(1:24))
    @test_throws ArgumentError POM._check_steps_start_at_one(2:24)
end

# Every thermal unit can cover its whole range in one step and has no minimum up or down
# time, so an outage is feasible at any step.
function _allow_outage_transitions!(sys)
    for g in PSY.get_components(PSY.ThermalStandard, sys)
        ramp = PSY.get_active_power_limits(g, u"SU").max
        PSY.set_ramp_limits!(g, (up = ramp * u"SU/minute", down = ramp * u"SU/minute"))
        PSY.set_time_limits!(g, nothing)
    end
    return
end

function _power_output(model, formulation, name)
    outputs = IOM.OptimizationProblemOutputs(model)
    key = if formulation <: Union{POM.AbstractCompactUnitCommitment, ThermalCompactDispatch}
        "PowerOutput__ThermalStandard"
    else
        "ActivePowerVariable__ThermalStandard"
    end
    reader = startswith(key, "PowerOutput") ? read_aux_variable : read_variable
    return reader(outputs, key; table_format = TableFormat.WIDE)[!, name]
end

# "Test PWL" carries a piecewise linear cost whose first breakpoint is above zero, so the
# cost rows tie its power to an on status of one unless they follow the outage.
@testset "An out unit with a piecewise linear cost is off under $(formulation), must-run $(must_run)" for (
    system,
    formulation,
    must_run,
) in (
    ("c_sys5_pwl_ed", ThermalBasicDispatch, false),
    ("c_sys5_pwl_ed", ThermalStandardDispatch, false),
    ("c_sys5_pwl_ed", ThermalCompactDispatch, false),
    ("c_sys5_pwl_uc", ThermalBasicUnitCommitment, true),
    ("c_sys5_pwl_uc", ThermalCompactUnitCommitment, true),
)
    sys = PSB.build_system(PSITestSystems, system)
    _allow_outage_transitions!(sys)
    unit = PSY.get_component(PSY.ThermalStandard, sys, "Test PWL")
    must_run && PSY.set_commitment_mode!(unit, PSY.CommitmentModes.MUST_RUN)
    _schedule_outage!(sys, unit, "maint", _maintenance)
    model = _built_model(_uc_template(formulation), sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    power = _power_output(model, formulation, "Test PWL")
    @test all(t -> isapprox(power[t], 0.0; atol = 1e-6), _OUT_STEPS)
    lambda = _var(model, PiecewiseLinearCostVariable, PSY.ThermalStandard)
    for ((name, _, t), v) in lambda.data
        name == "Test PWL" && t in _OUT_STEPS || continue
        @test isapprox(JuMP.value(v), 0.0; atol = 1e-9)
    end
end

# The source's import and export offers are block offers, whose rows tie its power to the
# offer curves.
@testset "An out import/export source has no power and no offer at its out steps" begin
    sys = make_5_bus_with_import_export(; add_single_time_series = false)
    source = PSY.get_component(PSY.Source, sys, "source")
    _schedule_outage!(sys, source, "maint", _maintenance)
    template = PowerOperationsProblemTemplate(NetworkModel(CopperPlateNetworkModel))
    set_device_model!(template, ThermalStandard, ThermalStandardUnitCommitment)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(
        template,
        DeviceModel(
            PSY.Source,
            ImportExportSourceModel;
            attributes = Dict("reservation" => false),
        ),
    )
    model = _built_model(template, sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    p_in = _var(model, ActivePowerInVariable, PSY.Source)
    p_out = _var(model, ActivePowerOutVariable, PSY.Source)
    for t in _OUT_STEPS
        @test _fixed_at_zero(p_in["source", t])
        @test _fixed_at_zero(p_out["source", t])
    end
    for t in setdiff(1:_n_steps(model), _OUT_STEPS)
        @test !JuMP.is_fixed(p_in["source", t])
        @test !JuMP.is_fixed(p_out["source", t])
    end
    # Import and export curves start at zero power, so the offer rows hold no offset; at an
    # out step every block of both offers clears nothing.
    offer_types = (
        POM.PiecewiseLinearBlockIncrementalOfferConstraint,
        POM.PiecewiseLinearBlockDecrementalOfferConstraint,
    )
    for T in offer_types
        rows = IOM.get_constraint(_container(model), IOM.ConstraintKey(T, PSY.Source))
        for t in _OUT_STEPS
            row = rows["source", t]
            @test iszero(JuMP.normalized_rhs(row))
            blocks = keys(JuMP.constraint_object(row).func.terms)
            @test length(blocks) > 1
            @test all(v -> isapprox(JuMP.value(v), 0.0; atol = 1e-9), blocks)
        end
    end
end

@testset "An out must-run unit with a market bid cost is off under ThermalBasicUnitCommitment" begin
    sys = _c_sys5_uc()
    _allow_outage_transitions!(sys)
    unit = PSY.get_component(PSY.ThermalStandard, sys, "Alta")
    add_mbc!(sys, make_selector(unit))
    PSY.set_commitment_mode!(unit, PSY.CommitmentModes.MUST_RUN)
    _schedule_outage!(sys, unit, "maint", _maintenance)
    model = _built_model(_uc_template(ThermalBasicUnitCommitment), sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    power = _power_output(model, ThermalBasicUnitCommitment, "Alta")
    @test all(t -> isapprox(power[t], 0.0; atol = 1e-6), _OUT_STEPS)
    @test all(t -> power[t] > 0.0, setdiff(1:_n_steps(model), _OUT_STEPS))
    # The offer row ties the power to the blocks above the first breakpoint `p1 > 0`; the
    # offset follows the status, so an out step holds no offset.
    offer = IOM.get_constraint(
        _container(model),
        IOM.ConstraintKey(
            POM.PiecewiseLinearBlockIncrementalOfferConstraint,
            PSY.ThermalStandard,
        ),
    )
    p1 = JuMP.normalized_rhs(offer["Alta", 1])
    @test p1 > 0.0
    for t in 1:_n_steps(model)
        @test JuMP.normalized_rhs(offer["Alta", t]) ≈ (t in _OUT_STEPS ? 0.0 : p1)
    end
end

@testset "An out renewable without a series has no curtailment cost at its out steps" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_re")
    unit = PSY.get_component(PSY.RenewableDispatch, sys, "WindBusA")
    base_cost = PSY.get_operation_cost(unit)
    PSY.set_operation_cost!(
        unit,
        PSY.RenewableGenerationCost(;
            variable_operation_cost = base_cost.variable_operation_cost,
            curtailment_cost = PSY.CostCurve(PSY.LinearCurve(10.0)),
            fixed = base_cost.fixed,
        ),
    )
    PSY.remove_time_series!(sys, PSY.Deterministic, unit, "max_active_power")
    _schedule_outage!(sys, unit, "maint", _maintenance)
    template = PowerOperationsProblemTemplate(CopperPlateNetworkModel)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, ThermalStandard, ThermalStandardDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    model = _built_model(template, sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    cost = IOM.get_expression(
        IOM.get_optimization_container(model),
        POM.CurtailmentCostExpression,
        PSY.RenewableDispatch,
    )
    p = _var(model, ActivePowerVariable, PSY.RenewableDispatch)
    for t in 1:_n_steps(model)
        expr = cost["WindBusA", t]
        if t in _OUT_STEPS
            @test iszero(JuMP.constant(expr))
            @test iszero(JuMP.coefficient(expr, p["WindBusA", t]))
        else
            @test JuMP.constant(expr) > 0.0
            @test JuMP.coefficient(expr, p["WindBusA", t]) < 0.0
        end
    end
end

# A DC power flow evaluated on the solution must see the injections the optimizer saw.
function _pf_model(sys)
    template = PowerOperationsProblemTemplate(
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(DCPowerFlow()),
    )
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    model = _built_model(template, sys)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    return model
end

@testset "Power flow in the loop and the outputs see an out load as out" begin
    sys = _c_sys5_uc()
    load = first(_sorted(PSY.PowerLoad, sys))
    name = PSY.get_name(load)
    _schedule_outage!(sys, load, "out", _out_at(3:5))
    model = _pf_model(sys)
    container = _container(model)
    key = IOM.ParameterKey(ActivePowerTimeSeriesParameter, PSY.PowerLoad)
    demand = IOM.lookup_value(container, key)
    outputs = IOM.read_parameter(
        IOM.OptimizationProblemOutputs(model),
        "ActivePowerTimeSeriesParameter__PowerLoad";
        table_format = TableFormat.WIDE,
    )[
        !,
        name,
    ]
    for t in 1:_n_steps(model)
        out = t in 3:5
        @test iszero(demand[name, t]) == out
        @test iszero(outputs[t]) == out
    end
    pf = IOM.get_aux_variable(container, POM.PowerFlowBranchActivePowerFromTo, PSY.Line)
    flows = IOM.lookup_value(container, IOM.ExpressionKey(POM.PTDFBranchFlow, PSY.Line))
    for t in 1:_n_steps(model)
        @test maximum(abs(pf[n, t] - flows[n, t]) for n in axes(pf, 1)) < 1e-9
    end
end

# A compact unit commitment model with a semicontinuous feedforward commits through its own
# `OnVariable`; the feedforward parameter serves only formulations without commitment.
function _compact_uc_objective(; feedforward, fuel = false)
    sys = _c_sys5_uc()
    if fuel
        unit = PSY.get_component(PSY.ThermalStandard, sys, "Brighton")
        cost = PSY.get_operation_cost(unit)
        PSY.set_operation_cost!(
            unit,
            PSY.ThermalGenerationCost(;
                variable_operation_cost = PSY.FuelCurve(;
                    value_curve = PSY.LinearCurve(17.0),
                    fuel_cost = 2.5,
                ),
                fixed = PSY.get_fixed(cost),
                start_up = PSY.get_start_up(cost),
                shut_down = PSY.get_shut_down(cost),
            ),
        )
    end
    device_model = DeviceModel(ThermalStandard, ThermalCompactUnitCommitment)
    feedforward && attach_feedforward!(
        device_model,
        SemiContinuousFeedforward(;
            component_type = ThermalStandard,
            source = OnVariable,
            affected_values = [PowerAboveMinimumVariable],
        ),
    )
    model = DecisionModel(MockOperationProblem, CopperPlateNetworkModel, sys)
    mock_construct_device!(model, device_model)
    return sys, IOM.get_optimization_container(model)
end

@testset "Compact unit commitment with a feedforward prices its own commitment" begin
    _, plain = _compact_uc_objective(; feedforward = false)
    sys, container = _compact_uc_objective(; feedforward = true)
    @test IOM.has_container_key(container, OnStatusParameter, PSY.ThermalStandard)
    objective(c) = c.objective_function.invariant_terms
    on = IOM.get_variable(container, OnVariable, PSY.ThermalStandard)
    on_plain = IOM.get_variable(plain, OnVariable, PSY.ThermalStandard)
    for name in axes(on, 1), t in axes(on, 2)
        coefficient = JuMP.coefficient(objective(container), on[name, t])
        @test coefficient == JuMP.coefficient(objective(plain), on_plain[name, t])
    end
    @test any(!iszero, (JuMP.coefficient(objective(container), v) for v in on.data))
    @test JuMP.constant(objective(container)) == JuMP.constant(objective(plain))
    unit = PSY.get_component(PSY.ThermalStandard, sys, "Brighton")
    pmin = POM.min_active_power_values(container, unit)
    terms = POM._min_power_series(container, ThermalCompactUnitCommitment, unit)
    for t in axes(on, 2)
        @test JuMP.coefficient(terms[t], on["Brighton", t]) ≈ pmin[t]
    end
end

@testset "Compact unit commitment with a feedforward burns fuel on its own commitment" begin
    _, plain = _compact_uc_objective(; feedforward = false, fuel = true)
    sys, container = _compact_uc_objective(; feedforward = true, fuel = true)
    fuel(c) = IOM.get_expression(c, POM.FuelConsumptionExpression, PSY.ThermalStandard)
    on = IOM.get_variable(container, OnVariable, PSY.ThermalStandard)
    on_plain = IOM.get_variable(plain, OnVariable, PSY.ThermalStandard)
    param = IOM.get_parameter_array(container, OnStatusParameter, PSY.ThermalStandard)
    unit = PSY.get_component(PSY.ThermalStandard, sys, "Brighton")
    pmin = POM.min_active_power_values(container, unit)
    @test any(!iszero, pmin)
    for t in axes(on, 2)
        expression = fuel(container)["Brighton", t]
        # The minimum-power term `Pmin * u` is on the unit's own commitment.
        @test JuMP.coefficient(expression, on["Brighton", t]) ≈
              JuMP.coefficient(fuel(plain)["Brighton", t], on_plain["Brighton", t])
        @test iszero(pmin[t]) || !iszero(JuMP.coefficient(expression, on["Brighton", t]))
        @test JuMP.constant(expression) == JuMP.constant(fuel(plain)["Brighton", t])
        param["Brighton", t] isa JuMP.VariableRef &&
            @test iszero(JuMP.coefficient(expression, param["Brighton", t]))
    end
end
