########################### Interfaces ########################################################
get_variable_key(variabletype, d) = error("Not Implemented")

get_expression_type_for_reserve(_, y::Type{<:PSY.Component}, z) =
    error("`get_expression_type_for_reserve` must be implemented for $y and $z")

does_subcomponent_exist(T::PSY.Component, S::Type{<:PSY.Component}) =
    error("`does_subcomponent_exist` must be implemented for $T and subcomponent type $S")

get_default_on_variable(::PSY.Component) = OnVariable()
