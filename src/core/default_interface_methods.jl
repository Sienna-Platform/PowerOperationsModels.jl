########################### Interfaces ########################################################
get_variable_key(variabletype, d) = error("Not Implemented")

#! format: off
# Defaults for the OCC `ObjectiveFunctionParameter` types. Needed because POM's catch-all
# in `core/interfaces.jl` errors for any parameter type that isn't a `TimeSeriesParameter`.
get_multiplier_value(::Type{StartupCostParameter}, ::PSY.Device, ::Type{<:AbstractDeviceFormulation}) = 1.0
get_multiplier_value(::Type{ShutdownCostParameter}, ::PSY.Device, ::Type{<:AbstractDeviceFormulation}) = 1.0
get_multiplier_value(::Type{<:AbstractCostAtMinParameter}, ::PSY.Device, ::Type{<:AbstractDeviceFormulation}) = 1.0
get_multiplier_value(::Type{<:AbstractPiecewiseLinearSlopeParameter}, ::PSY.Device, ::Type{<:AbstractDeviceFormulation}) = 1.0
get_multiplier_value(::Type{<:AbstractPiecewiseLinearBreakpointParameter}, ::PSY.Device, ::Type{<:AbstractDeviceFormulation}) = 1.0
#! format: on

get_expression_type_for_reserve(_, y::Type{<:PSY.Component}, z) =
    error("`get_expression_type_for_reserve` must be implemented for $y and $z")

does_subcomponent_exist(T::PSY.Component, S::Type{<:PSY.Component}) =
    error("`does_subcomponent_exist` must be implemented for $T and subcomponent type $S")

get_default_on_variable(::PSY.Component) = OnVariable()
get_default_on_parameter(::PSY.Component) = OnStatusParameter()
