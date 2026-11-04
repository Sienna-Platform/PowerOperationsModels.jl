"""
Replace each `ThermalStandard` in `sys` (or only those in `names`) with a
`LogicalGenerationUnit` twin that keeps its data, services and time series.
"""
function replace_thermals_with_logical_units!(sys::PSY.System; names = nothing)
    thermals = collect(PSY.get_components(PSY.ThermalStandard, sys))
    isnothing(names) || filter!(d -> PSY.get_name(d) in names, thermals)
    for thermal in thermals
        services = collect(PSY.get_services(thermal))
        unit = PSY.LogicalGenerationUnit(;
            name = PSY.get_name(thermal),
            available = PSY.get_available(thermal),
            status = PSY.get_status(thermal),
            bus = PSY.get_bus(thermal),
            active_power = PSY.get_active_power(thermal, u"CU"),
            reactive_power = PSY.get_reactive_power(thermal, u"CU"),
            rating = PSY.get_rating(thermal, u"CU"),
            prime_mover_type = PSY.PrimeMovers.CC,
            active_power_limits = PSY.get_active_power_limits(thermal, u"CU"),
            reactive_power_limits = PSY.get_reactive_power_limits(thermal, u"CU"),
            ramp_limits = PSY.get_ramp_limits(thermal, u"CU/minute"),
            power_trajectory = nothing,
            time_limits = PSY.get_time_limits(thermal),
            start_time_limits = nothing,
            start_types = 1,
            operation_cost = PSY.get_operation_cost(thermal),
            base_power = PSY.get_base_power(thermal),
            time_at_status = PSY.get_time_at_status(thermal),
            commitment_mode = PSY.get_commitment_mode(thermal),
            switching_times = PSY.get_switching_times(thermal),
            input_basis = u"CU",
        )
        PSY.add_component!(sys, unit)
        PSY.copy_time_series!(unit, thermal)
        for service in services
            PSY.remove_service!(thermal, service)
        end
        PSY.remove_component!(sys, thermal)
        for service in services
            PSY.add_service!(unit, service, sys)
        end
    end
    return sys
end

"""Build and solve the thermal dispatch template with `T => F` as the only generator model."""
function solved_commitment_model(sys, ::Type{T}, ::Type{F}, network) where {T, F}
    template = get_thermal_dispatch_template_network(network)
    delete!(IOM.get_device_models(template), :ThermalStandard)
    set_device_model!(template, T, F)
    model = DecisionModel(template, sys; optimizer = HiGHS_optimizer)
    @assert build!(model; output_dir = mktempdir()) == IOM.ModelBuildStatus.BUILT
    @assert solve!(model) == IOM.RunStatus.SUCCESSFULLY_FINALIZED
    return model
end

_objective(model) = IOM.get_optimization_container(model).optimizer_stats.objective_value

logical_unit_objective(sys, ::Type{F}; network = CopperPlateNetworkModel) where {F} =
    _objective(solved_commitment_model(sys, PSY.LogicalGenerationUnit, F, network))

thermal_objective(sys, ::Type{F}; network = CopperPlateNetworkModel) where {F} =
    _objective(solved_commitment_model(sys, PSY.ThermalStandard, F, network))
