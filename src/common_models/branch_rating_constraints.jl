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
