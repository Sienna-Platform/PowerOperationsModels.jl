"""
Helpers for asserting how a reserve's deployed fraction reaches the model. A reserve with a
deployed-fraction profile contributes through a product variable `y` whose defining row
`y - fraction(t) * award == 0` carries the fraction as the coefficient on the award.
"""

function deployed_product_rows(container, ::Type{U}, ::Type{V}, reserve) where {U, V}
    return IOM.get_constraint(
        container,
        IOM.ParameterizedProductConstraint,
        V,
        POM._deployed_product_meta(U, reserve),
    )
end

function deployed_product_variables(container, ::Type{U}, ::Type{V}, reserve) where {U, V}
    return IOM.get_variable(
        container,
        IOM.ParameterizedProductVariable,
        V,
        POM._deployed_product_meta(U, reserve),
    )
end

"The deployed fraction the model applies to `award` at `t`, read from its product row."
deployed_fraction_in_model(container, U, V, reserve, device_name, award, t) =
    -JuMP.normalized_coefficient(
        deployed_product_rows(container, U, V, reserve)[device_name, t],
        award,
    )

has_deployed_products(container, U, V, reserve) = IOM.has_container_key(
    container,
    IOM.ParameterizedProductVariable,
    V,
    POM._deployed_product_meta(U, reserve),
)
