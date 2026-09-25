# ACP network formulation. Provides bus voltage magnitude + angle
# variables, slack-bus pinning (vm + va), and active+reactive nodal balance.
# Branch flow variables, rate limits, and AC power flow constraints are added
# by the branch device construction path (Phase F).
#
# Convention: variables/constraints indexed by ACBus use bus NAME (String) — see dcp_model.jl.
# add_variables!(VoltageAngle, ...) for ACPNetworkModel is defined in dcp_model.jl
# via a Union dispatch shared with DCPNetworkModel (identical implementation).

function add_variables!(
    container::OptimizationContainer,
    ::Type{VoltageMagnitude},
    sys::PSY.System,
    network_model::NetworkModel{ACPNetworkModel},
)
    add_variables!(
        container,
        VoltageMagnitude,
        _network_buses(sys, network_model),
        ACPNetworkModel,
    )
    return
end

#! format: off
# bus voltage limits are already per-unit
get_variable_binary(::Type{VoltageMagnitude}, ::Type{PSY.ACBus}, ::Type{ACPNetworkModel}) = false
get_variable_lower_bound(::Type{VoltageMagnitude}, bus::PSY.ACBus, ::Type{ACPNetworkModel}) = PSY.get_voltage_limits(bus).min
get_variable_upper_bound(::Type{VoltageMagnitude}, bus::PSY.ACBus, ::Type{ACPNetworkModel}) = PSY.get_voltage_limits(bus).max
get_variable_warm_start_value(::Type{VoltageMagnitude}, bus::PSY.ACBus, ::Type{ACPNetworkModel}) = PSY.get_magnitude(bus)
#! format: on

function add_constraints!(
    container::OptimizationContainer,
    ::Type{ReferenceBusConstraint},
    sys::PSY.System,
    network_model::NetworkModel{ACPNetworkModel},
)
    time_steps = get_time_steps(container)
    va = get_variable(container, VoltageAngle, PSY.ACBus)
    vm = get_variable(container, VoltageMagnitude, PSY.ACBus)
    number_to_name = _retained_number_to_name(sys, network_model)
    subnets = network_model.subnetworks
    subnet_keys = collect(keys(subnets))

    cons_va = add_constraints_container!(
        container,
        ReferenceBusConstraint,
        PSY.ACBus,
        subnet_keys,
        time_steps;
        meta = "va",
    )
    cons_vm = add_constraints_container!(
        container,
        ReferenceBusConstraint,
        PSY.ACBus,
        subnet_keys,
        time_steps;
        meta = "vm",
    )

    for k in subnet_keys
        # `k` is the reference bus number already assigned by PNM (see the note in
        # dcp_model.jl). Pin both angle and magnitude at that bus directly. Only the
        # handful of reference buses are resolved (O(#subnets) name lookups), not a
        # whole-system number→bus map.
        ref_name = number_to_name[k]
        ref_bus = PSY.get_component(PSY.ACBus, sys, ref_name)
        _assert_reference_voltage_within_limits(ref_bus)
        v_set = PSY.get_magnitude(ref_bus)
        for t in time_steps
            cons_va[k, t] =
                JuMP.@constraint(get_jump_model(container), va[ref_name, t] == 0.0)
            cons_vm[k, t] =
                JuMP.@constraint(get_jump_model(container), vm[ref_name, t] == v_set)
        end
    end
    return
end
