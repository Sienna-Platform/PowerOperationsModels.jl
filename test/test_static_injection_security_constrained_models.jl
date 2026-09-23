# G-1 security-constrained reserves (`SecurityConstrainedContingencyReserve`).
#
# One fixture on `two_area_pjm_DA` covers the cases the formulation must keep apart:
# - an OnlineReserve and an OfflineReserve both named "Reserve1_2"; the online one is procured
#   (requirement series), the offline one only deploys;
# - a RenewableDispatch named "Brighton_2", like a thermal, contributing to the online reserve;
# - three outages overlapping on "Alta_1": A (online only), B (both reserves), C (offline only);
# - a parallel line and a parallel interchange, monitored or modeled-but-unmonitored.
# The main test builds and solves it under copper plate, PTDF, and area balance, and checks
# the solution against quantities recomputed from the system data.

const _G1_RESERVE = "Reserve1_2"
const _G1_TOL = 1e-4

function _attach_outage!(sys, generators, services, monitored)
    outage = PSY.FixedForcedOutage(;
        outage_status = 1.0,
        monitored_components = monitored,
    )
    for generator in generators
        add_supplemental_attribute!(sys, generator, outage)
    end
    for service in services
        add_supplemental_attribute!(sys, service, outage)
    end
    return outage
end

function _add_parallel_interchange!(sys::PSY.System)
    interchange = AreaInterchange(;
        name = "1_2_b",
        available = true,
        active_power_flow = 0.0,
        from_area = get_component(Area, sys, "Area1"),
        to_area = get_component(Area, sys, "Area2"),
        flow_limits = (from_to = 1.5, to_from = 1.5),
    )
    add_component!(sys, interchange)
    return interchange
end

_default_g1_monitored(sys) = [
    get_component(Line, sys, "4_1"),
    get_component(Line, sys, "2_2"),
    get_component(AreaInterchange, sys, "1_2"),
]

function g1_system(; monitored::Function = _default_g1_monitored)
    sys = PSB.build_system(PSISystems, "two_area_pjm_DA"; add_reserves = true)
    online = get_component(OnlineReserve{ReserveUp}, sys, _G1_RESERVE)
    offline = OfflineReserve(; name = _G1_RESERVE, available = true, time_frame = 30.0)
    add_service!(sys, offline, collect(get_components(ThermalStandard, sys)))

    wind = get_component(RenewableDispatch, sys, "WindBus1")
    PSY.set_name!(sys, wind, "Brighton_2")
    add_service!(wind, online, sys)

    add_equivalent_ac_transmission_with_parallel_circuits!(
        sys,
        get_component(Line, sys, "4_1"),
        Line,
    )
    _add_parallel_interchange!(sys)

    thermal(name) = get_component(ThermalStandard, sys, name)
    monitored_components = monitored(sys)
    outages = (
        a = _attach_outage!(
            sys,
            [thermal("Alta_1"), thermal("Park City_1")],
            [online],
            monitored_components,
        ),
        b = _attach_outage!(
            sys,
            [thermal("Alta_1"), thermal("Sundance_2")],
            [online, offline],
            monitored_components,
        ),
        c = _attach_outage!(
            sys,
            [thermal("Alta_1"), thermal("Park City_2")],
            [offline],
            monitored_components,
        ),
    )
    transform_single_time_series!(sys, Hour(24), Hour(1))
    return sys, outages
end

function g1_template(
    network::Type{<:AbstractNetworkModel};
    online_slacks::Bool = true,
    offline_slacks::Bool = true,
    model_interchanges::Bool = network === AreaBalanceNetworkModel,
    interchange_filter = nothing,
)
    template = get_thermal_dispatch_template_network(NetworkModel(network))
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    if model_interchanges
        attributes = Dict{String, Any}()
        isnothing(interchange_filter) ||
            (attributes["filter_function"] = interchange_filter)
        set_device_model!(
            template,
            DeviceModel(AreaInterchange, StaticBranch; attributes = attributes),
        )
    end
    set_service_model!(
        template,
        ServiceModel(
            OnlineReserve{ReserveUp},
            SecurityConstrainedContingencyReserve;
            use_slacks = online_slacks,
        ),
    )
    set_service_model!(
        template,
        ServiceModel(
            OfflineReserve,
            SecurityConstrainedContingencyReserve;
            use_slacks = offline_slacks,
        ),
    )
    return template
end

g1_model(template, sys) =
    DecisionModel(template, sys; resolution = Hour(1), optimizer = HiGHS_optimizer)

function aff_exprs_approx_equal(actual::JuMP.AffExpr, expected::JuMP.AffExpr)
    isapprox(actual.constant, expected.constant; atol = IOM.PTDF_ZERO_TOL) || return false
    return all(
        isapprox(
            get(actual.terms, v, 0.0),
            get(expected.terms, v, 0.0);
            atol = IOM.PTDF_ZERO_TOL,
        ) for v in union(keys(actual.terms), keys(expected.terms))
    )
end

_pair_types(::Type{IOM.ComponentPairKey{D, S}}) where {D, S} = (D, S)

# Every deployment entry as (device type, service type, service, device, outage, t) => variable.
function _deployments(container)
    entries = Dict{Tuple{DataType, DataType, String, String, Int, Int}, JuMP.VariableRef}()
    for (key, variable) in IOM.get_variables(container)
        IOM.get_entry_type(key) === PostContingencyDeploymentVariable || continue
        D, S = _pair_types(IOM.get_component_type(key))
        for ((s, d, uuid, t), var) in variable.data
            entries[(D, S, s, d, uuid, t)] = var
        end
    end
    return entries
end

_outaged(sys, outage) =
    collect(PSY.get_associated_components(sys, outage; component_type = PSY.Generator))

function _power_value(container, generator, t)
    power = IOM.get_variable(container, ActivePowerVariable, typeof(generator))
    return JuMP.value(power[PSY.get_name(generator), t])
end

# Σ deployment − Σ outaged power per `(outage, t, location(component))`, from the solution.
function _net_deployment(sys, container, deployments, outages, location)
    net = Dict{Tuple{Int, Int, Any}, Float64}()
    add!(key, value) = (net[key] = get(net, key, 0.0) + value)
    for ((D, _, _, d, uuid, t), var) in deployments
        add!((uuid, t, location(get_component(D, sys, d))), JuMP.value(var))
    end
    for outage in outages, generator in _outaged(sys, outage),
        t in IOM.get_time_steps(container)

        add!(
            (IS.get_id(outage), t, location(generator)),
            -_power_value(container, generator, t),
        )
    end
    return net
end

function check_g1_deployment(sys, model, outages)
    container = IOM.get_optimization_container(model)
    time_steps = IOM.get_time_steps(container)
    deployments = _deployments(container)
    uuids = Dict(IS.get_id(o) => o for o in values(outages))

    # Outaged devices do not deploy under their own outage.
    outaged = Set(
        (typeof(g), PSY.get_name(g), uuid) for (uuid, o) in uuids for g in _outaged(sys, o)
    )
    @test !any(((D, _, _, d, uuid, _),) -> (D, d, uuid) in outaged, keys(deployments))

    # Deployment replaces the outaged generation.
    net = _net_deployment(sys, container, deployments, values(outages), _ -> :system)
    @test all(
        abs(get(net, (uuid, t, :system), 0.0)) < _G1_TOL for uuid in keys(uuids),
        t in time_steps
    )

    # Deployment on the procured reserve stays within the award.
    award(D, S) =
        IOM.get_variable(container, ActivePowerReserveVariable, IOM.ComponentPairKey{D, S})
    @test all(
        JuMP.value(var) <= JuMP.value(award(D, S)[s, d, t]) + _G1_TOL for
        ((D, S, s, d, _, t), var) in deployments if S <: OnlineReserve
    )

    # Output plus total deployment stays within the device maximum.
    totals = Dict{Tuple{DataType, String, Int, Int}, Float64}()
    for ((D, _, _, d, uuid, t), var) in deployments
        totals[(D, d, uuid, t)] = get(totals, (D, d, uuid, t), 0.0) + JuMP.value(var)
    end
    @test all(
        _power_value(container, get_component(D, sys, d), t) + deployed <=
        PSY.get_max_active_power(get_component(D, sys, d), PSY.SU) + _G1_TOL for
        ((D, d, _, t), deployed) in totals
    )
    return
end

function check_g1_containers(model, outages)
    container = IOM.get_optimization_container(model)
    online_key(D) = IOM.ComponentPairKey{D, OnlineReserve{ReserveUp}}
    offline_key(D) = IOM.ComponentPairKey{D, OfflineReserve}

    # Same-named contributors of different types stay apart.
    for D in (ThermalStandard, RenewableDispatch)
        award = IOM.get_variable(container, ActivePowerReserveVariable, online_key(D))
        @test haskey(award.data, (_G1_RESERVE, "Brighton_2", 1))
    end

    # Same-named services of different types stay apart; only the online one responds to A
    # and only the offline one to C.
    online = IOM.get_variable(
        container,
        PostContingencyDeploymentVariable,
        online_key(ThermalStandard),
    )
    offline = IOM.get_variable(
        container,
        PostContingencyDeploymentVariable,
        offline_key(ThermalStandard),
    )
    responds(variable, outage) = any(k -> k[3] == IS.get_id(outage), keys(variable.data))
    @test responds(online, outages.a) && !responds(offline, outages.a)
    @test responds(online, outages.b) && responds(offline, outages.b)
    @test !responds(online, outages.c) && responds(offline, outages.c)

    # The offline reserve has no requirement series, so it is not procured.
    @test !IOM.has_container_key(container, RequirementConstraint, OfflineReserve)
    @test !IOM.has_container_key(
        container,
        ActivePowerReserveVariable,
        offline_key(ThermalStandard),
    )
    @test IOM.has_container_key(
        container,
        PostContingencyDeploymentConstraint,
        online_key(ThermalStandard),
    )
    @test !IOM.has_container_key(
        container,
        PostContingencyDeploymentConstraint,
        offline_key(ThermalStandard),
    )
    return
end

# Post-contingency flow change on each monitored entry equals the PTDF of a fresh matrix times
# the net deployment at each bus, recomputed from the solution and the system data.
function check_g1_ptdf_flows(sys, model, outages)
    container = IOM.get_optimization_container(model)
    network_model = IOM.get_network_model(IOM.get_template(model))
    reduction = POM.get_network_reduction(network_model)
    catalog = POM.get_branch_catalog(network_model)
    ptdf = PNM.VirtualPTDF(sys)
    bus_axis = PNM.get_bus_axis(ptdf)
    deployments = _deployments(container)
    mapped_bus(component) = PNM.get_mapped_bus_number(reduction, PSY.get_bus(component))

    net = _net_deployment(sys, container, deployments, values(outages), mapped_bus)

    post_flow = IOM.get_expression(container, PostContingencyBranchFlow, Line, "G1")
    pre_flow = IOM.get_expression(container, PTDFBranchFlow, Line)
    arc_map = PNM.get_name_to_arc_map(catalog, Line)
    rows = Dict(name => ptdf[arc, :] for (name, arc) in arc_map)
    flow_change(entry_name, uuid, t) =
        sum(
            r * get(net, (uuid, t, bus), 0.0) for
            (r, bus) in zip(rows[entry_name], bus_axis)
        )
    @test !isempty(post_flow.data)
    @test all(
        isapprox(
            JuMP.value(flow) - JuMP.value(pre_flow[entry_name, t]),
            flow_change(entry_name, uuid, t);
            atol = _G1_TOL,
        ) for ((entry_name, uuid, t), flow) in post_flow.data
    )

    # The parallel circuits share one reduced entry, limited once.
    entries = PNM.get_component_to_reduction_name_map(catalog, Line)
    @test entries["4_1"] == entries["4_1_copy"]
    return
end

function check_g1_area_flows(sys, model, outages)
    container = IOM.get_optimization_container(model)
    time_steps = IOM.get_time_steps(container)
    deployments = _deployments(container)
    deviation = IOM.get_variable(
        container,
        PostContingencyDeviationVariable,
        AreaInterchange,
    )
    area(c) = PSY.get_name(PSY.get_area(PSY.get_bus(c)))
    net = _net_deployment(sys, container, deployments, values(outages), area)

    # Each area balances its net deployment against the deviations on the Area1 -> Area2
    # interchanges.
    exported(uuid, t) = sum(JuMP.value(deviation[i, uuid, t]) for i in ("1_2", "1_2_b"))
    uuids = [IS.get_id(o) for o in values(outages)]
    @test all(
        abs(get(net, (uuid, t, "Area1"), 0.0) - exported(uuid, t)) < _G1_TOL &&
        abs(get(net, (uuid, t, "Area2"), 0.0) + exported(uuid, t)) < _G1_TOL for
        uuid in uuids, t in time_steps
    )

    # Both interchanges are modeled, but only the monitored one is limited.
    limits = IOM.get_constraint(
        container,
        PostContingencyFlowRateConstraint,
        AreaInterchange,
        "G1_ub",
    )
    limited = Set(k[1] for k in keys(limits.data))
    @test "1_2" in limited
    @test !("1_2_b" in limited)
    @test Set(axes(deviation, 1)) == Set(["1_2", "1_2_b"])
    return
end

@testset "G-1 reserves: $(network)" for network in (
    CopperPlateNetworkModel,
    PTDFNetworkModel,
    AreaBalanceNetworkModel,
)
    sys, outages = g1_system()
    model = g1_model(g1_template(network), sys)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT
    check_g1_containers(model, outages)
    @test solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    check_g1_deployment(sys, model, outages)
    network === PTDFNetworkModel && check_g1_ptdf_flows(sys, model, outages)
    network === AreaBalanceNetworkModel && check_g1_area_flows(sys, model, outages)
end

@testset "G-1 reserves on a degree-two reduced network" begin
    # `RADIAL1-RADIAL2-i_1` is merged into a degree-two series entry, so its post-contingency
    # flow is keyed and limited by that entry.
    sys = PSB.build_system(PSITestSystems, "case10_radial_series_reductions")
    load = first(collect(get_components(StandardLoad, sys)))
    add_time_series!(
        sys,
        load,
        Deterministic(
            "max_active_power",
            Dict(DateTime("2020-01-01T00:00:00") => ones(24)),
            Hour(1),
        ),
    )
    generators = collect(get_components(ThermalStandard, sys))
    reserve = OnlineReserve{ReserveUp}(;
        name = _G1_RESERVE,
        available = true,
        time_frame = 0.0,
        requirement = 0.0,
        sustained_time = 3600,
        max_output_fraction = 1.0,
        max_participation_factor = 1.0,
        deployed_fraction = 0.0,
    )
    add_service!(sys, reserve, generators)
    monitored_name = "RADIAL1-RADIAL2-i_1"
    outage = _attach_outage!(
        sys,
        [first(generators)],
        [reserve],
        [get_component(Line, sys, monitored_name)],
    )

    reductions = PNM.NetworkReduction[DegreeTwoReduction()]
    template = PowerOperationsProblemTemplate(
        NetworkModel(
            PTDFNetworkModel;
            network_source = SystemNetworkSource(reductions...),
        ),
    )
    set_device_model!(template, ThermalStandard, ThermalBasicDispatch)
    set_device_model!(template, StandardLoad, StaticPowerLoad)
    set_device_model!(template, Line, StaticBranch)
    set_service_model!(
        template,
        ServiceModel(OnlineReserve{ReserveUp}, SecurityConstrainedContingencyReserve),
    )
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
          IOM.ModelBuildStatus.BUILT

    # Coefficient-level: the post-contingency flow is the pre-contingency flow plus a fresh
    # reduced PTDF row times the deployment and outaged power, mapped to reduced buses.
    container = IOM.get_optimization_container(model)
    network_model = IOM.get_network_model(IOM.get_template(model))
    catalog = POM.get_branch_catalog(network_model)
    reduction = POM.get_network_reduction(network_model)
    entry_name = PNM.get_component_to_reduction_name_map(catalog, Line)[monitored_name]
    @test entry_name != monitored_name

    ptdf = PNM.VirtualPTDF(sys; network_reductions = reductions)
    bus_axis = PNM.get_bus_axis(ptdf)
    row = ptdf[PNM.get_name_to_arc_map(catalog, Line)[entry_name], :]
    factor(component) =
        row[findfirst(
            ==(PNM.get_mapped_bus_number(reduction, PSY.get_bus(component))),
            bus_axis,
        )]

    uuid = IS.get_id(outage)
    deployments = _deployments(container)
    power = IOM.get_variable(container, ActivePowerVariable, ThermalStandard)
    post_flow = IOM.get_expression(container, PostContingencyBranchFlow, Line, "G1")
    pre_flow = IOM.get_expression(container, PTDFBranchFlow, Line)
    for t in IOM.get_time_steps(container)
        expected = copy(pre_flow[entry_name, t])
        for ((D, _, _, d, u, tt), var) in deployments
            (u == uuid && tt == t) || continue
            JuMP.add_to_expression!(expected, factor(get_component(D, sys, d)), var)
        end
        outaged = first(generators)
        JuMP.add_to_expression!(
            expected,
            -factor(outaged),
            power[PSY.get_name(outaged), t],
        )
        @test aff_exprs_approx_equal(post_flow[entry_name, uuid, t], expected)
    end
end

@testset "G-1 reserves validation" begin
    @testset "monitored interchange excluded by filter_function is rejected" begin
        sys, _ = g1_system()
        template = g1_template(
            AreaBalanceNetworkModel;
            interchange_filter = x -> PSY.get_name(x) != "1_2",
        )
        @test build!(g1_model(template, sys); output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.FAILED
    end

    @testset "monitored interchange without a device model is rejected" begin
        sys, _ = g1_system()
        template = g1_template(AreaBalanceNetworkModel; model_interchanges = false)
        @test build!(g1_model(template, sys); output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.FAILED
    end

    @testset "no AreaInterchange model warns and balances each area alone" begin
        sys, _ = g1_system(; monitored = s -> [get_component(Line, s, "2_2")])
        model = g1_model(
            g1_template(AreaBalanceNetworkModel; model_interchanges = false),
            sys,
        )
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        container = IOM.get_optimization_container(model)
        @test !IOM.has_container_key(
            container,
            PostContingencyDeviationVariable,
            AreaInterchange,
        )
        # `build!` logs to the model's log file, not the caller's logger.
        log_text = read(IOM.get_log_file(model), String)
        @test length(
            collect(eachmatch(r"each area must cover its own outages", log_text)),
        ) ==
              1
    end

    @testset "unmodeled outaged generator warns and is skipped" begin
        sys, outages = g1_system()
        online = get_component(OnlineReserve{ReserveUp}, sys, _G1_RESERVE)
        _attach_outage!(
            sys,
            [get_component(RenewableDispatch, sys, "PVBus5")],
            [online],
            [get_component(Line, sys, "2_2")],
        )
        template = g1_template(CopperPlateNetworkModel)
        delete!(template.devices, :RenewableDispatch)
        model = g1_model(template, sys)
        @test build!(model; output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.BUILT
        log_text = read(IOM.get_log_file(model), String)
        @test occursin(r"PVBus5.*is not modeled", log_text)
    end

    @testset "service models sharing an outage must agree on use_slacks" begin
        sys, _ = g1_system()
        template = g1_template(PTDFNetworkModel; offline_slacks = false)
        @test build!(g1_model(template, sys); output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.FAILED
    end

    @testset "down reserves are rejected" begin
        sys, _ = g1_system()
        template = g1_template(CopperPlateNetworkModel)
        set_service_model!(
            template,
            ServiceModel(OnlineReserve{ReserveDown}, SecurityConstrainedContingencyReserve),
        )
        @test build!(g1_model(template, sys); output_dir = mktempdir(; cleanup = true)) ==
              IOM.ModelBuildStatus.FAILED
    end
end
