# ACR network formulation. Provides bus voltage real (vr) and imaginary (vi)
# variables, slack-bus pinning (vi_ref == 0, vr_ref == vm_set), rectangular voltage-
# magnitude bounds, and active+reactive nodal balance.
#
# Branch flow variables, rate limits, and the rectangular AC Ohm's law are added by the
# branch device construction path (see AC_branches.jl and branch_constructor.jl).
#
# Convention: variables/constraints indexed by ACBus use bus NAME (String) — see dcp_model.jl.
# _bus_name_number_pairs / _retained_number_to_name / _bus_by_number are defined in
# dcp_model.jl (same module scope) and available here.

const _RectangularVoltageNetworks = Union{ACRNetworkModel, IVRNetworkModel}

function add_variables!(
    container::OptimizationContainer,
    ::Type{T},
    sys::PSY.System,
    network_model::NetworkModel{N},
) where {T <: Union{VoltageReal, VoltageImaginary}, N <: _RectangularVoltageNetworks}
    add_variables!(container, T, _network_buses(sys, network_model), N)
    return
end

#! format: off
# bus voltage limits are already per-unit
get_variable_binary(::Type{<:Union{VoltageReal, VoltageImaginary}}, ::Type{PSY.ACBus}, ::Type{<:_RectangularVoltageNetworks}) = false
get_variable_lower_bound(::Type{<:Union{VoltageReal, VoltageImaginary}}, bus::PSY.ACBus, ::Type{<:_RectangularVoltageNetworks}) = -PSY.get_voltage_limits(bus).max
get_variable_upper_bound(::Type{<:Union{VoltageReal, VoltageImaginary}}, bus::PSY.ACBus, ::Type{<:_RectangularVoltageNetworks}) = PSY.get_voltage_limits(bus).max
get_variable_warm_start_value(::Type{VoltageReal}, bus::PSY.ACBus, ::Type{<:_RectangularVoltageNetworks}) = PSY.get_magnitude(bus)
get_variable_warm_start_value(::Type{VoltageImaginary}, ::PSY.ACBus, ::Type{<:_RectangularVoltageNetworks}) = 0.0
#! format: on

function add_constraints!(
    container::OptimizationContainer,
    ::Type{ReferenceBusConstraint},
    sys::PSY.System,
    network_model::NetworkModel{<:Union{ACRNetworkModel, IVRNetworkModel}},
)
    time_steps = get_time_steps(container)
    vi = get_variable(container, VoltageImaginary, PSY.ACBus)
    vr = get_variable(container, VoltageReal, PSY.ACBus)
    number_to_name = _retained_number_to_name(sys, network_model)
    subnets = network_model.subnetworks
    subnet_keys = collect(keys(subnets))

    cons_vi = add_constraints_container!(
        container,
        ReferenceBusConstraint,
        PSY.ACBus,
        subnet_keys,
        time_steps;
        meta = "vi",
    )
    cons_vr = add_constraints_container!(
        container,
        ReferenceBusConstraint,
        PSY.ACBus,
        subnet_keys,
        time_steps;
        meta = "vr",
    )

    for k in subnet_keys
        # `k` is the reference bus number assigned by PNM. Pin vi = 0 (angle = 0)
        # and vr = v_set (magnitude setpoint). With vi = 0, vr = sqrt(vr^2) = vm.
        # Only the reference buses are resolved (O(#subnets) name lookups), not a
        # whole-system number→bus map.
        ref_name = number_to_name[k]
        ref_bus = PSY.get_component(PSY.ACBus, sys, ref_name)
        _assert_reference_voltage_within_limits(ref_bus)
        v_set = PSY.get_magnitude(ref_bus)
        for t in time_steps
            cons_vi[k, t] =
                JuMP.@constraint(get_jump_model(container), vi[ref_name, t] == 0.0)
            cons_vr[k, t] =
                JuMP.@constraint(get_jump_model(container), vr[ref_name, t] == v_set)
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{VoltageMagnitudeConstraint},
    sys::PSY.System,
    network_model::NetworkModel{<:Union{ACRNetworkModel, IVRNetworkModel}},
)
    time_steps = get_time_steps(container)
    vr = get_variable(container, VoltageReal, PSY.ACBus)
    vi = get_variable(container, VoltageImaginary, PSY.ACBus)
    pairs = _bus_name_number_pairs(sys, network_model)
    bus_names = [name for (name, _) in pairs]
    bus_by_name = _bus_by_name(sys)

    cons = add_constraints_container!(
        container,
        VoltageMagnitudeConstraint,
        PSY.ACBus,
        bus_names,
        time_steps,
    )

    for name in bus_names
        bus = bus_by_name[name]
        # bus voltage limits are already per-unit
        vlim = PSY.get_voltage_limits(bus)
        for t in time_steps
            cons[name, t] = JuMP.@constraint(
                get_jump_model(container),
                vlim.min^2 <= vr[name, t]^2 + vi[name, t]^2 <= vlim.max^2,
            )
        end
    end
    return
end
