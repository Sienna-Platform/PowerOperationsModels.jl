# Build/solve-level tests for the contingency-event framework. PSI's `test_events.jl` is
# Simulation-driven (multi-stage UC/ED/Emulator) and does not port to POM, which has no
# Simulation. Here we attach an `EventModel` to a `DeviceModel`, build a single
# `DecisionModel`, and assert the event parameters/constraints are present and the model
# solves; the behavioral testset drives `AvailableStatusParameter → 0` (recurrent build)
# and confirms the outage constraint forces dispatch to zero.

# Attach a FixedForcedOutage supplemental attribute to every component of type `T` so the
# event builders find devices with an attached contingency.
function _attach_fixed_forced_outage!(sys, ::Type{T}) where {T <: PSY.Component}
    for d in PSY.get_components(T, sys)
        PSY.add_supplemental_attribute!(
            sys,
            d,
            PSY.FixedForcedOutage(; outage_status = 0.0),
        )
    end
    return
end

_has_param(model, P, D) =
    haskey(IOM.get_parameters(model), IOM.ParameterKey(P, D))
_has_constraint(model, C, D, meta) =
    haskey(IOM.get_constraints(model), IOM.ConstraintKey(C, D, meta))

@testset "Events: ThermalStandard outage on CopperPlate builds and solves" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    _attach_fixed_forced_outage!(sys, ThermalStandard)

    template = get_thermal_dispatch_template_network(NetworkModel(CopperPlatePowerModel))
    dm = DeviceModel(ThermalStandard, ThermalBasicDispatch)
    set_event_model!(dm, EventModel(PSY.FixedForcedOutage, ContinuousCondition()))
    set_device_model!(template, dm)

    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    c = IOM.get_optimization_container(model)
    @test _has_param(c, AvailableStatusParameter, ThermalStandard)
    @test _has_param(c, AvailableStatusChangeCountdownParameter, ThermalStandard)
    @test _has_constraint(c, ActivePowerOutageConstraint, ThermalStandard, "ub")
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "Events: ThermalStandard outage on DCP (nodal) builds and solves" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    _attach_fixed_forced_outage!(sys, ThermalStandard)

    template = get_thermal_dispatch_template_network(NetworkModel(DCPPowerModel))
    dm = DeviceModel(ThermalStandard, ThermalBasicDispatch)
    set_event_model!(dm, EventModel(PSY.FixedForcedOutage, ContinuousCondition()))
    set_device_model!(template, dm)

    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    c = IOM.get_optimization_container(model)
    @test _has_param(c, AvailableStatusParameter, ThermalStandard)
    @test _has_constraint(c, ActivePowerOutageConstraint, ThermalStandard, "ub")
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "Events: RenewableDispatch outage on CopperPlate builds and solves" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5_re")
    _attach_fixed_forced_outage!(sys, RenewableDispatch)

    template = PowerOperationsProblemTemplate(CopperPlatePowerModel)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, ThermalStandard, ThermalBasicDispatch)
    dm = DeviceModel(RenewableDispatch, RenewableFullDispatch)
    set_event_model!(dm, EventModel(PSY.FixedForcedOutage, ContinuousCondition()))
    set_device_model!(template, dm)

    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    c = IOM.get_optimization_container(model)
    @test _has_param(c, AvailableStatusParameter, RenewableDispatch)
    @test _has_constraint(c, ActivePowerOutageConstraint, RenewableDispatch, "ub")
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "Events: PowerLoad active-power offset on CopperPlate builds and solves" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    _attach_fixed_forced_outage!(sys, PowerLoad)

    template = PowerOperationsProblemTemplate(CopperPlatePowerModel)
    set_device_model!(template, ThermalStandard, ThermalBasicDispatch)
    dm = DeviceModel(PowerLoad, StaticPowerLoad)
    set_event_model!(dm, EventModel(PSY.FixedForcedOutage, ContinuousCondition()))
    set_device_model!(template, dm)

    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    c = IOM.get_optimization_container(model)
    @test _has_param(c, AvailableStatusParameter, PowerLoad)
    @test _has_param(c, ActivePowerOffsetParameter, PowerLoad)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "Events: ThermalStandard reactive outage constraint under ACP" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    _attach_fixed_forced_outage!(sys, ThermalStandard)

    dm = DeviceModel(ThermalStandard, ThermalBasicDispatch)
    model = DecisionModel(MockOperationProblem, ACPPowerModel, sys)
    mock_construct_device!(
        model,
        dm;
        built_for_recurrent_solves = true,
        add_event_model = true,
    )
    c = IOM.get_optimization_container(model)
    @test _has_param(c, AvailableStatusParameter, ThermalStandard)
    @test _has_constraint(c, ActivePowerOutageConstraint, ThermalStandard, "ub")
    @test _has_constraint(c, ReactivePowerOutageConstraint, ThermalStandard, "ub")
end

@testset "Events: AvailableStatusParameter=0 forces dispatch to zero" begin
    sys = PSB.build_system(PSITestSystems, "c_sys5")
    g = PSY.get_component(ThermalStandard, sys, "Solitude")
    PSY.add_supplemental_attribute!(sys, g, PSY.FixedForcedOutage(; outage_status = 0.0))

    dm = DeviceModel(ThermalStandard, ThermalBasicDispatch)
    model =
        DecisionModel(MockOperationProblem, DCPPowerModel, sys; optimizer = HiGHS_optimizer)
    mock_construct_device!(
        model,
        dm;
        built_for_recurrent_solves = true,
        add_event_model = true,
    )
    c = IOM.get_optimization_container(model)
    status = IOM.get_parameter_array(c, AvailableStatusParameter, ThermalStandard)
    p = IOM.get_variable(c, ActivePowerVariable, ThermalStandard)
    @test eltype(status) <: JuMP.VariableRef

    jm = IOM.get_jump_model(model)
    time_steps = axes(p)[2]
    JuMP.@objective(jm, MOI.MAX_SENSE, sum(p["Solitude", t] for t in time_steps))

    # Available (status defaults to 1): dispatch can reach the device maximum.
    JuMP.optimize!(jm)
    pmax = PSY.get_active_power_limits(g, PSY.SU).max
    @test JuMP.value(p["Solitude", first(time_steps)]) ≈ pmax atol = 1e-4

    # Outaged (status forced to 0): the outage constraint pins dispatch to zero.
    for t in time_steps
        JuMP.fix(status["Solitude", t], 0.0; force = true)
    end
    JuMP.optimize!(jm)
    for t in time_steps
        @test JuMP.value(p["Solitude", t]) ≈ 0.0 atol = 1e-4
    end
end
