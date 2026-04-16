########################### Interfaces ########################################################
get_variable_key(variabletype, d) = error("Not Implemented")

#! format: off
# FIXME: do we need these? We define a default method in IOM too.
get_multiplier_value(::Type{<:StartupCostParameter}, ::PSY.Device, ::Type{<:AbstractDeviceFormulation}) = 1.0
get_multiplier_value(::Type{<:ShutdownCostParameter}, ::PSY.Device, ::Type{<:AbstractDeviceFormulation}) = 1.0
get_multiplier_value(::Type{<:AbstractCostAtMinParameter}, ::PSY.Device, ::Type{<:AbstractDeviceFormulation}) = 1.0
get_multiplier_value(::Type{<:AbstractPiecewiseLinearSlopeParameter}, ::PSY.Device, ::Type{<:AbstractDeviceFormulation}) = 1.0
get_multiplier_value(::Type{<:AbstractPiecewiseLinearBreakpointParameter}, ::PSY.Device, ::Type{<:AbstractDeviceFormulation}) = 1.0
#! format: on

get_expression_type_for_reserve(_, y::Type{<:PSY.Component}, z) =
    error("`get_expression_type_for_reserve` must be implemented for $y and $z")

requires_initialization(::AbstractDeviceFormulation) = false

does_subcomponent_exist(T::PSY.Component, S::Type{<:PSY.Component}) =
    error("`does_subcomponent_exist` must be implemented for $T and subcomponent type $S")

get_default_on_variable(::PSY.Component) = OnVariable
get_default_on_parameter(::PSY.Component) = OnStatusParameter
