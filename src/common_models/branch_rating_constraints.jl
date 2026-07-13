"""
Squared apparent-power rate-limit RHS: `rating^2`.

The single source of truth for the right-hand side of `p² + q² ≤ rating²`
apparent-power constraints (and `cr² + ci² ≤ c_rating²` current-magnitude limits).
Callers pass the already-resolved rating value:

  - static path: a `Float64` rating (e.g. from `branch_rating`) → hand-check `2.0 → 4.0`.
  - time-series path: the `param * mult` product (rating_factor · rating), an
    apparent-power value that must be squared to match the static `rating²` RHS.

Squaring here — rather than at each `@constraint` site — is the point: the historical
shipped-bug class is a bare `rating` (not `rating²`) on an apparent-power constraint.
Keeping the exponent in one function makes every rate limit route through the same math.
"""
_rate_rhs_squared(rating) = rating^2

"""
Fill a symmetric, time-varying rating bound into pre-created `lb`/`ub` constraint
containers, for a single branch `name`:

    flow[name, t] <=  rating[t]
    flow[name, t] >= -rating[t]

with `rating[t] = param[t] * mult[name, t]` (a parameterized rating that varies per
time step). This is the parameterized-RHS counterpart to the scalar-limit
`add_slacked_range_constraints!`: the RHS is a time series, so it is not covered by
the scalar range helper. The `lb`/`ub` containers must already exist (the static
path creates them over all branch names); this only fills the entries for `name`.
The slack-relaxed variant takes the slack containers as trailing arguments.
"""
function add_parameterized_rating_constraints!(
    container::OptimizationContainer,
    con_ub::DenseAxisArray,
    con_lb::DenseAxisArray,
    flow::DenseAxisArray,
    name::AbstractString,
    param,
    mult::DenseAxisArray,
)
    jump_model = get_jump_model(container)
    for t in get_time_steps(container)
        rating = param[t] * mult[name, t]
        con_ub[name, t] = JuMP.@constraint(jump_model, flow[name, t] <= rating)
        con_lb[name, t] = JuMP.@constraint(jump_model, flow[name, t] >= -rating)
    end
    return
end

function add_parameterized_rating_constraints!(
    container::OptimizationContainer,
    con_ub::DenseAxisArray,
    con_lb::DenseAxisArray,
    flow::DenseAxisArray,
    name::AbstractString,
    param,
    mult::DenseAxisArray,
    slack_ub::DenseAxisArray,
    slack_lb::DenseAxisArray,
)
    jump_model = get_jump_model(container)
    for t in get_time_steps(container)
        rating = param[t] * mult[name, t]
        con_ub[name, t] =
            JuMP.@constraint(jump_model, flow[name, t] - slack_ub[name, t] <= rating)
        con_lb[name, t] =
            JuMP.@constraint(jump_model, flow[name, t] + slack_lb[name, t] >= -rating)
    end
    return
end
