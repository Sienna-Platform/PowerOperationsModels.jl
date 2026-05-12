function check_hvdc_line_limits_consistency(
    d::Union{PSY.TwoTerminalHVDC, PSY.TModelHVDCLine},
)
    from_min = PSY.get_active_power_limits_from(d).min
    to_min = PSY.get_active_power_limits_to(d).min
    from_max = PSY.get_active_power_limits_from(d).max
    to_max = PSY.get_active_power_limits_to(d).max

    if from_max < to_min
        throw(
            IS.ConflictingInputsError(
                "From Max $(from_max) can't be a smaller value than To Min $(to_min)",
            ),
        )
    elseif to_max < from_min
        throw(
            IS.ConflictingInputsError(
                "To Max $(to_max) can't be a smaller value than From Min $(from_min)",
            ),
        )
    end
    return
end

#################################### Branch Variables ##################################################
#! format: off
get_variable_binary(::Type{FlowActivePowerSlackUpperBound}, ::Type{<:PSY.TwoTerminalHVDC}, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = false
get_variable_binary(::Type{FlowActivePowerSlackLowerBound}, ::Type{<:PSY.TwoTerminalHVDC}, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = false
get_variable_binary(::Type{HVDCPiecewiseLossVariable}, ::Type{<:PSY.TwoTerminalHVDC}, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = false
get_variable_binary(::Type{HVDCActivePowerReceivedFromVariable}, ::Type{<:PSY.TwoTerminalHVDC}, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = false
get_variable_binary(::Type{HVDCActivePowerReceivedToVariable}, ::Type{<:PSY.TwoTerminalHVDC}, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = false
get_variable_binary(::Type{HVDCPiecewiseBinaryLossVariable}, ::Type{<:PSY.TwoTerminalHVDC}, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = true
get_variable_binary(::Type{<:VariableType}, ::Type{<:PSY.TwoTerminalHVDC}, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = false
get_variable_binary(::Type{FlowActivePowerVariable}, ::Type{<:PSY.TwoTerminalHVDC}, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = false
get_variable_binary(::Type{HVDCFlowDirectionVariable}, ::Type{<:PSY.TwoTerminalHVDC}, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = true
get_variable_multiplier(::Type{FlowActivePowerVariable}, ::Type{<:PSY.TwoTerminalHVDC}, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = NaN
get_parameter_multiplier(::Type{FixValueParameter}, ::PSY.TwoTerminalHVDC, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = 1.0
get_variable_multiplier(::Type{FlowActivePowerFromToVariable}, ::Type{<:PSY.TwoTerminalHVDC}, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = -1.0
get_variable_multiplier(::Type{FlowActivePowerToFromVariable}, ::Type{<:PSY.TwoTerminalHVDC}, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = -1.0
get_variable_multiplier(::Type{HVDCLosses}, ::Type{<:PSY.TwoTerminalHVDC}, ::Type{HVDCTwoTerminalDispatch}) = -1.0
#= Per-device loss check (l1 == l0 == 0 → 0.0, else -1.0) should be computed inline
   at the call site if this distinction is needed.
function get_variable_multiplier(
    ::Type{HVDCLosses},
    ::Type{<:PSY.TwoTerminalHVDC},
    ::Type{HVDCTwoTerminalDispatch},
)
    return -1.0
end
=#

get_variable_lower_bound(::Type{FlowActivePowerVariable}, d::PSY.TwoTerminalHVDC, ::Type{HVDCTwoTerminalUnbounded}) = nothing
get_variable_upper_bound(::Type{FlowActivePowerVariable}, d::PSY.TwoTerminalHVDC, ::Type{HVDCTwoTerminalUnbounded}) = nothing
get_variable_lower_bound(::Type{FlowActivePowerVariable}, d::PSY.TwoTerminalHVDC, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = nothing
get_variable_upper_bound(::Type{FlowActivePowerVariable}, d::PSY.TwoTerminalHVDC, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = nothing
get_variable_lower_bound(::Type{HVDCLosses}, d::PSY.TwoTerminalHVDC, ::Type{HVDCTwoTerminalDispatch}) = 0.0
get_variable_upper_bound(::Type{FlowActivePowerFromToVariable}, d::PSY.TwoTerminalHVDC, ::Type{HVDCTwoTerminalDispatch}) = PSY.get_active_power_limits_from(d).max
get_variable_lower_bound(::Type{FlowActivePowerFromToVariable}, d::PSY.TwoTerminalHVDC, ::Type{HVDCTwoTerminalDispatch}) = PSY.get_active_power_limits_from(d).min
get_variable_upper_bound(::Type{FlowActivePowerToFromVariable}, d::PSY.TwoTerminalHVDC, ::Type{HVDCTwoTerminalDispatch}) = PSY.get_active_power_limits_to(d).max
get_variable_lower_bound(::Type{FlowActivePowerToFromVariable}, d::PSY.TwoTerminalHVDC, ::Type{HVDCTwoTerminalDispatch}) = PSY.get_active_power_limits_to(d).min
get_variable_upper_bound(::Type{HVDCActivePowerReceivedFromVariable}, d::PSY.TwoTerminalHVDC, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = PSY.get_active_power_limits_from(d).max
get_variable_lower_bound(::Type{HVDCActivePowerReceivedFromVariable}, d::PSY.TwoTerminalHVDC, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = PSY.get_active_power_limits_from(d).min
get_variable_upper_bound(::Type{HVDCActivePowerReceivedToVariable}, d::PSY.TwoTerminalHVDC, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = PSY.get_active_power_limits_to(d).max
get_variable_lower_bound(::Type{HVDCActivePowerReceivedToVariable}, d::PSY.TwoTerminalHVDC, ::Type{<:AbstractTwoTerminalDCLineFormulation}) = PSY.get_active_power_limits_to(d).min

function get_variable_upper_bound(
    ::Type{HVDCLosses},
    d::PSY.TwoTerminalHVDC,
    ::Type{HVDCTwoTerminalDispatch},
)
    loss = PSY.get_loss(d)
    if !isa(loss, PSY.LinearCurve)
        error(
            "HVDCTwoTerminalDispatch of branch $(PSY.get_name(d)) only accepts LinearCurve for loss models.",
        )
    end
    l1 = PSY.get_proportional_term(loss)
    l0 = PSY.get_constant_term(loss)
    if l1 == 0.0 && l0 == 0.0
        return 0.0
    else
        return nothing
    end
end

get_variable_upper_bound(::Type{HVDCPiecewiseLossVariable}, d::PSY.TwoTerminalHVDC, ::Type{<:Union{HVDCTwoTerminalDispatch, HVDCTwoTerminalPiecewiseLoss}}) = 1.0
get_variable_lower_bound(::Type{HVDCPiecewiseLossVariable}, d::PSY.TwoTerminalHVDC, ::Type{<:Union{HVDCTwoTerminalDispatch, HVDCTwoTerminalPiecewiseLoss}}) = 0.0

#################################### LCC ##################################################
# FIXME consolidate to one definition on supertype.
get_variable_binary(::Type{HVDCActivePowerReceivedFromVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCActivePowerReceivedToVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCReactivePowerReceivedFromVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCReactivePowerReceivedToVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCRectifierDelayAngleVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCInverterExtinctionAngleVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCRectifierPowerFactorAngleVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCInverterPowerFactorAngleVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCRectifierOverlapAngleVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCInverterOverlapAngleVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCRectifierDCVoltageVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCInverterDCVoltageVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCRectifierACCurrentVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCInverterACCurrentVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{DCLineCurrentFlowVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCRectifierTapSettingVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_binary(::Type{HVDCInverterTapSettingVariable}, ::Type{PSY.TwoTerminalLCCLine}, ::Type{HVDCTwoTerminalLCC}) = false
get_variable_upper_bound(::Type{HVDCRectifierDelayAngleVariable}, d::PSY.TwoTerminalLCCLine, ::Type{HVDCTwoTerminalLCC}) = PSY.get_rectifier_delay_angle_limits(d).max
get_variable_lower_bound(::Type{HVDCRectifierDelayAngleVariable}, d::PSY.TwoTerminalLCCLine, ::Type{HVDCTwoTerminalLCC}) = PSY.get_rectifier_delay_angle_limits(d).min
get_variable_upper_bound(::Type{HVDCInverterExtinctionAngleVariable}, d::PSY.TwoTerminalLCCLine, ::Type{HVDCTwoTerminalLCC}) = PSY.get_inverter_extinction_angle_limits(d).max
get_variable_lower_bound(::Type{HVDCInverterExtinctionAngleVariable}, d::PSY.TwoTerminalLCCLine, ::Type{HVDCTwoTerminalLCC}) = PSY.get_inverter_extinction_angle_limits(d).min
get_variable_upper_bound(::Type{HVDCRectifierTapSettingVariable}, d::PSY.TwoTerminalLCCLine, ::Type{HVDCTwoTerminalLCC}) = PSY.get_rectifier_tap_limits(d).max
get_variable_lower_bound(::Type{HVDCRectifierTapSettingVariable}, d::PSY.TwoTerminalLCCLine, ::Type{HVDCTwoTerminalLCC}) = PSY.get_rectifier_tap_limits(d).min
get_variable_upper_bound(::Type{HVDCInverterTapSettingVariable}, d::PSY.TwoTerminalLCCLine, ::Type{HVDCTwoTerminalLCC}) = PSY.get_inverter_tap_limits(d).max
get_variable_lower_bound(::Type{HVDCInverterTapSettingVariable}, d::PSY.TwoTerminalLCCLine, ::Type{HVDCTwoTerminalLCC}) = PSY.get_inverter_tap_limits(d).min
#! format: on
##########################################################
function get_default_time_series_names(
    ::Type{U},
    ::Type{V},
) where {U <: PSY.TwoTerminalHVDC, V <: AbstractTwoTerminalDCLineFormulation}
    return Dict{Type{<:TimeSeriesParameter}, String}()
end

function get_default_attributes(
    ::Type{U},
    ::Type{V},
) where {U <: PSY.TwoTerminalHVDC, V <: AbstractTwoTerminalDCLineFormulation}
    return Dict{String, Any}()
end

get_initial_conditions_device_model(
    ::OperationModel,
    ::DeviceModel{T, U},
) where {T <: PSY.TwoTerminalHVDC, U <: AbstractTwoTerminalDCLineFormulation} =
    DeviceModel(T, U)

####################################### PWL Constraints #######################################################

function _get_range_segments(::PSY.TwoTerminalHVDC, loss::PSY.LinearCurve)
    return 1:4
end

function _get_range_segments(
    ::PSY.TwoTerminalHVDC,
    loss::PSY.PiecewiseIncrementalCurve,
)
    loss_factors = PSY.get_slopes(loss)
    return 1:(2 * length(loss_factors) + 2)
end

function _add_dense_pwl_loss_variables!(
    container::OptimizationContainer,
    devices,
    model::DeviceModel{D, HVDCTwoTerminalPiecewiseLoss},
) where {D <: PSY.TwoTerminalHVDC}
    # Check if type and length of PWL loss model are the same for all devices
    _check_pwl_loss_model(devices)

    # Create Variables
    time_steps = get_time_steps(container)
    settings = get_settings(container)
    formulation = HVDCTwoTerminalPiecewiseLoss
    T = HVDCPiecewiseLossVariable
    binary = get_variable_binary(T, D, formulation)
    first_loss = PSY.get_loss(first(devices))
    if isa(first_loss, PSY.LinearCurve)
        len_segments = 4 # 2*1 + 2
    elseif isa(first_loss, PSY.PiecewiseIncrementalCurve)
        len_segments = 2 * length(PSY.get_slopes(first_loss)) + 2
    else
        error("Should not be here")
    end

    segments = ["pwl_$i" for i in 1:len_segments]
    T = HVDCPiecewiseLossVariable
    variable = add_variable_container!(container, T,
        D,
        PSY.get_name.(devices),
        segments,
        time_steps,
    )

    for t in time_steps, s in segments, d in devices
        name = PSY.get_name(d)
        variable[name, s, t] = JuMP.@variable(
            get_jump_model(container),
            base_name = "$(T)_$(D)_{$(name), $(s), $(t)}",
            binary = binary
        )
        ub = get_variable_upper_bound(T, d, formulation)
        ub !== nothing && JuMP.set_upper_bound(variable[name, s, t], ub)

        lb = get_variable_lower_bound(T, d, formulation)
        lb !== nothing && JuMP.set_lower_bound(variable[name, s, t], lb)

        if get_warm_start(settings)
            init = get_variable_warm_start_value(T, d, formulation)
            init !== nothing && JuMP.set_start_value(variable[name, s, t], init)
        end
    end
end

# Full Binary
function _add_sparse_pwl_loss_variables!(
    container::OptimizationContainer,
    devices,
    ::DeviceModel{D, HVDCTwoTerminalPiecewiseLoss},
) where {D <: PSY.TwoTerminalHVDC}
    # Check if type and length of PWL loss model are the same for all devices
    #_check_pwl_loss_model(devices)

    # Create Variables
    time_steps = get_time_steps(container)
    settings = get_settings(container)
    formulation = HVDCTwoTerminalPiecewiseLoss
    T = HVDCPiecewiseLossVariable
    binary_T = get_variable_binary(T, D, formulation)
    U = HVDCPiecewiseBinaryLossVariable
    binary_U = get_variable_binary(U, D, formulation)
    first_loss = PSY.get_loss(first(devices))
    if isa(first_loss, PSY.LinearCurve)
        len_segments = 3 # 2*1 + 1
    elseif isa(first_loss, PSY.PiecewiseIncrementalCurve)
        len_segments = 2 * length(PSY.get_slopes(first_loss)) + 1
    else
        error("Should not be here")
    end

    var_container = lazy_container_addition!(container, T, D)
    var_container_binary = lazy_container_addition!(container, U, D)

    for d in devices
        name = PSY.get_name(d)
        for t in time_steps
            pwlvars = Array{JuMP.VariableRef}(undef, len_segments)
            pwlvars_bin = Array{JuMP.VariableRef}(undef, len_segments)
            for i in 1:len_segments
                pwlvars[i] =
                    var_container[(name, i, t)] = JuMP.@variable(
                        get_jump_model(container),
                        base_name = "$(T)_$(name)_{pwl_$(i), $(t)}",
                        binary = binary_T
                    )
                ub = get_variable_upper_bound(T, d, formulation)
                ub !== nothing && JuMP.set_upper_bound(var_container[name, i, t], ub)

                lb = get_variable_lower_bound(T, d, formulation)
                lb !== nothing && JuMP.set_lower_bound(var_container[name, i, t], lb)

                pwlvars_bin[i] =
                    var_container_binary[(name, i, t)] = JuMP.@variable(
                        get_jump_model(container),
                        base_name = "$(U)_$(name)_{pwl_$(i), $(t)}",
                        binary = binary_U
                    )
            end
        end
    end
end

function _get_pwl_loss_params(d::PSY.TwoTerminalHVDC, loss::PSY.LinearCurve)
    from_to_loss_params = Vector{Float64}(undef, 4)
    to_from_loss_params = Vector{Float64}(undef, 4)
    loss_factor = PSY.get_proportional_term(loss)
    P_send0 = PSY.get_constant_term(loss)
    P_max_ft = PSY.get_active_power_limits_from(d).max
    P_max_tf = PSY.get_active_power_limits_to(d).max
    if P_max_ft != P_max_tf
        error(
            "HVDC Line $(PSY.get_name(d)) has non-symmetrical limits for from and to, that are not supported in the HVDCTwoTerminalPiecewiseLoss formulation",
        )
    end
    P_sendS = P_max_ft
    ### Update Params Vectors ###
    from_to_loss_params[1] = -P_sendS - P_send0
    from_to_loss_params[2] = -P_send0
    from_to_loss_params[3] = 0.0
    from_to_loss_params[4] = P_sendS * (1 - loss_factor)

    to_from_loss_params[1] = P_sendS * (1 - loss_factor)
    to_from_loss_params[2] = 0.0
    to_from_loss_params[3] = -P_send0
    to_from_loss_params[4] = -P_sendS - P_send0

    return from_to_loss_params, to_from_loss_params
end

function _get_pwl_loss_params(
    d::PSY.TwoTerminalHVDC,
    loss::PSY.PiecewiseIncrementalCurve,
)
    p_breakpoints = PSY.get_x_coords(loss)
    loss_factors = PSY.get_slopes(loss)
    len_segments = length(loss_factors)
    len_variables = 2 * len_segments + 2
    from_to_loss_params = Vector{Float64}(undef, len_variables)
    to_from_loss_params = similar(from_to_loss_params)
    P_max_ft = PSY.get_active_power_limits_from(d).max
    P_max_tf = PSY.get_active_power_limits_to(d).max
    if P_max_ft != P_max_tf
        error(
            "HVDC Line $(PSY.get_name(d)) has non-symmetrical limits for from and to, that are not supported in the HVDCTwoTerminalPiecewiseLoss formulation",
        )
    end
    if P_max_ft != last(p_breakpoints)
        error(
            "Maximum power limit $P_max_ft of HVDC Line $(PSY.get_name(d)) has different value of last breakpoint from Loss data $(last(p_breakpoints)).",
        )
    end
    ### Update Params Vectors ###
    ## Update from 1 to S
    for i in 1:len_segments
        from_to_loss_params[i] = -p_breakpoints[2 + len_segments - i] - p_breakpoints[1] # for i = 1: P_end, for i = len_segments: P_2
        to_from_loss_params[i] =
            p_breakpoints[2 + len_segments - i] * (1 - loss_factors[len_segments + 1 - i])
    end
    ## Update from S+1 and S+2
    from_to_loss_params[len_segments + 1] = -p_breakpoints[1] # P_send0
    from_to_loss_params[len_segments + 2] = 0.0
    to_from_loss_params[len_segments + 1] = 0.0
    to_from_loss_params[len_segments + 2] = -p_breakpoints[1] # P_send0
    ## Update from S+3 to 2S+2
    for i in 1:len_segments
        from_to_loss_params[2 + len_segments + i] =
            p_breakpoints[i + 1] * (1 - loss_factors[i])
        to_from_loss_params[2 + len_segments + i] = -p_breakpoints[i + 1] - p_breakpoints[1]
    end

    return from_to_loss_params, to_from_loss_params
end

function add_variables!(
    container::OptimizationContainer,
    ::Type{FlowActivePowerVariable},
    network_model::NetworkModel{CopperPlatePowerModel},
    devices::IS.FlattenIteratorWrapper{T},
    ::Type{U},
) where {T <: PSY.TwoTerminalHVDC, U <: AbstractBranchFormulation}
    inter_network_branches = T[]
    for d in devices
        ref_bus_from = get_reference_bus(network_model, PSY.get_arc(d).from)
        ref_bus_to = get_reference_bus(network_model, PSY.get_arc(d).to)
        if ref_bus_from != ref_bus_to
            push!(inter_network_branches, d)
        else
            @warn(
                "HVDC Line $(PSY.get_name(d)) is in the same subnetwork, so the line will not be modeled."
            )
        end
    end
    if !isempty(inter_network_branches)
        add_variables!(container, FlowActivePowerVariable, inter_network_branches, U)
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{T},
    devices::Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    ::DeviceModel{U, HVDCTwoTerminalPiecewiseLoss},
    ::NetworkModel{<:AbstractPowerModel},
) where {T <: HVDCFlowCalculationConstraint, U <: PSY.TwoTerminalHVDC}
    var_pwl = get_variable(container, HVDCPiecewiseLossVariable, U)
    var_pwl_bin = get_variable(container, HVDCPiecewiseBinaryLossVariable, U)
    names = PSY.get_name.(devices)
    time_steps = get_time_steps(container)
    flow_ft = get_variable(container, HVDCActivePowerReceivedFromVariable, U)
    flow_tf = get_variable(container, HVDCActivePowerReceivedToVariable, U)

    constraint_from_to =
        add_constraints_container!(container, T, U, names, time_steps; meta = "ft")
    constraint_to_from =
        add_constraints_container!(container, T, U, names, time_steps; meta = "tf")
    constraint_binary =
        add_constraints_container!(container, T, U, names, time_steps; meta = "bin")
    for d in devices
        name = PSY.get_name(d)
        loss = PSY.get_loss(d)
        from_to_params, to_from_params = _get_pwl_loss_params(d, loss)
        range_segments = 1:(length(from_to_params) - 1) # 1:(2S+1)
        for t in time_steps
            ## Add Equality Constraints ##
            constraint_from_to[name, t] = JuMP.@constraint(
                get_jump_model(container),
                flow_ft[name, t] ==
                sum(
                    var_pwl_bin[name, ix, t] * from_to_params[ix] for
                    ix in range_segments
                ) + sum(
                    var_pwl[name, ix, t] * (from_to_params[ix + 1] - from_to_params[ix]) for
                    ix in range_segments
                )
            )
            constraint_to_from[name, t] = JuMP.@constraint(
                get_jump_model(container),
                flow_tf[name, t] ==
                sum(
                    var_pwl_bin[name, ix, t] * to_from_params[ix] for
                    ix in range_segments
                ) + sum(
                    var_pwl[name, ix, t] * (to_from_params[ix + 1] - to_from_params[ix]) for
                    ix in range_segments
                )
            )
            ## Add Binary Bound ###
            constraint_binary[name, t] = JuMP.@constraint(
                get_jump_model(container),
                sum(var_pwl_bin[name, ix, t] for ix in range_segments) == 1.0
            )
            ## Add Bounds for Continuous ##
            for ix in range_segments
                JuMP.@constraint(
                    get_jump_model(container),
                    var_pwl[name, ix, t] <= var_pwl_bin[name, ix, t]
                )
                if ix == div(length(range_segments) + 1, 2)
                    JuMP.fix(var_pwl[name, ix, t], 0.0; force = true)
                end
            end
        end
    end
    return
end

#################################### Rate Limits Constraints ##################################################
function _get_flow_bounds(d::PSY.TwoTerminalHVDC)
    check_hvdc_line_limits_consistency(d)
    from_min = PSY.get_active_power_limits_from(d).min
    to_min = PSY.get_active_power_limits_to(d).min
    from_max = PSY.get_active_power_limits_from(d).max
    to_max = PSY.get_active_power_limits_to(d).max

    if from_min >= 0.0 && to_min >= 0.0
        min_rate = min(from_min, to_min)
    elseif from_min <= 0.0 && to_min <= 0.0
        min_rate = max(from_min, to_min)
    elseif from_min <= 0.0 && to_min >= 0.0
        min_rate = from_min
    elseif to_min <= 0.0 && from_min >= 0.0
        min_rate = to_min
    end

    if from_max >= 0.0 && to_max >= 0.0
        max_rate = min(from_max, to_max)
    elseif from_max <= 0.0 && to_max <= 0.0
        max_rate = max(from_max, to_max)
    elseif from_max <= 0.0 && to_max >= 0.0
        max_rate = from_max
    elseif from_max >= 0.0 && to_max <= 0.0
        max_rate = to_max
    end

    return min_rate, max_rate
end

add_constraints!(
    ::OptimizationContainer,
    ::Type{<:Union{FlowRateConstraintFromTo, FlowRateConstraintToFrom}},
    ::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, HVDCTwoTerminalUnbounded},
    ::NetworkModel{<:AbstractPowerModel},
) where {T <: PSY.TwoTerminalHVDC} = nothing

add_constraints!(
    ::OptimizationContainer,
    ::Type{FlowRateConstraint},
    ::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, HVDCTwoTerminalUnbounded},
    ::NetworkModel{<:AbstractPowerModel},
) where {T <: PSY.TwoTerminalHVDC} = nothing

function add_constraints!(
    container::OptimizationContainer,
    ::Type{T},
    devices::Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    ::DeviceModel{U, HVDCTwoTerminalLossless},
    ::NetworkModel{<:AbstractPowerModel},
) where {T <: FlowRateConstraint, U <: PSY.TwoTerminalHVDC}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)

    var = get_variable(container, FlowActivePowerVariable, U)
    constraint_ub =
        add_constraints_container!(container, T, U, names, time_steps; meta = "ub")
    constraint_lb =
        add_constraints_container!(container, T, U, names, time_steps; meta = "lb")
    for d in devices
        min_rate, max_rate = _get_flow_bounds(d)
        for t in time_steps
            constraint_ub[PSY.get_name(d), t] = JuMP.@constraint(
                get_jump_model(container),
                var[PSY.get_name(d), t] <= max_rate
            )
            constraint_lb[PSY.get_name(d), t] = JuMP.@constraint(
                get_jump_model(container),
                min_rate <= var[PSY.get_name(d), t]
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{T},
    devices::Union{Vector{U}, IS.FlattenIteratorWrapper{U}},
    ::DeviceModel{U, HVDCTwoTerminalLossless},
    network_model::NetworkModel{CopperPlatePowerModel},
) where {T <: FlowRateConstraint, U <: PSY.TwoTerminalHVDC}
    time_steps = get_time_steps(container)
    names = String[]
    modeled_devices = U[]

    for d in devices
        ref_bus_from = get_reference_bus(network_model, PSY.get_arc(d).from)
        ref_bus_to = get_reference_bus(network_model, PSY.get_arc(d).to)
        if ref_bus_from != ref_bus_to
            push!(names, PSY.get_name(d))
            push!(modeled_devices, d)
        end
    end

    var = get_variable(container, FlowActivePowerVariable, U)
    constraint_ub =
        add_constraints_container!(container, T, U, names, time_steps; meta = "ub")
    constraint_lb =
        add_constraints_container!(container, T, U, names, time_steps; meta = "lb")
    for d in modeled_devices
        min_rate, max_rate = _get_flow_bounds(d)
        for t in time_steps
            constraint_ub[PSY.get_name(d), t] = JuMP.@constraint(
                get_jump_model(container),
                var[PSY.get_name(d), t] <= max_rate
            )
            constraint_lb[PSY.get_name(d), t] = JuMP.@constraint(
                get_jump_model(container),
                min_rate <= var[PSY.get_name(d), t]
            )
        end
    end
    return
end

function _add_hvdc_flow_constraints!(
    container::OptimizationContainer,
    devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}},
    ::Type{FlowRateConstraintFromTo},
) where {T <: PSY.TwoTerminalHVDC}
    _add_hvdc_flow_constraints!(
        container,
        devices,
        FlowActivePowerFromToVariable,
        FlowRateConstraintFromTo,
    )
end

function _add_hvdc_flow_constraints!(
    container::OptimizationContainer,
    devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}},
    ::Type{FlowRateConstraintToFrom},
) where {T <: PSY.TwoTerminalHVDC}
    _add_hvdc_flow_constraints!(
        container,
        devices,
        FlowActivePowerToFromVariable,
        FlowRateConstraintToFrom,
    )
end

function _add_hvdc_flow_constraints!(
    container::OptimizationContainer,
    devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}},
    ::Type{V},
    ::Type{C},
) where {
    T <: PSY.TwoTerminalHVDC,
    V <: Union{
        FlowActivePowerFromToVariable,
        FlowActivePowerToFromVariable,
        HVDCActivePowerReceivedFromVariable,
        HVDCActivePowerReceivedToVariable,
    },
    C <: Union{FlowRateConstraintFromTo, FlowRateConstraintToFrom},
}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)

    variable = get_variable(container, V, T)
    constraint_ub =
        add_constraints_container!(
            container,
            C,
            T,
            names,
            time_steps;
            meta = "ub",
        )
    constraint_lb =
        add_constraints_container!(
            container,
            C,
            T,
            names,
            time_steps;
            meta = "lb",
        )
    for d in devices
        check_hvdc_line_limits_consistency(d)
        max_rate = get_variable_upper_bound(V, d, HVDCTwoTerminalDispatch)
        min_rate = get_variable_lower_bound(V, d, HVDCTwoTerminalDispatch)
        name = PSY.get_name(d)
        for t in time_steps
            constraint_ub[name, t] = JuMP.@constraint(
                get_jump_model(container),
                variable[name, t] <= max_rate
            )
            constraint_lb[name, t] = JuMP.@constraint(
                get_jump_model(container),
                min_rate <= variable[name, t]
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{T},
    devices::IS.FlattenIteratorWrapper{U},
    model::DeviceModel{U, HVDCTwoTerminalDispatch},
    network_model::NetworkModel{CopperPlatePowerModel},
) where {
    T <: Union{FlowRateConstraintFromTo, FlowRateConstraintToFrom},
    U <: PSY.TwoTerminalHVDC,
}
    inter_network_branches = U[]
    for d in devices
        ref_bus_from = get_reference_bus(network_model, PSY.get_arc(d).from)
        ref_bus_to = get_reference_bus(network_model, PSY.get_arc(d).to)
        if ref_bus_from != ref_bus_to
            push!(inter_network_branches, d)
        end
    end
    if !isempty(inter_network_branches)
        _add_hvdc_flow_constraints!(container, devices, T)
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{T},
    devices::IS.FlattenIteratorWrapper{U},
    ::DeviceModel{U, HVDCTwoTerminalDispatch},
    ::NetworkModel{<:AbstractDCPModel},
) where {
    T <: Union{FlowRateConstraintToFrom, FlowRateConstraintFromTo},
    U <: PSY.TwoTerminalHVDC,
}
    _add_hvdc_flow_constraints!(container, devices, T)
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{T},
    devices::IS.FlattenIteratorWrapper{U},
    ::DeviceModel{U, HVDCTwoTerminalDispatch},
    ::NetworkModel{<:AbstractPTDFModel},
) where {
    T <: Union{FlowRateConstraintToFrom, FlowRateConstraintFromTo},
    U <: PSY.TwoTerminalHVDC,
}
    _add_hvdc_flow_constraints!(container, devices, T)
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{T},
    devices::IS.FlattenIteratorWrapper{U},
    model::DeviceModel{U, V},
    network_model::NetworkModel{CopperPlatePowerModel},
) where {
    T <: Union{FlowRateConstraintFromTo, FlowRateConstraintToFrom},
    U <: PSY.TwoTerminalHVDC,
    V <: HVDCTwoTerminalPiecewiseLoss,
}
    inter_network_branches = U[]
    for d in devices
        ref_bus_from = get_reference_bus(network_model, PSY.get_arc(d).from)
        ref_bus_to = get_reference_bus(network_model, PSY.get_arc(d).to)
        if ref_bus_from != ref_bus_to
            push!(inter_network_branches, d)
        end
    end
    if !isempty(inter_network_branches)
        if T <: FlowRateConstraintFromTo
            _add_hvdc_flow_constraints!(
                container,
                devices,
                HVDCActivePowerReceivedFromVariable,
                T,
            )
        else
            _add_hvdc_flow_constraints!(
                container,
                devices,
                HVDCActivePowerReceivedToVariable,
                T,
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{T},
    devices::IS.FlattenIteratorWrapper{U},
    ::DeviceModel{U, V},
    ::NetworkModel{<:AbstractPTDFModel},
) where {
    T <: Union{FlowRateConstraintFromTo, FlowRateConstraintToFrom},
    U <: PSY.TwoTerminalHVDC,
    V <: HVDCTwoTerminalPiecewiseLoss,
}
    if T <: FlowRateConstraintFromTo
        _add_hvdc_flow_constraints!(
            container,
            devices,
            HVDCActivePowerReceivedFromVariable,
            T,
        )
    else
        _add_hvdc_flow_constraints!(
            container,
            devices,
            HVDCActivePowerReceivedToVariable,
            T,
        )
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCPowerBalance},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, <:AbstractTwoTerminalDCLineFormulation},
    ::NetworkModel{<:AbstractDCPModel},
) where {T <: PSY.TwoTerminalHVDC}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    tf_var = get_variable(container, FlowActivePowerToFromVariable, T)
    ft_var = get_variable(container, FlowActivePowerFromToVariable, T)
    direction_var = get_variable(container, HVDCFlowDirectionVariable, T)
    losses = get_variable(container, HVDCLosses, T)

    constraint_ft_ub = add_constraints_container!(container, HVDCPowerBalance,
        T,
        names,
        time_steps;
        meta = "ft_ub",
    )
    constraint_tf_ub = add_constraints_container!(container, HVDCPowerBalance,
        T,
        names,
        time_steps;
        meta = "tf_ub",
    )
    constraint_ft_lb = add_constraints_container!(container, HVDCPowerBalance,
        T,
        names,
        time_steps;
        meta = "tf_lb",
    )
    constraint_tf_lb = add_constraints_container!(container, HVDCPowerBalance,
        T,
        names,
        time_steps;
        meta = "ft_lb",
    )
    constraint_loss = add_constraints_container!(container, HVDCPowerBalance,
        T,
        names,
        time_steps;
        meta = "loss",
    )
    constraint_loss_aux1 = add_constraints_container!(container, HVDCPowerBalance,
        T,
        names,
        time_steps;
        meta = "loss_aux1",
    )
    constraint_loss_aux2 = add_constraints_container!(container, HVDCPowerBalance,
        T,
        names,
        time_steps;
        meta = "loss_aux2",
    )
    constraint_loss_aux3 = add_constraints_container!(container, HVDCPowerBalance,
        T,
        names,
        time_steps;
        meta = "loss_aux3",
    )
    constraint_loss_aux4 = add_constraints_container!(container, HVDCPowerBalance,
        T,
        names,
        time_steps;
        meta = "loss_aux4",
    )
    for d in devices
        name = PSY.get_name(d)
        loss = PSY.get_loss(d)
        if !isa(loss, PSY.LinearCurve)
            error(
                "HVDCTwoTerminalDispatch of branch $(name) only accepts LinearCurve for loss models.",
            )
        end
        l1 = PSY.get_proportional_term(loss)
        l0 = PSY.get_constant_term(loss)
        R_min_from, R_max_from = PSY.get_active_power_limits_from(d)
        R_min_to, R_max_to = PSY.get_active_power_limits_to(d)
        for t in get_time_steps(container)
            constraint_tf_ub[name, t] = JuMP.@constraint(
                get_jump_model(container),
                tf_var[name, t] <= R_max_to * direction_var[name, t]
            )
            constraint_tf_lb[name, t] = JuMP.@constraint(
                get_jump_model(container),
                tf_var[name, t] >= R_min_to * (1 - direction_var[name, t])
            )
            constraint_ft_ub[name, t] = JuMP.@constraint(
                get_jump_model(container),
                ft_var[name, t] <= R_max_from * (1 - direction_var[name, t])
            )
            constraint_ft_lb[name, t] = JuMP.@constraint(
                get_jump_model(container),
                ft_var[name, t] >= R_min_from * direction_var[name, t]
            )
            constraint_loss[name, t] = JuMP.@constraint(
                get_jump_model(container),
                tf_var[name, t] + ft_var[name, t] == losses[name, t]
            )
            constraint_loss_aux1[name, t] = JuMP.@constraint(
                get_jump_model(container),
                losses[name, t] >= l0 + l1 * ft_var[name, t]
            )
            constraint_loss_aux2[name, t] = JuMP.@constraint(
                get_jump_model(container),
                losses[name, t] >= l0 + l1 * tf_var[name, t]
            )
            constraint_loss_aux3[name, t] = JuMP.@constraint(
                get_jump_model(container),
                losses[name, t] <=
                l0 + l1 * ft_var[name, t] + M_VALUE * direction_var[name, t]
            )
            constraint_loss_aux4[name, t] = JuMP.@constraint(
                get_jump_model(container),
                losses[name, t] <=
                l0 + l1 * tf_var[name, t] + M_VALUE * (1 - direction_var[name, t])
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCRectifierDCLineVoltageConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, <:HVDCTwoTerminalLCC},
    ::NetworkModel{ACPPowerModel},
) where {T <: PSY.TwoTerminalLCCLine}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    rect_dc_voltage_var = get_variable(container, HVDCRectifierDCVoltageVariable, T)
    rect_ac_voltage_bus_var = get_variable(container, VoltageMagnitude, PSY.ACBus)
    rect_delay_angle_var = get_variable(container, HVDCRectifierDelayAngleVariable, T)
    rect_tap_setting_var = get_variable(container, HVDCRectifierTapSettingVariable, T)
    dc_line_current_var = get_variable(container, DCLineCurrentFlowVariable, T)

    constraint_rect_dc_volt =
        add_constraints_container!(container, HVDCRectifierDCLineVoltageConstraint,
            T,
            names,
            time_steps;
        )

    for d in devices
        name = PSY.get_name(d)
        rect_bridges = PSY.get_rectifier_bridges(d)
        dc_rect_com_reactance = PSY.get_rectifier_xc(d)
        rect_tap_ratio = PSY.get_rectifier_transformer_ratio(d)
        bus_from = PSY.get_arc(d).from
        bus_from_name = PSY.get_name(bus_from)

        for t in get_time_steps(container)
            constraint_rect_dc_volt[name, t] = JuMP.@constraint(
                get_jump_model(container),
                rect_dc_voltage_var[name, t] ==
                (3 * rect_bridges / pi) * (
                    sqrt(2) * (
                        rect_tap_ratio *
                        rect_ac_voltage_bus_var[bus_from_name, t] *
                        cos(rect_delay_angle_var[name, t])
                    ) / rect_tap_setting_var[name, t] -
                    dc_rect_com_reactance * dc_line_current_var[name, t]
                )
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCInverterDCLineVoltageConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, <:HVDCTwoTerminalLCC},
    ::NetworkModel{ACPPowerModel},
) where {T <: PSY.TwoTerminalLCCLine}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    inv_dc_voltage_var = get_variable(container, HVDCInverterDCVoltageVariable, T)
    inv_ac_voltage_bus_var = get_variable(container, VoltageMagnitude, PSY.ACBus)
    inv_extinction_angle_var =
        get_variable(container, HVDCInverterExtinctionAngleVariable, T)
    inv_tap_setting_var = get_variable(container, HVDCInverterTapSettingVariable, T)
    dc_line_current_var = get_variable(container, DCLineCurrentFlowVariable, T)

    constraint_inv_dc_volt =
        add_constraints_container!(container, HVDCInverterDCLineVoltageConstraint,
            T,
            names,
            time_steps;
        )

    for d in devices
        name = PSY.get_name(d)
        inv_bridges = PSY.get_inverter_bridges(d)
        dc_inv_com_reactance = PSY.get_inverter_xc(d)
        inv_tap_ratio = PSY.get_inverter_transformer_ratio(d)
        bus_to = PSY.get_arc(d).to
        bus_to_name = PSY.get_name(bus_to)

        for t in get_time_steps(container)
            constraint_inv_dc_volt[name, t] = JuMP.@constraint(
                get_jump_model(container),
                inv_dc_voltage_var[name, t] ==
                (3 * inv_bridges / pi) * (
                    sqrt(2) * (
                        inv_tap_ratio *
                        inv_ac_voltage_bus_var[bus_to_name, t] *
                        cos(inv_extinction_angle_var[name, t])
                    ) / inv_tap_setting_var[name, t] -
                    dc_inv_com_reactance * dc_line_current_var[name, t]
                )
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCRectifierOverlapAngleConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, <:HVDCTwoTerminalLCC},
    ::NetworkModel{ACPPowerModel},
) where {T <: PSY.TwoTerminalLCCLine}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    rect_ac_voltage_bus_var = get_variable(container, VoltageMagnitude, PSY.ACBus)
    rect_delay_angle_var = get_variable(container, HVDCRectifierDelayAngleVariable, T)
    rect_overlap_angle_var = get_variable(container, HVDCRectifierOverlapAngleVariable, T)
    rect_tap_setting_var = get_variable(container, HVDCRectifierTapSettingVariable, T)
    dc_line_current_var = get_variable(container, DCLineCurrentFlowVariable, T)

    constraint_rect_over_ang =
        add_constraints_container!(container, HVDCRectifierOverlapAngleConstraint,
            T,
            names,
            time_steps;
        )

    for d in devices
        name = PSY.get_name(d)
        dc_rect_com_reactance = PSY.get_rectifier_xc(d)
        rect_tap_ratio = PSY.get_rectifier_transformer_ratio(d)
        bus_from = PSY.get_arc(d).from
        bus_from_name = PSY.get_name(bus_from)

        for t in get_time_steps(container)
            constraint_rect_over_ang[name, t] = JuMP.@constraint(
                get_jump_model(container),
                rect_overlap_angle_var[name, t] == (
                    acos(
                        cos(rect_delay_angle_var[name, t])
                        -
                        (
                            (
                                sqrt(2) * dc_rect_com_reactance *
                                dc_line_current_var[name, t] *
                                rect_tap_setting_var[name, t]
                            )
                            /
                            (
                                rect_tap_ratio *
                                rect_ac_voltage_bus_var[bus_from_name, t]
                            )
                        ),
                    )
                    -
                    rect_delay_angle_var[name, t]
                )
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCInverterOverlapAngleConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, <:HVDCTwoTerminalLCC},
    ::NetworkModel{ACPPowerModel},
) where {T <: PSY.TwoTerminalLCCLine}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    inv_ac_voltage_bus_var = get_variable(container, VoltageMagnitude, PSY.ACBus)
    inv_extinction_angle_var =
        get_variable(container, HVDCInverterExtinctionAngleVariable, T)
    inv_overlap_angle_var = get_variable(container, HVDCInverterOverlapAngleVariable, T)
    inv_tap_setting_var = get_variable(container, HVDCInverterTapSettingVariable, T)
    dc_line_current_var = get_variable(container, DCLineCurrentFlowVariable, T)

    constraint_inv_over_ang =
        add_constraints_container!(container, HVDCInverterOverlapAngleConstraint,
            T,
            names,
            time_steps;
        )

    for d in devices
        name = PSY.get_name(d)
        dc_inv_com_reactance = PSY.get_inverter_xc(d)
        inv_tap_ratio = PSY.get_inverter_transformer_ratio(d)
        bus_to = PSY.get_arc(d).to
        bus_to_name = PSY.get_name(bus_to)

        for t in get_time_steps(container)
            constraint_inv_over_ang[name, t] = JuMP.@constraint(
                get_jump_model(container),
                inv_overlap_angle_var[name, t] == (
                    acos(
                        cos(inv_extinction_angle_var[name, t])
                        -
                        (
                            (
                                sqrt(2) * dc_inv_com_reactance *
                                dc_line_current_var[name, t] *
                                inv_tap_setting_var[name, t]
                            )
                            /
                            (
                                inv_tap_ratio *
                                inv_ac_voltage_bus_var[bus_to_name, t]
                            )
                        ),
                    )
                    -
                    inv_extinction_angle_var[name, t]
                )
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCRectifierPowerFactorAngleConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, <:HVDCTwoTerminalLCC},
    ::NetworkModel{ACPPowerModel},
) where {T <: PSY.TwoTerminalLCCLine}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    rect_delay_angle_var = get_variable(container, HVDCRectifierDelayAngleVariable, T)
    rect_overlap_angle_var = get_variable(container, HVDCRectifierOverlapAngleVariable, T)
    rect_power_factor_var =
        get_variable(container, HVDCRectifierPowerFactorAngleVariable, T)

    constraint_rect_power_factor_ang =
        add_constraints_container!(container, HVDCRectifierPowerFactorAngleConstraint,
            T,
            names,
            time_steps;
        )

    for d in devices
        name = PSY.get_name(d)

        for t in get_time_steps(container)
            constraint_rect_power_factor_ang[name, t] = JuMP.@constraint(
                get_jump_model(container),
                # Full equation not working with Ipopt
                # rect_power_factor_var[name, t] *
                #     (
                #         cos(2 * rect_delay_angle_var[name, t]) - cos(
                #             2(
                #                 rect_overlap_angle_var[name, t] +
                #                 rect_delay_angle_var[name, t]
                #             ),
                #         )
                #     ) == atan(
                #     (
                #         - 2 * rect_overlap_angle_var[name, t] +
                #         - sin(2 * rect_delay_angle_var[name, t]) + sin(
                #             2 * (
                #                 rect_overlap_angle_var[name, t] +
                #                 rect_delay_angle_var[name, t]
                #             ),
                #         )
                #     )
                # )

                # Approximation of rectifier power factor calculation
                rect_power_factor_var[name, t] == acos(
                    0.5 * cos(rect_delay_angle_var[name, t]) +
                    0.5 * cos(
                        rect_delay_angle_var[name, t] + rect_overlap_angle_var[name, t],
                    ),
                )
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCInverterPowerFactorAngleConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, <:HVDCTwoTerminalLCC},
    ::NetworkModel{ACPPowerModel},
) where {T <: PSY.TwoTerminalLCCLine}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    inv_extinction_angle_var =
        get_variable(container, HVDCInverterExtinctionAngleVariable, T)
    inv_overlap_angle_var = get_variable(container, HVDCInverterOverlapAngleVariable, T)
    inv_power_factor_var =
        get_variable(container, HVDCInverterPowerFactorAngleVariable, T)

    constraint_inv_power_factor_ang =
        add_constraints_container!(container, HVDCInverterPowerFactorAngleConstraint,
            T,
            names,
            time_steps;
        )

    for d in devices
        name = PSY.get_name(d)

        for t in get_time_steps(container)
            constraint_inv_power_factor_ang[name, t] = JuMP.@constraint(
                get_jump_model(container),
                # Full equation not working with Ipopt
                # inv_power_factor_var[name, t] *
                #     (
                #         cos(2 * inv_extinction_angle_var[name, t]) - cos(
                #             2(
                #                 inv_overlap_angle_var[name, t] +
                #                 inv_extinction_angle_var[name, t]
                #             ),
                #         )
                #     ) == atan(
                #     (
                #         - 2 * inv_overlap_angle_var[name, t] +
                #         - sin(2 * inv_extinction_angle_var[name, t]) + sin(
                #             2 * (
                #                 inv_overlap_angle_var[name, t] +
                #                 inv_extinction_angle_var[name, t]
                #             ),
                #         )
                #     )
                # )

                # Approximation of inverter power factor calculation
                inv_power_factor_var[name, t] == acos(
                    0.5 * cos(inv_extinction_angle_var[name, t]) +
                    0.5 * cos(
                        inv_extinction_angle_var[name, t] + inv_overlap_angle_var[name, t],
                    ),
                )
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCRectifierACCurrentFlowConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, <:HVDCTwoTerminalLCC},
    ::NetworkModel{ACPPowerModel},
) where {T <: PSY.TwoTerminalLCCLine}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    rect_ac_current_var = get_variable(container, HVDCRectifierACCurrentVariable, T)
    dc_line_current_var = get_variable(container, DCLineCurrentFlowVariable, T)

    constraint_rect_ac_current =
        add_constraints_container!(container, HVDCRectifierACCurrentFlowConstraint,
            T,
            names,
            time_steps;
        )

    for d in devices
        name = PSY.get_name(d)
        rect_bridges = PSY.get_rectifier_bridges(d)

        for t in get_time_steps(container)
            constraint_rect_ac_current[name, t] = JuMP.@constraint(
                get_jump_model(container),
                rect_ac_current_var[name, t] ==
                sqrt(6) * rect_bridges * dc_line_current_var[name, t] / pi
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCInverterACCurrentFlowConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, <:HVDCTwoTerminalLCC},
    ::NetworkModel{ACPPowerModel},
) where {T <: PSY.TwoTerminalLCCLine}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    inv_ac_current_var = get_variable(container, HVDCInverterACCurrentVariable, T)
    dc_line_current_var = get_variable(container, DCLineCurrentFlowVariable, T)

    constraint_inv_ac_current =
        add_constraints_container!(container, HVDCInverterACCurrentFlowConstraint,
            T,
            names,
            time_steps;
        )

    for d in devices
        name = PSY.get_name(d)
        inv_bridges = PSY.get_inverter_bridges(d)

        for t in get_time_steps(container)
            constraint_inv_ac_current[name, t] = JuMP.@constraint(
                get_jump_model(container),
                inv_ac_current_var[name, t] ==
                sqrt(6) * inv_bridges * dc_line_current_var[name, t] / pi
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCRectifierPowerCalculationConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, <:HVDCTwoTerminalLCC},
    ::NetworkModel{ACPPowerModel},
) where {T <: PSY.TwoTerminalLCCLine}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    rect_ac_ppower_var = get_variable(container, HVDCActivePowerReceivedFromVariable, T)
    rect_ac_qpower_var = get_variable(container, HVDCReactivePowerReceivedFromVariable, T)
    rect_ac_current_var = get_variable(container, HVDCRectifierACCurrentVariable, T)
    rect_ac_voltage_bus_var = get_variable(container, VoltageMagnitude, PSY.ACBus)
    rect_power_factor_var =
        get_variable(container, HVDCRectifierPowerFactorAngleVariable, T)
    rect_tap_setting_var = get_variable(container, HVDCRectifierTapSettingVariable, T)

    constraint_ft_p =
        add_constraints_container!(container, HVDCRectifierPowerCalculationConstraint,
            T,
            names,
            time_steps;
            meta = "active",
        )
    constraint_ft_q =
        add_constraints_container!(container, HVDCRectifierPowerCalculationConstraint,
            T,
            names,
            time_steps;
            meta = "reactive",
        )

    for d in devices
        name = PSY.get_name(d)
        rect_tap_ratio = PSY.get_rectifier_transformer_ratio(d)
        bus_from = PSY.get_arc(d).from
        bus_from_name = PSY.get_name(bus_from)

        for t in get_time_steps(container)
            constraint_ft_p[name, t] = JuMP.@constraint(
                get_jump_model(container),
                rect_ac_ppower_var[name, t] ==
                (
                    rect_tap_ratio * sqrt(3) * rect_ac_current_var[name, t]
                    * rect_ac_voltage_bus_var[bus_from_name, t] *
                    cos(rect_power_factor_var[name, t])
                ) / rect_tap_setting_var[name, t],
            )
            constraint_ft_q[name, t] = JuMP.@constraint(
                get_jump_model(container),
                rect_ac_qpower_var[name, t] ==
                (
                    rect_tap_ratio * sqrt(3) * rect_ac_current_var[name, t]
                    * rect_ac_voltage_bus_var[bus_from_name, t] *
                    sin(rect_power_factor_var[name, t])
                ) / rect_tap_setting_var[name, t],
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCInverterPowerCalculationConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, <:HVDCTwoTerminalLCC},
    ::NetworkModel{ACPPowerModel},
) where {T <: PSY.TwoTerminalLCCLine}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    inv_ac_ppower_var = get_variable(container, HVDCActivePowerReceivedToVariable, T)
    inv_ac_qpower_var = get_variable(container, HVDCReactivePowerReceivedToVariable, T)
    inv_ac_current_var = get_variable(container, HVDCInverterACCurrentVariable, T)
    inv_ac_voltage_bus_var = get_variable(container, VoltageMagnitude, PSY.ACBus)
    inv_power_factor_var =
        get_variable(container, HVDCInverterPowerFactorAngleVariable, T)
    inv_tap_setting_var = get_variable(container, HVDCInverterTapSettingVariable, T)

    constraint_ft_p =
        add_constraints_container!(container, HVDCInverterPowerCalculationConstraint,
            T,
            names,
            time_steps;
            meta = "active",
        )
    constraint_ft_q =
        add_constraints_container!(container, HVDCInverterPowerCalculationConstraint,
            T,
            names,
            time_steps;
            meta = "reactive",
        )

    for d in devices
        name = PSY.get_name(d)
        inv_tap_ratio = PSY.get_inverter_transformer_ratio(d)
        bus_to = PSY.get_arc(d).to
        bus_to_name = PSY.get_name(bus_to)

        for t in get_time_steps(container)
            constraint_ft_p[name, t] = JuMP.@constraint(
                get_jump_model(container),
                inv_ac_ppower_var[name, t] ==
                (
                    inv_tap_ratio * sqrt(3) * inv_ac_current_var[name, t]
                    * inv_ac_voltage_bus_var[bus_to_name, t] *
                    cos(inv_power_factor_var[name, t])
                ) / inv_tap_setting_var[name, t],
            )
            constraint_ft_q[name, t] = JuMP.@constraint(
                get_jump_model(container),
                inv_ac_qpower_var[name, t] ==
                (
                    inv_tap_ratio * sqrt(3) * inv_ac_current_var[name, t]
                    * inv_ac_voltage_bus_var[bus_to_name, t] *
                    sin(inv_power_factor_var[name, t])
                ) / inv_tap_setting_var[name, t],
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCTransmissionDCLineConstraint},
    devices::IS.FlattenIteratorWrapper{T},
    ::DeviceModel{T, <:HVDCTwoTerminalLCC},
    ::NetworkModel{ACPPowerModel},
) where {T <: PSY.TwoTerminalLCCLine}
    time_steps = get_time_steps(container)
    names = PSY.get_name.(devices)
    rect_dc_voltage_var = get_variable(container, HVDCRectifierDCVoltageVariable, T)
    inv_dc_voltage_var = get_variable(container, HVDCInverterDCVoltageVariable, T)
    dc_line_current_var = get_variable(container, DCLineCurrentFlowVariable, T)

    constraint_tl_c =
        add_constraints_container!(container, HVDCTransmissionDCLineConstraint,
            T,
            names,
            time_steps;
        )

    for d in devices
        name = PSY.get_name(d)
        dc_line_resistance = PSY.get_r(d)

        for t in get_time_steps(container)
            constraint_tl_c[name, t] = JuMP.@constraint(
                get_jump_model(container),
                inv_dc_voltage_var[name, t] ==
                rect_dc_voltage_var[name, t] -
                dc_line_resistance * dc_line_current_var[name, t]
            )
        end
    end
    return
end

##############################################################################
####################### Two-Terminal VSC Formulation #########################
##############################################################################

#! format: off

# Variable trait methods for the shared cable current and DC voltages
get_variable_binary(::Type{DCLineCurrentFlowVariable}, ::Type{PSY.TwoTerminalVSCLine}, ::Type{<:AbstractTwoTerminalVSCFormulation}) = false
get_variable_binary(::Type{HVDCFromDCVoltage}, ::Type{PSY.TwoTerminalVSCLine}, ::Type{<:AbstractTwoTerminalVSCFormulation}) = false
get_variable_binary(::Type{HVDCToDCVoltage}, ::Type{PSY.TwoTerminalVSCLine}, ::Type{<:AbstractTwoTerminalVSCFormulation}) = false
get_variable_binary(::Type{<:HVDCReactivePowerVariable}, ::Type{PSY.TwoTerminalVSCLine}, ::Type{<:AbstractTwoTerminalVSCFormulation}) = false
get_variable_binary(::Type{PositiveCurrent}, ::Type{PSY.TwoTerminalVSCLine}, ::Type{<:AbstractTwoTerminalVSCFormulation}) = false
get_variable_binary(::Type{NegativeCurrent}, ::Type{PSY.TwoTerminalVSCLine}, ::Type{<:AbstractTwoTerminalVSCFormulation}) = false
get_variable_binary(::Type{CurrentDirection}, ::Type{PSY.TwoTerminalVSCLine}, ::Type{<:AbstractTwoTerminalVSCFormulation}) = true
get_variable_binary(::Type{FlowActivePowerFromToVariable}, ::Type{PSY.TwoTerminalVSCLine}, ::Type{<:AbstractTwoTerminalVSCFormulation}) = false
get_variable_binary(::Type{FlowActivePowerToFromVariable}, ::Type{PSY.TwoTerminalVSCLine}, ::Type{<:AbstractTwoTerminalVSCFormulation}) = false

# Warm starts
get_variable_warm_start_value(::Type{DCLineCurrentFlowVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_dc_current(d)
get_variable_warm_start_value(::Type{HVDCReactivePowerFromVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_reactive_power_from(d)
get_variable_warm_start_value(::Type{HVDCReactivePowerToVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_reactive_power_to(d)
get_variable_warm_start_value(::Type{FlowActivePowerFromToVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_active_power_flow(d)
get_variable_warm_start_value(::Type{FlowActivePowerToFromVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = -PSY.get_active_power_flow(d)

# Active power flow bounds (per-terminal)
get_variable_lower_bound(::Type{FlowActivePowerFromToVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_active_power_limits_from(d).min
get_variable_upper_bound(::Type{FlowActivePowerFromToVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_active_power_limits_from(d).max
get_variable_lower_bound(::Type{FlowActivePowerToFromVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_active_power_limits_to(d).min
get_variable_upper_bound(::Type{FlowActivePowerToFromVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_active_power_limits_to(d).max

# Reactive power bounds (per-terminal)
get_variable_lower_bound(::Type{HVDCReactivePowerFromVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_reactive_power_limits_from(d).min
get_variable_upper_bound(::Type{HVDCReactivePowerFromVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_reactive_power_limits_from(d).max
get_variable_lower_bound(::Type{HVDCReactivePowerToVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_reactive_power_limits_to(d).min
get_variable_upper_bound(::Type{HVDCReactivePowerToVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_reactive_power_limits_to(d).max

# DC voltage bounds (per-terminal)
get_variable_lower_bound(::Type{HVDCFromDCVoltage}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_voltage_limits_from(d).min
get_variable_upper_bound(::Type{HVDCFromDCVoltage}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_voltage_limits_from(d).max
get_variable_lower_bound(::Type{HVDCToDCVoltage}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_voltage_limits_to(d).min
get_variable_upper_bound(::Type{HVDCToDCVoltage}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = PSY.get_voltage_limits_to(d).max

# Shared cable current bounds — must respect BOTH terminals' I_max ratings
_vsc_shared_i_max(d::PSY.TwoTerminalVSCLine) =
    min(PSY.get_max_dc_current_from(d), PSY.get_max_dc_current_to(d))
get_variable_lower_bound(::Type{DCLineCurrentFlowVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = -_vsc_shared_i_max(d)
get_variable_upper_bound(::Type{DCLineCurrentFlowVariable}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = _vsc_shared_i_max(d)

# Positive/negative parts: each in [0, i_max]
get_variable_lower_bound(::Type{PositiveCurrent}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = 0.0
get_variable_upper_bound(::Type{PositiveCurrent}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = _vsc_shared_i_max(d)
get_variable_lower_bound(::Type{NegativeCurrent}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = 0.0
get_variable_upper_bound(::Type{NegativeCurrent}, d::PSY.TwoTerminalVSCLine, ::Type{<:AbstractTwoTerminalVSCFormulation}) = _vsc_shared_i_max(d)

#! format: on

####################### VSC reactive-power optional path #####################
# The reactive power and PQ capability machinery is added only when the
# network actually models reactive power. On active-only networks these
# helpers are no-ops.

function _maybe_add_reactive_power_variables!(
    container::OptimizationContainer,
    devices,
    model::DeviceModel{PSY.TwoTerminalVSCLine, F},
    network_model::NetworkModel{<:AbstractPowerModel},
) where {F <: AbstractTwoTerminalVSCFormulation}
    add_variables!(container, HVDCReactivePowerFromVariable, devices, F)
    add_variables!(container, HVDCReactivePowerToVariable, devices, F)
    add_to_expression!(
        container, ReactivePowerBalance, HVDCReactivePowerFromVariable,
        devices, model, network_model,
    )
    add_to_expression!(
        container, ReactivePowerBalance, HVDCReactivePowerToVariable,
        devices, model, network_model,
    )
    return
end

_maybe_add_reactive_power_variables!(
    ::OptimizationContainer,
    _devices,
    ::DeviceModel{PSY.TwoTerminalVSCLine, <:AbstractTwoTerminalVSCFormulation},
    ::NetworkModel{<:AbstractActivePowerModel},
) = nothing

function _maybe_add_reactive_power_constraints!(
    container::OptimizationContainer,
    devices,
    model::DeviceModel{PSY.TwoTerminalVSCLine, F},
    network_model::NetworkModel{<:AbstractPowerModel},
) where {F <: AbstractTwoTerminalVSCFormulation}
    add_constraints!(
        container, HVDCVSCReactiveCapabilityConstraint,
        devices, model, network_model,
    )
    return
end

_maybe_add_reactive_power_constraints!(
    ::OptimizationContainer,
    _devices,
    ::DeviceModel{PSY.TwoTerminalVSCLine, <:AbstractTwoTerminalVSCFormulation},
    ::NetworkModel{<:AbstractActivePowerModel},
) = nothing

####################### VSC core constraints ################################

# Cable Ohm's law:  v_f - v_t = (1/g) * I
function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCCableOhmsLawConstraint},
    devices::Union{
        Vector{PSY.TwoTerminalVSCLine},
        IS.FlattenIteratorWrapper{PSY.TwoTerminalVSCLine},
    },
    ::DeviceModel{PSY.TwoTerminalVSCLine, F},
    ::NetworkModel{<:AbstractPowerModel},
) where {F <: AbstractTwoTerminalVSCFormulation}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    jump_model = get_jump_model(container)
    v_f = get_variable(container, HVDCFromDCVoltage, PSY.TwoTerminalVSCLine)
    v_t = get_variable(container, HVDCToDCVoltage, PSY.TwoTerminalVSCLine)
    i_var = get_variable(container, DCLineCurrentFlowVariable, PSY.TwoTerminalVSCLine)

    cons = add_constraints_container!(
        container, HVDCCableOhmsLawConstraint, PSY.TwoTerminalVSCLine,
        names, time_steps,
    )

    for d in devices
        name = PSY.get_name(d)
        g = PSY.get_g(d)
        for t in time_steps
            cons[name, t] = if iszero(g)
                JuMP.@constraint(jump_model, i_var[name, t] == 0)
            else
                JuMP.@constraint(
                    jump_model,
                    v_f[name, t] - v_t[name, t] == (1.0 / g) * i_var[name, t],
                )
            end
        end
    end
    return
end

# Per-terminal converter power balance:
#   p_ft ==  v_f * I + (a_f * I^2 + b_f * |I| + c_f)
#   p_tf == -v_t * I + (a_t * I^2 + b_t * |I| + c_t)
# Sign convention: FlowActivePowerFromToVariable / ToFromVariable are positive
# when the corresponding AC bus is sourcing power into the converter (matches
# the existing add_to_expression! method's -1.0 multiplier).
function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCVSCConverterPowerConstraint},
    devices::Union{
        Vector{PSY.TwoTerminalVSCLine},
        IS.FlattenIteratorWrapper{PSY.TwoTerminalVSCLine},
    },
    model::DeviceModel{PSY.TwoTerminalVSCLine, F},
    ::NetworkModel{<:AbstractPowerModel},
) where {F <: AbstractTwoTerminalVSCFormulation}
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    jump_model = get_jump_model(container)

    p_ft = get_variable(container, FlowActivePowerFromToVariable, PSY.TwoTerminalVSCLine)
    p_tf = get_variable(container, FlowActivePowerToFromVariable, PSY.TwoTerminalVSCLine)
    vi_expr = get_expression(
        container,
        IOM.BilinearProductExpression,
        PSY.TwoTerminalVSCLine,
        "vi_ft",
    )
    vi_expr_to = get_expression(
        container,
        IOM.BilinearProductExpression,
        PSY.TwoTerminalVSCLine,
        "vi_tf",
    )
    i_sq_expr =
        get_expression(container, IOM.QuadraticExpression, PSY.TwoTerminalVSCLine, "i_sq")

    use_linear_loss =
        get_attribute(model, "use_linear_loss") &&
        !isempty(_devices_with_linear_loss(devices))
    if use_linear_loss
        i_pos_var = get_variable(container, PositiveCurrent, PSY.TwoTerminalVSCLine)
        i_neg_var = get_variable(container, NegativeCurrent, PSY.TwoTerminalVSCLine)
    end

    cons_ft = add_constraints_container!(
        container, HVDCVSCConverterPowerConstraint, PSY.TwoTerminalVSCLine,
        names, time_steps; meta = "ft",
    )
    cons_tf = add_constraints_container!(
        container, HVDCVSCConverterPowerConstraint, PSY.TwoTerminalVSCLine,
        names, time_steps; meta = "tf",
    )

    for d in devices
        name = PSY.get_name(d)
        loss_from = PSY.get_converter_loss_from(d)
        loss_to = PSY.get_converter_loss_to(d)
        a_f = _get_quadratic_term(loss_from)
        b_f = PSY.get_proportional_term(loss_from)
        c_f = PSY.get_constant_term(loss_from)
        a_t = _get_quadratic_term(loss_to)
        b_t = PSY.get_proportional_term(loss_to)
        c_t = PSY.get_constant_term(loss_to)
        for t in time_steps
            i_pos_t = use_linear_loss ? i_pos_var[name, t] : nothing
            i_neg_t = use_linear_loss ? i_neg_var[name, t] : nothing
            loss_ft = _quadratic_converter_loss_expr(
                a_f, b_f, c_f, i_sq_expr[name, t], i_pos_t, i_neg_t;
                use_linear_loss = use_linear_loss,
            )
            loss_tf = _quadratic_converter_loss_expr(
                a_t, b_t, c_t, i_sq_expr[name, t], i_pos_t, i_neg_t;
                use_linear_loss = use_linear_loss,
            )
            cons_ft[name, t] = JuMP.@constraint(
                jump_model,
                p_ft[name, t] == vi_expr[name, t] + loss_ft,
            )
            cons_tf[name, t] = JuMP.@constraint(
                jump_model,
                p_tf[name, t] == -vi_expr_to[name, t] + loss_tf,
            )
        end
    end
    return
end

# PQ capability:  p_k^2 + q_k^2 <= S_k^2 (NLP) or octagonal polygon (MIP).
function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCVSCReactiveCapabilityConstraint},
    devices::Union{
        Vector{PSY.TwoTerminalVSCLine},
        IS.FlattenIteratorWrapper{PSY.TwoTerminalVSCLine},
    },
    ::DeviceModel{PSY.TwoTerminalVSCLine, HVDCTwoTerminalVSC},
    ::NetworkModel{<:AbstractPowerModel},
)
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    jump_model = get_jump_model(container)

    p_ft = get_variable(container, FlowActivePowerFromToVariable, PSY.TwoTerminalVSCLine)
    p_tf = get_variable(container, FlowActivePowerToFromVariable, PSY.TwoTerminalVSCLine)
    q_f = get_variable(container, HVDCReactivePowerFromVariable, PSY.TwoTerminalVSCLine)
    q_t = get_variable(container, HVDCReactivePowerToVariable, PSY.TwoTerminalVSCLine)

    cons_f = add_constraints_container!(
        container, HVDCVSCReactiveCapabilityConstraint, PSY.TwoTerminalVSCLine,
        names, time_steps; meta = "from",
    )
    cons_t = add_constraints_container!(
        container, HVDCVSCReactiveCapabilityConstraint, PSY.TwoTerminalVSCLine,
        names, time_steps; meta = "to",
    )

    for d in devices
        name = PSY.get_name(d)
        s_f = PSY.get_rating_from(d)
        s_t = PSY.get_rating_to(d)
        for t in time_steps
            cons_f[name, t] = JuMP.@constraint(
                jump_model,
                p_ft[name, t]^2 + q_f[name, t]^2 <= s_f^2,
            )
            cons_t[name, t] = JuMP.@constraint(
                jump_model,
                p_tf[name, t]^2 + q_t[name, t]^2 <= s_t^2,
            )
        end
    end
    return
end

function add_constraints!(
    container::OptimizationContainer,
    ::Type{HVDCVSCReactiveCapabilityConstraint},
    devices::Union{
        Vector{PSY.TwoTerminalVSCLine},
        IS.FlattenIteratorWrapper{PSY.TwoTerminalVSCLine},
    },
    ::DeviceModel{PSY.TwoTerminalVSCLine, HVDCTwoTerminalVSCMIP},
    ::NetworkModel{<:AbstractPowerModel},
)
    time_steps = get_time_steps(container)
    names = [PSY.get_name(d) for d in devices]
    jump_model = get_jump_model(container)

    p_ft = get_variable(container, FlowActivePowerFromToVariable, PSY.TwoTerminalVSCLine)
    p_tf = get_variable(container, FlowActivePowerToFromVariable, PSY.TwoTerminalVSCLine)
    q_f = get_variable(container, HVDCReactivePowerFromVariable, PSY.TwoTerminalVSCLine)
    q_t = get_variable(container, HVDCReactivePowerToVariable, PSY.TwoTerminalVSCLine)

    diag_tags = ("from_pp", "from_pn", "from_np", "from_nn",
        "to_pp", "to_pn", "to_np", "to_nn")
    axis_tags = ("from_p_ub", "from_p_lb", "from_q_ub", "from_q_lb",
        "to_p_ub", "to_p_lb", "to_q_ub", "to_q_lb")
    cons = Dict{String, Any}()
    for tag in (diag_tags..., axis_tags...)
        cons[tag] = add_constraints_container!(
            container, HVDCVSCReactiveCapabilityConstraint, PSY.TwoTerminalVSCLine,
            names, time_steps; meta = tag,
        )
    end

    inv_sqrt2 = 1.0 / sqrt(2.0)
    for d in devices
        name = PSY.get_name(d)
        rating_f = PSY.get_rating_from(d)
        rating_t = PSY.get_rating_to(d)
        diag_f = rating_f * inv_sqrt2 * 2.0
        diag_t = rating_t * inv_sqrt2 * 2.0
        for t in time_steps
            cons["from_pp"][name, t] =
                JuMP.@constraint(jump_model, p_ft[name, t] + q_f[name, t] <= diag_f)
            cons["from_pn"][name, t] =
                JuMP.@constraint(jump_model, p_ft[name, t] - q_f[name, t] <= diag_f)
            cons["from_np"][name, t] =
                JuMP.@constraint(jump_model, -p_ft[name, t] + q_f[name, t] <= diag_f)
            cons["from_nn"][name, t] =
                JuMP.@constraint(jump_model, -p_ft[name, t] - q_f[name, t] <= diag_f)
            cons["to_pp"][name, t] =
                JuMP.@constraint(jump_model, p_tf[name, t] + q_t[name, t] <= diag_t)
            cons["to_pn"][name, t] =
                JuMP.@constraint(jump_model, p_tf[name, t] - q_t[name, t] <= diag_t)
            cons["to_np"][name, t] =
                JuMP.@constraint(jump_model, -p_tf[name, t] + q_t[name, t] <= diag_t)
            cons["to_nn"][name, t] =
                JuMP.@constraint(jump_model, -p_tf[name, t] - q_t[name, t] <= diag_t)

            cons["from_p_ub"][name, t] =
                JuMP.@constraint(jump_model, p_ft[name, t] <= rating_f)
            cons["from_p_lb"][name, t] =
                JuMP.@constraint(jump_model, -p_ft[name, t] <= rating_f)
            cons["from_q_ub"][name, t] =
                JuMP.@constraint(jump_model, q_f[name, t] <= rating_f)
            cons["from_q_lb"][name, t] =
                JuMP.@constraint(jump_model, -q_f[name, t] <= rating_f)
            cons["to_p_ub"][name, t] =
                JuMP.@constraint(jump_model, p_tf[name, t] <= rating_t)
            cons["to_p_lb"][name, t] =
                JuMP.@constraint(jump_model, -p_tf[name, t] <= rating_t)
            cons["to_q_ub"][name, t] =
                JuMP.@constraint(jump_model, q_t[name, t] <= rating_t)
            cons["to_q_lb"][name, t] =
                JuMP.@constraint(jump_model, -q_t[name, t] <= rating_t)
        end
    end
    return
end

####################### VSC defaults #########################################

function get_default_time_series_names(
    ::Type{PSY.TwoTerminalVSCLine},
    ::Type{<:AbstractTwoTerminalVSCFormulation},
)
    return Dict{Type{<:TimeSeriesParameter}, String}()
end

function get_default_attributes(
    ::Type{PSY.TwoTerminalVSCLine},
    ::Type{HVDCTwoTerminalVSC},
)
    return Dict{String, Any}("use_linear_loss" => false)
end

function get_default_attributes(
    ::Type{PSY.TwoTerminalVSCLine},
    ::Type{HVDCTwoTerminalVSCMIP},
)
    return Dict{String, Any}("use_linear_loss" => true)
end
