function _expressions_match(a::JuMP.AffExpr, b::JuMP.AffExpr)
    diff = a - b
    return isapprox(JuMP.constant(diff), 0.0; atol = 1e-9) &&
           all(isapprox(c, 0.0; atol = 1e-9) for c in values(diff.terms))
end

# The contributions of the devices at a bus add up to the nodal balance of that bus.
function _test_contributions_match_nodal_balance(container, sys)
    nodal = IOM.get_expression(container, ActivePowerBalance, ACBus)
    total = Dict((b, t) => JuMP.AffExpr(0.0) for b in axes(nodal, 1), t in axes(nodal, 2))
    for (key, contribution) in IOM.get_expressions(container)
        IOM.get_entry_type(key) === POM.ActivePowerBalanceContribution || continue
        V = IOM.get_component_type(key)
        for name in axes(contribution, 1)
            bus = PSY.get_number(PSY.get_bus(PSY.get_component(V, sys, name)))
            for t in axes(contribution, 2)
                JuMP.add_to_expression!(total[(bus, t)], contribution[name, t])
            end
        end
    end
    for b in axes(nodal, 1), t in axes(nodal, 2)
        @test _expressions_match(total[(b, t)], nodal[b, t])
    end
    return
end

function _build_balance_contribution_model(template, sys; optimizer = HiGHS_optimizer)
    model = DecisionModel(template, sys; optimizer = optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    return model
end

function _has_entry_type(container, ::Type{T}) where {T}
    return any(
        IOM.get_entry_type(key) === T for key in keys(IOM.get_expressions(container))
    )
end

@testset "thermal and static load contributions equal the nodal balance" begin
    sys = build_system(PSITestSystems, "c_sys5_uc")
    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(DCPowerFlow()),
    )
    model = _build_balance_contribution_model(template, sys)
    container = get_optimization_container(model)
    @test IOM.has_container_key(
        container, POM.ActivePowerBalanceContribution, ThermalStandard,
    )
    @test IOM.has_container_key(container, POM.ActivePowerBalanceContribution, PowerLoad)
    _test_contributions_match_nodal_balance(container, sys)
end

@testset "compact thermal contributions equal the nodal balance" begin
    sys = build_system(PSITestSystems, "c_sys5_uc")
    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(DCPowerFlow()),
    )
    set_device_model!(template, ThermalStandard, ThermalCompactUnitCommitment)
    model = _build_balance_contribution_model(template, sys)
    container = get_optimization_container(model)
    _test_contributions_match_nodal_balance(container, sys)
end

@testset "a model without a power flow evaluator has no contribution" begin
    sys = build_system(PSITestSystems, "c_sys5_uc")
    template = get_template_dispatch_with_network(NetworkModel(PTDFNetworkModel))
    model = _build_balance_contribution_model(template, sys)
    container = get_optimization_container(model)
    @test !_has_entry_type(container, POM.ActivePowerBalanceContribution)
    @test !_has_entry_type(container, POM.ReactivePowerBalanceContribution)
end

@testset "an active power network has no reactive contribution" begin
    sys = build_system(PSITestSystems, "c_sys5_uc")
    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(DCPowerFlow()),
    )
    model = _build_balance_contribution_model(template, sys)
    container = get_optimization_container(model)
    @test !_has_entry_type(container, POM.ReactivePowerBalanceContribution)
end

@testset "an AC network has a reactive contribution" begin
    sys = build_system(PSITestSystems, "c_sys5_uc")
    template = PowerOperationsProblemTemplate(
        NetworkModel(ACPNetworkModel);
        evaluations = power_flow_evaluations(ACPowerFlow()),
    )
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, Line, StaticBranch)
    model = _build_balance_contribution_model(template, sys; optimizer = ipopt_optimizer)
    container = get_optimization_container(model)
    @test IOM.has_container_key(
        container, POM.ReactivePowerBalanceContribution, ThermalStandard,
    )
end

@testset "a filtered device model contributes for its devices only" begin
    sys = build_system(PSITestSystems, "c_sys5_uc")
    template = get_template_dispatch_with_network(
        NetworkModel(PTDFNetworkModel);
        evaluations = power_flow_evaluations(DCPowerFlow()),
    )
    set_device_model!(
        template,
        DeviceModel(
            ThermalStandard,
            ThermalBasicDispatch;
            attributes = Dict{String, Any}(
                "filter_function" => x -> PSY.get_name(x) != "Alta",
            ),
        ),
    )
    model = _build_balance_contribution_model(template, sys)
    container = get_optimization_container(model)
    contribution =
        IOM.get_expression(container, POM.ActivePowerBalanceContribution, ThermalStandard)
    @test !("Alta" in axes(contribution, 1))
end

function _contribution_template(network = PTDFNetworkModel)
    return get_template_dispatch_with_network(
        NetworkModel(network);
        evaluations = power_flow_evaluations(DCPowerFlow()),
    )
end

function _test_device_contributions(template, sys, ::Type{V}) where {V}
    model = _build_balance_contribution_model(template, sys)
    container = get_optimization_container(model)
    @test IOM.has_container_key(container, POM.ActivePowerBalanceContribution, V)
    _test_contributions_match_nodal_balance(container, sys)
    return
end

function _add_motor_load!(sys, load)
    mload = MotorLoad(;
        name = "motor_load",
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
    add_component!(sys, mload)
    return
end

function _shiftable_load_system()
    sys = PSB.build_system(PSITestSystems, "c_sys5_il"; add_single_time_series = true)
    il_load = first(PSY.get_components(InterruptiblePowerLoad, sys))
    shiftable_load = ShiftablePowerLoad(;
        name = "shiftable_load",
        available = true,
        bus = PSY.get_bus(il_load),
        active_power = PSY.get_active_power(il_load, u"SU"),
        active_power_limits = (min = 0.0, max = PSY.get_active_power(il_load, u"SU")),
        reactive_power = PSY.get_reactive_power(il_load, u"SU"),
        max_active_power = PSY.get_max_active_power(il_load, u"SU"),
        max_reactive_power = PSY.get_max_reactive_power(il_load, u"SU"),
        base_power = PSY.get_base_power(il_load, u"NU"),
        load_balance_time_horizon = 1,
        operation_cost = LoadCost(;
            variable_operation_cost = CostCurve(
                LinearCurve(0.0),
                PSY.NU,
                LinearCurve(1.0),
            ),
            fixed = 0.0,
        ),
        input_basis = u"CU",
    )
    PSY.add_component!(sys, shiftable_load)
    PSY.set_available!(il_load, false)
    PSY.copy_time_series!(shiftable_load, il_load)
    tstamps = TimeSeries.timestamp(
        PSY.get_time_series_array(SingleTimeSeries, shiftable_load, "max_active_power"),
    )
    for name in ("shift_up_max_active_power", "shift_down_max_active_power")
        PSY.add_time_series!(
            sys,
            shiftable_load,
            SingleTimeSeries(name, TimeArray(tstamps, ones(length(tstamps)))),
        )
    end
    PSY.transform_single_time_series!(sys, Hour(24), Hour(24))
    return sys
end

@testset "device contributions equal the nodal balance" begin
    @testset "motor load" begin
        sys = build_system(PSITestSystems, "c_sys5_uc")
        _add_motor_load!(sys, get_component(PowerLoad, sys, "Bus2"))
        template = _contribution_template()
        set_device_model!(template, MotorLoad, StaticPowerLoad)
        _test_device_contributions(template, sys, MotorLoad)
    end

    @testset "storage" begin
        sys = build_system(PSITestSystems, "c_sys5_bat")
        template = _contribution_template()
        set_device_model!(template, EnergyReservoirStorage, StorageDispatchWithReserves)
        _test_device_contributions(template, sys, EnergyReservoirStorage)
    end

    @testset "controllable load" begin
        sys = build_system(PSITestSystems, "c_sys5_il")
        template = _contribution_template()
        set_device_model!(template, InterruptiblePowerLoad, PowerLoadDispatch)
        _test_device_contributions(template, sys, InterruptiblePowerLoad)
    end

    @testset "shiftable load" begin
        sys = _shiftable_load_system()
        template = _contribution_template()
        set_device_model!(
            template,
            DeviceModel(
                ShiftablePowerLoad,
                PowerLoadShift;
                attributes = Dict{String, Any}("additional_balance_interval" => Hour(12)),
            ),
        )
        _test_device_contributions(template, sys, ShiftablePowerLoad)
    end

    @testset "hydro pump" begin
        sys = PSB.build_system(
            PSITestSystems,
            "c_sys5_hydro_pump_energy";
            add_single_time_series = true,
        )
        transform_single_time_series!(sys, Hour(24), Hour(24))
        template = _contribution_template()
        set_device_model!(template, HydroPumpTurbine, HydroPumpEnergyDispatch)
        _test_device_contributions(template, sys, HydroPumpTurbine)
    end

    @testset "fixed output renewable" begin
        sys = build_system(PSITestSystems, "c_sys5_uc_re")
        template = _contribution_template()
        set_device_model!(template, RenewableDispatch, FixedOutput)
        _test_device_contributions(template, sys, RenewableDispatch)
    end

    @testset "import and export source" begin
        sys = make_5_bus_with_import_export(; add_single_time_series = false)
        template = _contribution_template()
        set_device_model!(
            template,
            DeviceModel(
                Source,
                ImportExportSourceModel;
                attributes = Dict("reservation" => false),
            ),
        )
        _test_device_contributions(template, sys, Source)
    end
end

@testset "storage under AreaPTDF contributes" begin
    sys = build_system(PSISystems, "two_area_pjm_DA")
    transform_single_time_series!(sys, Hour(2), Hour(2))
    bat = EnergyReservoirStorage(;
        name = "bat",
        available = true,
        bus = get_bus(sys, 11),
        prime_mover_type = PrimeMovers.BA,
        storage_technology_type = StorageTech.OTHER_CHEM,
        storage_capacity = 4.0,
        storage_level_limits = (min = 0.0, max = 1.0),
        initial_storage_capacity_level = 0.5,
        rating = 4.0,
        active_power = 4.0,
        input_active_power_limits = (min = 0.0, max = 2.0),
        output_active_power_limits = (min = 0.0, max = 2.0),
        efficiency = (in = 0.9, out = 0.9),
        reactive_power = 0.0,
        reactive_power_limits = (min = -2.0, max = 2.0),
        base_power = 100.0,
        input_basis = u"CU",
    )
    add_component!(sys, bat)

    template = get_thermal_dispatch_template_network(
        AreaPTDFNetworkModel;
        evaluations = power_flow_evaluations(DCPowerFlow()),
    )
    set_device_model!(
        template,
        DeviceModel(
            EnergyReservoirStorage,
            StorageDispatchWithReserves;
            attributes = Dict{String, Any}(
                "reservation" => true,
                "cycling_limits" => false,
                "energy_target" => true,
                "complete_coverage" => false,
                "regularization" => true,
            ),
        ),
    )
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    model = _build_balance_contribution_model(template, sys)
    container = get_optimization_container(model)

    contribution = IOM.get_expression(
        container, POM.ActivePowerBalanceContribution, EnergyReservoirStorage,
    )
    p_out = IOM.get_variable(container, ActivePowerOutVariable, EnergyReservoirStorage)
    p_in = IOM.get_variable(container, ActivePowerInVariable, EnergyReservoirStorage)
    @test JuMP.coefficient(contribution["bat", 1], p_out["bat", 1]) == 1.0
    @test JuMP.coefficient(contribution["bat", 1], p_in["bat", 1]) == -1.0
end

function _add_two_areas!(sys)
    areas = [Area("Area_1", 0.0, 0.0, 0.0), Area("Area_2", 0.0, 0.0, 0.0)]
    for area in areas
        add_component!(sys, area)
    end
    for bus in get_components(ACBus, sys)
        if get_number(bus) <= 5
            set_area!(bus, areas[1])
        else
            set_area!(bus, areas[2])
        end
    end
    return
end

function _test_converter_ac_side_contribution(
    sys,
    network,
    converter_model::DeviceModel;
    hvdc_model = TransportHVDCNetworkModel,
    line_formulation = LosslessLine,
)
    template = PowerOperationsProblemTemplate(
        NetworkModel(network);
        evaluations = power_flow_evaluations(DCPowerFlow()),
    )
    set_device_model!(template, ThermalStandard, ThermalDispatchNoMin)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, DeviceModel(Line, StaticBranch))
    set_device_model!(template, DeviceModel(TModelHVDCLine, line_formulation))
    set_device_model!(template, converter_model)
    set_hvdc_network_model!(template, hvdc_model)
    model = _build_balance_contribution_model(template, sys)
    container = get_optimization_container(model)

    contribution = IOM.get_expression(
        container, POM.ActivePowerBalanceContribution, InterconnectingConverter,
    )
    p = IOM.get_variable(container, ActivePowerVariable, InterconnectingConverter)
    for ic in get_components(InterconnectingConverter, sys)
        name = get_name(ic)
        @test JuMP.coefficient(contribution[name, 1], p[name, 1]) == 1.0
        @test length(contribution[name, 1].terms) == 1
    end
    return
end

@testset "a converter contributes its AC side" begin
    sys = build_system(PSISystems, "sys10_pjm_ac_dc")
    _test_converter_ac_side_contribution(
        sys,
        PTDFNetworkModel,
        DeviceModel(InterconnectingConverter, LosslessConverter),
    )
end

@testset "a converter contributes its AC side on the other network models" begin
    sys = build_system(PSISystems, "sys10_pjm_ac_dc")
    _test_converter_ac_side_contribution(
        sys,
        DCPNetworkModel,
        DeviceModel(InterconnectingConverter, LosslessConverter),
    )

    sys = build_system(PSISystems, "sys10_pjm_ac_dc")
    _add_two_areas!(sys)
    _test_converter_ac_side_contribution(
        sys,
        AreaPTDFNetworkModel,
        DeviceModel(InterconnectingConverter, LosslessConverter),
    )

    sys = build_system(PSISystems, "sys10_pjm_ac_dc")
    _test_converter_ac_side_contribution(
        sys,
        PTDFNetworkModel,
        DeviceModel(
            InterconnectingConverter,
            QuadraticLossConverter;
            attributes = Dict{String, Any}("bilinear_approximation" => "bin2"),
        );
        hvdc_model = VoltageDispatchHVDCNetworkModel,
        line_formulation = DCLossyLine,
    )
end

@testset "a motor load builds under AreaPTDF" begin
    sys = build_system(PSISystems, "two_area_pjm_DA")
    transform_single_time_series!(sys, Hour(24), Hour(1))
    _add_motor_load!(sys, first(get_components(PowerLoad, sys)))
    template = get_thermal_dispatch_template_network(AreaPTDFNetworkModel)
    set_device_model!(template, AreaInterchange, StaticBranch)
    set_device_model!(template, MotorLoad, StaticPowerLoad)
    model = DecisionModel(
        template, sys; resolution = Hour(1), optimizer = HiGHS_optimizer,
    )
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
end
