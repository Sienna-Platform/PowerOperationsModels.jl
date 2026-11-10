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
